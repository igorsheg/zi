import type { Readable, Writable } from "node:stream"
import { pathToFileURL } from "node:url"

import type {
  ExtensionAPI,
  ExtensionCustomEntry,
  ExtensionCustomMessage,
  ExtensionLifecycleEvent,
  ExtensionMessageDelivery,
  ExtensionShutdownEvent,
  ExtensionStartEvent,
  ExtensionToolContext,
  JsonValue as ExtensionJsonValue
} from "@with-zi/extension-api"
import { Type } from "typebox"
import { Compile, type Validator } from "typebox/compile"

import type { ExtensionLoadPlan, ExtensionSource } from "./discovery.js"
import {
  boundedExtensionDiagnostic,
  boundedExtensionLoadDiagnostic,
  boundedExtensionToolError,
  extensionLifecycleTimeoutMs,
  ExtensionProtocolDecoder,
  ExtensionProtocolError,
  ExtensionProtocolWriter,
  extensionProtocolVersion,
  extensionStartupTimeoutMs,
  maxExtensionDiagnostics,
  maxExtensionPendingRequests,
  maxExtensionTools,
  maxSubagentTypes,
  type ExtensionDiagnostic,
  type ExtensionLoadResult,
  type ExtensionSessionResponse,
  type ExtensionSubagentTypeRegistration,
  type ExtensionToolRegistration,
  type HostMessage,
  type JsonValue,
  type WorkerMessage,
  validateExtensionSubagentTypeCatalog,
  validateExtensionSubagentTypeRegistration,
  validateExtensionToolArguments,
  validateExtensionToolCatalog,
  validateExtensionToolRegistration,
  validateExtensionToolResult,
  validateHostMessage,
  validateWorkerMessage
} from "./protocol.js"

export const maxExtensionLifecycleHandlers = 1024

interface WorkerOperation {
  readonly generation: number
  readonly settled: Promise<void>
}

type WorkerProcessState =
  | { readonly type: "awaiting_initialize" }
  | ({ readonly type: "initializing" } & WorkerOperation)
  | { readonly type: "ready"; readonly generation: number; readonly extensions: LoadedExtensionGeneration }
  | ({
      readonly type: "dispatching" | "cancelling"
      readonly extensions: LoadedExtensionGeneration
      readonly requestId: number
    } & WorkerOperation)
  | ({ readonly type: "stopping"; readonly requestId: number } & WorkerOperation)
  | { readonly type: "failed"; readonly error: Error }
  | { readonly type: "stopped" }

interface StartHandler {
  readonly source: ExtensionSource
  readonly handler: (event: ExtensionStartEvent) => void | Promise<void>
}

interface ShutdownHandler {
  readonly source: ExtensionSource
  readonly handler: (event: ExtensionShutdownEvent) => void | Promise<void>
}

interface RegisteredTool {
  readonly registration: ExtensionToolRegistration
  readonly inputChecker: Validator
  readonly outputChecker: Validator
  readonly execute: (parameters: Readonly<Record<string, JsonValue>>, context: ExtensionToolContext) => Promise<unknown>
}

interface WorkerToolExecution {
  readonly requestId: number
  readonly generation: number
  readonly controller: AbortController
}

type WorkerToolInvocation =
  | ({ readonly type: "running" } & WorkerToolExecution)
  | ({ readonly type: "cancelling" } & WorkerToolExecution)
  | { readonly type: "responding"; readonly requestId: number; readonly generation: number }

type WorkerToolResponse = Extract<WorkerMessage, { type: "tool_result" | "tool_error" | "tool_cancelled" }>

type WorkerSessionRequest =
  | { readonly type: "custom_entries_get"; readonly settled: Deferred<readonly ExtensionCustomEntry[]> }
  | { readonly type: "custom_entry_append"; readonly settled: Deferred<ExtensionCustomEntry> }
  | { readonly type: "custom_message_send"; readonly settled: VoidDeferred }

export interface WorkerSessionOperations {
  getEntries(source: ExtensionSource, customType: string): Promise<readonly ExtensionCustomEntry[]>
  appendEntry(source: ExtensionSource, customType: string, data?: ExtensionJsonValue): Promise<ExtensionCustomEntry>
  sendMessage(
    source: ExtensionSource,
    message: ExtensionCustomMessage,
    delivery: ExtensionMessageDelivery
  ): Promise<void>
}

export interface ExtensionLifecycleResult {
  readonly diagnostics: readonly ExtensionDiagnostic[]
  readonly omittedDiagnostics: number
  readonly fatal?: ExtensionDiagnostic
}

type LifecycleState =
  | { readonly type: "loaded" }
  | { readonly type: "starting" }
  | { readonly type: "started" }
  | { readonly type: "shutting_down" }
  | { readonly type: "stopped" }
  | { readonly type: "failed"; readonly diagnostic: ExtensionDiagnostic }

