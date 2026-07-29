import type { AgentTool, AgentToolResult, AgentToolUpdateCallback } from "@earendil-works/pi-agent-core"
import { Type } from "@earendil-works/pi-ai"
import { validateToolArguments } from "@earendil-works/pi-ai/compat"

import { isBuiltInToolError } from "../tools/outcome.js"
import { createCodeModeWorkerSpawner, type CodeModeWorkerExit, type CodeModeWorkerProcess } from "./process.js"
import {
  CodeModeProtocolDecoder,
  CodeModeProtocolWriter,
  codeModeProtocolVersion,
  isCodeModeToolName,
  maxCodeBytes,
  maxCodeModeErrorBytes,
  maxCodeModeToolNames,
  validateCodeModeJson,
  validateWorkerMessage,
  type CodeModeHostMessage,
  type CodeModeJson,
  type CodeModeWorkerMessage
} from "./protocol.js"
import { codeModeToolContract } from "./tool-contract.js"
import { type CodeModeCall, type CodeModeDetails } from "./trace.js"

export { isCodeModeDetails, type CodeModeCall, type CodeModeDetails } from "./trace.js"

const maxResultScalars = 50 * 1024
const maxTraceStringScalars = 4_096
const maxTraceScalars = 8_192
const maxTraceNodes = 128
const maxTraceDepth = 8
const maxDescriptionBytes = 64 * 1024
const maxWorkerOutputBytes = 64 * 1024

const parameters = Type.Object({
  code: Type.String({
    minLength: 1,
    maxLength: maxCodeBytes,
    description: "JavaScript async arrow function to execute"
  })
})

interface CodeModeTimeouts {
  readonly startupMs: number
  readonly executionMs: number
  readonly shutdownMs: number
  readonly nestedSettlementMs: number
}

const defaultTimeouts: CodeModeTimeouts = Object.freeze({
  startupMs: 10_000,
  executionMs: 120_000,
  shutdownMs: 1_000,
  nestedSettlementMs: 2_000
})

interface CodeExecutionResult {
  readonly type: "completed" | "failed"
  readonly result?: CodeModeJson
  readonly error?: string
  readonly calls: readonly CodeModeCall[]
  readonly logs: readonly string[]
  readonly terminate: boolean
}

type ExecutionState =
  | { readonly type: "starting" }
  | { readonly type: "running" }
  | { readonly type: "final" }
  | { readonly type: "settled" }

export class CodeMode {
  readonly #spawn: () => CodeModeWorkerProcess
  readonly #timeouts: CodeModeTimeouts

  constructor(cwd: string, workerCommand: readonly string[]) {
    const spawn = createCodeModeWorkerSpawner(workerCommand)
    this.#spawn = () => spawn(cwd)
    this.#timeouts = defaultTimeouts
  }

