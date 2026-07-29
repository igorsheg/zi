// PROTOTYPE: remove this module after the direct-vs-code-mode agent evaluation.

import type { AgentTool, AgentToolResult } from "@earendil-works/pi-agent-core"
import { Type } from "@earendil-works/pi-ai"
import { validateToolArguments } from "@earendil-works/pi-ai/compat"
import quickJsVariant from "@jitl/quickjs-singlefile-mjs-release-sync"
import {
  newQuickJSWASMModuleFromVariant,
  type QuickJSContext,
  type QuickJSDeferredPromise,
  type QuickJSHandle
} from "quickjs-emscripten-core"

import { isBuiltInToolError } from "./tools/index.js"

const maxCodeBytes = 256 * 1024
const maxCalls = 64
const maxLogs = 32
const maxLogScalars = 4_096
const maxResultScalars = 50 * 1024
const memoryLimitBytes = 64 * 1024 * 1024
const stackLimitBytes = 512 * 1024
const guestBurstMs = 500
const executionTimeoutMs = 120_000

const parameters = Type.Object({
  code: Type.String({
    minLength: 1,
    maxLength: maxCodeBytes,
    description: "JavaScript async arrow function to execute"
  })
})

export type CodeModePrototypeCall =
  | { readonly state: "running"; readonly name: string }
  | { readonly state: "succeeded"; readonly name: string }
  | { readonly state: "failed"; readonly name: string; readonly error: string }

export type CodeModePrototypeDetails =
  | {
      readonly type: "code_mode_prototype"
      readonly outcome: "success"
      readonly calls: readonly CodeModePrototypeCall[]
      readonly logs: readonly string[]
    }
  | {
      readonly type: "code_mode_prototype"
      readonly outcome: "error"
      readonly error: string
      readonly calls: readonly CodeModePrototypeCall[]
      readonly logs: readonly string[]
    }

interface CodeRunResult {
  readonly outcome: "success" | "error"
  readonly result?: unknown
  readonly error?: string
  readonly calls: readonly CodeModePrototypeCall[]
  readonly logs: readonly string[]
}

interface SandboxToolResult {
  readonly text: string
  readonly details: unknown
}

export class CodeModePrototype {
  readonly #module = newQuickJSWASMModuleFromVariant(quickJsVariant)

  createTool(tools: readonly AgentTool[]): AgentTool<typeof parameters, CodeModePrototypeDetails> {
    const catalog = Object.freeze([...tools])
    const byName = new Map(catalog.map(tool => [tool.name, tool]))
    return {
      name: "code",
      label: "code",
      description: codeToolDescription(catalog),
      parameters,
      executionMode: "sequential",
      execute: async (toolCallId, input, signal) => {
        const run = await this.#execute(toolCallId, input.code, byName, signal)
        if (run.outcome === "error") {
          const error = run.error ?? "Code execution failed"
          return {
            content: [{ type: "text", text: `Code execution failed: ${error}` }],
            details: { type: "code_mode_prototype", outcome: "error", error, calls: run.calls, logs: run.logs }
          }
        }
        return {
          content: [{ type: "text", text: formatResult(run.result, run.logs) }],
          details: { type: "code_mode_prototype", outcome: "success", calls: run.calls, logs: run.logs }
        }
      }
    }
  }