export class LoadedExtensionGeneration {
  readonly results: readonly ExtensionLoadResult[]
  readonly tools: readonly ExtensionToolRegistration[]
  readonly subagentTypes: readonly ExtensionSubagentTypeRegistration[]
  readonly #startHandlers: readonly StartHandler[]
  readonly #shutdownHandlers: readonly ShutdownHandler[]
  readonly #toolsByName: ReadonlyMap<string, RegisteredTool>
  #state: LifecycleState = { type: "loaded" }

  constructor(
    results: readonly ExtensionLoadResult[],
    startHandlers: readonly StartHandler[],
    shutdownHandlers: readonly ShutdownHandler[],
    tools: readonly RegisteredTool[],
    subagentTypes: readonly ExtensionSubagentTypeRegistration[]
  ) {
    this.results = Object.freeze([...results])
    this.tools = Object.freeze(tools.map(tool => tool.registration))
    this.subagentTypes = Object.freeze([...subagentTypes])
    this.#startHandlers = Object.freeze([...startHandlers])
    this.#shutdownHandlers = Object.freeze([...shutdownHandlers])
    this.#toolsByName = new Map(tools.map(tool => [tool.registration.name, tool]))
  }

  invoke(name: string, parameters: Readonly<Record<string, JsonValue>>, signal: AbortSignal): Promise<JsonValue> {
    if (this.#state.type !== "started") {
      return Promise.reject(new Error(`Cannot invoke extension tools while lifecycle is ${this.#state.type}`))
    }
    const tool = this.#toolsByName.get(name)
    if (!tool) return Promise.reject(new Error(`Unknown extension tool: ${name}`))
    if (!tool.inputChecker.Check(parameters)) {
      return Promise.reject(new Error(`Invalid arguments for extension tool ${name}`))
    }
    const context = Object.freeze({ signal })
    return Promise.resolve()
      .then(() => tool.execute(parameters, context))
      .then(value => {
        const result = validateExtensionToolResult(value)
        if (!tool.outputChecker.Check(result)) {
          throw new Error(`Invalid result for extension tool ${name}`)
        }
        return result
      })
  }

  dispatch(event: ExtensionLifecycleEvent, timeoutMs = extensionLifecycleTimeoutMs): Promise<ExtensionLifecycleResult> {
    validateTimeout(timeoutMs)
    if (event.type === "session_start") {
      if (this.#state.type !== "loaded") return Promise.reject(forbiddenLifecycle(this.#state, event.type))
      this.#state = { type: "starting" }
      return this.#run(event, this.#startHandlers, timeoutMs, { type: "started" })
    }
    if (this.#state.type !== "started") return Promise.reject(forbiddenLifecycle(this.#state, event.type))
    this.#state = { type: "shutting_down" }
    return this.#run(event, this.#shutdownHandlers, timeoutMs, { type: "stopped" })
  }

  async #run<Event extends ExtensionLifecycleEvent>(
    event: Event,
    handlers: readonly { readonly source: ExtensionSource; readonly handler: (event: Event) => void | Promise<void> }[],
    timeoutMs: number,
    completed: LifecycleState
  ): Promise<ExtensionLifecycleResult> {
    const diagnostics: ExtensionDiagnostic[] = []
    let omittedDiagnostics = 0
    const deadline = Date.now() + timeoutMs
    const immutableEvent = Object.freeze({ ...event }) as Event

    for (const registered of handlers) {
      const remaining = deadline - Date.now()
      if (remaining <= 0) {
        return this.#fatalLifecycle(registered.source, diagnostics, omittedDiagnostics)
      }
      try {
        // Lifecycle order is part of the extension contract.
        // oxlint-disable-next-line eslint/no-await-in-loop
        await settleWithin(
          Promise.resolve().then(() => registered.handler(immutableEvent)),
          remaining,
          "Extension lifecycle deadline exceeded"
        )
      } catch (cause) {
        if (cause instanceof ExtensionDeadlineError) {
          return this.#fatalLifecycle(registered.source, diagnostics, omittedDiagnostics)
        }
        const diagnostic = diagnosticFor(registered.source, "lifecycle", cause)
        if (diagnostics.length < maxExtensionDiagnostics) diagnostics.push(diagnostic)
        else omittedDiagnostics++
      }
    }

    this.#state = completed
    return Object.freeze({ diagnostics: Object.freeze(diagnostics), omittedDiagnostics })
  }

  #fatalLifecycle(
    source: ExtensionSource,
    diagnostics: readonly ExtensionDiagnostic[],
    omittedDiagnostics: number
  ): ExtensionLifecycleResult {
    const fatal = boundedExtensionDiagnostic({
      extensionId: source.id,
      path: source.entryPath,
      phase: "lifecycle",
      severity: "error",
      message: "Extension lifecycle deadline exceeded"
    })
    this.#state = { type: "failed", diagnostic: fatal }
    return Object.freeze({ diagnostics: Object.freeze([...diagnostics]), omittedDiagnostics, fatal })
  }
}