  createTool(tools: readonly AgentTool[]): AgentTool<typeof parameters, CodeModeDetails> {
    if (tools.some(tool => tool.name === "code" || tool.name === "then")) {
      throw new Error("The tool names code and then are reserved for native code mode")
    }
    if (tools.length > maxCodeModeToolNames) {
      throw new Error(`Code mode cannot admit more than ${maxCodeModeToolNames} tools`)
    }
    if (tools.some(tool => !isCodeModeToolName(tool.name))) {
      throw new Error("Code mode requires non-empty bounded tool names without control characters")
    }
    if (new Set(tools.map(tool => tool.name)).size !== tools.length) {
      throw new Error("Code mode requires unique admitted tool names")
    }
    const catalog = Object.freeze([...tools])
    const byName = new Map(catalog.map(tool => [tool.name, tool]))
    return {
      name: "code",
      label: "code",
      description: codeToolDescription(catalog),
      parameters,
      executionMode: "sequential",
      execute: async (toolCallId, input, signal, onUpdate) => {
        if (Buffer.byteLength(input.code) > maxCodeBytes) {
          const error = `Code must not exceed ${maxCodeBytes} bytes`
          return {
            content: [{ type: "text", text: `Code execution failed: ${error}` }],
            details: { type: "code_mode", outcome: "error", error, calls: [], logs: [] }
          }
        }
        let process: CodeModeWorkerProcess
        try {
          process = this.#spawn()
        } catch (cause) {
          if (signal?.aborted) throw cause
          const error = boundedErrorText(errorMessage(cause))
          return {
            content: [{ type: "text", text: `Code execution failed: ${error}` }],
            details: { type: "code_mode", outcome: "error", error, calls: [], logs: [] }
          }
        }
        const execution = new CodeExecution(process, this.#timeouts, toolCallId, input.code, byName, signal, onUpdate)
        const result = await execution.run()
        if (result.type === "failed") {
          const error = boundedErrorText(result.error ?? "Code execution failed")
          return {
            content: [{ type: "text", text: `Code execution failed: ${error}` }],
            details: { type: "code_mode", outcome: "error", error, calls: result.calls, logs: result.logs },
            ...(result.terminate ? { terminate: true } : {})
          }
        }
        return {
          content: [{ type: "text", text: formatResult(result.result, result.logs) }],
          details: { type: "code_mode", outcome: "success", calls: result.calls, logs: result.logs },
          ...(result.terminate ? { terminate: true } : {})
        }
      }
    }
  }
}

class CodeExecution {
  readonly #process: CodeModeWorkerProcess
  readonly #writer: CodeModeProtocolWriter
  readonly #timeouts: CodeModeTimeouts
  readonly #toolCallId: string
  readonly #code: string
  readonly #tools: ReadonlyMap<string, AgentTool>
  readonly #parentSignal: AbortSignal | undefined
  readonly #onUpdate: AgentToolUpdateCallback<CodeModeDetails> | undefined
  readonly #controller = new AbortController()
  readonly #calls: CodeModeCall[] = []
  readonly #callIds = new Set<number>()
  readonly #ready = deferred<void>()
  readonly #final = deferred<Extract<CodeModeWorkerMessage, { type: "completed" | "failed" }>>()
  readonly #failure = deferred<never>()
  readonly #timers = new Set<ReturnType<typeof setTimeout>>()
  #state: ExecutionState = { type: "starting" }
  #dispatchQueue = Promise.resolve()
  #terminate = false

  constructor(
    process: CodeModeWorkerProcess,
    timeouts: CodeModeTimeouts,
    toolCallId: string,
    code: string,
    tools: ReadonlyMap<string, AgentTool>,
    parentSignal: AbortSignal | undefined,
    onUpdate: AgentToolUpdateCallback<CodeModeDetails> | undefined
  ) {
    this.#process = process
    this.#writer = new CodeModeProtocolWriter(process.input)
    this.#timeouts = timeouts
    this.#toolCallId = toolCallId
    this.#code = code
    this.#tools = tools
    this.#parentSignal = parentSignal
    this.#onUpdate = onUpdate
  }