  async #execute(
    toolCallId: string,
    code: string,
    tools: ReadonlyMap<string, AgentTool>,
    parentSignal: AbortSignal | undefined
  ): Promise<CodeRunResult> {
    const QuickJS = await this.#module
    const runtime = QuickJS.newRuntime()
    runtime.setMemoryLimit(memoryLimitBytes)
    runtime.setMaxStackSize(stackLimitBytes)
    let guestDeadline = Date.now() + guestBurstMs
    const controller = new AbortController()
    const abort = () => controller.abort(parentSignal?.reason ?? new Error("Code execution aborted"))
    if (parentSignal?.aborted) abort()
    else parentSignal?.addEventListener("abort", abort, { once: true })
    const timeout = setTimeout(() => controller.abort(new Error("Code execution timed out")), executionTimeoutMs)
    runtime.setInterruptHandler(() => controller.signal.aborted || Date.now() >= guestDeadline)

    const context = runtime.newContext()
    const pending = new Map<number, QuickJSDeferredPromise>()
    const calls: CodeModePrototypeCall[] = []
    const logs: string[] = []
    const fatal = deferred<never>()
    let queue = Promise.resolve()
    let ended = false

    const fail = (cause: unknown): void => {
      if (!fatal.settled) fatal.reject(cause instanceof Error ? cause : new Error(String(cause)))
    }
    const executeJobs = (): void => {
      if (ended) return
      guestDeadline = Date.now() + guestBurstMs
      const jobs = runtime.executePendingJobs()
      if (!jobs.error) return
      const message = quickJsError(context, jobs.error)
      jobs.error.dispose()
      fail(new Error(message))
    }
    const settleCall = (id: number, envelope: unknown): void => {
      if (ended) return
      const pendingCall = pending.get(id)
      if (!pendingCall) return
      pending.delete(id)
      const value = context.newString(JSON.stringify(envelope))
      pendingCall.resolve(value)
      value.dispose()
      executeJobs()
    }
    const dispatch = (id: number, name: string, arguments_: unknown): void => {
      const callIndex = calls.push({ state: "running", name }) - 1
      const operation = queue.then(async () => {
        if (controller.signal.aborted) throw abortError(controller.signal)
        const tool = tools.get(name)
        if (!tool) throw new Error(`Tool ${name} not found`)
        const prepared = tool.prepareArguments ? tool.prepareArguments(arguments_) : arguments_
        if (!isRecord(prepared)) throw new Error(`Tool ${name} requires object arguments`)
        const validated = validateToolArguments(tool, {
          type: "toolCall",
          id: `${toolCallId}:nested:${id}`,
          name,
          arguments: prepared
        })
        const result = await tool.execute(`${toolCallId}:nested:${id}`, validated, controller.signal)
        if (isBuiltInToolError(name, result.details)) throw new Error(toolResultText(result))
        return sandboxToolResult(result)
      })
      queue = operation.then(
        () => undefined,
        () => undefined
      )
      void operation.then(
        result => {
          calls[callIndex] = { state: "succeeded", name }
          settleCall(id, { result })
          return undefined
        },
        cause => {
          const error = errorMessage(cause)
          calls[callIndex] = { state: "failed", name, error }
          settleCall(id, { error })
          return undefined
        }
      )
    }

    try {
      installHostBridge(
        context,
        pending,
        logs,
        () => ended,
        (id, name, arguments_) => dispatch(id, name, arguments_)
      )

      const bridge = context.evalCode(sandboxPrelude())
      if (bridge.error) {
        const message = quickJsError(context, bridge.error)
        bridge.error.dispose()
        return { outcome: "error", error: message, calls, logs }
      }
      bridge.value.dispose()

      guestDeadline = Date.now() + guestBurstMs
      const evaluation = context.evalCode(`(${stripCodeFences(code)})()`)
      if (evaluation.error) {
        const message = quickJsError(context, evaluation.error)
        evaluation.error.dispose()
        return { outcome: "error", error: message, calls, logs }
      }

      const promiseHandle = evaluation.value
      const guest = context.resolvePromise(promiseHandle)
      promiseHandle.dispose()
      executeJobs()
      const result = await Promise.race([guest, fatal.promise, aborted(controller.signal)])
      if (result.error) {
        const message = quickJsError(context, result.error)
        result.error.dispose()
        return { outcome: "error", error: message, calls, logs }
      }
      const value = context.dump(result.value)
      result.value.dispose()
      return { outcome: "success", result: value, calls, logs }
    } catch (cause) {
      if (controller.signal.aborted) {
        if (parentSignal?.aborted) throw abortError(controller.signal)
        return { outcome: "error", error: errorMessage(controller.signal.reason), calls, logs }
      }
      return { outcome: "error", error: errorMessage(cause), calls, logs }
    } finally {
      ended = true
      clearTimeout(timeout)
      parentSignal?.removeEventListener("abort", abort)
      for (const pendingCall of pending.values()) pendingCall.dispose()
      pending.clear()
      context.dispose()
      runtime.dispose()
    }
  }
}

