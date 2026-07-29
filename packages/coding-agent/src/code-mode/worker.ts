import { closeSync, writeSync } from "node:fs"

import quickJsVariant from "@jitl/quickjs-singlefile-mjs-release-sync"
import {
  newQuickJSWASMModuleFromVariant,
  type QuickJSContext,
  type QuickJSDeferredPromise,
  type QuickJSHandle
} from "quickjs-emscripten-core"

import { normalizeCode } from "./normalize.js"
import {
  CodeModeProtocolDecoder,
  encodeCodeModeFrame,
  maxCodeModeCalls,
  maxCodeModeLogBytes,
  maxCodeModeLogs,
  validateCodeModeJson,
  validateHostMessage,
  type CodeModeHostMessage,
  type CodeModeWorkerMessage
} from "./protocol.js"

const memoryLimitBytes = 64 * 1024 * 1024
const stackLimitBytes = 512 * 1024
const guestBurstMs = 500

type WorkerRunState = { readonly type: "running" } | { readonly type: "settled" }

interface WorkerRun {
  readonly settled: Promise<void>
  accept(message: Exclude<CodeModeHostMessage, { type: "start" }>): void
  cancel(): void
}

export async function runCodeModeWorkerFromStdio(): Promise<void> {
  const decoder = new CodeModeProtocolDecoder(validateHostMessage)
  let run: WorkerRun | undefined
  try {
    for await (const chunk of process.stdin) {
      for (const message of decoder.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk))) {
        if (message.type === "start") {
          if (run) throw new Error("Code-mode worker accepts one start message")
          // The protocol admits exactly one start, so initialization is intentionally serial.
          // eslint-disable-next-line no-await-in-loop
          run = await startRun(message)
        } else {
          if (!run) throw new Error("Code-mode worker requires start before control messages")
          run.accept(message)
        }
      }
    }
    decoder.end()
    if (!run) throw new Error("Code-mode worker input ended before start")
    await run.settled
  } finally {
    run?.cancel()
    closeSync(3)
  }
}