class ExtensionWorkerProcess {
  readonly #writer: ExtensionProtocolWriter
  readonly #terminal = deferred()
  readonly #toolInvocations = new Map<number, WorkerToolInvocation>()
  readonly #settledToolRequests = new Set<number>()
  readonly #settledToolRequestOrder: number[] = []
  readonly #sessionRequests = new Map<number, WorkerSessionRequest>()
  #nextSessionRequestId = 1
  #state: WorkerProcessState = { type: "awaiting_initialize" }

  constructor(output: Writable) {
    this.#writer = new ExtensionProtocolWriter(output, cause => this.#fail(cause))
  }

  get terminal(): Promise<void> {
    return this.#terminal.promise
  }

  receive(message: HostMessage): void {
    const state = this.#state
    if (
      message.type === "custom_entries_result" ||
      message.type === "custom_entry_result" ||
      message.type === "custom_message_result" ||
      message.type === "session_operation_error"
    ) {
      this.#settleSessionRequest(message)
      return
    }
    if (message.type === "initialize") {
      if (state.type !== "awaiting_initialize") {
        this.#protocolFailure("Extension worker was initialized more than once")
        return
      }
      const operation = deferred()
      this.#state = { type: "initializing", generation: message.generation, settled: operation.promise }
      void this.#initialize(message, operation)
      return
    }

    if (state.type === "awaiting_initialize") {
      this.#protocolFailure("Extension worker received a request before initialization")
      return
    }
    if (message.type === "cancel") {
      if (state.type === "dispatching") {
        if (message.generation !== state.generation || message.requestId !== state.requestId) {
          this.#protocolFailure("Extension worker received cancellation for a stale request")
          return
        }
        this.#state = { ...state, type: "cancelling" }
        return
      }
      if (state.type === "ready" && this.#cancelToolInvocation(message)) return
      this.#protocolFailure("Extension worker received cancellation for a stale request")
      return
    }
    if (state.type !== "ready") {
      this.#protocolFailure(`Extension worker cannot receive ${message.type} while ${state.type}`)
      return
    }
    if (message.generation !== state.generation) {
      this.#protocolFailure("Extension worker received a stale generation request")
      return
    }

    if (message.type === "tool_invoke") {
      if (this.#toolInvocations.size >= maxExtensionPendingRequests) {
        this.#protocolFailure(`Extension worker cannot run more than ${maxExtensionPendingRequests} tool invocations`)
        return
      }
      if (this.#toolInvocations.has(message.requestId)) {
        this.#protocolFailure("Extension worker received a duplicate tool request")
        return
      }
      const invocation: WorkerToolInvocation = {
        type: "running",
        requestId: message.requestId,
        generation: message.generation,
        controller: new AbortController()
      }
      this.#toolInvocations.set(message.requestId, invocation)
      void this.#invokeTool(state.extensions, message, invocation)
      return
    }
    if (message.type === "session_start" || message.type === "session_shutdown") {
      if (message.type === "session_shutdown" && this.#hasExecutingToolInvocations()) {
        this.#protocolFailure("Extension worker cannot shut down with active tool invocations")
        return
      }
      const operation = deferred()
      this.#state = {
        type: "dispatching",
        generation: state.generation,
        extensions: state.extensions,
        requestId: message.requestId,
        settled: operation.promise
      }
      void this.#dispatch(state.extensions, message, operation)
      return
    }
    if (message.type === "stop") {
      if (this.#hasExecutingToolInvocations()) {
        this.#protocolFailure("Extension worker cannot stop with active tool invocations")
        return
      }
      const operation = deferred()
      this.#state = {
        type: "stopping",
        generation: state.generation,
        requestId: message.requestId,
        settled: operation.promise
      }
      void this.#stop(message, operation)
      return
    }
    this.#protocolFailure("Extension worker received cancellation without an active request")
  }

  protocolFailure(cause: unknown): void {
    const error = cause instanceof Error ? cause : new Error(String(cause))
    this.#protocolFailure(error.message)
  }

  async inputEnded(): Promise<void> {
    const state = this.#state
    if (
      state.type === "initializing" ||
      state.type === "dispatching" ||
      state.type === "cancelling" ||
      state.type === "stopping"
    ) {
      await state.settled
    }
    if (this.#state.type === "stopped") return
    this.#protocolFailure("Extension host input ended before the worker stopped")
    return this.#terminal.promise
  }

  dispose(): void {
    this.#rejectSessionRequests(new Error("Extension worker disposed with pending session operations"))
    this.#writer.dispose()
  }

  async #initialize(message: Extract<HostMessage, { type: "initialize" }>, operation: VoidDeferred): Promise<void> {
    try {
      const extensions = await loadExtensionGeneration(
        message.plan,
        message.generation,
        extensionStartupTimeoutMs,
        this.#extensionSessionOperations(message.generation)
      )
      const state = this.#state
      if (state.type !== "initializing" || state.generation !== message.generation) return
      this.#state = { type: "ready", generation: message.generation, extensions }
      await this.#writer.send({
        type: "ready",
        protocolVersion: extensionProtocolVersion,
        generation: message.generation,
        extensions: extensions.results,
        tools: extensions.tools,
        subagentTypes: extensions.subagentTypes
      })
    } catch (cause) {
      this.#fatal(message.generation, fatalDiagnostic("handshake", cause), cause)
    } finally {
      operation.resolve()
    }
  }

  #extensionSessionOperations(generation: number): WorkerSessionOperations {
    const operations: WorkerSessionOperations = {
      getEntries: (source, customType) => {
        const settled = deferred<readonly ExtensionCustomEntry[]>()
        this.#requestSessionOperation(
          generation,
          { type: "custom_entries_get", settled },
          { type: "custom_entries_get", extensionId: source.id, customType }
        )
        return settled.promise
      },
      appendEntry: (source, customType, data) => {
        const settled = deferred<ExtensionCustomEntry>()
        this.#requestSessionOperation(
          generation,
          { type: "custom_entry_append", settled },
          { type: "custom_entry_append", extensionId: source.id, customType, ...(data === undefined ? {} : { data }) }
        )
        return settled.promise
      },
      sendMessage: (source, message, delivery) => {
        const settled = deferred<void>()
        this.#requestSessionOperation(
          generation,
          { type: "custom_message_send", settled },
          { type: "custom_message_send", extensionId: source.id, message, delivery }
        )
        return settled.promise
      }
    }
    return Object.freeze(operations)
  }

  #requestSessionOperation(
    generation: number,
    request: WorkerSessionRequest,
    fields:
      | { readonly type: "custom_entries_get"; readonly extensionId: string; readonly customType: string }
      | {
          readonly type: "custom_entry_append"
          readonly extensionId: string
          readonly customType: string
          readonly data?: ExtensionJsonValue
        }
      | {
          readonly type: "custom_message_send"
          readonly extensionId: string
          readonly message: ExtensionCustomMessage
          readonly delivery: ExtensionMessageDelivery
        }
  ): void {
    if (workerGeneration(this.#state) !== generation) {
      request.settled.reject(new Error("Extension session operation belongs to a stale generation"))
      return
    }
    if (this.#sessionRequests.size >= maxExtensionPendingRequests) {
      request.settled.reject(
        new Error(`Extension workers cannot await more than ${maxExtensionPendingRequests} session operations`)
      )
      return
    }
    const requestId = this.#nextSessionRequestId
    if (!Number.isSafeInteger(requestId)) {
      request.settled.reject(new Error("Extension session operation request IDs are exhausted"))
      return
    }

    let message: WorkerMessage
    try {
      message = validateWorkerMessage({ ...fields, generation, requestId })
    } catch (cause) {
      request.settled.reject(cause)
      return
    }
    this.#nextSessionRequestId++
    this.#sessionRequests.set(requestId, request)
    void this.#writer.send(message).catch(cause => {
      if (this.#sessionRequests.get(requestId) === request) {
        this.#sessionRequests.delete(requestId)
        request.settled.reject(cause)
      }
    })
  }

  #settleSessionRequest(response: ExtensionSessionResponse): void {
    const generation = workerGeneration(this.#state)
    const request = this.#sessionRequests.get(response.requestId)
    if (generation !== response.generation || !request) {
      this.#protocolFailure("Extension host settled an unknown session operation")
      return
    }
    this.#sessionRequests.delete(response.requestId)
    if (response.type === "session_operation_error") {
      request.settled.reject(new Error(response.message))
      return
    }
    if (request.type === "custom_entries_get" && response.type === "custom_entries_result") {
      request.settled.resolve(response.entries)
      return
    }
    if (request.type === "custom_entry_append" && response.type === "custom_entry_result") {
      request.settled.resolve(response.entry)
      return
    }
    if (request.type === "custom_message_send" && response.type === "custom_message_result") {
      request.settled.resolve()
      return
    }
    const error = new ExtensionProtocolError("Extension host returned the wrong session-operation result")
    request.settled.reject(error)
    this.#protocolFailure(error.message)
  }

  #cancelToolInvocation(message: Extract<HostMessage, { type: "cancel" }>): boolean {
    const invocation = this.#toolInvocations.get(message.requestId)
    if (!invocation) return this.#settledToolRequests.has(message.requestId)
    if (invocation.generation !== message.generation) return false
    if (invocation.type !== "running") return true
    const cancelling: WorkerToolInvocation = { ...invocation, type: "cancelling" }
    this.#toolInvocations.set(message.requestId, cancelling)
    invocation.controller.abort()
    return true
  }

  async #invokeTool(
    extensions: LoadedExtensionGeneration,
    message: Extract<HostMessage, { type: "tool_invoke" }>,
    invocation: Extract<WorkerToolInvocation, { type: "running" }>
  ): Promise<void> {
    let outcome:
      | { readonly type: "result"; readonly value: JsonValue }
      | { readonly type: "error"; readonly message: string }
    try {
      const parameters = validateExtensionToolArguments(message.arguments)
      const value = await extensions.invoke(message.name, parameters, invocation.controller.signal)
      outcome = { type: "result", value }
    } catch (cause) {
      outcome = { type: "error", message: boundedExtensionToolError(cause) }
    }
    const current = this.#toolInvocations.get(message.requestId)
    if (!current || current.type === "responding" || current.controller !== invocation.controller) return
    const response: WorkerToolResponse =
      current.type === "cancelling"
        ? { type: "tool_cancelled", generation: message.generation, requestId: message.requestId }
        : outcome.type === "result"
          ? { type: "tool_result", generation: message.generation, requestId: message.requestId, value: outcome.value }
          : {
              type: "tool_error",
              generation: message.generation,
              requestId: message.requestId,
              message: outcome.message
            }
    await this.#respondTool(current, response)
  }

  async #respondTool(
    invocation: Exclude<WorkerToolInvocation, { type: "responding" }>,
    response: WorkerToolResponse
  ): Promise<void> {
    const responding: WorkerToolInvocation = {
      type: "responding",
      generation: invocation.generation,
      requestId: invocation.requestId
    }
    this.#toolInvocations.set(invocation.requestId, responding)
    try {
      await this.#writer.send(response)
      if (this.#toolInvocations.get(invocation.requestId) !== responding) return
      this.#toolInvocations.delete(invocation.requestId)
      this.#rememberSettledToolRequest(invocation.requestId)
    } catch (cause) {
      this.#fail(cause)
    }
  }

  #hasExecutingToolInvocations(): boolean {
    for (const invocation of this.#toolInvocations.values()) {
      if (invocation.type !== "responding") return true
    }
    return false
  }

  #rememberSettledToolRequest(requestId: number): void {
    this.#settledToolRequests.add(requestId)
    this.#settledToolRequestOrder.push(requestId)
    if (this.#settledToolRequestOrder.length <= maxExtensionPendingRequests) return
    const evicted = this.#settledToolRequestOrder.shift()
    if (evicted !== undefined) this.#settledToolRequests.delete(evicted)
  }

  async #dispatch(
    extensions: LoadedExtensionGeneration,
    message: Extract<HostMessage, { type: "session_start" | "session_shutdown" }>,
    operation: VoidDeferred
  ): Promise<void> {
    try {
      const event: ExtensionLifecycleEvent =
        message.type === "session_start"
          ? { type: "session_start", reason: message.reason }
          : { type: "session_shutdown", reason: message.reason }
      const result = await extensions.dispatch(event)
      const state = this.#state
      if ((state.type !== "dispatching" && state.type !== "cancelling") || state.requestId !== message.requestId) return
      for (const diagnostic of result.diagnostics) {
        // Keep bounded diagnostics ordered without filling the writer queue at once.
        // oxlint-disable-next-line eslint/no-await-in-loop
        await this.#writer.send({ type: "diagnostic", generation: message.generation, diagnostic })
      }
      if (result.omittedDiagnostics > 0) {
        await this.#writer.send({
          type: "diagnostic",
          generation: message.generation,
          diagnostic: boundedExtensionDiagnostic({
            phase: "lifecycle",
            severity: "warning",
            message: `${result.omittedDiagnostics} additional extension lifecycle diagnostics were omitted`
          })
        })
      }
      if (result.fatal) {
        this.#fatal(message.generation, result.fatal, new Error(result.fatal.message))
        return
      }
      const completedState = this.#state
      if (
        (completedState.type !== "dispatching" && completedState.type !== "cancelling") ||
        completedState.requestId !== message.requestId
      )
        return
      this.#state = { type: "ready", generation: message.generation, extensions }
      await this.#writer.send({ type: "settled", generation: message.generation, requestId: message.requestId })
    } catch (cause) {
      this.#fatal(message.generation, fatalDiagnostic("lifecycle", cause), cause)
    } finally {
      operation.resolve()
    }
  }

  async #stop(message: Extract<HostMessage, { type: "stop" }>, operation: VoidDeferred): Promise<void> {
    try {
      const state = this.#state
      await this.#writer.send({ type: "settled", generation: message.generation, requestId: message.requestId })
      if (this.#state === state) {
        this.#state = { type: "stopped" }
        this.#terminal.resolve()
      }
    } catch (cause) {
      this.#fail(cause)
    } finally {
      operation.resolve()
    }
  }

  #protocolFailure(message: string): void {
    const error = new ExtensionProtocolError(message)
    const generation = workerGeneration(this.#state)
    if (generation === undefined) {
      this.#fail(error)
      return
    }
    this.#fatal(generation, fatalDiagnostic("protocol", error), error)
  }

  #fatal(generation: number, diagnostic: ExtensionDiagnostic, cause: unknown): void {
    if (this.#state.type === "failed" || this.#state.type === "stopped") return
    const error = cause instanceof Error ? cause : new Error(String(cause))
    this.#abortToolInvocations()
    this.#rejectSessionRequests(error)
    this.#state = { type: "failed", error }
    void this.#writer.send({ type: "fatal", generation, diagnostic }).then(
      () => this.#terminal.reject(error),
      writerCause => this.#terminal.reject(writerCause)
    )
  }

  #rejectSessionRequests(error: Error): void {
    for (const request of this.#sessionRequests.values()) request.settled.reject(error)
    this.#sessionRequests.clear()
  }

  #abortToolInvocations(): void {
    for (const invocation of this.#toolInvocations.values()) {
      if (invocation.type !== "responding") invocation.controller.abort()
    }
    this.#toolInvocations.clear()
    this.#settledToolRequests.clear()
    this.#settledToolRequestOrder.length = 0
  }

  #fail(cause: unknown): void {
    if (this.#state.type === "failed" || this.#state.type === "stopped") return
    const error = cause instanceof Error ? cause : new Error(String(cause))
    this.#abortToolInvocations()
    this.#rejectSessionRequests(error)
    this.#state = { type: "failed", error }
    this.#writer.fail(error)
    this.#terminal.reject(error)
  }
}