export function isCodeModePrototypeDetails(value: unknown): value is CodeModePrototypeDetails {
  return (
    isRecord(value) &&
    value.type === "code_mode_prototype" &&
    (value.outcome === "success" || value.outcome === "error")
  )
}

function installHostBridge(
  context: QuickJSContext,
  pending: Map<number, QuickJSDeferredPromise>,
  logs: string[],
  ended: () => boolean,
  dispatch: (id: number, name: string, arguments_: unknown) => void
): void {
  let nextCallId = 0
  const hostCall = context.newFunction("__ziHostCall", (nameHandle, argumentsHandle) => {
    const name = context.getString(nameHandle)
    if (ended()) return context.newString(JSON.stringify({ error: "Code execution ended" }))
    if (nextCallId >= maxCalls) {
      return context.newString(JSON.stringify({ error: `Code cannot make more than ${maxCalls} tool calls` }))
    }
    const id = nextCallId++
    let input: unknown
    try {
      input = JSON.parse(context.getString(argumentsHandle))
    } catch {
      return context.newString(JSON.stringify({ error: "Tool arguments must be JSON serializable" }))
    }
    const promise = context.newPromise()
    pending.set(id, promise)
    dispatch(id, name, input)
    return promise.handle
  })
  hostCall.consume(handle => context.setProp(context.global, "__ziHostCall", handle))

  const hostLog = context.newFunction("__ziHostLog", valueHandle => {
    if (logs.length >= maxLogs) return
    logs.push(Array.from(context.getString(valueHandle)).slice(0, maxLogScalars).join(""))
  })
  hostLog.consume(handle => context.setProp(context.global, "__ziHostLog", handle))
}

function sandboxPrelude(): string {
  return `
(() => {
  const callHost = globalThis.__ziHostCall;
  const writeLog = globalThis.__ziHostLog;
  globalThis.zi = new Proxy(Object.create(null), {
    get: (_target, name) => async (arguments_) => {
      const response = JSON.parse(await callHost(String(name), JSON.stringify(arguments_ ?? {})));
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

function sandboxToolResult(result: AgentToolResult<unknown>): SandboxToolResult {
  return { text: toolResultText(result), details: result.details }
}

function toolResultText(result: AgentToolResult<unknown>): string {
  return result.content.map(part => (part.type === "text" ? part.text : `[image: ${part.mimeType}]`)).join("\n")
}

function codeToolDescription(tools: readonly AgentTool[]): string {
  const declarations = tools
    .map(tool => {
      const description = tool.description.replaceAll("*/", "* /").replaceAll(/\s+/g, " ").trim()
      return `  /** ${description} */\n  ${typescriptProperty(tool.name)}: (input: ${schemaType(tool.parameters, 0)}) => Promise<ZiToolResult>;`
    })
    .join("\n")
  return `Execute JavaScript that orchestrates Zi tools.

Available APIs:
interface ZiToolResult { text: string; details: unknown }
declare const zi: {
${declarations}
};

Write one JavaScript async arrow function and return its final result.
Complete data-dependent workflows inside one execution when possible: list, loop, parse, filter, branch, and perform the final action in JavaScript instead of returning intermediate data for another model turn.
Tool responses have { text, details }; use JSON.parse(response.text) when a tool returns JSON.
Do not use TypeScript syntax, markdown fences, imports, fetch, process, Bun, require, or filesystem APIs.
All effects must go through zi.<tool>(input). Tool failures reject and may be handled with try/catch.

Example:
async () => {
  const file = await zi.read({ path: "package.json" });
  return file.text;
}`
}

function schemaType(schema: unknown, depth: number): string {
  if (!isRecord(schema) || depth >= 12) return "unknown"
  if ("const" in schema) return JSON.stringify(schema.const)
  if (Array.isArray(schema.enum)) return schema.enum.map(value => JSON.stringify(value)).join(" | ") || "never"
  const alternatives = Array.isArray(schema.anyOf)
    ? schema.anyOf
    : Array.isArray(schema.oneOf)
      ? schema.oneOf
      : undefined
  if (alternatives) return alternatives.map(value => schemaType(value, depth + 1)).join(" | ")
  if (schema.type === "array") return `Array<${schemaType(schema.items, depth + 1)}>`
  if (schema.type === "object" || isRecord(schema.properties)) {
    const properties = isRecord(schema.properties) ? schema.properties : {}
    const required = new Set(Array.isArray(schema.required) ? schema.required.filter(isString) : [])
    const fields = Object.entries(properties).map(([name, value]) => {
      const description = isRecord(value) && typeof value.description === "string" ? value.description : undefined
      const comment = description ? `/** ${description.replaceAll("*/", "* /").replaceAll(/\s+/g, " ").trim()} */ ` : ""
      return `${comment}${typescriptProperty(name)}${required.has(name) ? "" : "?"}: ${schemaType(value, depth + 1)}`
    })
    return `{ ${fields.join("; ")} }`
  }
  if (schema.type === "string") return "string"
  if (schema.type === "number" || schema.type === "integer") return "number"
  if (schema.type === "boolean") return "boolean"
  if (schema.type === "null") return "null"
  return "unknown"
}

