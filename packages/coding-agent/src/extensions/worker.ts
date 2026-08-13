import { AsyncLocalStorage } from "node:async_hooks"
import type { Readable, Writable } from "node:stream"
import { pathToFileURL } from "node:url"

import type {
  ExtensionAgentSettledEvent,
  ExtensionAgentStartEvent,
  ExtensionAPI,
  ExtensionCommandContext,
  ExtensionContext,
  ExtensionCustomEntry,
  ExtensionCustomMessage,
  ExtensionLifecycleEvent,
  ExtensionMessageDelivery,
  ExtensionShutdownEvent,
  ExtensionStartEvent,
  ExtensionSubagentAPI,
  ExtensionSubagentInterruptSettlement,
  ExtensionSubagentProfile,
  ExtensionSubagentSnapshot,
  ExtensionToolContext,
  JsonValue as ExtensionJsonValue
} from "@with-zi/extension-api"
import { Type } from "typebox"
import { Compile, type Validator } from "typebox/compile"

import { isRecord } from "../guards.js"
import { FramedJsonDecoder, FramedJsonWriter } from "../processes/framed-json.js"
import type { ExtensionLoadPlan, ExtensionSource } from "./discovery.js"
import {
  boundedExtensionCommandError,
  boundedExtensionDiagnostic,
  boundedExtensionLoadDiagnostic,
  boundedExtensionToolError,
  extensionAgentEventTimeoutMs,
  extensionFramingLabel,
  extensionFramingLimits,
  extensionLifecycleTimeoutMs,
  ExtensionProtocolError,
  extensionProtocolVersion,
  extensionStartupTimeoutMs,
  maxExtensionCommands,
  maxExtensionDiagnostics,
  maxExtensionQueuedAgentEvents,
  maxExtensionPendingRequests,
  maxExtensionSubagentProfiles,
  maxExtensionTools,
  type ExtensionCommandRegistration,
  type ExtensionDiagnostic,
  type ExtensionLoadResult,
  type ExtensionSessionRequest,
  type ExtensionSessionResponse,
  type ExtensionSubagentRegistration,
  type ExtensionToolRegistration,
  type HostMessage,
  type JsonValue,
  type WorkerMessage,
  validateExtensionCommandArguments,
  validateExtensionCommandCatalog,
  validateExtensionCommandRegistration,
  validateExtensionCommandResult,
  validateExtensionSubagentCatalog,
  validateExtensionToolArguments,
  validateExtensionToolCatalog,
  validateExtensionToolRegistration,
  validateExtensionToolResult,
  validateHostMessage,
  validateWorkerMessage
} from "./protocol.js"

export const maxExtensionEventHandlers = 1024

interface WorkerOperation {
  readonly generation: number
  readonly settled: Promise<void>
}

interface WorkerAgentEvent {
  readonly sequence: number
  readonly event: ExtensionAgentEvent
}

type WorkerAgentEventDelivery =
  | { readonly type: "open" }
  | {
      readonly type: "delivering"
      readonly generation: number
      readonly extensions: LoadedExtensionGeneration
      readonly pending: WorkerAgentEvent[]
      readonly settled: VoidDeferred
    }
  | { readonly type: "closing"; readonly active: VoidDeferred }
  | { readonly type: "closed" }

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
  readonly handler: (event: ExtensionStartEvent, context: ExtensionContext) => void | Promise<void>
}

interface ShutdownHandler {
  readonly source: ExtensionSource
  readonly handler: (event: ExtensionShutdownEvent, context: ExtensionContext) => void | Promise<void>
}

type ExtensionAgentEvent = ExtensionAgentStartEvent | ExtensionAgentSettledEvent

interface AgentEventHandler<Event extends ExtensionAgentEvent> {
  readonly source: ExtensionSource
  readonly handler: (event: Event, context: ExtensionContext) => void | Promise<void>
}

interface RegisteredCommand {
  readonly registration: ExtensionCommandRegistration
  readonly execute: (arguments_: string, context: ExtensionCommandContext) => Promise<unknown>
}

interface RegisteredTool {
  readonly registration: ExtensionToolRegistration
  readonly inputChecker: Validator
  readonly outputChecker: Validator
  readonly execute: (parameters: Readonly<Record<string, JsonValue>>, context: ExtensionToolContext) => Promise<unknown>
}

interface WorkerInvocationExecution {
  readonly kind: "command" | "tool"
  readonly requestId: number
  readonly generation: number
  readonly controller: AbortController
}

type WorkerInvocation =
  | ({ readonly type: "running" } & WorkerInvocationExecution)
  | ({ readonly type: "cancelling" } & WorkerInvocationExecution)
  | {
      readonly type: "responding"
      readonly kind: "command" | "tool"
      readonly requestId: number
      readonly generation: number
    }

type WorkerInvocationResponse = Extract<
  WorkerMessage,
  { type: "command_result" | "command_error" | "command_cancelled" | "tool_result" | "tool_error" | "tool_cancelled" }
>