export async function runExtensionWorkerProcess(input: Readable, output: Writable): Promise<void> {
  const decoder = new ExtensionProtocolDecoder(validateHostMessage)
  const worker = new ExtensionWorkerProcess(output)
  const iterator = input[Symbol.asyncIterator]()
  const terminal = worker.terminal.then(
    () => ({ type: "terminal" as const }),
    cause => Promise.reject(cause)
  )

  try {
    while (true) {
      const read = iterator.next().then(result => ({ type: "read" as const, result }))
      // The single reader serializes frame admission while dispatched work runs independently.
      // oxlint-disable-next-line eslint/no-await-in-loop
      const outcome = await Promise.race([read, terminal])
      if (outcome.type === "terminal") return
      if (outcome.result.done) {
        decoder.end()
        // oxlint-disable-next-line eslint/no-await-in-loop -- EOF settlement belongs to this reader iteration.
        await worker.inputEnded()
        return
      }
      for (const message of decoder.push(outcome.result.value)) worker.receive(message)
    }
  } catch (cause) {
    worker.protocolFailure(cause)
    return await worker.terminal
  } finally {
    input.destroy()
    worker.dispose()
  }
}

const unavailableSessionOperations: WorkerSessionOperations = Object.freeze({
  getEntries: () => Promise.reject(new Error("Extension session operations are unavailable")),
  appendEntry: () => Promise.reject(new Error("Extension session operations are unavailable")),
  sendMessage: () => Promise.reject(new Error("Extension session operations are unavailable"))
})

