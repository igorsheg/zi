import type { Readable, Writable } from "node:stream"
import { pathToFileURL } from "node:url"

import type {
  ExtensionAPI,
  ExtensionLifecycleEvent,
  ExtensionShutdownEvent,
  ExtensionStartEvent
} from "@with-zi/extension-api"

import type { ExtensionLoadPlan, ExtensionSource } from "./discovery.js"
import {
  boundedExtensionDiagnostic,
  boundedExtensionLoadDiagnostic,
  extensionLifecycleTimeoutMs,
  ExtensionProtocolDecoder,
  ExtensionProtocolError,
  ExtensionProtocolWriter,
  extensionProtocolVersion,
  extensionStartupTimeoutMs,
  maxExtensionDiagnostics,
  type ExtensionDiagnostic,
  type ExtensionLoadResult,
  type HostMessage,
  validateHostMessage
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
  readonly #startHandlers: readonly StartHandler[]
  readonly #shutdownHandlers: readonly ShutdownHandler[]
  #state: LifecycleState = { type: "loaded" }

  constructor(
    results: readonly ExtensionLoadResult[],
    startHandlers: readonly StartHandler[],
    shutdownHandlers: readonly ShutdownHandler[]
  ) {
    this.results = Object.freeze([...results])
    this.#startHandlers = Object.freeze([...startHandlers])
    this.#shutdownHandlers = Object.freeze([...shutdownHandlers])
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
  #state: WorkerProcessState = { type: "awaiting_initialize" }

  constructor(output: Writable) {
    this.#writer = new ExtensionProtocolWriter(output, cause => this.#fail(cause))
  }

  get terminal(): Promise<void> {
    return this.#terminal.promise
  }

  receive(message: HostMessage): void {
    const state = this.#state
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
    if (message.type === "cancel" && state.type === "dispatching") {
      if (message.generation !== state.generation || message.requestId !== state.requestId) {
        this.#protocolFailure("Extension worker received cancellation for a stale request")
        return
      }
      this.#state = { ...state, type: "cancelling" }
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

    if (message.type === "session_start" || message.type === "session_shutdown") {
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
    this.#writer.dispose()
  }

  async #initialize(message: Extract<HostMessage, { type: "initialize" }>, operation: VoidDeferred): Promise<void> {
    try {
      const extensions = await loadExtensionGeneration(message.plan, message.generation)
      const state = this.#state
      if (state.type !== "initializing" || state.generation !== message.generation) return
      await this.#writer.send({
        type: "ready",
        protocolVersion: extensionProtocolVersion,
        generation: message.generation,
        extensions: extensions.results
      })
      if (this.#state === state) this.#state = { type: "ready", generation: message.generation, extensions }
    } catch (cause) {
      this.#fatal(message.generation, fatalDiagnostic("handshake", cause), cause)
    } finally {
      operation.resolve()
    }
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
      await this.#writer.send({ type: "settled", generation: message.generation, requestId: message.requestId })
      const completedState = this.#state
      if (
        (completedState.type === "dispatching" || completedState.type === "cancelling") &&
        completedState.requestId === message.requestId
      ) {
        this.#state = { type: "ready", generation: message.generation, extensions }
      }
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
    this.#state = { type: "failed", error }
    void this.#writer.send({ type: "fatal", generation, diagnostic }).then(
      () => this.#terminal.reject(error),
      writerCause => this.#terminal.reject(writerCause)
    )
  }

  #fail(cause: unknown): void {
    if (this.#state.type === "failed" || this.#state.type === "stopped") return
    const error = cause instanceof Error ? cause : new Error(String(cause))
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

export async function loadExtensionGeneration(
  plan: ExtensionLoadPlan,
  generation: number,
  factoryTimeoutMs = extensionStartupTimeoutMs
): Promise<LoadedExtensionGeneration> {
  if (!Number.isSafeInteger(generation) || generation <= 0) {
    throw new Error("Extension generation must be a positive safe integer")
  }
  validateTimeout(factoryTimeoutMs)

  const results: ExtensionLoadResult[] = []
  const startHandlers: StartHandler[] = []
  const shutdownHandlers: ShutdownHandler[] = []

  for (const source of plan.sources) {
    const localStart: StartHandler[] = []
    const localShutdown: ShutdownHandler[] = []
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
      results.push(Object.freeze({ source, status: "loaded" }))
    } catch (cause) {
      acceptingRegistrations = false
      results.push(failedResult(source, "factory", cause))
    }
  }

  return new LoadedExtensionGeneration(results, startHandlers, shutdownHandlers)
}

function failedResult(source: ExtensionSource, phase: "import" | "factory", cause: unknown): ExtensionLoadResult {
  return Object.freeze({ source, status: "failed", diagnostic: diagnosticFor(source, phase, cause) })
}

function diagnosticFor(
  source: ExtensionSource,
  phase: "import" | "factory" | "lifecycle",
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

function deferred(): VoidDeferred {
  let resolve!: () => void
  let reject!: (cause: unknown) => void
  const promise = new Promise<void>((resolvePromise, rejectPromise) => {
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
  return typeof value === "object" && value !== null
}

function assertNever(value: never): never {
  throw new Error(`Unknown extension worker state: ${String(value)}`)
}