type WorkerSessionRequest =
  | { readonly type: "custom_entries_get"; readonly settled: Deferred<readonly ExtensionCustomEntry[]> }
  | { readonly type: "custom_entry_append"; readonly settled: Deferred<ExtensionCustomEntry> }
  | { readonly type: "custom_message_send"; readonly settled: VoidDeferred }
  | { readonly type: "active_tools_get"; readonly settled: Deferred<readonly string[]> }
  | { readonly type: "active_tools_set"; readonly settled: VoidDeferred }
  | { readonly type: "subagent_profiles_get"; readonly settled: Deferred<readonly ExtensionSubagentProfile[]> }
  | { readonly type: "subagent_spawn"; readonly settled: Deferred<string> }
  | { readonly type: "subagent_send"; readonly settled: VoidDeferred }
  | { readonly type: "subagent_continue"; readonly settled: Deferred<"started_turn" | "follow_up"> }
  | { readonly type: "subagent_wait"; readonly settled: Deferred<readonly ExtensionSubagentSnapshot[]> }
  | { readonly type: "subagent_interrupt"; readonly settled: Deferred<ExtensionSubagentInterruptSettlement> }
  | { readonly type: "subagent_close"; readonly settled: Deferred<ExtensionSubagentSnapshot> }
  | { readonly type: "subagent_list"; readonly settled: Deferred<readonly ExtensionSubagentSnapshot[]> }

type WorkerSessionRequestFields = ExtensionSessionRequest extends infer Request
  ? Request extends ExtensionSessionRequest
    ? Omit<Request, "generation" | "requestId">
    : never
  : never

export interface WorkerSessionOperations {
  readonly subagentsAvailable: boolean
  getEntries(source: ExtensionSource, customType: string): Promise<readonly ExtensionCustomEntry[]>
  appendEntry(source: ExtensionSource, customType: string, data?: ExtensionJsonValue): Promise<ExtensionCustomEntry>
  sendMessage(
    source: ExtensionSource,
    message: ExtensionCustomMessage,
    delivery: ExtensionMessageDelivery
  ): Promise<void>
  getActiveTools(source: ExtensionSource): Promise<readonly string[]>
  setActiveTools(source: ExtensionSource, names: readonly string[]): Promise<void>
  listSubagentProfiles(source: ExtensionSource): Promise<readonly ExtensionSubagentProfile[]>
  spawnSubagent(
    source: ExtensionSource,
    profile: string,
    name: string,
    prompt: string,
    signal?: AbortSignal
  ): Promise<string>
  sendSubagent(source: ExtensionSource, name: string, text: string): Promise<void>
  continueSubagent(source: ExtensionSource, name: string, text: string): Promise<"started_turn" | "follow_up">
  waitSubagents(
    source: ExtensionSource,
    names: readonly string[],
    timeoutMs?: number,
    signal?: AbortSignal
  ): Promise<readonly ExtensionSubagentSnapshot[]>
  interruptSubagent(source: ExtensionSource, name: string): Promise<ExtensionSubagentInterruptSettlement>
  closeSubagent(source: ExtensionSource, name: string): Promise<ExtensionSubagentSnapshot>
  listSubagents(source: ExtensionSource): Promise<readonly ExtensionSubagentSnapshot[]>
}

export interface ExtensionLifecycleResult {
  readonly diagnostics: readonly ExtensionDiagnostic[]
  readonly omittedDiagnostics: number
  readonly fatal?: ExtensionDiagnostic
}

type LifecycleState =
  | { readonly type: "loaded" }
  | { readonly type: "starting" }
  | { readonly type: "started"; readonly context: ExtensionContext }
  | { readonly type: "shutting_down"; readonly context: ExtensionContext }
  | { readonly type: "stopped" }
  | { readonly type: "failed"; readonly diagnostic: ExtensionDiagnostic }

export class LoadedExtensionGeneration {
  readonly results: readonly ExtensionLoadResult[]
  readonly commands: readonly ExtensionCommandRegistration[]
  readonly tools: readonly ExtensionToolRegistration[]
  readonly subagents: readonly ExtensionSubagentRegistration[]
  readonly #startHandlers: readonly StartHandler[]
  readonly #shutdownHandlers: readonly ShutdownHandler[]
  readonly #agentStartHandlers: readonly AgentEventHandler<ExtensionAgentStartEvent>[]
  readonly #agentSettledHandlers: readonly AgentEventHandler<ExtensionAgentSettledEvent>[]
  readonly #commandsByName: ReadonlyMap<string, RegisteredCommand>
  readonly #toolsByName: ReadonlyMap<string, RegisteredTool>
  #state: LifecycleState = { type: "loaded" }

  constructor(
    results: readonly ExtensionLoadResult[],
    startHandlers: readonly StartHandler[],
    shutdownHandlers: readonly ShutdownHandler[],
    agentStartHandlers: readonly AgentEventHandler<ExtensionAgentStartEvent>[],
    agentSettledHandlers: readonly AgentEventHandler<ExtensionAgentSettledEvent>[],
    commands: readonly RegisteredCommand[],
    tools: readonly RegisteredTool[],
    subagents: readonly ExtensionSubagentRegistration[]
  ) {
    this.results = Object.freeze([...results])
    this.commands = Object.freeze(commands.map(command => command.registration))
    this.tools = Object.freeze(tools.map(tool => tool.registration))
    this.subagents = Object.freeze([...subagents])
    this.#startHandlers = Object.freeze([...startHandlers])
    this.#shutdownHandlers = Object.freeze([...shutdownHandlers])
    this.#agentStartHandlers = Object.freeze([...agentStartHandlers])
    this.#agentSettledHandlers = Object.freeze([...agentSettledHandlers])
    this.#commandsByName = new Map(commands.map(command => [command.registration.name, command]))
    this.#toolsByName = new Map(tools.map(tool => [tool.registration.name, tool]))
  }

  #startedContext(): ExtensionContext {
    if (this.#state.type !== "started") throw new Error(`Extension generation is ${this.#state.type}`)
    return this.#state.context
  }