export async function loadExtensionGeneration(
  plan: ExtensionLoadPlan,
  generation: number,
  factoryTimeoutMs = extensionStartupTimeoutMs,
  sessionOperations: WorkerSessionOperations = unavailableSessionOperations
): Promise<LoadedExtensionGeneration> {
  if (!Number.isSafeInteger(generation) || generation <= 0) {
    throw new Error("Extension generation must be a positive safe integer")
  }
  validateTimeout(factoryTimeoutMs)

  const results: ExtensionLoadResult[] = []
  const startHandlers: StartHandler[] = []
  const shutdownHandlers: ShutdownHandler[] = []
  const tools: RegisteredTool[] = []
  const toolNames = new Set<string>()
  const subagentTypes: ExtensionSubagentTypeRegistration[] = []
  const subagentTypeNames = new Set<string>()

  for (const source of plan.sources) {
    const localStart: StartHandler[] = []
    const localShutdown: ShutdownHandler[] = []
    const localTools: RegisteredTool[] = []
    const localToolNames = new Set<string>()
    const localSubagentTypes: ExtensionSubagentTypeRegistration[] = []
    const localSubagentTypeNames = new Set<string>()
    let acceptingRegistrations = true
    const api = Object.freeze({
      on(registeredEvent: unknown, handler: unknown): void {
        if (!acceptingRegistrations) throw new Error("Extension registration closed after factory settlement")
        if (typeof handler !== "function") throw new Error("Extension lifecycle handlers must be functions")
        if (
          startHandlers.length + shutdownHandlers.length + localStart.length + localShutdown.length >=
          maxExtensionLifecycleHandlers
        ) {
          throw new Error(
            `Extension generations cannot register more than ${maxExtensionLifecycleHandlers} lifecycle handlers`
          )
        }
        if (registeredEvent === "session_start") {
          localStart.push({
            source,
            handler: lifecycleEvent => Promise.resolve(handler(lifecycleEvent)).then(() => undefined)
          })
          return
        }
        if (registeredEvent === "session_shutdown") {
          localShutdown.push({
            source,
            handler: lifecycleEvent => Promise.resolve(handler(lifecycleEvent)).then(() => undefined)
          })
          return
        }
        throw new Error(`Unknown extension lifecycle event: ${String(registeredEvent)}`)
      },
      registerTool(value: unknown): void {
        if (!acceptingRegistrations)
          throw new ExtensionRegistrationError("Extension registration closed after factory settlement")
        if (tools.length + localTools.length >= maxExtensionTools) {
          throw new ExtensionRegistrationError(
            `Extension generations cannot register more than ${maxExtensionTools} tools`
          )
        }
        const registered = registerTool(source, value)
        const name = registered.registration.name
        if (toolNames.has(name) || localToolNames.has(name)) {
          throw new ExtensionRegistrationError(`Duplicate extension tool name: ${name}`)
        }
        validateExtensionToolCatalog([
          ...tools.map(tool => tool.registration),
          ...localTools.map(tool => tool.registration),
          registered.registration
        ])
        localToolNames.add(name)
        localTools.push(registered)
      },
      registerSubagentType(value: unknown): void {
        if (!acceptingRegistrations) {
          throw new ExtensionRegistrationError("Extension registration closed after factory settlement")
        }
        if (subagentTypes.length + localSubagentTypes.length >= maxSubagentTypes) {
          throw new ExtensionRegistrationError(
            `Extension generations cannot register more than ${maxSubagentTypes} subagent types`
          )
        }
        const registered = registerSubagentType(source, value)
        if (subagentTypeNames.has(registered.name) || localSubagentTypeNames.has(registered.name)) {
          throw new ExtensionRegistrationError(`Duplicate subagent type name: ${registered.name}`)
        }
        try {
          validateExtensionSubagentTypeCatalog([...subagentTypes, ...localSubagentTypes, registered])
        } catch (cause) {
          throw new ExtensionRegistrationError(cause instanceof Error ? cause.message : String(cause), { cause })
        }
        localSubagentTypeNames.add(registered.name)
        localSubagentTypes.push(registered)
      },
      getSessionEntries(customType: string) {
        return sessionOperations.getEntries(source, customType)
      },
      appendEntry(customType: string, data?: ExtensionJsonValue) {
        return sessionOperations.appendEntry(source, customType, data)
      },
      sendMessage(message: ExtensionCustomMessage, delivery: ExtensionMessageDelivery) {
        return sessionOperations.sendMessage(source, message, delivery)
      }
    }) as ExtensionAPI

    let extensionModule: Record<string, unknown>
    try {
      // Source order defines registration and lifecycle order.
      // oxlint-disable-next-line eslint/no-await-in-loop
      const loaded: unknown = await settleWithin(
        import(pathToFileURL(source.entryPath).href),
        factoryTimeoutMs,
        "Extension import deadline exceeded"
      )
      if (!isRecord(loaded)) throw new Error("Extension module did not return a module namespace")
      extensionModule = loaded
    } catch (cause) {
      results.push(failedResult(source, "import", cause))
      continue
    }

    try {
      const factory = extensionModule.default
      if (typeof factory !== "function") throw new Error("Extension default export must be a function")
      // Factory settlement is the source's registration barrier.
      // oxlint-disable-next-line eslint/no-await-in-loop
      await settleWithin(
        Promise.resolve().then(() => factory(api)),
        factoryTimeoutMs,
        "Extension factory deadline exceeded"
      )
      acceptingRegistrations = false
      startHandlers.push(...localStart)
      shutdownHandlers.push(...localShutdown)
      tools.push(...localTools)
      for (const name of localToolNames) toolNames.add(name)
      subagentTypes.push(...localSubagentTypes)
      for (const name of localSubagentTypeNames) subagentTypeNames.add(name)
      results.push(Object.freeze({ source, status: "loaded" }))
    } catch (cause) {
      acceptingRegistrations = false
      results.push(
        failedResult(source, cause instanceof ExtensionRegistrationError ? "registration" : "factory", cause)
      )
    }
  }

  return new LoadedExtensionGeneration(results, startHandlers, shutdownHandlers, tools, subagentTypes)
}

