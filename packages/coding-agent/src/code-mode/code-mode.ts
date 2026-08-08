import type { AgentTool, AgentToolResult, AgentToolUpdateCallback } from "@earendil-works/pi-agent-core"
import { Type } from "@earendil-works/pi-ai"
import { validateToolArguments } from "@earendil-works/pi-ai/compat"

import type { ProcessTreeTracker } from "../processes/process-tree.js"
import type { SessionManager } from "../session-manager.js"
import { isBuiltInToolError } from "../tools/outcome.js"
import { createCodeModeWorkerSpawner, type CodeModeWorkerExit, type CodeModeWorkerProcess } from "./process.js"
import {
  CodeModeProtocolDecoder,
  CodeModeProtocolWriter,
  codeModeProtocolVersion,
  isCodeModeToolName,
  maxCodeBytes,
  maxCodeModeCalls,
  maxCodeModeErrorBytes,
  maxCodeModeStateBytes,
  maxCodeModeToolNames,
  validateCodeModeJson,
  validateCodeModeState,
  validateWorkerMessage,
  type CodeModeHostMessage,
  type CodeModeJson,
  type CodeModeState,
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

type CodeExecutionFailure =
  | { readonly kind: "cell"; readonly error: string }
  | { readonly kind: "nested_tool"; readonly tool: string; readonly error: string }
  | { readonly kind: "nested_settlement"; readonly error: string }
  | { readonly kind: "runtime"; readonly error: string }

type CodeExecutionResult = {
  readonly calls: readonly CodeModeCall[]
  readonly logs: readonly string[]
  readonly terminate: boolean
  readonly recoverWorker: boolean
} & (
  | { readonly type: "completed"; readonly result?: CodeModeJson; readonly state?: CodeModeState }
  | { readonly type: "failed"; readonly failure: CodeExecutionFailure }
)

type ExecutionState = { readonly type: "running" } | { readonly type: "final" } | { readonly type: "settled" }

type WorkerState =
  | { readonly type: "starting" }
  | { readonly type: "ready" }
  | {
      readonly type: "running"
      readonly executionId: number
      readonly accept: (message: Extract<CodeModeWorkerMessage, { type: "tool_call" }>) => void
      readonly final: ReturnType<typeof deferred<Extract<CodeModeWorkerMessage, { type: "completed" | "failed" }>>>
    }
  | { readonly type: "disposed" }

export class CodeMode {
  readonly #spawn: () => CodeModeWorkerProcess
  readonly #sessionManager: SessionManager | undefined
  #worker: CodeWorker | undefined
  #startingWorker: CodeWorker | undefined
  #workerStart: Promise<CodeWorker> | undefined
  #workerReset: Promise<void> | undefined
  #generation = 0
  #executionId = 0
  #state: CodeModeState
  #disposed = false
  #disposal: Promise<void> | undefined

  constructor(
    cwd: string,
    workerCommand: readonly string[],
    sessionManager?: SessionManager,
    processTreeTracker?: ProcessTreeTracker
  ) {
    const spawn = createCodeModeWorkerSpawner(workerCommand, processTreeTracker)
    this.#spawn = () => spawn(cwd)
    this.#sessionManager = sessionManager
    const restored = sessionManager?.latestActiveProgramState()?.data
    this.#state = restored === undefined ? {} : validateCodeModeState(restored)
  }

  createTool(tools: readonly AgentTool[]): AgentTool<typeof parameters, CodeModeDetails> {
    if (tools.some(tool => tool.name === "code" || tool.name === "then")) {
      throw new Error("The tool names code and then are reserved for native code mode")
    }
    if (tools.length > maxCodeModeToolNames)
      throw new Error(`Code mode cannot admit more than ${maxCodeModeToolNames} tools`)
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
        if (Buffer.byteLength(input.code) > maxCodeBytes)
          return codeFailure(`Code must not exceed ${maxCodeBytes} bytes`)
        if (this.#disposed) return codeFailure("Programmatic runtime is disposed")
        let worker: CodeWorker
        try {
          worker = await this.#ensureWorker(signal)
        } catch (cause) {
          if (signal?.aborted) throw cause
          return codeFailure(errorMessage(cause))
        }
        const execution = new CodeExecution(
          worker,
          toolCallId,
          this.#executionId++,
          input.code,
          byName,
          this.#state,
          signal,
          onUpdate
        )
        let result: CodeExecutionResult
        try {
          result = await execution.run()
        } catch (cause) {
          await this.#resetWorker(worker)
          throw cause
        }
        if (result.recoverWorker) await this.#resetWorker(worker)
        if (result.type === "failed") return resultFailure(result)
        try {
          if (result.state) this.#commitState(result.state)
        } catch (cause) {
          return stateCommitFailure(result, cause)
        }
        return {
          content: [{ type: "text", text: formatResult(result.result, result.logs) }],
          details: { type: "code_mode", outcome: "success", calls: result.calls, logs: result.logs },
          ...(result.terminate ? { terminate: true } : {})
        }
      }
    }
  }

  dispose(): Promise<void> {
    if (this.#disposal) return this.#disposal
    this.#disposed = true
    const disposal = this.#disposeOwnedWorker()
    this.#disposal = disposal
    return disposal
  }

  async #disposeOwnedWorker(): Promise<void> {
    const starting = this.#workerStart
    const worker = this.#worker ?? this.#startingWorker
    this.#worker = undefined
    this.#startingWorker = undefined
    this.#workerStart = undefined
    if (worker) await worker.dispose()
    await starting?.catch(() => undefined)
    await this.#workerReset?.catch(() => undefined)
  }

  async #ensureWorker(signal?: AbortSignal): Promise<CodeWorker> {
    if (this.#disposed) throw new Error("Programmatic runtime is disposed")
    await this.#workerReset
    if (this.#disposed) throw new Error("Programmatic runtime is disposed")
    if (this.#worker) return this.#worker
    if (!this.#workerStart) {
      const worker = new CodeWorker(this.#spawn(), ++this.#generation)
      this.#startingWorker = worker
      const start = worker
        .start()
        .then(() => {
          if (this.#disposed) throw new Error("Programmatic runtime was disposed during startup")
          this.#worker = worker
          return worker
        })
        .catch(async cause => {
          await worker.dispose()
          throw cause
        })
      this.#workerStart = start
      void start
        .finally(() => {
          if (this.#startingWorker === worker) this.#startingWorker = undefined
          if (this.#workerStart === start) this.#workerStart = undefined
        })
        .catch(() => {})
    }
    return raceWithAbort(this.#workerStart, signal)
  }

  async #resetWorker(worker: CodeWorker): Promise<void> {
    if (this.#worker === worker) this.#worker = undefined
    const reset = worker.dispose()
    this.#workerReset = reset
    try {
      await reset
    } finally {
      if (this.#workerReset === reset) this.#workerReset = undefined
    }
  }

  #commitState(state: CodeModeState): void {
    const next = validateCodeModeState(state)
    if (JSON.stringify(next) === JSON.stringify(this.#state)) return
    this.#sessionManager?.appendProgramState(next)
    this.#state = next
  }
}

class CodeWorker {
  readonly #process: CodeModeWorkerProcess
  readonly #generation: number
  readonly #writer: CodeModeProtocolWriter
  readonly #ready = deferred<void>()
  readonly #failure = deferred<never>()
  readonly #stdout: BoundedOutput
  readonly #stderr: BoundedOutput
  readonly #protocol: Promise<void>
  #state: WorkerState = { type: "starting" }

  constructor(process: CodeModeWorkerProcess, generation: number) {
    this.#process = process
    this.#generation = generation
    this.#writer = new CodeModeProtocolWriter(process.input)
    this.#stdout = new BoundedOutput(process.stdout)
    this.#stderr = new BoundedOutput(process.stderr)
    this.#protocol = this.#readProtocol()
  }

  async start(): Promise<void> {
    const startupDeadline = createDeadline(defaultTimeouts.startupMs, "Code-mode worker startup timed out")
    try {
      await Promise.race([
        this.#process.admitted,
        this.#process.containmentFailure,
        processExited(this.#process.exited),
        startupDeadline.promise
      ])
      await this.#writer.send({ version: codeModeProtocolVersion, type: "initialize", generation: this.#generation })
      await Promise.race([
        this.#ready.promise,
        this.#failure.promise,
        this.#process.containmentFailure,
        processExited(this.#process.exited),
        startupDeadline.promise
      ])
      if (this.#state.type !== "ready") throw new Error("Code-mode worker did not become ready")
    } finally {
      startupDeadline.dispose()
    }
  }

  execute(
    executionId: number,
    code: string,
    tools: readonly string[],
    state: CodeModeState,
    accept: (message: Extract<CodeModeWorkerMessage, { type: "tool_call" }>) => void
  ): Promise<Extract<CodeModeWorkerMessage, { type: "completed" | "failed" }>> {
    if (this.#state.type !== "ready") return Promise.reject(new Error("Code-mode worker is not ready"))
    const final = deferred<Extract<CodeModeWorkerMessage, { type: "completed" | "failed" }>>()
    this.#state = { type: "running", executionId, accept, final }
    return this.#writer
      .send({
        version: codeModeProtocolVersion,
        type: "execute",
        generation: this.#generation,
        executionId,
        code,
        tools,
        state
      })
      .then(() => Promise.race([final.promise, this.#failure.promise, this.#process.containmentFailure]))
  }

  send(message: Extract<CodeModeHostMessage, { type: "tool_result" | "tool_error" }>): Promise<void> {
    if (
      this.#state.type !== "running" ||
      message.generation !== this.#generation ||
      message.executionId !== this.#state.executionId
    )
      return Promise.reject(new Error("Stale code-mode tool response"))
    return this.#writer.send(message)
  }

  get diagnostic(): string {
    return this.#stderr.text || this.#stdout.text
  }

  async settledDiagnostic(): Promise<string> {
    await settle(
      Promise.allSettled([this.#stdout.settled, this.#stderr.settled]),
      100,
      "Code-mode worker diagnostics did not settle"
    ).catch(() => undefined)
    return this.diagnostic
  }

  async dispose(): Promise<void> {
    if (this.#state.type === "disposed") return
    this.#state = { type: "disposed" }
    this.#failure.reject(new Error("Code-mode worker disposed"))
    this.#writer.dispose()
    this.#process.closeInput()
    this.#process.terminate(false)
    if (!(await exitsWithin(this.#process.exited, defaultTimeouts.shutdownMs))) this.#process.terminate(true)
    let treeFailure: unknown
    try {
      await this.#process.terminateTree()
    } catch (cause) {
      treeFailure = cause
    }
    const exited = await exitsWithin(this.#process.exited, defaultTimeouts.shutdownMs)
    this.#process.dispose()
    let streamFailure: unknown
    try {
      await settle(
        Promise.allSettled([this.#protocol, this.#stdout.settled, this.#stderr.settled]),
        defaultTimeouts.shutdownMs,
        "Code-mode worker streams did not settle"
      )
    } catch (cause) {
      streamFailure = cause
    }
    if (treeFailure) throw treeFailure
    if (!exited) throw new Error(`Code-mode worker process ${this.#process.pid} did not exit during disposal`)
    if (streamFailure) throw streamFailure
  }

  async #readProtocol(): Promise<void> {
    const decoder = new CodeModeProtocolDecoder(validateWorkerMessage)
    try {
      for await (const chunk of this.#process.protocol) {
        for (const message of decoder.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk))) this.#accept(message)
      }
      decoder.end()
      if (this.#state.type !== "disposed") this.#failure.reject(new Error("Code-mode worker protocol ended"))
    } catch (cause) {
      this.#failure.reject(cause)
    }
  }

  #accept(message: CodeModeWorkerMessage): void {
    if (message.generation !== this.#generation) throw new Error("Stale code-mode worker generation")
    if (message.type === "ready") {
      if (this.#state.type !== "starting") throw new Error("Unexpected code-mode ready message")
      this.#state = { type: "ready" }
      this.#ready.resolve()
      return
    }
    if (message.type === "tool_call") {
      if (this.#state.type !== "running" || message.executionId !== this.#state.executionId) {
        throw new Error("Code-mode tool call arrived outside execution")
      }
      this.#state.accept(message)
      return
    }
    if (this.#state.type !== "running" || message.executionId !== this.#state.executionId) {
      throw new Error("Code-mode result arrived outside execution")
    }
    const final = this.#state.final
    this.#state = { type: "ready" }
    final.resolve(message)
  }
}

class CodeExecution {
  readonly #worker: CodeWorker
  readonly #toolCallId: string
  readonly #executionId: number
  readonly #code: string
  readonly #tools: ReadonlyMap<string, AgentTool>
  readonly #programState: CodeModeState
  readonly #parentSignal: AbortSignal | undefined
  readonly #onUpdate: AgentToolUpdateCallback<CodeModeDetails> | undefined
  readonly #controller = new AbortController()
  readonly #calls: CodeModeCall[] = []
  readonly #callIds = new Set<number>()
  #state: ExecutionState = { type: "running" }
  #dispatchQueue = Promise.resolve()
  #terminate = false

  constructor(
    worker: CodeWorker,
    toolCallId: string,
    executionId: number,
    code: string,
    tools: ReadonlyMap<string, AgentTool>,
    programState: CodeModeState,
    parentSignal: AbortSignal | undefined,
    onUpdate: AgentToolUpdateCallback<CodeModeDetails> | undefined
  ) {
    this.#worker = worker
    this.#toolCallId = toolCallId
    this.#executionId = executionId
    this.#code = code
    this.#tools = tools
    this.#programState = programState
    this.#parentSignal = parentSignal
    this.#onUpdate = onUpdate
  }

  async run(): Promise<CodeExecutionResult> {
    const abort = () => this.#controller.abort(this.#parentSignal?.reason ?? new Error("Code execution aborted"))
    if (this.#parentSignal?.aborted) abort()
    else this.#parentSignal?.addEventListener("abort", abort, { once: true })
    const executionDeadline = createDeadline(defaultTimeouts.executionMs, "Code execution timed out")
    try {
      let final: Extract<CodeModeWorkerMessage, { type: "completed" | "failed" }>
      try {
        final = await Promise.race([
          this.#worker.execute(this.#executionId, this.#code, [...this.#tools.keys()], this.#programState, message =>
            this.#queueCall(message)
          ),
          aborted(this.#controller.signal),
          executionDeadline.promise
        ])
      } catch (cause) {
        return await this.#recoverFailure("runtime", cause)
      }
      this.#state = { type: "final" }
      if (final.type === "failed") this.#controller.abort(new Error(final.error))
      try {
        await settle(this.#dispatchQueue, defaultTimeouts.nestedSettlementMs, "Nested code-mode tools did not settle")
      } catch (cause) {
        return await this.#recoverFailure("nested_settlement", cause)
      }
      if (final.type === "failed") this.#abortCalls()
      const calls = snapshotCalls(this.#calls)
      const common = { calls, logs: final.logs, terminate: this.#terminate, recoverWorker: false }
      if (final.type === "failed") {
        const nested = final.toolCallId === undefined ? undefined : calls.find(call => call.id === final.toolCallId)
        const failure: CodeExecutionFailure = nested
          ? { kind: "nested_tool", tool: nested.name, error: final.error }
          : { kind: "cell", error: final.error }
        return { type: "failed", failure, ...common, recoverWorker: final.reset === true }
      }
      return {
        type: "completed",
        ...(final.result === undefined ? {} : { result: final.result }),
        state: final.state,
        ...common
      }
    } finally {
      this.#state = { type: "settled" }
      executionDeadline.dispose()
      this.#controller.abort()
      this.#parentSignal?.removeEventListener("abort", abort)
    }
  }

  async #recoverFailure(
    kind: Extract<CodeExecutionFailure, { kind: "runtime" | "nested_settlement" }>["kind"],
    cause: unknown
  ): Promise<CodeExecutionResult> {
    this.#controller.abort(cause)
    if (kind === "runtime") {
      await settle(
        this.#dispatchQueue,
        defaultTimeouts.nestedSettlementMs,
        "Nested code-mode tools did not settle"
      ).catch(() => undefined)
    }
    this.#abortCalls()
    if (this.#parentSignal?.aborted) throw abortError(this.#controller.signal)
    const diagnostic = await this.#worker.settledDiagnostic()
    return {
      type: "failed",
      failure: {
        kind,
        error: boundedErrorText(`${errorMessage(cause)}${diagnostic ? `\nWorker: ${diagnostic}` : ""}`)
      },
      calls: snapshotCalls(this.#calls),
      logs: [],
      terminate: this.#terminate,
      recoverWorker: true
    }
  }

  #queueCall(message: Extract<CodeModeWorkerMessage, { type: "tool_call" }>): void {
    if (this.#state.type !== "running") return
    if (this.#callIds.has(message.id)) throw new Error(`Duplicate code-mode call ID: ${message.id}`)
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
      const nestedId = `${this.#toolCallId}:code:${message.id}`
      const contract = codeModeToolContract(tool)
      const invocation = contract
        ? await contract.execute(nestedId, validated, this.#controller.signal, onUpdate)
        : { result: await tool.execute(nestedId, validated, this.#controller.signal, onUpdate), value: undefined }
      const text = toolResultText(invocation.result)
      if (isBuiltInToolError(message.name, invocation.result.details)) throw new Error(text)
      if (invocation.result.terminate) this.#terminate = true
      return {
        text,
        value: validateCodeModeJson(contract ? invocation.value : text),
        terminate: invocation.result.terminate === true
      }
    })
    this.#dispatchQueue = operation.then(
      () => undefined,
      () => undefined
    )
    void operation.then(
      async result => {
        if (this.#state.type !== "running") return undefined
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
        await this.#worker
          .send({
            version: codeModeProtocolVersion,
            type: "tool_result",
            generation: message.generation,
            executionId: message.executionId,
            id: message.id,
            value: result.value,
            ...(result.terminate ? { terminate: true } : {})
          })
          .catch(() => undefined)
        return undefined
      },
      async cause => {
        if (this.#state.type !== "running") return undefined
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
        await this.#worker
          .send({
            version: codeModeProtocolVersion,
            type: "tool_error",
            generation: message.generation,
            executionId: message.executionId,
            id: message.id,
            error
          })
          .catch(() => undefined)
        return undefined
      }
    )
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

function resultFailure(result: Extract<CodeExecutionResult, { type: "failed" }>): AgentToolResult<CodeModeDetails> {
  const error = boundedErrorText(result.failure.error)
  const recovery = result.recoverWorker
    ? "\nThe programmatic worker was replaced. Volatile scratch was cleared; committed state was preserved."
    : ""
  return {
    content: [{ type: "text", text: `${failureLabel(result.failure)}: ${error}${recovery}` }],
    details: { type: "code_mode", outcome: "error", error, calls: result.calls, logs: result.logs },
    ...(result.terminate ? { terminate: true } : {})
  }
}

function failureLabel(failure: CodeExecutionFailure): string {
  switch (failure.kind) {
    case "cell":
      return "Code cell failed"
    case "nested_tool":
      return `Nested Zi tool ${failure.tool} failed`
    case "nested_settlement":
      return "Nested Zi tool settlement failed"
    case "runtime":
      return "Code runtime failed"
  }
  const unreachable: never = failure
  return unreachable
}

function stateCommitFailure(result: CodeExecutionResult, cause: unknown): AgentToolResult<CodeModeDetails> {
  const causeText = boundedErrorText(errorMessage(cause))
  const error = boundedErrorText(`Could not commit program state: ${causeText}`)
  return {
    content: [
      {
        type: "text",
        text: `Code cell completed, but program state was not committed: ${causeText}\nTool and ambient effects and scratch changes may already have occurred.`
      }
    ],
    details: { type: "code_mode", outcome: "error", error, calls: result.calls, logs: result.logs },
    ...(result.terminate ? { terminate: true } : {})
  }
}

function codeFailure(error: string): AgentToolResult<CodeModeDetails> {
  return resultFailure({
    type: "failed",
    failure: { kind: "runtime", error },
    calls: [],
    logs: [],
    terminate: false,
    recoverWorker: false
  })
}

async function raceWithAbort<T>(operation: Promise<T>, signal?: AbortSignal): Promise<T> {
  if (!signal) return operation
  if (signal.aborted) throw abortError(signal)
  let rejectAbort!: (cause: unknown) => void
  const cancellation = new Promise<never>((_, reject) => {
    rejectAbort = reject
  })
  const abort = () => rejectAbort(abortError(signal))
  signal.addEventListener("abort", abort, { once: true })
  try {
    return await Promise.race([operation, cancellation])
  } finally {
    signal.removeEventListener("abort", abort)
  }
}

function createDeadline(milliseconds: number, message: string): { readonly promise: Promise<never>; dispose(): void } {
  let timer: ReturnType<typeof setTimeout> | undefined
  const promise = new Promise<never>((_, reject) => {
    timer = setTimeout(() => {
      timer = undefined
      reject(new Error(message))
    }, milliseconds)
    timer.unref?.()
  })
  return {
    promise,
    dispose() {
      if (timer) clearTimeout(timer)
      timer = undefined
    }
  }
}
function toolResultText(result: AgentToolResult<unknown>): string {
  return result.content.map(part => (part.type === "text" ? part.text : `[image: ${part.mimeType}]`)).join("\n")
}

function codeToolDescription(tools: readonly AgentTool[]): string {
  const prefix = `Execute JavaScript that orchestrates the other Zi tools.

Each cell is an ordinary JavaScript async arrow function with full Node-compatible process authority. This is not a security sandbox.
Every direct tool is also available as zi.<tool>(input) with the same input fields; use zi["tool-name"] for punctuation.
Successful calls return the declared JSON-compatible JavaScript value directly; values are already decoded.
Tool failures throw Error and may be handled with try/catch. Console logs are retained when execution completes, not streamed live.
Zi executes tool calls serially, including calls created with Promise.all; Promise.allSettled retains independent failures but does not add concurrency.
scratch holds arbitrary volatile JavaScript and survives successful and ordinarily failed cells. It is cleared when the worker is replaced or the session resumes.
state holds bounded JSON, commits only when a cell succeeds, and survives worker replacement, compaction, and session resume.
Tool calls and ambient effects are not transactional when a cell or state commit fails.
Use project.import(specifier) to resolve packages and project files from the session working directory. Native fetch, process, Bun, and dynamic import are also available.
Prefer zi tools where tracing and cancellation matter. Await every zi tool call before returning; unawaited calls fail the cell.
A cell may make at most ${maxCodeModeCalls} zi calls and commit at most ${maxCodeModeStateBytes} bytes of state.
Do not use TypeScript syntax.

Available APIs:
declare const scratch: Record<string, unknown>;
declare const state: Record<string, null | boolean | number | string | unknown[] | Record<string, unknown>>;
declare const project: { import(specifier: string): Promise<unknown> };
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
  void promise.catch(() => {})
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