  invokeCommand(name: string, arguments_: string, signal: AbortSignal): Promise<string | undefined> {
    if (this.#state.type !== "started") {
      return Promise.reject(new Error(`Cannot invoke extension commands while lifecycle is ${this.#state.type}`))
    }
    const command = this.#commandsByName.get(name)
    if (!command) return Promise.reject(new Error(`Unknown extension command: ${name}`))
    const context = Object.freeze({ ...this.#startedContext(), signal })
    return Promise.resolve()
      .then(() => command.execute(arguments_, context))
      .then(validateExtensionCommandResult)
  }

  invoke(
    name: string,
    parameters: Readonly<Record<string, JsonValue>>,
    signal: AbortSignal,
    reportProgress: (message: string) => void = () => {}
  ): Promise<JsonValue> {
    if (this.#state.type !== "started") {
      return Promise.reject(new Error(`Cannot invoke extension tools while lifecycle is ${this.#state.type}`))
    }
    const tool = this.#toolsByName.get(name)
    if (!tool) return Promise.reject(new Error(`Unknown extension tool: ${name}`))
    if (!tool.inputChecker.Check(parameters)) {
      return Promise.reject(new Error(`Invalid arguments for extension tool ${name}`))
    }
    const context = Object.freeze({ ...this.#startedContext(), signal, reportProgress })
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

  dispatchAgentEvent(
    event: ExtensionAgentEvent,
    timeoutMs = extensionAgentEventTimeoutMs
  ): Promise<ExtensionLifecycleResult> {
    validateTimeout(timeoutMs)
    if (this.#state.type !== "started") return Promise.reject(forbiddenAgentEvent(this.#state, event.type))
    if (event.type === "agent_start") {
      return this.#runAgentEvent(event, this.#state.context, this.#agentStartHandlers, timeoutMs)
    }
    return this.#runAgentEvent(event, this.#state.context, this.#agentSettledHandlers, timeoutMs)
  }

  dispatch(
    event: ExtensionLifecycleEvent,
    context?: ExtensionContext,
    timeoutMs = extensionLifecycleTimeoutMs
  ): Promise<ExtensionLifecycleResult> {
    validateTimeout(timeoutMs)
    if (event.type === "session_start") {
      if (this.#state.type !== "loaded") return Promise.reject(forbiddenLifecycle(this.#state, event.type))
      if (!context) return Promise.reject(new Error("session_start requires an extension context"))
      this.#state = { type: "starting" }
      return this.#run(event, context, this.#startHandlers, timeoutMs, { type: "started", context })
    }
    if (this.#state.type !== "started") return Promise.reject(forbiddenLifecycle(this.#state, event.type))
    const current = this.#state.context
    this.#state = { type: "shutting_down", context: current }
    return this.#run(event, current, this.#shutdownHandlers, timeoutMs, { type: "stopped" })
  }

  async #runAgentEvent<Event extends ExtensionAgentEvent>(
    event: Event,
    context: ExtensionContext,
    handlers: readonly AgentEventHandler<Event>[],
    timeoutMs: number
  ): Promise<ExtensionLifecycleResult> {
    const diagnostics: ExtensionDiagnostic[] = []
    let omittedDiagnostics = 0
    const deadline = Date.now() + timeoutMs
    const immutableEvent: Event = Object.freeze(event)

    for (const registered of handlers) {
      const remaining = deadline - Date.now()
      if (remaining <= 0) return this.#fatalAgentEvent(registered.source, diagnostics, omittedDiagnostics)
      try {
        // Event order is part of the extension contract.
        // oxlint-disable-next-line eslint/no-await-in-loop
        await settleWithin(
          Promise.resolve().then(() => registered.handler(immutableEvent, context)),
          remaining,
          "Extension agent event deadline exceeded"
        )
      } catch (cause) {
        if (cause instanceof ExtensionDeadlineError) {
          return this.#fatalAgentEvent(registered.source, diagnostics, omittedDiagnostics)
        }
        const diagnostic = diagnosticFor(registered.source, "event", cause)
        if (diagnostics.length < maxExtensionDiagnostics) diagnostics.push(diagnostic)
        else omittedDiagnostics++
      }
    }

    return Object.freeze({ diagnostics: Object.freeze(diagnostics), omittedDiagnostics })
  }

  #fatalAgentEvent(
    source: ExtensionSource,
    diagnostics: readonly ExtensionDiagnostic[],
    omittedDiagnostics: number
  ): ExtensionLifecycleResult {
    const fatal = boundedExtensionDiagnostic({
      extensionId: source.id,
      path: source.entryPath,
      phase: "event",
      severity: "error",
      message: "Extension agent event deadline exceeded"
    })
    this.#state = { type: "failed", diagnostic: fatal }
    return Object.freeze({ diagnostics: Object.freeze([...diagnostics]), omittedDiagnostics, fatal })
  }

  async #run<Event extends ExtensionLifecycleEvent>(
    event: Event,
    context: ExtensionContext,
    handlers: readonly {
      readonly source: ExtensionSource
      readonly handler: (event: Event, context: ExtensionContext) => void | Promise<void>
    }[],
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
          Promise.resolve().then(() => registered.handler(immutableEvent, context)),
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
  readonly #writer: FramedJsonWriter<WorkerMessage>
  readonly #terminal = deferred()
  readonly #invocationOwner = new AsyncLocalStorage<number>()
  readonly #invocations = new Map<number, WorkerInvocation>()
  readonly #settledInvocationRequests = new Set<number>()
  readonly #settledInvocationRequestOrder: number[] = []
  readonly #sessionRequests = new Map<number, WorkerSessionRequest>()
  #lastInvocationRequestId = 0
  #lastAgentEventSequence = 0
  #nextSessionRequestId = 1
  #agentEvents: WorkerAgentEventDelivery = { type: "open" }
  #state: WorkerProcessState = { type: "awaiting_initialize" }

  constructor(output: Writable) {
    this.#writer = new FramedJsonWriter(output, extensionFramingLimits, extensionFramingLabel, cause =>
      this.#fail(cause)
    )
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
      message.type === "active_tools_result" ||
      message.type === "subagent_profiles_result" ||
      message.type === "subagent_spawn_result" ||
      message.type === "subagent_send_result" ||
      message.type === "subagent_continue_result" ||
      message.type === "subagent_wait_result" ||
      message.type === "subagent_interrupt_result" ||
      message.type === "subagent_close_result" ||
      message.type === "subagent_list_result" ||
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
      if (state.type === "ready") {
        if (message.generation !== state.generation) {
          this.#protocolFailure("Extension worker received cancellation for a stale generation")
          return
        }
        if (this.#cancelInvocation(message)) return
      }
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

    if (message.type === "agent_start" || message.type === "agent_settled") {
      if (message.sequence <= this.#lastAgentEventSequence) {
        this.#protocolFailure("Extension worker received a replayed agent event")
        return
      }
      this.#lastAgentEventSequence = message.sequence
      this.#enqueueAgentEvent(state.generation, state.extensions, {
        sequence: message.sequence,
        event: { type: message.type }
      })
      return
    }
    if (message.type === "command_invoke" || message.type === "tool_invoke") {
      if (this.#invocations.size >= maxExtensionPendingRequests) {
        this.#protocolFailure(`Extension worker cannot run more than ${maxExtensionPendingRequests} invocations`)
        return
      }
      if (message.requestId <= this.#lastInvocationRequestId) {
        this.#protocolFailure("Extension worker received a replayed invocation request")
        return
      }
      this.#lastInvocationRequestId = message.requestId
      const invocation: WorkerInvocation = {
        type: "running",
        kind: message.type === "command_invoke" ? "command" : "tool",
        requestId: message.requestId,
        generation: message.generation,
        controller: new AbortController()
      }
      this.#invocations.set(message.requestId, invocation)
      if (message.type === "command_invoke") void this.#invokeCommand(state.extensions, message, invocation)
      else void this.#invokeTool(state.extensions, message, invocation)
      return
    }
    if (message.type === "session_start" || message.type === "session_shutdown") {
      if (message.type === "session_shutdown" && this.#hasExecutingInvocations()) {
        this.#protocolFailure("Extension worker cannot shut down with active invocations")
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
      if (this.#hasExecutingInvocations()) {
        this.#protocolFailure("Extension worker cannot stop with active invocations")
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
        this.#extensionSessionOperations(message.generation, message.subagentsAvailable === true)
      )
      const state = this.#state
      if (state.type !== "initializing" || state.generation !== message.generation) return
      this.#state = { type: "ready", generation: message.generation, extensions }
      await this.#writer.send({
        type: "ready",
        protocolVersion: extensionProtocolVersion,
        generation: message.generation,
        extensions: extensions.results,
        commands: extensions.commands,
        tools: extensions.tools,
        subagents: extensions.subagents
      })
    } catch (cause) {
      this.#fatal(message.generation, fatalDiagnostic("handshake", cause), cause)
    } finally {
      operation.resolve()
    }
  }

  #extensionSessionOperations(generation: number, subagentsAvailable: boolean): WorkerSessionOperations {
    const operations: WorkerSessionOperations = {
      subagentsAvailable,
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
      },
      getActiveTools: source => {
        const settled = deferred<readonly string[]>()
        this.#requestSessionOperation(
          generation,
          { type: "active_tools_get", settled },
          { type: "active_tools_get", extensionId: source.id }
        )
        return settled.promise
      },
      setActiveTools: (source, names) => {
        const settled = deferred<void>()
        this.#requestSessionOperation(
          generation,
          { type: "active_tools_set", settled },
          { type: "active_tools_set", extensionId: source.id, names }
        )
        return settled.promise
      },
      listSubagentProfiles: source => {
        const settled = deferred<readonly ExtensionSubagentProfile[]>()
        this.#requestSessionOperation(
          generation,
          { type: "subagent_profiles_get", settled },
          { type: "subagent_profiles_get", extensionId: source.id }
        )
        return settled.promise
      },
      spawnSubagent: (source, profile, name, prompt, signal) => {
        const settled = deferred<string>()
        this.#requestSessionOperation(
          generation,
          { type: "subagent_spawn", settled },
          { type: "subagent_spawn", extensionId: source.id, profile, name, prompt },
          signal
        )
        return settled.promise
      },
      sendSubagent: (source, name, text) => {
        const settled = deferred<void>()
        this.#requestSessionOperation(
          generation,
          { type: "subagent_send", settled },
          { type: "subagent_send", extensionId: source.id, name, text }
        )
        return settled.promise
      },
      continueSubagent: (source, name, text) => {
        const settled = deferred<"started_turn" | "follow_up">()
        this.#requestSessionOperation(
          generation,
          { type: "subagent_continue", settled },
          { type: "subagent_continue", extensionId: source.id, name, text }
        )
        return settled.promise
      },
      waitSubagents: (source, names, timeoutMs, signal) => {
        const settled = deferred<readonly ExtensionSubagentSnapshot[]>()
        const ownerRequestId = this.#invocationOwner.getStore()
        this.#requestSessionOperation(
          generation,
          { type: "subagent_wait", settled },
          {
            type: "subagent_wait",
            extensionId: source.id,
            ...(ownerRequestId === undefined ? {} : { ownerRequestId }),
            names,
            ...(timeoutMs === undefined ? {} : { timeoutMs })
          },
          signal
        )
        return settled.promise
      },
      interruptSubagent: (source, name) => {
        const settled = deferred<ExtensionSubagentInterruptSettlement>()
        this.#requestSessionOperation(
          generation,
          { type: "subagent_interrupt", settled },
          { type: "subagent_interrupt", extensionId: source.id, name }
        )
        return settled.promise
      },
      closeSubagent: (source, name) => {
        const settled = deferred<ExtensionSubagentSnapshot>()
        this.#requestSessionOperation(
          generation,
          { type: "subagent_close", settled },
          { type: "subagent_close", extensionId: source.id, name }
        )
        return settled.promise
      },
      listSubagents: source => {
        const settled = deferred<readonly ExtensionSubagentSnapshot[]>()
        this.#requestSessionOperation(
          generation,
          { type: "subagent_list", settled },
          { type: "subagent_list", extensionId: source.id }
        )
        return settled.promise
      }
    }
    return Object.freeze(operations)
  }

  #requestSessionOperation(
    generation: number,
    request: WorkerSessionRequest,
    fields: WorkerSessionRequestFields,
    signal?: AbortSignal
  ): void {
    if (signal?.aborted) {
      request.settled.reject(new Error("Extension subagent operation was cancelled"))
      return
    }
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
    const cancel = signal
      ? () => {
          void this.#writer.send(
            validateWorkerMessage({
              type: "subagent_operation_cancel",
              generation,
              requestId,
              extensionId: fields.extensionId,
              targetRequestId: requestId
            })
          )
        }
      : undefined
    signal?.addEventListener("abort", cancel!, { once: true })
    if (cancel) {
      void request.settled.promise.then(
        () => signal?.removeEventListener("abort", cancel),
        () => signal?.removeEventListener("abort", cancel)
      )
    }
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
    if (request.type === "active_tools_get" && response.type === "active_tools_result") {
      request.settled.resolve(response.names)
      return
    }
    if (request.type === "active_tools_set" && response.type === "active_tools_result") {
      request.settled.resolve()
      return
    }
    if (request.type === "subagent_profiles_get" && response.type === "subagent_profiles_result") {
      request.settled.resolve(response.profiles)
      return
    }
    if (request.type === "subagent_spawn" && response.type === "subagent_spawn_result") {
      request.settled.resolve(response.name)
      return
    }
    if (request.type === "subagent_send" && response.type === "subagent_send_result") {
      request.settled.resolve()
      return
    }
    if (request.type === "subagent_continue" && response.type === "subagent_continue_result") {
      request.settled.resolve(response.delivery)
      return
    }
    if (request.type === "subagent_wait" && response.type === "subagent_wait_result") {
      request.settled.resolve(response.snapshots)
      return
    }
    if (request.type === "subagent_interrupt" && response.type === "subagent_interrupt_result") {
      request.settled.resolve(response.settlement)
      return
    }
    if (request.type === "subagent_close" && response.type === "subagent_close_result") {
      request.settled.resolve(response.snapshot)
      return
    }
    if (request.type === "subagent_list" && response.type === "subagent_list_result") {
      request.settled.resolve(response.snapshots)
      return
    }
    const error = new ExtensionProtocolError("Extension host returned the wrong session-operation result")
    request.settled.reject(error)
    this.#protocolFailure(error.message)
  }

  #cancelInvocation(message: Extract<HostMessage, { type: "cancel" }>): boolean {
    const invocation = this.#invocations.get(message.requestId)
    if (!invocation) return this.#settledInvocationRequests.has(message.requestId)
    if (invocation.generation !== message.generation) return false
    if (invocation.type !== "running") return true
    const cancelling: WorkerInvocation = { ...invocation, type: "cancelling" }
    this.#invocations.set(message.requestId, cancelling)
    invocation.controller.abort()
    return true
  }

  async #invokeCommand(
    extensions: LoadedExtensionGeneration,
    message: Extract<HostMessage, { type: "command_invoke" }>,
    invocation: Extract<WorkerInvocation, { type: "running" }>
  ): Promise<void> {
    let outcome:
      | { readonly type: "result"; readonly message: string | undefined }
      | { readonly type: "error"; readonly message: string }
    try {
      const commandArguments = validateExtensionCommandArguments(message.arguments)
      const result = await this.#invocationOwner.run(message.requestId, () =>
        extensions.invokeCommand(message.name, commandArguments, invocation.controller.signal)
      )
      outcome = { type: "result", message: result }
    } catch (cause) {
      outcome = { type: "error", message: boundedExtensionCommandError(cause) }
    }
    const current = this.#invocations.get(message.requestId)
    if (!current || current.type === "responding" || current.controller !== invocation.controller) return
    const response: WorkerInvocationResponse =
      current.type === "cancelling"
        ? { type: "command_cancelled", generation: message.generation, requestId: message.requestId }
        : outcome.type === "result"
          ? {
              type: "command_result",
              generation: message.generation,
              requestId: message.requestId,
              ...(outcome.message === undefined ? {} : { message: outcome.message })
            }
          : {
              type: "command_error",
              generation: message.generation,
              requestId: message.requestId,
              message: outcome.message
            }
    await this.#respondInvocation(current, response)
  }

  async #invokeTool(
    extensions: LoadedExtensionGeneration,
    message: Extract<HostMessage, { type: "tool_invoke" }>,
    invocation: Extract<WorkerInvocation, { type: "running" }>
  ): Promise<void> {
    let outcome:
      | { readonly type: "result"; readonly value: JsonValue }
      | { readonly type: "error"; readonly message: string }
    try {
      const parameters = validateExtensionToolArguments(message.arguments)
      const value = await this.#invocationOwner.run(message.requestId, () =>
        extensions.invoke(message.name, parameters, invocation.controller.signal, progress => {
          const current = this.#invocations.get(message.requestId)
          if (
            !current ||
            current.type !== "running" ||
            current.controller !== invocation.controller ||
            current.controller.signal.aborted
          ) {
            return
          }
          void this.#writer
            .send(
              validateWorkerMessage({
                type: "tool_progress",
                generation: message.generation,
                requestId: message.requestId,
                message: progress
              })
            )
            .catch(cause => this.#fail(cause))
        })
      )
      outcome = { type: "result", value }
    } catch (cause) {
      outcome = { type: "error", message: boundedExtensionToolError(cause) }
    }
    const current = this.#invocations.get(message.requestId)
    if (!current || current.type === "responding" || current.controller !== invocation.controller) return
    const response: WorkerInvocationResponse =
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
    await this.#respondInvocation(current, response)
  }

  async #respondInvocation(
    invocation: Exclude<WorkerInvocation, { type: "responding" }>,
    response: WorkerInvocationResponse
  ): Promise<void> {
    const responding: WorkerInvocation = {
      type: "responding",
      kind: invocation.kind,
      generation: invocation.generation,
      requestId: invocation.requestId
    }
    this.#invocations.set(invocation.requestId, responding)
    try {
      await this.#writer.send(response)
      if (this.#invocations.get(invocation.requestId) !== responding) return
      this.#invocations.delete(invocation.requestId)
      this.#rememberSettledInvocationRequest(invocation.requestId)
    } catch (cause) {
      this.#fail(cause)
    }
  }

  #hasExecutingInvocations(): boolean {
    for (const invocation of this.#invocations.values()) {
      if (invocation.type !== "responding") return true
    }
    return false
  }

  #rememberSettledInvocationRequest(requestId: number): void {
    this.#settledInvocationRequests.add(requestId)
    this.#settledInvocationRequestOrder.push(requestId)
    if (this.#settledInvocationRequestOrder.length <= maxExtensionPendingRequests) return
    const evicted = this.#settledInvocationRequestOrder.shift()
    if (evicted !== undefined) this.#settledInvocationRequests.delete(evicted)
  }

  #enqueueAgentEvent(generation: number, extensions: LoadedExtensionGeneration, event: WorkerAgentEvent): void {
    const state = this.#agentEvents
    if (state.type === "open") {
      const settled = deferred()
      const delivery: WorkerAgentEventDelivery = { type: "delivering", generation, extensions, pending: [], settled }
      this.#agentEvents = delivery
      void this.#deliverAgentEvents(delivery, event)
      return
    }
    if (state.type !== "delivering") {
      this.#protocolFailure("Extension worker received an agent event after event delivery closed")
      return
    }
    if (state.extensions !== extensions) {
      this.#protocolFailure("Extension worker received an agent event for a stale generation")
      return
    }
    if (state.pending.length >= maxExtensionQueuedAgentEvents - 1) {
      this.#protocolFailure(`Extension worker cannot queue more than ${maxExtensionQueuedAgentEvents} agent events`)
      return
    }
    state.pending.push(event)
  }

  async #deliverAgentEvents(
    delivery: Extract<WorkerAgentEventDelivery, { type: "delivering" }>,
    first: WorkerAgentEvent
  ): Promise<void> {
    let current: WorkerAgentEvent | undefined = first
    try {
      while (current) {
        // Events are observational but preserve host publication order.
        // oxlint-disable-next-line no-await-in-loop
        const result = await delivery.extensions.dispatchAgentEvent(current.event)
        for (const diagnostic of result.diagnostics) {
          // Keep bounded diagnostics ordered without filling the writer queue at once.
          // oxlint-disable-next-line eslint/no-await-in-loop
          await this.#writer.send({ type: "diagnostic", generation: delivery.generation, diagnostic })
        }
        if (result.omittedDiagnostics > 0) {
          // oxlint-disable-next-line no-await-in-loop
          await this.#writer.send({
            type: "diagnostic",
            generation: delivery.generation,
            diagnostic: boundedExtensionDiagnostic({
              phase: "event",
              severity: "warning",
              message: `${result.omittedDiagnostics} additional extension event diagnostics were omitted`
            })
          })
        }
        if (result.fatal) {
          this.#fatal(delivery.generation, result.fatal, new Error(result.fatal.message))
          return
        }
        // oxlint-disable-next-line no-await-in-loop
        await this.#writer.send({
          type: "agent_event_settled",
          generation: delivery.generation,
          sequence: current.sequence
        })
        if (this.#agentEvents !== delivery) return
        current = delivery.pending.shift()
      }
      if (this.#agentEvents === delivery) this.#agentEvents = { type: "open" }
    } catch (cause) {
      this.#fail(cause)
    } finally {
      delivery.settled.resolve()
    }
  }

  async #closeAgentEvents(): Promise<void> {
    const state = this.#agentEvents
    if (state.type === "closed") return
    if (state.type === "open") {
      this.#agentEvents = { type: "closed" }
      return
    }
    if (state.type === "closing") {
      await state.active.promise
      return
    }
    const dropped = state.pending.splice(0)
    this.#agentEvents = { type: "closing", active: state.settled }
    for (const event of dropped) {
      // Closed generations acknowledge dropped observations so host deadlines do not outlive shutdown.
      // oxlint-disable-next-line no-await-in-loop
      await this.#writer.send({ type: "agent_event_settled", generation: state.generation, sequence: event.sequence })
    }
    await state.settled.promise
    if (this.#agentEvents.type === "closing" && this.#agentEvents.active === state.settled) {
      this.#agentEvents = { type: "closed" }
    }
  }

  async #dispatch(
    extensions: LoadedExtensionGeneration,
    message: Extract<HostMessage, { type: "session_start" | "session_shutdown" }>,
    operation: VoidDeferred
  ): Promise<void> {
    try {
      if (message.type === "session_shutdown") await this.#closeAgentEvents()
      const event: ExtensionLifecycleEvent =
        message.type === "session_start"
          ? { type: "session_start", reason: message.reason }
          : { type: "session_shutdown", reason: message.reason }
      const result = await extensions.dispatch(event, message.type === "session_start" ? message.context : undefined)
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
      await this.#closeAgentEvents()
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
    this.#abortInvocations()
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

  #abortInvocations(): void {
    for (const invocation of this.#invocations.values()) {
      if (invocation.type !== "responding") invocation.controller.abort()
    }
    this.#invocations.clear()
    this.#settledInvocationRequests.clear()
    this.#settledInvocationRequestOrder.length = 0
  }

  #fail(cause: unknown): void {
    if (this.#state.type === "failed" || this.#state.type === "stopped") return
    const error = cause instanceof Error ? cause : new Error(String(cause))
    this.#abortInvocations()
    this.#rejectSessionRequests(error)
    this.#state = { type: "failed", error }
    this.#writer.fail(error)
    this.#terminal.reject(error)
  }
}