function registerSubagentType(source: ExtensionSource, value: unknown): ExtensionSubagentTypeRegistration {
  let definition
  try {
    definition = validateExtensionSubagentTypeRegistration({ source, ...strictSubagentTypeDefinition(value) })
  } catch (cause) {
    throw new ExtensionRegistrationError(cause instanceof Error ? cause.message : String(cause), { cause })
  }
  return definition
}

function strictSubagentTypeDefinition(value: unknown): Readonly<Record<string, unknown>> {
  if (!isRecord(value)) throw new ExtensionRegistrationError("Subagent type definitions must be objects")
  if (Object.keys(value).some(key => key !== "name" && key !== "description" && key !== "instructions")) {
    throw new ExtensionRegistrationError("Subagent type definitions require only name, description, and instructions")
  }
  return value
}

function registerTool(source: ExtensionSource, value: unknown): RegisteredTool {
  if (!isRecord(value)) throw new ExtensionRegistrationError("Extension tools must be objects")
  if (!isCallable(value.execute)) {
    throw new ExtensionRegistrationError("Extension tools require an execute function")
  }
  let registration: ExtensionToolRegistration
  try {
    registration = validateExtensionToolRegistration({
      source,
      name: value.name,
      label: value.label ?? value.name,
      description: value.description,
      parameters: value.parameters,
      outputSchema: value.outputSchema ?? Type.String()
    })
  } catch (cause) {
    throw new ExtensionRegistrationError(cause instanceof Error ? cause.message : String(cause), { cause })
  }
  let inputChecker: Validator
  let outputChecker: Validator
  try {
    inputChecker = Compile(Type.Unsafe(registration.parameters))
    outputChecker = Compile(Type.Unsafe(registration.outputSchema))
  } catch (cause) {
    throw new ExtensionRegistrationError(cause instanceof Error ? cause.message : "Invalid extension tool schema", {
      cause
    })
  }
  const execute: (...arguments_: unknown[]) => unknown = value.execute
  return Object.freeze({
    registration,
    inputChecker,
    outputChecker,
    execute: (parameters: Readonly<Record<string, JsonValue>>, context: ExtensionToolContext) =>
      Promise.resolve(execute(parameters, context))
  })
}