async function startRun(start: Extract<CodeModeHostMessage, { type: "start" }>): Promise<WorkerRun> {
  const QuickJS = await newQuickJSWASMModuleFromVariant(quickJsVariant)
  const runtime = QuickJS.newRuntime()
  runtime.setMemoryLimit(memoryLimitBytes)
  runtime.setMaxStackSize(stackLimitBytes)
  let guestDeadline = Date.now() + guestBurstMs
  runtime.setInterruptHandler(() => Date.now() >= guestDeadline)
  const context = runtime.newContext()
  const tools = new Set(start.tools)
  const pending = new Map<number, QuickJSDeferredPromise>()
  const logs: string[] = []
  let nextCallId = 0
  let terminateRequested = false
  let state: WorkerRunState = { type: "running" }
  let resolveSettled!: () => void
  const settled = new Promise<void>(resolve => {
    resolveSettled = resolve
  })

  const finish = (message: Exclude<CodeModeWorkerMessage, { type: "ready" | "tool_call" }>): void => {
    if (state.type === "settled") return
    state = { type: "settled" }
    try {
      try {
        send(message)
      } catch (cause) {
        send({ version: 1, type: "failed", error: `Could not encode sandbox result: ${errorMessage(cause)}`, logs })
      }
    } catch (cause) {
      process.stderr.write(`Could not send code-mode result: ${errorMessage(cause)}\n`)
    } finally {
      for (const promise of pending.values()) promise.dispose()
      pending.clear()
      context.dispose()
      runtime.dispose()
      resolveSettled()
    }
  }
  const executeJobs = (): void => {
    if (state.type !== "running") return
    guestDeadline = Date.now() + guestBurstMs
    const jobs = runtime.executePendingJobs()
    if (!jobs.error) return
    const error = quickJsError(context, jobs.error)
    jobs.error.dispose()
    finish({ version: 1, type: "failed", error, logs })
  }
  const resolveCall = (id: number, envelope: unknown): void => {
    if (state.type !== "running") return
    const promise = pending.get(id)
    if (!promise) {
      finish({ version: 1, type: "failed", error: `Unknown code-mode tool response ID: ${id}`, logs })
      return
    }
    pending.delete(id)
    const value = context.newString(JSON.stringify(envelope))
    promise.resolve(value)
    value.dispose()
    executeJobs()
  }

  const hostCall = context.newFunction("__ziHostCall", (nameHandle, argumentsHandle) => {
    const name = context.getString(nameHandle)
    if (state.type !== "running") return context.newString(JSON.stringify({ error: "Code execution ended" }))
    if (terminateRequested) {
      return context.newString(JSON.stringify({ error: "A previous tool requested turn termination" }))
    }
    if (!tools.has(name)) return context.newString(JSON.stringify({ error: `Tool ${name} not found` }))
    if (nextCallId >= maxCodeModeCalls) {
      return context.newString(JSON.stringify({ error: `Code cannot make more than ${maxCodeModeCalls} tool calls` }))
    }
    let input: unknown
    try {
      input = JSON.parse(context.getString(argumentsHandle))
    } catch {
      return context.newString(JSON.stringify({ error: "Tool arguments must be JSON serializable" }))
    }
    const id = nextCallId++
    const promise = context.newPromise()
    pending.set(id, promise)
    try {
      send({ version: 1, type: "tool_call", id, name, arguments: validateCodeModeJson(input) })
    } catch (cause) {
      pending.delete(id)
      promise.dispose()
      return context.newString(JSON.stringify({ error: errorMessage(cause) }))
    }
    return promise.handle
  })
  hostCall.consume(handle => context.setProp(context.global, "__ziHostCall", handle))

  const hostLog = context.newFunction("__ziHostLog", valueHandle => {
    if (logs.length >= maxCodeModeLogs) return
    const value = Buffer.from(context.getString(valueHandle))
    logs.push(value.subarray(0, maxCodeModeLogBytes).toString())
  })
  hostLog.consume(handle => context.setProp(context.global, "__ziHostLog", handle))

  try {
    const prelude = context.evalCode(sandboxPrelude())
    if (prelude.error) {
      const error = quickJsError(context, prelude.error)
      prelude.error.dispose()
      finish({ version: 1, type: "failed", error, logs })
      return { settled, accept: () => {}, cancel: () => {} }
    }
    prelude.value.dispose()
    send({ version: 1, type: "ready" })

    guestDeadline = Date.now() + guestBurstMs
    const normalized = normalizeCode(start.code)
    const evaluation = context.evalCode(`(async () => {
  const value = await (${normalized})();
  return JSON.stringify({ defined: value !== undefined, value });
})()`)
    if (evaluation.error) {
      const error = quickJsError(context, evaluation.error)
      evaluation.error.dispose()
      finish({ version: 1, type: "failed", error, logs })
      return { settled, accept: () => {}, cancel: () => {} }
    }
    const promiseHandle = evaluation.value
    const result = context.resolvePromise(promiseHandle)
    promiseHandle.dispose()
    executeJobs()
    void result.then(outcome => {
      if (state.type !== "running") {
        if ("value" in outcome) outcome.value.dispose()
        else outcome.error.dispose()
        return undefined
      }
      if (outcome.error) {
        const error = quickJsError(context, outcome.error)
        outcome.error.dispose()
        finish({ version: 1, type: "failed", error, logs })
        return undefined
      }
      const encoded = context.getString(outcome.value)
      outcome.value.dispose()
      if (pending.size > 0) {
        finish({
          version: 1,
          type: "failed",
          error: `Code returned with ${pending.size} unawaited tool ${pending.size === 1 ? "call" : "calls"}`,
          logs
        })
        return undefined
      }
      try {
        const decoded: unknown = JSON.parse(encoded)
        if (!isRecord(decoded) || typeof decoded.defined !== "boolean") throw new Error("Invalid sandbox result")
        finish({
          version: 1,
          type: "completed",
          ...(decoded.defined ? { result: validateCodeModeJson(decoded.value) } : {}),
          logs
        })
      } catch (cause) {
        finish({ version: 1, type: "failed", error: errorMessage(cause), logs })
      }
      return undefined
    })
  } catch (cause) {
    finish({ version: 1, type: "failed", error: errorMessage(cause), logs })
  }

  return {
    settled,
    accept(message) {
      if (state.type !== "running") return
      switch (message.type) {
        case "tool_result":
          if (message.result.terminate) terminateRequested = true
          resolveCall(message.id, { result: message.result })
          break
        case "tool_error":
          resolveCall(message.id, { error: message.error })
          break
        default:
          assertNever(message)
      }
    },
    cancel() {
      finish({ version: 1, type: "failed", error: "Code execution cancelled", logs })
    }
  }
}

function sandboxPrelude(): string {
  return `
(() => {
  const callHost = globalThis.__ziHostCall;
  const writeLog = globalThis.__ziHostLog;
  globalThis.zi = new Proxy(Object.create(null), {
    get: (_target, name) => async (input) => {
      const response = JSON.parse(await callHost(String(name), JSON.stringify(input ?? {})));
      if (response.error) throw new Error(response.error);
      return response.result;
    }
  });
  globalThis.console = Object.freeze({
    log: (...values) => writeLog(values.map(String).join(" ")),
    warn: (...values) => writeLog("[warn] " + values.map(String).join(" ")),
    error: (...values) => writeLog("[error] " + values.map(String).join(" "))
  });
  delete globalThis.__ziHostCall;
  delete globalThis.__ziHostLog;
})();
`
}

function send(message: CodeModeWorkerMessage): void {
  const frame = encodeCodeModeFrame(message)
  let offset = 0
  while (offset < frame.byteLength) {
    const written = writeSync(3, frame, offset)
    if (written === 0) throw new Error("Code-mode protocol output stopped accepting bytes")
    offset += written
  }
}

function quickJsError(context: QuickJSContext, handle: QuickJSHandle): string {
  const value = context.dump(handle)
  return isRecord(value) && typeof value.message === "string" ? value.message : String(value)
}

function errorMessage(cause: unknown): string {
  return cause instanceof Error ? cause.message : String(cause)
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}

function assertNever(value: never): never {
  throw new Error(`Unknown code-mode worker message: ${String(value)}`)
}