export async function runExtensionWorkerProcess(input: Readable, output: Writable): Promise<void> {
  const decoder = new FramedJsonDecoder(validateHostMessage, extensionFramingLimits, extensionFramingLabel)
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

const unavailableOperation = () => Promise.reject(new Error("Extension session operations are unavailable"))
const unavailableSessionOperations: WorkerSessionOperations = Object.freeze({
  subagentsAvailable: false,
  getEntries: unavailableOperation,
  appendEntry: unavailableOperation,
  sendMessage: unavailableOperation,
  getActiveTools: unavailableOperation,
  setActiveTools: unavailableOperation,
  listSubagentProfiles: unavailableOperation,
  spawnSubagent: unavailableOperation,
  sendSubagent: unavailableOperation,
  continueSubagent: unavailableOperation,
  waitSubagents: unavailableOperation,
  interruptSubagent: unavailableOperation,
  closeSubagent: unavailableOperation,
  listSubagents: unavailableOperation
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
  const agentStartHandlers: AgentEventHandler<ExtensionAgentStartEvent>[] = []
  const agentSettledHandlers: AgentEventHandler<ExtensionAgentSettledEvent>[] = []
  const commands: RegisteredCommand[] = []
  const commandNames = new Set<string>()
  const tools: RegisteredTool[] = []
  const toolNames = new Set<string>()
  const subagents: ExtensionSubagentRegistration[] = []
  const subagentNames = new Set<string>()

  for (const source of plan.sources) {
    const localStart: StartHandler[] = []
    const localShutdown: ShutdownHandler[] = []
    const localAgentStart: AgentEventHandler<ExtensionAgentStartEvent>[] = []
    const localAgentSettled: AgentEventHandler<ExtensionAgentSettledEvent>[] = []
    const localCommands: RegisteredCommand[] = []
    const localCommandNames = new Set<string>()
    const localTools: RegisteredTool[] = []
    const localToolNames = new Set<string>()
    const localSubagents: ExtensionSubagentRegistration[] = []
    const localSubagentNames = new Set<string>()
    let acceptingRegistrations = true
    const subagentApi: ExtensionSubagentAPI | undefined = sessionOperations.subagentsAvailable
      ? Object.freeze({
          listProfiles: () => sessionOperations.listSubagentProfiles(source),
          spawn: (profile, name, prompt, signal) =>
            sessionOperations.spawnSubagent(source, profile, name, prompt, signal),
          send: (name, text) => sessionOperations.sendSubagent(source, name, text),
          continue: (name, text) => sessionOperations.continueSubagent(source, name, text),
          wait: (names, timeoutMs, signal) => sessionOperations.waitSubagents(source, names, timeoutMs, signal),
          interrupt: name => sessionOperations.interruptSubagent(source, name),
          close: name => sessionOperations.closeSubagent(source, name),
          list: () => sessionOperations.listSubagents(source)
        } satisfies ExtensionSubagentAPI)
      : undefined
    const api = Object.freeze({
      ...(subagentApi ? { subagents: subagentApi } : {}),
      on(registeredEvent: unknown, handler: unknown): void {
        if (!acceptingRegistrations) throw new Error("Extension registration closed after factory settlement")
        if (typeof handler !== "function") throw new Error("Extension lifecycle handlers must be functions")
        if (
          startHandlers.length +
            shutdownHandlers.length +
            agentStartHandlers.length +
            agentSettledHandlers.length +
            localStart.length +
            localShutdown.length +
            localAgentStart.length +
            localAgentSettled.length >=
          maxExtensionEventHandlers
        ) {
          throw new Error(`Extension generations cannot register more than ${maxExtensionEventHandlers} event handlers`)
        }
        if (registeredEvent === "session_start") {
          localStart.push({
            source,
            handler: (lifecycleEvent, context) =>
              Promise.resolve(handler(lifecycleEvent, context)).then(() => undefined)
          })
          return
        }
        if (registeredEvent === "session_shutdown") {
          localShutdown.push({
            source,
            handler: (lifecycleEvent, context) =>
              Promise.resolve(handler(lifecycleEvent, context)).then(() => undefined)
          })
          return
        }
        if (registeredEvent === "agent_start") {
          localAgentStart.push({
            source,
            handler: (agentEvent, context) => Promise.resolve(handler(agentEvent, context)).then(() => undefined)
          })
          return
        }
        if (registeredEvent === "agent_settled") {
          localAgentSettled.push({
            source,
            handler: (agentEvent, context) => Promise.resolve(handler(agentEvent, context)).then(() => undefined)
          })
          return
        }
        throw new Error(`Unknown extension event: ${String(registeredEvent)}`)
      },
      registerCommand(value: unknown): void {
        if (!acceptingRegistrations) {
          throw new ExtensionRegistrationError("Extension registration closed after factory settlement")
        }
        if (commands.length + localCommands.length >= maxExtensionCommands) {
          throw new ExtensionRegistrationError(
            `Extension generations cannot register more than ${maxExtensionCommands} commands`
          )
        }
        const registered = registerCommand(source, value)
        const name = registered.registration.name
        if (commandNames.has(name) || localCommandNames.has(name)) {
          throw new ExtensionRegistrationError(`Duplicate extension command name: ${name}`)
        }
        validateExtensionCommandCatalog([
          ...commands.map(command => command.registration),
          ...localCommands.map(command => command.registration),
          registered.registration
        ])
        localCommandNames.add(name)
        localCommands.push(registered)
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
      getActiveTools() {
        return sessionOperations.getActiveTools(source)
      },
      setActiveTools(names: readonly string[]) {
        return sessionOperations.setActiveTools(source, names)
      },
      registerSubagentProfile(value: ExtensionSubagentProfile): void {
        if (!acceptingRegistrations) {
          throw new ExtensionRegistrationError("Extension registration closed after factory settlement")
        }
        if (subagents.length + localSubagents.length >= maxExtensionSubagentProfiles) {
          throw new ExtensionRegistrationError(
            `Extension generations cannot register more than ${maxExtensionSubagentProfiles} subagent profiles`
          )
        }
        const registered = validateExtensionSubagentCatalog([{ ...value, source }])[0]!
        if (subagentNames.has(registered.name) || localSubagentNames.has(registered.name)) {
          throw new ExtensionRegistrationError(`Duplicate extension subagent profile name: ${registered.name}`)
        }
        validateExtensionSubagentCatalog([...subagents, ...localSubagents, registered])
        localSubagentNames.add(registered.name)
        localSubagents.push(registered)
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
      agentStartHandlers.push(...localAgentStart)
      agentSettledHandlers.push(...localAgentSettled)
      commands.push(...localCommands)
      for (const name of localCommandNames) commandNames.add(name)
      tools.push(...localTools)
      for (const name of localToolNames) toolNames.add(name)
      subagents.push(...localSubagents)
      for (const name of localSubagentNames) subagentNames.add(name)
      results.push(Object.freeze({ source, status: "loaded" }))
    } catch (cause) {
      acceptingRegistrations = false
      results.push(
        failedResult(source, cause instanceof ExtensionRegistrationError ? "registration" : "factory", cause)
      )
    }
  }

  return new LoadedExtensionGeneration(
    results,
    startHandlers,
    shutdownHandlers,
    agentStartHandlers,
    agentSettledHandlers,
    commands,
    tools,
    subagents
  )
}

function registerCommand(source: ExtensionSource, value: unknown): RegisteredCommand {
  if (!isRecord(value)) throw new ExtensionRegistrationError("Extension commands must be objects")
  if (!isCallable(value.execute)) {
    throw new ExtensionRegistrationError("Extension commands require an execute function")
  }
  let registration: ExtensionCommandRegistration
  try {
    registration = validateExtensionCommandRegistration({
      source,
      name: value.name,
      description: value.description,
      ...(value.argumentHint === undefined ? {} : { argumentHint: value.argumentHint })
    })
  } catch (cause) {
    throw new ExtensionRegistrationError(cause instanceof Error ? cause.message : String(cause), { cause })
  }
  const execute: (...arguments_: unknown[]) => unknown = value.execute
  return Object.freeze({
    registration,
    execute: (arguments_: string, context: ExtensionCommandContext) => Promise.resolve(execute(arguments_, context))
  })
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
      active: value.active ?? true,
      ...(value.timeoutMs === undefined ? {} : { timeoutMs: value.timeoutMs }),
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
  phase: "import" | "factory" | "registration" | "lifecycle" | "event",
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
  return phase === "lifecycle" || phase === "event"
    ? boundedExtensionDiagnostic(diagnostic)
    : boundedExtensionLoadDiagnostic(diagnostic)
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

function forbiddenAgentEvent(state: LifecycleState, event: ExtensionAgentEvent["type"]): Error {
  return new Error(`Cannot dispatch ${event} while extension lifecycle is ${state.type}`)
}

function forbiddenLifecycle(state: LifecycleState, event: ExtensionLifecycleEvent["type"]): Error {
  return new Error(`Cannot dispatch ${event} while extension lifecycle is ${state.type}`)
}

function isCallable(value: unknown): value is (...arguments_: unknown[]) => unknown {
  return typeof value === "function"
}

function assertNever(value: never): never {
  throw new Error(`Unknown extension worker state: ${String(value)}`)
}