class ExtensionRegistrationError extends Error {
  constructor(message: string, options?: ErrorOptions) {
    super(message, options)
    this.name = "ExtensionRegistrationError"
  }
}

function failedResult(
  source: ExtensionSource,
  phase: "import" | "factory" | "registration",
  cause: unknown
): ExtensionLoadResult {
  return Object.freeze({ source, status: "failed", diagnostic: diagnosticFor(source, phase, cause) })
}

function diagnosticFor(
  source: ExtensionSource,
  phase: "import" | "factory" | "registration" | "lifecycle",
  cause: unknown
): ExtensionDiagnostic {
  const error = cause instanceof Error ? cause : new Error(String(cause))
  const diagnostic = {
    extensionId: source.id,
    path: source.entryPath,
    phase,
    severity: "error" as const,
    message: error.message || error.name || "Unknown extension error",
    ...(error.stack ? { stack: error.stack } : {})
  }
  return phase === "lifecycle" ? boundedExtensionDiagnostic(diagnostic) : boundedExtensionLoadDiagnostic(diagnostic)
}

interface Deferred<T> {
  readonly promise: Promise<T>
  resolve(value: T): void
  reject(cause: unknown): void
}

type VoidDeferred = Omit<Deferred<void>, "resolve"> & { resolve(): void }