  async run(): Promise<CodeExecutionResult> {
    const abort = () => this.#controller.abort(this.#parentSignal?.reason ?? new Error("Code execution aborted"))
    if (this.#parentSignal?.aborted) abort()
    else this.#parentSignal?.addEventListener("abort", abort, { once: true })

    const stdout = new BoundedOutput(this.#process.stdout)
    const stderr = new BoundedOutput(this.#process.stderr)
    const protocol = this.#readProtocol()
    const exit = this.#process.exited
    let outcome: CodeExecutionResult | undefined
    let cancellation: Error | undefined
    try {
      const start: CodeModeHostMessage = {
        version: codeModeProtocolVersion,
        type: "start",
        code: this.#code,
        tools: Object.freeze([...this.#tools.keys()])
      }
      await this.#writer.send(start)
      await Promise.race([
        this.#ready.promise,
        this.#failure.promise,
        processExited(exit),
        aborted(this.#controller.signal),
        this.#deadline(this.#timeouts.startupMs, "Code-mode worker startup timed out")
      ])
      if (this.#state.type !== "running") throw new Error("Code-mode worker did not enter running state")

      const final = await Promise.race([
        this.#final.promise,
        this.#failure.promise,
        processExited(exit),
        aborted(this.#controller.signal),
        this.#deadline(this.#timeouts.executionMs, "Code execution timed out")
      ])
      await settle(this.#dispatchQueue, this.#timeouts.nestedSettlementMs, "Nested code-mode tools did not settle")
      const calls = snapshotCalls(this.#calls)
      outcome =
        final.type === "failed"
          ? { type: "failed", error: final.error, calls, logs: final.logs, terminate: this.#terminate }
          : {
              type: "completed",
              ...(final.result === undefined ? {} : { result: final.result }),
              calls,
              logs: final.logs,
              terminate: this.#terminate
            }
    } catch (cause) {
      this.#controller.abort(cause)
      await settle(
        this.#dispatchQueue,
        this.#timeouts.nestedSettlementMs,
        "Nested code-mode tools did not settle"
      ).catch(() => undefined)
      this.#abortCalls()
      if (this.#parentSignal?.aborted) cancellation = abortError(this.#controller.signal)
      else {
        outcome = {
          type: "failed",
          error: boundedErrorText(errorMessage(cause)),
          calls: snapshotCalls(this.#calls),
          logs: [],
          terminate: this.#terminate
        }
      }
    } finally {
      const workerFinished = this.#state.type === "final"
      this.#state = { type: "settled" }
      for (const timer of this.#timers) clearTimeout(timer)
      this.#timers.clear()
      this.#controller.abort()
      this.#parentSignal?.removeEventListener("abort", abort)
      this.#writer.dispose()
      this.#process.closeInput()
      if (!workerFinished) this.#process.terminate(false)
      if (!(await exitsWithin(exit, this.#timeouts.shutdownMs))) {
        this.#process.terminate(true)
        await exitsWithin(exit, this.#timeouts.shutdownMs)
      }
      this.#process.dispose()
      await settle(
        Promise.allSettled([protocol, stdout.settled, stderr.settled]),
        this.#timeouts.shutdownMs,
        "Code-mode streams did not settle"
      ).catch(() => undefined)
    }

    if (cancellation) throw cancellation
    if (!outcome) throw new Error("Code execution settled without an outcome")
    const diagnostic = stderr.text || stdout.text
    if (outcome.type === "failed" && diagnostic) {
      return {
        ...outcome,
        error: boundedErrorText(`${outcome.error ?? "Code execution failed"}\nWorker: ${diagnostic}`)
      }
    }
    return outcome
  }

  #deadline(milliseconds: number, message: string): Promise<never> {
    return new Promise<never>((_, reject) => {
      const timer = setTimeout(() => {
        this.#timers.delete(timer)
        reject(new Error(message))
      }, milliseconds)
      this.#timers.add(timer)
    })
  }

  async #readProtocol(): Promise<void> {
    const decoder = new CodeModeProtocolDecoder(validateWorkerMessage)
    try {
      for await (const chunk of this.#process.protocol) {
        for (const message of decoder.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk))) {
          this.#accept(message)
        }
      }
      decoder.end()
      if (this.#state.type === "starting" || this.#state.type === "running") {
        this.#failure.reject(new Error("Code-mode worker protocol ended before execution completed"))
      }
    } catch (cause) {
      this.#failure.reject(cause)
    }
  }

  #accept(message: CodeModeWorkerMessage): void {
    switch (message.type) {
      case "ready":
        if (this.#state.type !== "starting") throw new Error("Unexpected code-mode ready message")
        this.#state = { type: "running" }
        this.#ready.resolve()
        break
      case "tool_call":
        if (this.#state.type !== "running") throw new Error("Code-mode tool call arrived outside execution")
        this.#queueCall(message)
        break
      case "completed":
      case "failed":
        if (this.#state.type !== "running") throw new Error("Code-mode result arrived outside execution")
        this.#state = { type: "final" }
        if (message.type === "failed") this.#controller.abort(new Error(message.error))
        this.#final.resolve(message)
        break
      default:
        assertNever(message)
    }
  }

  #queueCall(message: Extract<CodeModeWorkerMessage, { type: "tool_call" }>): void {
    if (this.#callIds.has(message.id)) {
      this.#failure.reject(new Error(`Duplicate code-mode call ID: ${message.id}`))
      return
    }
    this.#callIds.add(message.id)
    const startedAt = Date.now()
    const traceArguments = projectTraceArguments(message.name, message.arguments)
    const callIndex =
      this.#calls.push({ state: "running", id: message.id, name: message.name, arguments: traceArguments, startedAt }) -
      1
    this.#publishProgress()

    const operation = this.#dispatchQueue.then(async () => {
      if (this.#controller.signal.aborted) throw abortError(this.#controller.signal)
      const tool = this.#tools.get(message.name)
      if (!tool) throw new Error(`Tool ${message.name} not found`)
      const prepared = tool.prepareArguments ? tool.prepareArguments(message.arguments) : message.arguments
      if (!isRecord(prepared)) throw new Error(`Tool ${message.name} requires object arguments`)
      const validated = validateToolArguments(tool, {
        type: "toolCall",
        id: `${this.#toolCallId}:code:${message.id}`,
        name: message.name,
        arguments: prepared
      })
      const onUpdate: AgentToolUpdateCallback<unknown> = partial => {
        const call = this.#calls[callIndex]
        if (!call || call.state !== "running") return
        this.#calls[callIndex] = { ...call, preview: boundedText(toolResultText(partial)) }
        this.#publishProgress()
      }
      const toolCallId = `${this.#toolCallId}:code:${message.id}`
      const contract = codeModeToolContract(tool)
      const invocation = contract
        ? await contract.execute(toolCallId, validated, this.#controller.signal, onUpdate)
        : { result: await tool.execute(toolCallId, validated, this.#controller.signal, onUpdate), value: undefined }
      const text = toolResultText(invocation.result)
      if (isBuiltInToolError(message.name, invocation.result.details)) throw new Error(text)
      if (invocation.result.terminate) this.#terminate = true
      return {
        text,
        value: contract ? validateCodeModeJson(invocation.value) : text,
        terminate: invocation.result.terminate === true
      }
    })
    this.#dispatchQueue = operation.then(
      () => undefined,
      () => undefined
    )
    void operation.then(
      async result => {
        if (this.#state.type === "settled") return undefined
        this.#calls[callIndex] = {
          state: "succeeded",
          id: message.id,
          name: message.name,
          arguments: traceArguments,
          startedAt,
          durationMs: Math.max(0, Date.now() - startedAt),
          result: boundedText(result.text)
        }
        this.#publishProgress()
        if (this.#state.type !== "running") return undefined
        try {
          await this.#writer.send({
            version: codeModeProtocolVersion,
            type: "tool_result",
            id: message.id,
            value: result.value,
            ...(result.terminate ? { terminate: true } : {})
          })
        } catch (cause) {
          await this.#sendCallError(message.id, errorMessage(cause))
        }
        return undefined
      },
      async cause => {
        if (this.#state.type === "settled") return undefined
        const error = boundedErrorText(errorMessage(cause))
        const common = {
          id: message.id,
          name: message.name,
          arguments: traceArguments,
          startedAt,
          durationMs: Math.max(0, Date.now() - startedAt)
        }
        this.#calls[callIndex] = this.#controller.signal.aborted
          ? { state: "aborted", ...common }
          : { state: "failed", ...common, error }
        this.#publishProgress()
        await this.#sendCallError(message.id, error)
        return undefined
      }
    )
  }

  async #sendCallError(id: number, error: string): Promise<void> {
    if (this.#state.type !== "running") return
    try {
      await this.#writer.send({
        version: codeModeProtocolVersion,
        type: "tool_error",
        id,
        error: boundedErrorText(error)
      })
    } catch (cause) {
      this.#failure.reject(cause)
    }
  }

  #publishProgress(): void {
    if (!this.#onUpdate) return
    const running = this.#calls.findLast(call => call.state === "running")
    this.#onUpdate({
      content: [{ type: "text", text: running ? `Running ${running.name}` : "Running code" }],
      details: { type: "code_mode", outcome: "progress", calls: snapshotCalls(this.#calls), logs: [] }
    })
  }

  #abortCalls(): void {
    const now = Date.now()
    for (let index = 0; index < this.#calls.length; index++) {
      const call = this.#calls[index]
      if (!call || call.state !== "running") continue
      this.#calls[index] = {
        state: "aborted",
        id: call.id,
        name: call.name,
        arguments: call.arguments,
        startedAt: call.startedAt,
        durationMs: Math.max(0, now - call.startedAt)
      }
    }
  }
}

function toolResultText(result: AgentToolResult<unknown>): string {
  return result.content.map(part => (part.type === "text" ? part.text : `[image: ${part.mimeType}]`)).join("\n")
}

function codeToolDescription(tools: readonly AgentTool[]): string {
  const prefix = `Execute JavaScript that orchestrates the other Zi tools.

Every direct tool is also available as zi.<tool>(input) with the same input fields; use zi["tool-name"] for punctuation.
Successful calls return the declared JSON-compatible JavaScript value directly; values are already decoded.
Tool failures throw Error and may be handled with try/catch. Console logs are retained when execution completes, not streamed live.
Use code for data-dependent loops, filtering, branching, aggregation, and multi-call extension/API workflows.
Prefer direct read, edit, write, and bash calls for ordinary coding operations that do not benefit from orchestration.
Await every zi tool call before returning. Unawaited calls fail the execution.
Do not use TypeScript syntax, imports, fetch, process, Bun, require, or ambient filesystem APIs.

Available APIs:
declare const zi: {
`
  const suffix = "\n};"
  const blocks: string[] = []
  let bytes = Buffer.byteLength(prefix) + Buffer.byteLength(suffix)
  let omitted = 0
  for (const tool of tools) {
    const description = tool.description.replaceAll("*/", "* /").replaceAll(/\s+/g, " ").trim()
    const outputSchema = codeModeToolContract(tool)?.outputSchema ?? { type: "string" }
    const block = `  /** ${description} */\n  ${typescriptProperty(tool.name)}: (input: ${schemaType(tool.parameters, 0)}) => Promise<${schemaType(outputSchema, 0)}>;\n`
    const blockBytes = Buffer.byteLength(block)
    if (bytes + blockBytes > maxDescriptionBytes - 256) {
      omitted++
      continue
    }
    blocks.push(block)
    bytes += blockBytes
  }
  const omission = omitted > 0 ? `\n  /** ${omitted} additional tools retain their direct tool schemas. */` : ""
  return `${prefix}${blocks.join("")}${omission}${suffix}`
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

function projectTraceArguments(name: string, value: CodeModeJson): CodeModeJson {
  if (!isRecord(value)) return traceValue(value)
  if (name === "write") {
    const output: Record<string, CodeModeJson> = {}
    if (typeof value.path === "string") output.path = traceValue(value.path)
    if (typeof value.content === "string") output.contentBytes = Buffer.byteLength(value.content)
    return Object.freeze(output)
  }
  if (name === "edit") {
    const output: Record<string, CodeModeJson> = {}
    if (typeof value.path === "string") output.path = traceValue(value.path)
    if (Array.isArray(value.edits)) output.operations = value.edits.length
    return Object.freeze(output)
  }
  return traceValue(value)
}

function traceValue(value: unknown): CodeModeJson {
  const budget = { nodes: maxTraceNodes, scalars: maxTraceScalars }
  return traceJson(value, budget, 0)
}

function traceJson(value: unknown, budget: { nodes: number; scalars: number }, depth: number): CodeModeJson {
  if (budget.nodes-- <= 0) return "… collection limit"
  if (depth >= maxTraceDepth) return "… depth limit"
  if (value === null || typeof value === "boolean") return value
  if (typeof value === "number") return Number.isFinite(value) ? value : null
  if (typeof value === "string") {
    const limit = Math.min(maxTraceStringScalars, budget.scalars)
    const selected = boundedScalars(value, limit, true)
    budget.scalars -= selected.scalars
    return selected.text
  }
  if (Array.isArray(value)) {
    const output: CodeModeJson[] = []
    for (const item of value) {
      if (budget.nodes <= 0) {
        output.push("… collection limit")
        break
      }
      output.push(traceJson(item, budget, depth + 1))
    }
    return Object.freeze(output)
  }
  if (typeof value === "bigint") return value.toString()
  if (typeof value === "undefined") return "undefined"
  if (typeof value === "symbol") return value.description ?? "symbol"
  if (typeof value === "function") return value.name || "function"
  if (!isRecord(value)) return "unsupported value"
  const output: Record<string, CodeModeJson> = {}
  for (const [key, item] of Object.entries(value)) {
    if (budget.nodes <= 0) {
      output["…"] = "collection limit"
      break
    }
    const projectedKey = boundedScalars(key, 256, true).text
    if (Object.hasOwn(output, projectedKey)) continue
    output[projectedKey] = traceJson(item, budget, depth + 1)
  }
  return Object.freeze(output)
}

function snapshotCalls(calls: readonly CodeModeCall[]): readonly CodeModeCall[] {
  return Object.freeze(calls.map(call => Object.freeze({ ...call })))
}

function formatResult(result: CodeModeJson | undefined, logs: readonly string[]): string {
  const text =
    typeof result === "string"
      ? result
      : result === undefined
        ? "Code completed without a result."
        : JSON.stringify(result, null, 2)
  const output = logs.length > 0 ? `Console output:\n${logs.join("\n")}\n\nResult:\n${text}` : text
  return boundedScalars(output, maxResultScalars, false).text
}

function boundedText(value: string): string {
  return boundedScalars(value, maxTraceStringScalars, false).text
}

function boundedErrorText(value: string): string {
  return boundedUtf8(value, maxCodeModeErrorBytes)
}

function boundedUtf8(value: string, limit: number): string {
  let output = ""
  let bytes = 0
  for (const scalar of value) {
    const scalarBytes = Buffer.byteLength(scalar)
    if (bytes + scalarBytes > limit) break
    output += scalar
    bytes += scalarBytes
  }
  return output
}

function boundedScalars(
  value: string,
  limit: number,
  ellipsis: boolean
): { readonly text: string; readonly scalars: number } {
  let text = ""
  let scalars = 0
  for (const scalar of value) {
    if (scalars === limit) return { text: ellipsis ? `${text}…` : text, scalars }
    text += scalar
    scalars++
  }
  return { text, scalars }
}

class BoundedOutput {
  readonly #chunks: Buffer[] = []
  readonly settled: Promise<void>
  #bytes = 0

  constructor(stream: NodeJS.ReadableStream) {
    this.settled = this.#read(stream)
  }

  get text(): string {
    return Buffer.concat(this.#chunks, this.#bytes).toString("utf8").trim()
  }

  async #read(stream: NodeJS.ReadableStream): Promise<void> {
    for await (const chunk of stream) {
      if (this.#bytes >= maxWorkerOutputBytes) continue
      const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk)
      const selected = buffer.subarray(0, maxWorkerOutputBytes - this.#bytes)
      this.#chunks.push(selected)
      this.#bytes += selected.byteLength
    }
  }
}

function processExited(exit: Promise<CodeModeWorkerExit>): Promise<never> {
  return exit.then(value => {
    const detail = value.error?.message ?? `exit ${value.code ?? "null"}${value.signal ? ` (${value.signal})` : ""}`
    throw new Error(`Code-mode worker exited before completion: ${detail}`)
  })
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

async function exitsWithin(exit: Promise<CodeModeWorkerExit>, milliseconds: number): Promise<boolean> {
  let timer: ReturnType<typeof setTimeout> | undefined
  try {
    return await Promise.race([
      exit.then(() => true),
      new Promise<false>(resolve => {
        timer = setTimeout(() => resolve(false), milliseconds)
      })
    ])
  } finally {
    if (timer) clearTimeout(timer)
  }
}

async function settle<T>(operation: Promise<T>, milliseconds: number, message: string): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined
  try {
    return await Promise.race([
      operation,
      new Promise<never>((_, reject) => {
        timer = setTimeout(() => reject(new Error(message)), milliseconds)
      })
    ])
  } finally {
    if (timer) clearTimeout(timer)
  }
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
  return { promise, resolve, reject }
}

function typescriptProperty(value: string): string {
  return /^[A-Za-z_$][A-Za-z0-9_$]*$/.test(value) ? value : JSON.stringify(value)
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

function assertNever(value: never): never {
  throw new Error(`Unknown code-mode state: ${String(value)}`)
}