function typescriptProperty(value: string): string {
  return /^[A-Za-z_$][A-Za-z0-9_$]*$/.test(value) ? value : JSON.stringify(value)
}

function stripCodeFences(code: string): string {
  const trimmed = code.trim()
  const match = /^```(?:js|javascript)?\s*\n([\s\S]*?)```$/.exec(trimmed)
  return (match?.[1] ?? trimmed).trim()
}

function formatResult(result: unknown, logs: readonly string[]): string {
  let text: string
  if (typeof result === "string") text = result
  else if (result === undefined) text = "Code completed without a result."
  else {
    try {
      text = JSON.stringify(result, null, 2)
    } catch {
      text = "Result is not JSON serializable."
    }
  }
  const sections = logs.length > 0 ? [`Console output:\n${logs.join("\n")}`, `Result:\n${text}`] : [text]
  return Array.from(sections.join("\n\n")).slice(0, maxResultScalars).join("")
}

function quickJsError(context: QuickJSContext, handle: QuickJSHandle): string {
  const value = context.dump(handle)
  return isRecord(value) && typeof value.message === "string" ? value.message : String(value)
}

function aborted(signal: AbortSignal): Promise<never> {
  if (signal.aborted) return Promise.reject(abortError(signal))
  return new Promise<never>((_, reject) => {
    signal.addEventListener("abort", () => reject(abortError(signal)), { once: true })
  })
}

function abortError(signal: AbortSignal): Error {
  return signal.reason instanceof Error ? signal.reason : new Error("Code execution aborted")
}

function deferred<T>() {
  let settled = false
  let resolve!: (value: T | PromiseLike<T>) => void
  let reject!: (cause?: unknown) => void
  const promise = new Promise<T>((resolvePromise, rejectPromise) => {
    resolve = value => {
      if (settled) return
      settled = true
      resolvePromise(value)
    }
    reject = cause => {
      if (settled) return
      settled = true
      rejectPromise(cause)
    }
  })
  return {
    promise,
    resolve,
    reject,
    get settled() {
      return settled
    }
  }
}

function errorMessage(cause: unknown): string {
  return cause instanceof Error ? cause.message : String(cause)
}

function isString(value: unknown): value is string {
  return typeof value === "string"
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}