function deferred(): VoidDeferred
function deferred<T>(): Deferred<T>
function deferred<T = void>(): Deferred<T> {
  let resolve!: (value: T) => void
  let reject!: (cause: unknown) => void
  const promise = new Promise<T>((resolvePromise, rejectPromise) => {
    resolve = resolvePromise
    reject = rejectPromise
  })
  void promise.catch(() => {})
  return { promise, resolve, reject }
}

function workerGeneration(state: WorkerProcessState): number | undefined {
  switch (state.type) {
    case "initializing":
    case "ready":
    case "dispatching":
    case "cancelling":
    case "stopping":
      return state.generation
    case "awaiting_initialize":
    case "failed":
    case "stopped":
      return undefined
    default:
      return assertNever(state)
  }
}

function fatalDiagnostic(phase: "handshake" | "lifecycle" | "protocol", cause: unknown): ExtensionDiagnostic {
  const error = cause instanceof Error ? cause : new Error(String(cause))
  return boundedExtensionDiagnostic({
    phase,
    severity: "error",
    message: error.message || error.name || "Unknown extension worker error",
    ...(error.stack ? { stack: error.stack } : {})
  })
}

class ExtensionDeadlineError extends Error {
  constructor(message: string) {
    super(message)
    this.name = "ExtensionDeadlineError"
  }
}

function settleWithin<T>(operation: Promise<T>, timeoutMs: number, message: string): Promise<T> {
  let timeout: ReturnType<typeof setTimeout> | undefined
  const deadline = new Promise<never>((_, reject) => {
    timeout = setTimeout(() => reject(new ExtensionDeadlineError(message)), timeoutMs)
    timeout.unref?.()
  })
  return Promise.race([operation, deadline]).finally(() => {
    if (timeout) clearTimeout(timeout)
  })
}

function validateTimeout(timeoutMs: number): void {
  if (!Number.isSafeInteger(timeoutMs) || timeoutMs <= 0 || timeoutMs > 300_000) {
    throw new Error("Extension deadlines must contain 1 to 300000 milliseconds")
  }
}

function forbiddenLifecycle(state: LifecycleState, event: ExtensionLifecycleEvent["type"]): Error {
  return new Error(`Cannot dispatch ${event} while extension lifecycle is ${state.type}`)
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}

function isCallable(value: unknown): value is (...arguments_: unknown[]) => unknown {
  return typeof value === "function"
}

function assertNever(value: never): never {
  throw new Error(`Unknown extension worker state: ${String(value)}`)
}
