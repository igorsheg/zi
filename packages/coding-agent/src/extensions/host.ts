import { spawn } from "node:child_process"
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { delimiter, isAbsolute, join } from "node:path"
import { Readable, Writable } from "node:stream"

import type {
  ExtensionCustomEntry,
  ExtensionCustomMessage,
  ExtensionMessageDelivery,
  ExtensionShutdownReason,
  ExtensionStartReason,
  JsonValue as ExtensionJsonValue
} from "@with-zi/extension-api"

import type { ExtensionLoadPlan } from "./discovery.js"
import {
  boundedExtensionDiagnostic,
  boundedExtensionSessionOperationError,
  extensionLifecycleTimeoutMs,
  ExtensionProtocolDecoder,
  ExtensionProtocolWriter,
  extensionProtocolVersion,
  extensionShutdownTimeoutMs,
  extensionStartupTimeoutMs,
  extensionToolCancellationTimeoutMs,
  extensionToolTimeoutMs,
  maxExtensionDiagnostics,
  maxExtensionLogBytesPerStream,
  maxExtensionPendingRequests,
  type ExtensionDiagnostic,
  type ExtensionLoadResult,
  type ExtensionSessionRequest,
  type ExtensionSessionResponse,
  type ExtensionToolRegistration,
  type HostMessage,
  type JsonValue,
  type WorkerMessage,
  validateExtensionToolArguments,
  validateWorkerMessage
} from "./protocol.js"
import { extensionApiModuleSource } from "./public-api-module.js"
import { extensionWorkerArgument } from "./worker-mode.js"

export interface ExtensionWorkerExit {
  readonly code: number | null
  readonly signal: NodeJS.Signals | null
  readonly error?: Error
}

export interface ExtensionWorkerProcess {
  readonly input: Writable
  readonly stdout: Readable
  readonly stderr: Readable
  readonly protocol: Readable
  readonly exited: Promise<ExtensionWorkerExit>
  terminate(force: boolean): void
  dispose(): void
}

export type SpawnExtensionWorker = (plan: ExtensionLoadPlan) => ExtensionWorkerProcess

export interface ExtensionSessionOperations {
  getEntries(customType: string): readonly ExtensionCustomEntry[]
  appendEntry(customType: string, data?: ExtensionJsonValue): ExtensionCustomEntry
  sendMessage(message: ExtensionCustomMessage, delivery: ExtensionMessageDelivery): void
}

export interface ExtensionHostTimeouts {
  readonly startupMs: number
  readonly lifecycleMs: number
  readonly shutdownMs: number
  readonly toolMs: number
  readonly toolCancellationMs: number
}

export const defaultExtensionHostTimeouts: ExtensionHostTimeouts = Object.freeze({
  startupMs: extensionStartupTimeoutMs,
  lifecycleMs: extensionLifecycleTimeoutMs,
  shutdownMs: extensionShutdownTimeoutMs,
  toolMs: extensionToolTimeoutMs,
  toolCancellationMs: extensionToolCancellationTimeoutMs
})

export type ExtensionReplacementReason = Exclude<ExtensionStartReason, "startup">
export type ExtensionHostLifecycle = "unbound" | "started" | "stopped"
export type ExtensionHostStatus =
  | "disabled"
  | "starting"
  | "ready"
  | "dispatching"
  | "replacing"
  | "stopping"
  | "failed"
  | "disposed"

export interface ExtensionLogTail {
  readonly text: string
  readonly retainedBytes: number
  readonly omittedBytes: number
}

export interface ExtensionHostSnapshot {
  readonly status: ExtensionHostStatus
  readonly lifecycle: ExtensionHostLifecycle
  readonly extensions: readonly ExtensionLoadResult[]
  readonly tools: readonly ExtensionToolRegistration[]
  readonly diagnostics: readonly ExtensionDiagnostic[]
  readonly failure?: ExtensionDiagnostic
  readonly omittedDiagnostics: number
  readonly staleFrames: number
  readonly stdout: ExtensionLogTail
  readonly stderr: ExtensionLogTail
}

type Candidate =
  | { readonly type: "spawning"; readonly id: number; readonly plan: ExtensionLoadPlan }
  | { readonly type: "spawned"; readonly generation: ExtensionGeneration }

type ExtensionHostState =
  | { readonly type: "disabled"; readonly lifecycle: ExtensionHostLifecycle }
  | { readonly type: "starting"; readonly lifecycle: ExtensionHostLifecycle; readonly candidate: Candidate }
  | { readonly type: "ready"; readonly lifecycle: ExtensionHostLifecycle; readonly current: ExtensionGeneration }
  | {
      readonly type: "dispatching"
      readonly lifecycle: ExtensionHostLifecycle
      readonly current: ExtensionGeneration
      readonly event: "session_start" | "session_shutdown"
    }
  | {
      readonly type: "replacing"
      readonly lifecycle: ExtensionHostLifecycle
      readonly current: ExtensionGeneration
      readonly candidate: Candidate | { readonly type: "empty" }
    }
  | {
      readonly type: "stopping"
      readonly lifecycle: ExtensionHostLifecycle
      readonly generations: readonly ExtensionGeneration[]
      readonly shutdown?: ExtensionGeneration
      readonly cleanups: readonly Promise<void>[]
      readonly settled: VoidDeferred
    }
  | {
      readonly type: "failed"
      readonly lifecycle: ExtensionHostLifecycle
      readonly diagnostic: ExtensionDiagnostic
      readonly cleanup: Promise<void>
    }
  | { readonly type: "disposed" }

type GenerationLifecycle = "loaded" | "started" | "stopped"

interface ExtensionGenerationReady {
  readonly extensions: readonly ExtensionLoadResult[]
  readonly tools: readonly ExtensionToolRegistration[]
}

type GenerationToolInvocation =
  | {
      readonly type: "running"
      readonly requestId: number
      readonly registration: ExtensionToolRegistration
      readonly settled: Deferred<string>
      readonly signal?: AbortSignal
      readonly onAbort?: () => void
      readonly timeout: ReturnType<typeof setTimeout>
    }
  | {
      readonly type: "cancelling"
      readonly requestId: number
      readonly registration: ExtensionToolRegistration
      readonly settled: Deferred<string>
      readonly signal: AbortSignal
      readonly onAbort: () => void
      readonly timeout: ReturnType<typeof setTimeout>
    }

type GenerationState =
  | { readonly type: "starting"; readonly ready: Deferred<ExtensionGenerationReady> }
  | { readonly type: "ready"; readonly lifecycle: GenerationLifecycle }
  | {
      readonly type: "requesting"
      readonly requestId: number
      readonly request: "session_start" | "session_shutdown"
      readonly lifecycle: GenerationLifecycle
      readonly settled: VoidDeferred
    }
  | {
      readonly type: "disposing_stopping"
      readonly requestId: number
      readonly settled: VoidDeferred
      readonly disposal: VoidDeferred
    }
  | { readonly type: "disposing_waiting_exit"; readonly disposal: VoidDeferred }
  | { readonly type: "disposing_terminating"; readonly disposal: VoidDeferred }
  | { readonly type: "failed"; readonly error: ExtensionGenerationError }
  | { readonly type: "disposed" }

type ExtensionSessionRequestOutcome =
  | { readonly type: "custom_entries_result"; readonly entries: readonly ExtensionCustomEntry[] }
  | { readonly type: "custom_entry_result"; readonly entry: ExtensionCustomEntry }
  | { readonly type: "custom_message_result" }
  | { readonly type: "session_operation_error"; readonly message: string }

type ProcessStatus = { readonly type: "running" } | { readonly type: "exited"; readonly exit: ExtensionWorkerExit }

class ExtensionGenerationError extends Error {
  readonly diagnostic: ExtensionDiagnostic

  constructor(value: ExtensionDiagnostic, options?: ErrorOptions) {
    super(value.message, options)
    this.name = "ExtensionGenerationError"
    this.diagnostic = value
  }
}

class ExtensionToolExecutionError extends Error {
  constructor(message: string) {
    super(message)
    this.name = "ExtensionToolExecutionError"
  }
}

class LogTail {
  #bytes = Buffer.alloc(0)
  #omittedBytes = 0

  append(chunk: Uint8Array): void {
    const incoming = Buffer.from(chunk.buffer, chunk.byteOffset, chunk.byteLength)
    if (incoming.byteLength >= maxExtensionLogBytesPerStream) {
      this.#omit(this.#bytes.byteLength + incoming.byteLength - maxExtensionLogBytesPerStream)
      this.#bytes = Buffer.from(incoming.subarray(incoming.byteLength - maxExtensionLogBytesPerStream))
      return
    }
    const overflow = this.#bytes.byteLength + incoming.byteLength - maxExtensionLogBytesPerStream
    if (overflow > 0) {
      this.#omit(overflow)
      this.#bytes = Buffer.concat([this.#bytes.subarray(overflow), incoming])
      return
    }
    this.#bytes = Buffer.concat([this.#bytes, incoming])
  }

  snapshot(): ExtensionLogTail {
    return Object.freeze({
      text: this.#bytes.toString("utf8"),
      retainedBytes: this.#bytes.byteLength,
      omittedBytes: this.#omittedBytes
    })
  }

  #omit(bytes: number): void {
    this.#omittedBytes = Math.min(Number.MAX_SAFE_INTEGER, this.#omittedBytes + bytes)
  }
}

class ExtensionGeneration {
  readonly id: number
  readonly plan: ExtensionLoadPlan
  readonly #process: ExtensionWorkerProcess
  readonly #writer: ExtensionProtocolWriter
  readonly #decoder = new ExtensionProtocolDecoder(validateWorkerMessage)
  readonly #timeouts: ExtensionHostTimeouts
  readonly #onDiagnostic: (diagnostic: ExtensionDiagnostic) => void
  readonly #onFailure: (generation: ExtensionGeneration, diagnostic: ExtensionDiagnostic) => void
  readonly #onStaleFrame: () => void
  readonly #onSessionRequest: (
    generation: ExtensionGeneration,
    request: ExtensionSessionRequest
  ) => ExtensionSessionRequestOutcome
  readonly #stdout = new LogTail()
  readonly #stderr = new LogTail()
  readonly #toolInvocations = new Map<number, GenerationToolInvocation>()
  readonly #sessionResponses = new Set<number>()
  #lastSessionRequestId = 0
  #tools: readonly ExtensionToolRegistration[] = Object.freeze([])
  readonly #onProtocolData: (chunk: Buffer) => void
  readonly #onProtocolEnd: () => void
  readonly #onProtocolError: (cause: Error) => void
  readonly #onStdoutData: (chunk: Buffer) => void
  readonly #onStderrData: (chunk: Buffer) => void
  readonly #onStdoutError: (cause: Error) => void
  readonly #onStderrError: (cause: Error) => void
  #state: GenerationState
  #processStatus: ProcessStatus = { type: "running" }
  #nextRequestId = 1

  constructor(
    id: number,
    plan: ExtensionLoadPlan,
    process: ExtensionWorkerProcess,
    timeouts: ExtensionHostTimeouts,
    onDiagnostic: (diagnostic: ExtensionDiagnostic) => void,
    onFailure: (generation: ExtensionGeneration, diagnostic: ExtensionDiagnostic) => void,
    onStaleFrame: () => void,
    onSessionRequest: (
      generation: ExtensionGeneration,
      request: ExtensionSessionRequest
    ) => ExtensionSessionRequestOutcome
  ) {
    this.id = id
    this.plan = plan
    this.#process = process
    this.#timeouts = timeouts
    this.#onDiagnostic = onDiagnostic
    this.#onFailure = onFailure
    this.#onStaleFrame = onStaleFrame
    this.#onSessionRequest = onSessionRequest
    this.#state = { type: "starting", ready: deferred<ExtensionGenerationReady>() }
    this.#writer = new ExtensionProtocolWriter(process.input, cause =>
      this.#fail("protocol", "Extension worker protocol output failed", cause)
    )
    this.#onProtocolData = chunk => this.#receiveBytes(chunk)
    this.#onProtocolEnd = () => this.#protocolEnded()
    this.#onProtocolError = cause => this.#fail("protocol", "Extension worker protocol input failed", cause)
    this.#onStdoutData = chunk => this.#stdout.append(chunk)
    this.#onStderrData = chunk => this.#stderr.append(chunk)
    this.#onStdoutError = cause => this.#logFailure("stdout", cause)
    this.#onStderrError = cause => this.#logFailure("stderr", cause)
    process.protocol.on("data", this.#onProtocolData)
    process.protocol.once("end", this.#onProtocolEnd)
    process.protocol.once("error", this.#onProtocolError)
    process.stdout.on("data", this.#onStdoutData)
    process.stderr.on("data", this.#onStderrData)
    process.stdout.on("error", this.#onStdoutError)
    process.stderr.on("error", this.#onStderrError)
    void process.exited.then(exit => this.#processExited(exit))
  }

  get lifecycle(): GenerationLifecycle | undefined {
    const state = this.#state
    if (state.type === "ready" || state.type === "requesting") return state.lifecycle
    return undefined
  }

  get failure(): ExtensionDiagnostic | undefined {
    return this.#state.type === "failed" ? this.#state.error.diagnostic : undefined
  }

  get tools(): readonly ExtensionToolRegistration[] {
    return this.#tools
  }

  logs(): { readonly stdout: ExtensionLogTail; readonly stderr: ExtensionLogTail } {
    return Object.freeze({ stdout: this.#stdout.snapshot(), stderr: this.#stderr.snapshot() })
  }

  async initialize(): Promise<ExtensionGenerationReady> {
    const state = this.#state
    if (state.type !== "starting") throw new Error("Extension generation initialization was already admitted")
    const initialize: HostMessage = {
      type: "initialize",
      protocolVersion: extensionProtocolVersion,
      generation: this.id,
      plan: this.plan
    }
    try {
      return await within(
        Promise.all([this.#writer.send(initialize), state.ready.promise]).then(([, extensions]) => extensions),
        this.#timeouts.startupMs,
        "Extension worker startup deadline exceeded"
      )
    } catch (cause) {
      if (cause instanceof ExtensionGenerationError) throw cause
      this.#fail("handshake", errorMessage(cause, "Extension worker startup failed"), cause)
      throw generationError(this.#state, cause)
    }
  }

  async requestStart(reason: ExtensionStartReason): Promise<void> {
    const admitted = this.#admitRequest("session_start")
    void this.#runRequest(
      { type: "session_start", generation: this.id, requestId: admitted.requestId, reason },
      admitted.settled
    )
    return admitted.settled.promise
  }

  async requestShutdown(reason: ExtensionShutdownReason): Promise<void> {
    const admitted = this.#admitRequest("session_shutdown")
    void this.#runRequest(
      { type: "session_shutdown", generation: this.id, requestId: admitted.requestId, reason },
      admitted.settled
    )
    return admitted.settled.promise
  }

  requestTool(name: string, arguments_: Readonly<Record<string, JsonValue>>, signal?: AbortSignal): Promise<string> {
    const state = this.#state
    if (state.type !== "ready" || state.lifecycle !== "started") {
      return Promise.reject(new Error(`Extension generation cannot invoke tools while ${state.type}`))
    }
    const registration = this.#tools.find(tool => tool.name === name)
    if (!registration) return Promise.reject(new Error(`Unknown extension tool: ${name}`))
    if (this.#toolInvocations.size >= maxExtensionPendingRequests) {
      return Promise.reject(
        new Error(`Extension generation cannot run more than ${maxExtensionPendingRequests} tool invocations`)
      )
    }
    if (signal?.aborted) return Promise.reject(abortError())

    const requestId = this.#takeRequestId()
    const settled = deferred<string>()
    const onAbort = signal ? () => this.#cancelToolInvocation(requestId) : undefined
    const timeout = setTimeout(
      () => this.#toolInvocationTimedOut(requestId, "Extension tool deadline exceeded"),
      this.#timeouts.toolMs
    )
    timeout.unref?.()
    const invocation: GenerationToolInvocation = {
      type: "running",
      requestId,
      registration,
      settled,
      ...(signal ? { signal } : {}),
      ...(onAbort ? { onAbort } : {}),
      timeout
    }
    this.#toolInvocations.set(requestId, invocation)
    if (signal && onAbort) signal.addEventListener("abort", onAbort, { once: true })
    void this.#writer
      .send({ type: "tool_invoke", generation: this.id, requestId, name, arguments: arguments_ })
      .catch(cause => {
        const message = errorMessage(cause, "Extension tool request failed")
        this.#fail("tool", message, cause, this.#toolDiagnostic(registration, message))
      })
    return settled.promise
  }

  dispose(): Promise<void> {
    const state = this.#state
    if (this.#toolInvocations.size > 0) {
      const error = new Error("Extension generation disposed during tool invocation")
      for (const invocation of this.#toolInvocations.values()) {
        this.#finishToolInvocation(invocation, { error })
      }
      const disposal = deferred<void>()
      this.#state = { type: "disposing_terminating", disposal }
      void this.#terminateAndRelease(disposal)
      return disposal.promise
    }
    switch (state.type) {
      case "disposed":
        return Promise.resolve()
      case "disposing_stopping":
      case "disposing_waiting_exit":
      case "disposing_terminating":
        return state.disposal.promise
      case "ready": {
        const disposal = deferred<void>()
        const settled = deferred<void>()
        const requestId = this.#takeRequestId()
        this.#state = { type: "disposing_stopping", requestId, settled, disposal }
        void this.#gracefulDispose(requestId, settled, disposal)
        return disposal.promise
      }
      case "starting":
        state.ready.reject(new Error("Extension generation was disposed during startup"))
        break
      case "requesting":
        state.settled.reject(new Error("Extension generation request was superseded by disposal"))
        break
      case "failed":
        break
      default:
        return assertNever(state)
    }
    const disposal = deferred<void>()
    this.#state = { type: "disposing_terminating", disposal }
    void this.#terminateAndRelease(disposal)
    return disposal.promise
  }

  #admitRequest(request: "session_start" | "session_shutdown"): {
    readonly requestId: number
    readonly settled: VoidDeferred
  } {
    const state = this.#state
    if (state.type !== "ready") {
      throw new Error(`Extension generation cannot dispatch ${request} while ${state.type}`)
    }
    if (request === "session_start" && state.lifecycle !== "loaded") {
      throw new Error(`Extension generation cannot start while ${state.lifecycle}`)
    }
    if (request === "session_shutdown" && state.lifecycle !== "started") {
      throw new Error(`Extension generation cannot shut down while ${state.lifecycle}`)
    }
    if (request === "session_shutdown" && this.#toolInvocations.size > 0) {
      throw new Error("Extension generation cannot shut down with active tool invocations")
    }

    const requestId = this.#takeRequestId()
    const settled = deferred<void>()
    this.#state = { type: "requesting", requestId, request, lifecycle: state.lifecycle, settled }
    return { requestId, settled }
  }

  #cancelToolInvocation(requestId: number): void {
    const invocation = this.#toolInvocations.get(requestId)
    if (!invocation || invocation.type !== "running" || !invocation.signal || !invocation.onAbort) return
    clearTimeout(invocation.timeout)
    const timeout = setTimeout(
      () => this.#toolInvocationTimedOut(requestId, "Extension tool cancellation deadline exceeded"),
      this.#timeouts.toolCancellationMs
    )
    timeout.unref?.()
    const cancelling: GenerationToolInvocation = {
      type: "cancelling",
      requestId,
      registration: invocation.registration,
      settled: invocation.settled,
      signal: invocation.signal,
      onAbort: invocation.onAbort,
      timeout
    }
    this.#toolInvocations.set(requestId, cancelling)
    void this.#writer.send({ type: "cancel", generation: this.id, requestId }).catch(cause => {
      const message = errorMessage(cause, "Extension tool cancellation failed")
      this.#fail("tool", message, cause, this.#toolDiagnostic(invocation.registration, message))
    })
  }

  #toolInvocationTimedOut(requestId: number, message: string): void {
    const invocation = this.#toolInvocations.get(requestId)
    if (!invocation) return
    this.#fail("tool", message, undefined, this.#toolDiagnostic(invocation.registration, message))
  }

  #toolDiagnostic(registration: ExtensionToolRegistration, message: string): ExtensionDiagnostic {
    return boundedExtensionDiagnostic({
      extensionId: registration.source.id,
      path: registration.source.entryPath,
      phase: "tool",
      severity: "error",
      message
    })
  }

  #finishToolInvocation(invocation: GenerationToolInvocation, outcome: { content: string } | { error: Error }): void {
    if (this.#toolInvocations.get(invocation.requestId) !== invocation) return
    this.#toolInvocations.delete(invocation.requestId)
    clearTimeout(invocation.timeout)
    if (invocation.signal && invocation.onAbort) {
      invocation.signal.removeEventListener("abort", invocation.onAbort)
    }
    if ("content" in outcome) invocation.settled.resolve(outcome.content)
    else invocation.settled.reject(outcome.error)
  }

  async #runRequest(message: HostMessage, settled: VoidDeferred): Promise<void> {
    try {
      await this.#writer.send(message)
      await within(settled.promise, this.#timeouts.lifecycleMs, "Extension lifecycle deadline exceeded")
    } catch (cause) {
      const state = this.#state
      if (state.type === "requesting" && state.settled === settled) {
        this.#fail("lifecycle", errorMessage(cause, "Extension lifecycle failed"), cause)
      }
    }
  }

  #receiveBytes(chunk: Buffer): void {
    try {
      for (const message of this.#decoder.push(chunk)) this.#receive(message)
    } catch (cause) {
      this.#fail("protocol", errorMessage(cause, "Extension worker sent invalid protocol data"), cause)
    }
  }

  #receive(message: WorkerMessage): void {
    if (message.generation !== this.id) {
      this.#onStaleFrame()
      return
    }
    const state = this.#state
    switch (message.type) {
      case "custom_entries_get":
      case "custom_entry_append":
      case "custom_message_send":
        this.#respondToSessionRequest(message)
        return
      case "ready":
        if (state.type !== "starting") {
          this.#fail("protocol", `Extension worker sent ready while ${state.type}`)
          return
        }
        if (!matchesLoadPlan(this.plan, message.extensions)) {
          this.#fail("handshake", "Extension worker ready results did not match its admitted load plan")
          return
        }
        if (!toolsMatchLoadedExtensions(message.tools, message.extensions)) {
          this.#fail("handshake", "Extension worker tools did not match its loaded extensions")
          return
        }
        this.#tools = message.tools
        this.#state = { type: "ready", lifecycle: "loaded" }
        state.ready.resolve({ extensions: message.extensions, tools: message.tools })
        return
      case "settled":
        if (state.type === "requesting" && state.requestId === message.requestId) {
          const lifecycle = state.request === "session_start" ? "started" : "stopped"
          this.#state = { type: "ready", lifecycle }
          state.settled.resolve()
          return
        }
        if (state.type === "disposing_stopping" && state.requestId === message.requestId) {
          this.#state = { type: "disposing_waiting_exit", disposal: state.disposal }
          state.settled.resolve()
          return
        }
        this.#fail("protocol", "Extension worker settled an unknown request")
        return
      case "tool_result":
      case "tool_error":
      case "tool_cancelled": {
        const invocation = this.#toolInvocations.get(message.requestId)
        if (!invocation) {
          this.#fail("protocol", "Extension worker settled an unknown tool request")
          return
        }
        if (invocation.type === "cancelling") {
          this.#finishToolInvocation(invocation, { error: abortError() })
          return
        }
        if (message.type === "tool_result") {
          this.#finishToolInvocation(invocation, { content: message.content })
          return
        }
        if (message.type === "tool_error") {
          this.#finishToolInvocation(invocation, { error: new ExtensionToolExecutionError(message.message) })
          return
        }
        this.#fail("protocol", "Extension worker cancelled a tool request that was not cancelling")
        return
      }
      case "diagnostic":
        this.#onDiagnostic(message.diagnostic)
        return
      case "fatal":
        this.#fail(message.diagnostic.phase, message.diagnostic.message, undefined, message.diagnostic)
        return
      default:
        return assertNever(message)
    }
  }

  #respondToSessionRequest(request: ExtensionSessionRequest): void {
    if (this.#sessionResponses.size >= maxExtensionPendingRequests || request.requestId <= this.#lastSessionRequestId) {
      this.#fail("protocol", "Extension worker exceeded or reused its pending session-operation requests")
      return
    }
    this.#lastSessionRequestId = request.requestId

    let outcome: ExtensionSessionRequestOutcome
    try {
      outcome = this.#onSessionRequest(this, request)
    } catch (cause) {
      outcome = { type: "session_operation_error", message: boundedExtensionSessionOperationError(cause) }
    }
    const response: ExtensionSessionResponse = { ...outcome, generation: this.id, requestId: request.requestId }
    this.#sessionResponses.add(request.requestId)
    void this.#writer.send(response).then(
      () => {
        this.#sessionResponses.delete(request.requestId)
        return undefined
      },
      cause => {
        this.#sessionResponses.delete(request.requestId)
        this.#fail("protocol", "Extension session-operation response failed", cause)
        return undefined
      }
    )
  }

  #protocolEnded(): void {
    try {
      this.#decoder.end()
    } catch (cause) {
      this.#fail("protocol", errorMessage(cause, "Extension worker protocol ended with a partial frame"), cause)
      return
    }
    const state = this.#state
    if (
      state.type !== "disposing_waiting_exit" &&
      state.type !== "disposing_terminating" &&
      state.type !== "disposed" &&
      state.type !== "failed"
    ) {
      this.#fail(state.type === "starting" ? "handshake" : "protocol", "Extension worker protocol ended unexpectedly")
    }
  }

  #processExited(exit: ExtensionWorkerExit): void {
    if (this.#processStatus.type === "exited") return
    this.#processStatus = { type: "exited", exit }
    const state = this.#state
    if (
      state.type === "disposing_waiting_exit" ||
      state.type === "disposing_terminating" ||
      state.type === "disposed" ||
      state.type === "failed"
    ) {
      if (exit.error) {
        this.#onDiagnostic(
          diagnostic("shutdown", `Extension worker cleanup failed: ${exit.error.message}`, exit.error, "warning")
        )
      } else if (state.type === "failed") {
        const stderr = this.#stderr.snapshot().text.trim()
        const suffix = `code ${String(exit.code)}, signal ${String(exit.signal)}`
        this.#onDiagnostic(
          diagnostic(
            "shutdown",
            `Extension worker exited after failure (${suffix})${stderr ? `: ${stderr}` : ""}`,
            undefined,
            "warning"
          )
        )
      }
      return
    }
    const suffix = exit.error
      ? `: ${exit.error.message}`
      : ` (code ${String(exit.code)}, signal ${String(exit.signal)})`
    const phase = state.type === "starting" ? "handshake" : "protocol"
    this.#fail(phase, `Extension worker exited unexpectedly${suffix}`, exit.error)
  }

  async #gracefulDispose(requestId: number, settled: VoidDeferred, disposal: VoidDeferred): Promise<void> {
    const startedAt = Date.now()
    const graceEndsAt = startedAt + Math.floor(this.#timeouts.shutdownMs / 3)
    try {
      await this.#writer.send({ type: "stop", generation: this.id, requestId })
      await until(settled.promise, graceEndsAt, "Extension worker stop deadline exceeded")
      await until(this.#process.exited, graceEndsAt, "Extension worker exit deadline exceeded")
    } catch (cause) {
      this.#onDiagnostic(
        diagnostic("shutdown", errorMessage(cause, "Extension worker did not stop gracefully"), cause, "warning")
      )
    }
    await this.#terminateAndRelease(disposal, startedAt)
  }

  async #terminateAndRelease(disposal: VoidDeferred, startedAt = Date.now()): Promise<void> {
    if (this.#state.type !== "disposing_terminating") {
      this.#state = { type: "disposing_terminating", disposal }
    }
    const terminateEndsAt = startedAt + Math.floor((this.#timeouts.shutdownMs * 2) / 3)
    const forceEndsAt = startedAt + this.#timeouts.shutdownMs

    if (this.#processStatus.type === "running") {
      this.#process.terminate(false)
      await ignoreDeadline(this.#process.exited, terminateEndsAt)
    }
    if (this.#processStatus.type === "running") {
      this.#process.terminate(true)
      await ignoreDeadline(this.#process.exited, forceEndsAt)
    }
    if (this.#processStatus.type === "running") {
      this.#onDiagnostic(
        diagnostic("shutdown", "Extension worker did not exit before its forced shutdown deadline", undefined, "error")
      )
    }

    this.#release()
    this.#state = { type: "disposed" }
    disposal.resolve()
  }

  #fail(
    phase: ExtensionDiagnostic["phase"],
    message: string,
    cause?: unknown,
    suppliedDiagnostic?: ExtensionDiagnostic
  ): void {
    const state = this.#state
    if (state.type === "failed" || state.type === "disposed" || state.type === "disposing_terminating") return
    const diagnosticValue = suppliedDiagnostic ?? diagnostic(phase, message, cause)
    const error = new ExtensionGenerationError(diagnosticValue, cause === undefined ? undefined : { cause })
    for (const invocation of this.#toolInvocations.values()) {
      this.#finishToolInvocation(invocation, { error })
    }
    this.#sessionResponses.clear()

    if (state.type === "disposing_stopping") {
      state.settled.reject(error)
      this.#state = { type: "disposing_terminating", disposal: state.disposal }
    } else if (state.type === "disposing_waiting_exit") {
      this.#state = { type: "disposing_terminating", disposal: state.disposal }
    } else {
      if (state.type === "starting") state.ready.reject(error)
      if (state.type === "requesting") state.settled.reject(error)
      this.#state = { type: "failed", error }
    }
    this.#writer.fail(error)
    this.#onFailure(this, diagnosticValue)
  }

  #logFailure(stream: "stdout" | "stderr", cause: Error): void {
    this.#onDiagnostic(
      diagnostic("protocol", `Extension worker ${stream} log stream failed: ${cause.message}`, cause, "warning")
    )
  }

  #takeRequestId(): number {
    const requestId = this.#nextRequestId
    if (!Number.isSafeInteger(requestId)) throw new Error("Extension request IDs are exhausted")
    this.#nextRequestId++
    return requestId
  }

  #release(): void {
    const error = new Error("Extension generation disposed during tool invocation")
    for (const invocation of this.#toolInvocations.values()) {
      this.#finishToolInvocation(invocation, { error })
    }
    this.#sessionResponses.clear()
    this.#writer.dispose()
    this.#process.protocol.off("data", this.#onProtocolData)
    this.#process.protocol.off("end", this.#onProtocolEnd)
    this.#process.protocol.off("error", this.#onProtocolError)
    this.#process.stdout.off("data", this.#onStdoutData)
    this.#process.stderr.off("data", this.#onStderrData)
    this.#process.stdout.off("error", this.#onStdoutError)
    this.#process.stderr.off("error", this.#onStderrError)
    this.#process.input.destroy()
    this.#process.protocol.destroy()
    this.#process.stdout.destroy()
    this.#process.stderr.destroy()
    try {
      this.#process.dispose()
    } catch (cause) {
      this.#onDiagnostic(
        diagnostic("shutdown", errorMessage(cause, "Extension worker process cleanup failed"), cause, "warning")
      )
    }
  }
}

export class ExtensionHost {
  readonly #spawnWorker: SpawnExtensionWorker
  readonly #timeouts: ExtensionHostTimeouts
  readonly #diagnostics: ExtensionDiagnostic[] = []
  #state: ExtensionHostState = { type: "disabled", lifecycle: "unbound" }
  #nextGenerationId = 1
  #omittedDiagnostics = 0
  #staleFrames = 0
  #extensions: readonly ExtensionLoadResult[] = Object.freeze([])
  #tools: readonly ExtensionToolRegistration[] = Object.freeze([])
  #toolCatalogListener: ((tools: readonly ExtensionToolRegistration[]) => void) | undefined
  #sessionOperations: ExtensionSessionOperations | undefined
  #lastLogs: { readonly stdout: ExtensionLogTail; readonly stderr: ExtensionLogTail } = Object.freeze({
    stdout: emptyLogTail(),
    stderr: emptyLogTail()
  })

  constructor(spawnWorker: SpawnExtensionWorker, timeouts: ExtensionHostTimeouts = defaultExtensionHostTimeouts) {
    validateTimeouts(timeouts)
    this.#spawnWorker = spawnWorker
    this.#timeouts = Object.freeze({ ...timeouts })
  }

  static async create(
    plan: ExtensionLoadPlan,
    spawnWorker: SpawnExtensionWorker,
    timeouts: ExtensionHostTimeouts = defaultExtensionHostTimeouts
  ): Promise<ExtensionHost> {
    const host = new ExtensionHost(spawnWorker, timeouts)
    await host.start(plan)
    return host
  }

  admitDiagnostics(values: readonly ExtensionDiagnostic[], omitted = 0): void {
    const state = this.#state
    if (state.type !== "disabled" || state.lifecycle !== "unbound") {
      throw new Error("Extension host diagnostics must be admitted before startup")
    }
    if (!Number.isSafeInteger(omitted) || omitted < 0) {
      throw new Error("Omitted extension diagnostics must be a non-negative safe integer")
    }
    for (const value of values) this.#diagnose(boundedExtensionDiagnostic(value))
    this.#omittedDiagnostics = Math.min(Number.MAX_SAFE_INTEGER, this.#omittedDiagnostics + omitted)
  }

  async start(plan: ExtensionLoadPlan): Promise<void> {
    const state = this.#state
    if (state.type !== "disabled" && state.type !== "failed") {
      throw new Error(`Extension host cannot start while ${state.type}`)
    }
    if (state.type === "failed") {
      await state.cleanup
      if (this.#state !== state) return
    }
    await this.#startPlan(plan, state.lifecycle)
  }

  snapshot(): ExtensionHostSnapshot {
    const state = this.#state
    const logs = this.#activeGeneration(state)?.logs() ?? this.#lastLogs
    return Object.freeze({
      status: hostStatus(state),
      lifecycle: state.type === "disposed" ? "stopped" : state.lifecycle,
      extensions: this.#extensions,
      tools: this.#tools,
      diagnostics: Object.freeze([...this.#diagnostics]),
      ...(state.type === "failed" ? { failure: state.diagnostic } : {}),
      omittedDiagnostics: this.#omittedDiagnostics,
      staleFrames: this.#staleFrames,
      stdout: logs.stdout,
      stderr: logs.stderr
    })
  }

  toolCatalog(): readonly ExtensionToolRegistration[] {
    return this.#tools
  }

  bindSessionOperations(operations: ExtensionSessionOperations): () => void {
    if (this.#state.type === "disposed") throw new Error("Extension host is disposed")
    if (this.#sessionOperations) throw new Error("Extension host session operations are already bound")
    this.#sessionOperations = operations
    return () => {
      if (this.#sessionOperations === operations) this.#sessionOperations = undefined
    }
  }

  bindToolCatalog(listener: (tools: readonly ExtensionToolRegistration[]) => void): () => void {
    if (this.#state.type === "disposed") throw new Error("Extension host is disposed")
    if (this.#toolCatalogListener) throw new Error("Extension host tool catalog is already bound")
    this.#toolCatalogListener = listener
    return () => {
      if (this.#toolCatalogListener === listener) this.#toolCatalogListener = undefined
    }
  }

  invokeTool(name: string, arguments_: unknown, signal?: AbortSignal): Promise<string> {
    const state = this.#state
    if (state.type !== "ready" || state.lifecycle !== "started") {
      return Promise.reject(new Error(`Extension host cannot invoke tools while ${state.type}`))
    }
    if (!this.#tools.some(tool => tool.name === name)) {
      return Promise.reject(new Error(`Unknown admitted extension tool: ${name}`))
    }
    let parameters: Readonly<Record<string, JsonValue>>
    try {
      parameters = validateExtensionToolArguments(arguments_)
    } catch (cause) {
      return Promise.reject(cause)
    }
    return state.current.requestTool(name, parameters, signal)
  }

  rejectTool(tool: ExtensionToolRegistration, message: string): void {
    if (!this.#tools.includes(tool)) throw new Error("Extension host cannot reject an unknown tool registration")
    this.#setToolCatalog(Object.freeze(this.#tools.filter(candidate => candidate !== tool)))
    this.#diagnose(
      boundedExtensionDiagnostic({
        extensionId: tool.source.id,
        path: tool.source.entryPath,
        phase: "registration",
        severity: "error",
        message
      })
    )
  }

  async sessionStart(reason: ExtensionStartReason): Promise<void> {
    const state = this.#state
    if (state.type === "disabled") {
      if (state.lifecycle !== "unbound") throw new Error(`Extension host cannot start while ${state.lifecycle}`)
      this.#state = { type: "disabled", lifecycle: "started" }
      return
    }
    if (state.type === "failed") {
      if (state.lifecycle !== "unbound") throw new Error(`Extension host cannot start while ${state.lifecycle}`)
      this.#state = { ...state, lifecycle: "started" }
      return
    }
    if (state.type !== "ready") throw new Error(`Extension host cannot start a session while ${state.type}`)
    if (state.lifecycle !== "unbound") throw new Error(`Extension host cannot start while ${state.lifecycle}`)

    const dispatching: ExtensionHostState = {
      type: "dispatching",
      lifecycle: state.lifecycle,
      current: state.current,
      event: "session_start"
    }
    this.#state = dispatching
    try {
      await state.current.requestStart(reason)
      if (this.#state === dispatching) {
        this.#state = { type: "ready", lifecycle: "started", current: state.current }
      }
    } catch (cause) {
      await this.#operationFailed(dispatching, state.current, cause, "started")
    }
  }

  async sessionShutdown(reason: ExtensionShutdownReason): Promise<void> {
    const state = this.#state
    if (state.type === "disabled") {
      if (state.lifecycle === "stopped") return
      this.#state = { type: "disabled", lifecycle: "stopped" }
      return
    }
    if (state.type === "failed") {
      if (state.lifecycle === "stopped") return
      this.#state = { ...state, lifecycle: "stopped" }
      return
    }
    if (state.type !== "ready") throw new Error(`Extension host cannot shut down a session while ${state.type}`)
    if (state.lifecycle === "stopped") return
    if (state.lifecycle === "unbound") {
      this.#state = { ...state, lifecycle: "stopped" }
      return
    }

    const dispatching: ExtensionHostState = {
      type: "dispatching",
      lifecycle: state.lifecycle,
      current: state.current,
      event: "session_shutdown"
    }
    this.#state = dispatching
    try {
      await state.current.requestShutdown(reason)
      if (this.#state === dispatching) {
        this.#state = { type: "ready", lifecycle: "stopped", current: state.current }
      }
    } catch (cause) {
      await this.#operationFailed(dispatching, state.current, cause, "stopped")
    }
  }

  async reload(plan: ExtensionLoadPlan, reason: ExtensionReplacementReason = "reload"): Promise<void> {
    const state = this.#state
    if (state.type === "disposed" || state.type === "stopping") {
      throw new Error(`Extension host cannot reload while ${state.type}`)
    }
    if (state.type === "starting" || state.type === "dispatching" || state.type === "replacing") {
      throw new Error(`Extension host cannot reload while ${state.type}`)
    }
    if (state.lifecycle === "stopped") throw new Error("Extension host cannot reload after session shutdown")
    if (state.type === "failed") {
      await state.cleanup
      if (this.#state !== state) return
    }

    if (state.type === "disabled" || state.type === "failed") {
      if (plan.sources.length === 0) {
        this.#state = { type: "disabled", lifecycle: state.lifecycle }
        this.#extensions = Object.freeze([])
        this.#setToolCatalog(Object.freeze([]))
        return
      }
      await this.#startPlan(plan, state.lifecycle, reason)
      return
    }

    if (plan.sources.length === 0) {
      const replacing: ExtensionHostState = {
        type: "replacing",
        lifecycle: state.lifecycle,
        current: state.current,
        candidate: { type: "empty" }
      }
      this.#state = replacing
      await this.#retireCurrent(replacing, state.current, reason)
      if (this.#state === replacing) {
        this.#extensions = Object.freeze([])
        this.#setToolCatalog(Object.freeze([]))
        this.#state = { type: "disabled", lifecycle: state.lifecycle }
      }
      return
    }

    const id = this.#takeGenerationId()
    const replacing: ExtensionHostState = {
      type: "replacing",
      lifecycle: state.lifecycle,
      current: state.current,
      candidate: { type: "spawning", id, plan }
    }
    this.#state = replacing
    let candidate: ExtensionGeneration
    try {
      candidate = this.#spawn(plan, id)
    } catch (cause) {
      this.#diagnose(diagnostic("spawn", errorMessage(cause, "Could not spawn extension worker"), cause))
      if (this.#state === replacing) this.#state = state
      return
    }
    const spawned: ExtensionHostState = { ...replacing, candidate: { type: "spawned", generation: candidate } }
    this.#state = spawned

    let ready: ExtensionGenerationReady
    try {
      ready = await candidate.initialize()
    } catch {
      await candidate.dispose()
      if (this.#state === spawned) {
        const currentFailure = state.current.failure
        if (currentFailure) {
          const cleanup = state.current.dispose()
          this.#extensions = Object.freeze([])
          this.#setToolCatalog(Object.freeze([]))
          this.#state = { type: "failed", lifecycle: state.lifecycle, diagnostic: currentFailure, cleanup }
          await cleanup
        } else {
          this.#state = state
        }
      }
      return
    }
    if (this.#state !== spawned) {
      await candidate.dispose()
      return
    }
    this.#admitLoadResults(ready.extensions)
    await this.#retireCurrent(spawned, state.current, reason)
    if (this.#state !== spawned) {
      await candidate.dispose()
      return
    }

    this.#extensions = ready.extensions
    this.#setToolCatalog(ready.tools)
    if (state.lifecycle === "started") {
      const dispatching: ExtensionHostState = {
        type: "dispatching",
        lifecycle: "unbound",
        current: candidate,
        event: "session_start"
      }
      this.#state = dispatching
      try {
        await candidate.requestStart(reason)
        if (this.#state === dispatching) {
          this.#state = { type: "ready", lifecycle: "started", current: candidate }
        }
      } catch (cause) {
        await this.#operationFailed(dispatching, candidate, cause, "started")
      }
      return
    }
    this.#state = { type: "ready", lifecycle: state.lifecycle, current: candidate }
  }

  dispose(reason: ExtensionShutdownReason = "quit"): Promise<void> {
    const state = this.#state
    if (state.type === "disposed") return Promise.resolve()
    if (state.type === "stopping") return state.settled.promise

    const generations: ExtensionGeneration[] = []
    const cleanups: Promise<void>[] = []
    let shutdown: ExtensionGeneration | undefined
    if (state.type === "ready") {
      generations.push(state.current)
      if (state.lifecycle === "started") shutdown = state.current
    } else if (state.type === "dispatching") {
      generations.push(state.current)
    } else if (state.type === "starting" && state.candidate.type === "spawned") {
      generations.push(state.candidate.generation)
    } else if (state.type === "replacing") {
      if (state.candidate.type === "spawned") generations.push(state.candidate.generation)
      generations.push(state.current)
      if (state.lifecycle === "started" && state.current.lifecycle === "started") shutdown = state.current
    } else if (state.type === "failed") {
      cleanups.push(state.cleanup)
    }

    const lifecycle = state.lifecycle
    const settled = deferred<void>()
    const stopping: ExtensionHostState = {
      type: "stopping",
      lifecycle,
      generations: Object.freeze(generations),
      ...(shutdown ? { shutdown } : {}),
      cleanups: Object.freeze(cleanups),
      settled
    }
    this.#state = stopping
    void this.#finishDispose(stopping, reason)
    return settled.promise
  }

  async #startPlan(
    plan: ExtensionLoadPlan,
    lifecycle: ExtensionHostLifecycle,
    startReason?: ExtensionReplacementReason
  ): Promise<void> {
    if (plan.sources.length === 0) {
      this.#state = { type: "disabled", lifecycle }
      this.#extensions = Object.freeze([])
      this.#setToolCatalog(Object.freeze([]))
      return
    }
    const id = this.#takeGenerationId()
    const starting: ExtensionHostState = { type: "starting", lifecycle, candidate: { type: "spawning", id, plan } }
    this.#state = starting
    let candidate: ExtensionGeneration
    try {
      candidate = this.#spawn(plan, id)
    } catch (cause) {
      const failure = diagnostic("spawn", errorMessage(cause, "Could not spawn extension worker"), cause)
      this.#diagnose(failure)
      if (this.#state === starting) {
        this.#state = { type: "failed", lifecycle, diagnostic: failure, cleanup: Promise.resolve() }
      }
      return
    }
    const spawned: ExtensionHostState = { ...starting, candidate: { type: "spawned", generation: candidate } }
    this.#state = spawned

    let ready: ExtensionGenerationReady
    try {
      ready = await candidate.initialize()
    } catch (cause) {
      const cleanup = candidate.dispose()
      if (this.#state === spawned) {
        const failure = failureDiagnostic(cause)
        this.#extensions = Object.freeze([])
        this.#setToolCatalog(Object.freeze([]))
        this.#state = { type: "failed", lifecycle, diagnostic: failure, cleanup }
      }
      await cleanup
      this.#lastLogs = candidate.logs()
      const stderr = this.#lastLogs.stderr.text.trim()
      if (stderr) {
        this.#diagnose(
          diagnostic("handshake", `Extension worker stderr after startup failure: ${stderr}`, undefined, "warning")
        )
      }
      return
    }
    if (this.#state !== spawned) {
      await candidate.dispose()
      return
    }
    this.#admitLoadResults(ready.extensions)
    this.#extensions = ready.extensions
    this.#setToolCatalog(ready.tools)

    if (lifecycle === "started") {
      const dispatching: ExtensionHostState = {
        type: "dispatching",
        lifecycle: "unbound",
        current: candidate,
        event: "session_start"
      }
      this.#state = dispatching
      try {
        await candidate.requestStart(startReason ?? "reload")
        if (this.#state === dispatching) {
          this.#state = { type: "ready", lifecycle: "started", current: candidate }
        }
      } catch (cause) {
        await this.#operationFailed(dispatching, candidate, cause, "started")
      }
      return
    }
    this.#state = { type: "ready", lifecycle, current: candidate }
  }

  #spawn(plan: ExtensionLoadPlan, id: number): ExtensionGeneration {
    const process = this.#spawnWorker(plan)
    return new ExtensionGeneration(
      id,
      plan,
      process,
      this.#timeouts,
      value => this.#diagnose(value),
      (generation, value) => this.#generationFailed(generation, value),
      () => this.#staleFrame(),
      (generation, request) => this.#handleSessionRequest(generation, request)
    )
  }

  #handleSessionRequest(
    generation: ExtensionGeneration,
    request: ExtensionSessionRequest
  ): ExtensionSessionRequestOutcome {
    if (this.#activeGeneration(this.#state) !== generation) {
      this.#staleFrame()
      return { type: "session_operation_error", message: "Extension session operation came from a stale generation" }
    }
    const loaded = this.#extensions.some(
      result => result.status === "loaded" && result.source.id === request.extensionId
    )
    if (!loaded) {
      return {
        type: "session_operation_error",
        message: `Extension session operation has unknown source: ${request.extensionId}`
      }
    }
    const operations = this.#sessionOperations
    if (!operations) {
      return { type: "session_operation_error", message: "Extension session operations are not bound" }
    }

    try {
      switch (request.type) {
        case "custom_entries_get":
          return { type: "custom_entries_result", entries: operations.getEntries(request.customType) }
        case "custom_entry_append":
          return {
            type: "custom_entry_result",
            entry:
              request.data === undefined
                ? operations.appendEntry(request.customType)
                : operations.appendEntry(request.customType, request.data)
          }
        case "custom_message_send":
          operations.sendMessage(request.message, request.delivery)
          return { type: "custom_message_result" }
        default:
          return assertNever(request)
      }
    } catch (cause) {
      return { type: "session_operation_error", message: boundedExtensionSessionOperationError(cause) }
    }
  }

  async #retireCurrent(
    ownerState: Extract<ExtensionHostState, { type: "replacing" }>,
    current: ExtensionGeneration,
    reason: ExtensionReplacementReason
  ): Promise<void> {
    if (ownerState.lifecycle === "started" && current.lifecycle === "started") {
      try {
        await current.requestShutdown(reason)
      } catch (cause) {
        if (!(cause instanceof ExtensionGenerationError)) this.#diagnose(failureDiagnostic(cause))
      }
    }
    await current.dispose()
    this.#lastLogs = current.logs()
  }

  async #operationFailed(
    ownerState: Extract<ExtensionHostState, { type: "dispatching" }>,
    generation: ExtensionGeneration,
    cause: unknown,
    lifecycle: ExtensionHostLifecycle = ownerState.lifecycle
  ): Promise<void> {
    const failure = failureDiagnostic(cause)
    const cleanup = generation.dispose()
    if (this.#state === ownerState) {
      if (!(cause instanceof ExtensionGenerationError)) this.#diagnose(failure)
      this.#extensions = Object.freeze([])
      this.#setToolCatalog(Object.freeze([]))
      this.#state = { type: "failed", lifecycle, diagnostic: failure, cleanup }
    }
    await cleanup
    this.#lastLogs = generation.logs()
  }

  #generationFailed(generation: ExtensionGeneration, value: ExtensionDiagnostic): void {
    this.#diagnose(value)
    const state = this.#state
    if (state.type === "ready" && state.current === generation) {
      const cleanup = generation.dispose().then(() => {
        this.#lastLogs = generation.logs()
        return undefined
      })
      this.#extensions = Object.freeze([])
      this.#setToolCatalog(Object.freeze([]))
      this.#state = { type: "failed", lifecycle: state.lifecycle, diagnostic: value, cleanup }
    }
  }

  async #finishDispose(state: Extract<ExtensionHostState, { type: "stopping" }>, reason: ExtensionShutdownReason) {
    if (state.shutdown?.lifecycle === "started") {
      try {
        await state.shutdown.requestShutdown(reason)
      } catch (cause) {
        if (!(cause instanceof ExtensionGenerationError)) this.#diagnose(failureDiagnostic(cause))
      }
    }
    try {
      await Promise.all([...state.cleanups, ...state.generations.map(generation => generation.dispose())])
    } catch (cause) {
      this.#diagnose(diagnostic("shutdown", errorMessage(cause, "Extension host cleanup failed"), cause, "warning"))
    } finally {
      const retainedGeneration = state.generations.at(-1)
      if (retainedGeneration) this.#lastLogs = retainedGeneration.logs()
      if (this.#state === state) {
        this.#extensions = Object.freeze([])
        this.#setToolCatalog(Object.freeze([]))
        this.#state = { type: "disposed" }
      }
      this.#toolCatalogListener = undefined
      state.settled.resolve()
    }
  }

  #admitLoadResults(results: readonly ExtensionLoadResult[]): void {
    for (const result of results) {
      if (result.status === "failed" && result.diagnostic) this.#diagnose(result.diagnostic)
    }
  }

  #setToolCatalog(tools: readonly ExtensionToolRegistration[]): void {
    if (this.#tools === tools) return
    this.#tools = tools
    try {
      this.#toolCatalogListener?.(tools)
    } catch (cause) {
      this.#diagnose(diagnostic("protocol", errorMessage(cause, "Extension tool catalog binding failed"), cause))
    }
  }

  #diagnose(value: ExtensionDiagnostic): void {
    if (this.#diagnostics.length >= maxExtensionDiagnostics) {
      this.#omittedDiagnostics = Math.min(Number.MAX_SAFE_INTEGER, this.#omittedDiagnostics + 1)
      return
    }
    this.#diagnostics.push(value)
  }

  #staleFrame(): void {
    this.#staleFrames = Math.min(Number.MAX_SAFE_INTEGER, this.#staleFrames + 1)
  }

  #takeGenerationId(): number {
    const id = this.#nextGenerationId
    if (!Number.isSafeInteger(id)) throw new Error("Extension generation IDs are exhausted")
    this.#nextGenerationId++
    return id
  }

  #activeGeneration(state: ExtensionHostState): ExtensionGeneration | undefined {
    switch (state.type) {
      case "starting":
        return state.candidate.type === "spawned" ? state.candidate.generation : undefined
      case "ready":
      case "dispatching":
        return state.current
      case "replacing":
        return state.current
      case "stopping":
        return state.shutdown ?? state.generations[0]
      case "disabled":
      case "failed":
      case "disposed":
        return undefined
      default:
        return assertNever(state)
    }
  }
}

type SpawnedExtensionChild =
  | { readonly type: "bun"; readonly process: Bun.Subprocess<"pipe", "pipe", "pipe"> }
  | { readonly type: "node"; readonly process: ReturnType<typeof spawn> }

export function createExtensionWorkerSpawner(
  command: readonly string[],
  removePublicApiDirectory: (path: string) => void = path => rmSync(path, { recursive: true, force: true })
): SpawnExtensionWorker {
  if (
    command.length === 0 ||
    command.length > 16 ||
    !isAbsolute(command[0]!) ||
    command.some(part => part.length === 0 || part.includes("\0") || Buffer.byteLength(part) > 4096)
  ) {
    throw new Error(
      "Extension worker commands require an absolute executable and at most 15 non-empty 4096-byte prefix arguments"
    )
  }
  const admitted = Object.freeze([...command])
  const inheritedEnvironment = Object.freeze({ ...process.env })
  return plan => {
    const publicApi = createPublicApiModule(removePublicApiDirectory)
    const args = [...admitted.slice(1), extensionWorkerArgument]
    const env = {
      ...inheritedEnvironment,
      NODE_PATH: inheritedEnvironment.NODE_PATH
        ? `${publicApi.nodeModules}${delimiter}${inheritedEnvironment.NODE_PATH}`
        : publicApi.nodeModules
    }
    let child: SpawnedExtensionChild
    try {
      // Bun owns POSIX pipe creation because its node adapter can fail while materializing fd 3 under Linux load.
      // The node adapter remains required on Windows, where Bun's direct fd 3 transport is not connected.
      child =
        process.platform === "win32"
          ? {
              type: "node",
              process: spawn(admitted[0]!, args, {
                cwd: plan.cwd,
                env,
                stdio: ["pipe", "pipe", "pipe", "pipe"],
                windowsHide: true
              })
            }
          : {
              type: "bun",
              process: Bun.spawn([admitted[0]!, ...args], {
                cwd: plan.cwd,
                env,
                stdio: ["pipe", "pipe", "pipe", "pipe"],
                windowsHide: true
              })
            }
    } catch (cause) {
      publicApi.dispose()
      throw cause
    }
    let input: Writable
    let stdout: Readable
    let stderr: Readable
    let protocol: Readable
    try {
      if (child.type === "bun") {
        const protocolDescriptor = child.process.stdio[3]
        if (typeof protocolDescriptor !== "number") {
          throw new Error("Extension worker process did not expose all required pipes")
        }
        input = createBunProcessInput(child.process.stdin)
        stdout = Readable.from(child.process.stdout)
        stderr = Readable.from(child.process.stderr)
        protocol = Readable.from(Bun.file(protocolDescriptor).stream())
      } else {
        const protocolStream = child.process.stdio[3]
        if (
          !child.process.stdin ||
          !child.process.stdout ||
          !child.process.stderr ||
          !(protocolStream instanceof Readable)
        ) {
          throw new Error("Extension worker process did not expose all required pipes")
        }
        input = child.process.stdin
        stdout = child.process.stdout
        stderr = child.process.stderr
        protocol = protocolStream
      }
    } catch (cause) {
      if (child.type === "node") child.process.once("error", () => {})
      killSpawnedExtensionChild(child, "SIGKILL")
      unrefSpawnedExtensionChild(child)
      const cleanupError = publicApi.dispose()
      if (cleanupError) {
        throw new Error(`${errorMessage(cause, "Could not connect extension worker pipes")}; ${cleanupError.message}`, {
          cause
        })
      }
      throw cause
    }

    let settled = false
    let processError: Error | undefined
    let resolveExit!: (exit: ExtensionWorkerExit) => void
    const exited = new Promise<ExtensionWorkerExit>(resolve => {
      resolveExit = resolve
    })
    const finish = (code: number | null, signal: NodeJS.Signals | null): void => {
      if (settled) return
      settled = true
      const cleanupError = publicApi.dispose()
      if (cleanupError) {
        processError = processError
          ? new Error(`${processError.message}; public API cleanup failed: ${cleanupError.message}`, {
              cause: processError
            })
          : cleanupError
      }
      resolveExit({ code, signal, ...(processError ? { error: processError } : {}) })
    }
    let stopObservingExit: (() => void) | undefined
    if (child.type === "bun") {
      const childProcess = child.process
      void childProcess.exited.then(
        code => finish(code, childProcess.signalCode),
        cause => {
          processError = cause instanceof Error ? cause : new Error("Extension worker process failed")
          finish(childProcess.exitCode, childProcess.signalCode)
        }
      )
    } else {
      const childProcess = child.process
      const onError = (cause: Error): void => {
        processError = cause
      }
      const onClose = (code: number | null, signal: NodeJS.Signals | null): void => finish(code, signal)
      childProcess.on("error", onError)
      childProcess.on("close", onClose)
      stopObservingExit = () => {
        childProcess.off("error", onError)
        childProcess.off("close", onClose)
      }
    }

    return {
      input,
      stdout,
      stderr,
      protocol,
      exited,
      terminate(force) {
        if (!settled) killSpawnedExtensionChild(child, force ? "SIGKILL" : "SIGTERM")
      },
      dispose() {
        stopObservingExit?.()
        if (!settled) {
          unrefSpawnedExtensionChild(child)
          processError ??= new Error("Extension worker process ownership ended before exit observation")
          const exit = spawnedExtensionChildExit(child)
          finish(exit.code, exit.signal)
        }
      }
    }
  }
}

function killSpawnedExtensionChild(child: SpawnedExtensionChild, signal: NodeJS.Signals): void {
  child.process.kill(signal)
}

function unrefSpawnedExtensionChild(child: SpawnedExtensionChild): void {
  child.process.unref()
}

function spawnedExtensionChildExit(child: SpawnedExtensionChild): Pick<ExtensionWorkerExit, "code" | "signal"> {
  return { code: child.process.exitCode, signal: child.process.signalCode }
}

function createBunProcessInput(sink: Bun.FileSink): Writable {
  let ended = false
  return new Writable({
    write(chunk: Buffer, _encoding, callback) {
      void writeBunProcessInput(sink, chunk, callback)
    },
    final(callback) {
      ended = true
      void closeBunProcessInput(sink, null, callback)
    },
    destroy(cause, callback) {
      if (ended) {
        callback(cause)
        return
      }
      ended = true
      void closeBunProcessInput(sink, cause, callback)
    }
  })
}

async function writeBunProcessInput(
  sink: Bun.FileSink,
  chunk: Buffer,
  callback: (error?: Error | null) => void
): Promise<void> {
  try {
    await sink.write(chunk)
    await sink.flush()
    callback()
  } catch (cause) {
    callback(processStreamError(cause))
  }
}

async function closeBunProcessInput(
  sink: Bun.FileSink,
  cause: Error | null,
  callback: (error: Error | null) => void
): Promise<void> {
  try {
    await sink.end(cause ?? undefined)
    callback(cause)
  } catch (failure) {
    callback(cause ?? processStreamError(failure))
  }
}

function processStreamError(cause: unknown): Error {
  return cause instanceof Error ? cause : new Error("Extension worker process stream failed")
}

function createPublicApiModule(removeDirectory: (path: string) => void): {
  readonly nodeModules: string
  dispose(): Error | undefined
} {
  const root = mkdtempSync(join(tmpdir(), "zi-extension-api-"))
  const nodeModules = join(root, "node_modules")
  const packageDirectory = join(nodeModules, "@with-zi", "extension-api")
  try {
    mkdirSync(packageDirectory, { recursive: true, mode: 0o700 })
    writeFileSync(
      join(packageDirectory, "package.json"),
      `${JSON.stringify({ name: "@with-zi/extension-api", type: "module", exports: "./index.js" })}\n`,
      { mode: 0o600 }
    )
    writeFileSync(join(packageDirectory, "index.js"), extensionApiModuleSource, { mode: 0o600 })
  } catch (cause) {
    try {
      removeDirectory(root)
    } catch (cleanupCause) {
      throw new Error(
        `${errorMessage(cause, "Could not create extension public API module")}; cleanup failed: ${errorMessage(cleanupCause, "unknown cleanup error")}`,
        { cause: cleanupCause }
      )
    }
    throw cause
  }
  let disposed = false
  return {
    nodeModules,
    dispose() {
      if (disposed) return undefined
      disposed = true
      try {
        removeDirectory(root)
        return undefined
      } catch (cause) {
        return cause instanceof Error ? cause : new Error(String(cause))
      }
    }
  }
}

function matchesLoadPlan(plan: ExtensionLoadPlan, results: readonly ExtensionLoadResult[]): boolean {
  if (plan.sources.length !== results.length) return false
  return plan.sources.every((source, index) => {
    const result = results[index]
    if (!result) return false
    const received = result.source
    return (
      received.id === source.id &&
      received.declaredPath === source.declaredPath &&
      received.entryPath === source.entryPath &&
      received.scope === source.scope &&
      received.origin === source.origin
    )
  })
}

function toolsMatchLoadedExtensions(
  tools: readonly ExtensionToolRegistration[],
  extensions: readonly ExtensionLoadResult[]
): boolean {
  return tools.every(tool =>
    extensions.some(result => result.status === "loaded" && sameExtensionSource(result.source, tool.source))
  )
}

function sameExtensionSource(
  left: ExtensionToolRegistration["source"],
  right: ExtensionToolRegistration["source"]
): boolean {
  return (
    left.id === right.id &&
    left.declaredPath === right.declaredPath &&
    left.entryPath === right.entryPath &&
    left.scope === right.scope &&
    left.origin === right.origin
  )
}

function hostStatus(state: ExtensionHostState): ExtensionHostStatus {
  return state.type
}

function diagnostic(
  phase: ExtensionDiagnostic["phase"],
  message: string,
  cause?: unknown,
  severity: ExtensionDiagnostic["severity"] = "error"
): ExtensionDiagnostic {
  const error = cause instanceof Error ? cause : undefined
  return boundedExtensionDiagnostic({ phase, severity, message, ...(error?.stack ? { stack: error.stack } : {}) })
}

function failureDiagnostic(cause: unknown): ExtensionDiagnostic {
  if (cause instanceof ExtensionGenerationError) return cause.diagnostic
  return diagnostic("protocol", errorMessage(cause, "Extension generation failed"), cause)
}

function generationError(state: GenerationState, cause: unknown): ExtensionGenerationError {
  if (state.type === "failed") return state.error
  return new ExtensionGenerationError(
    diagnostic("handshake", errorMessage(cause, "Extension generation failed"), cause)
  )
}

function errorMessage(cause: unknown, fallback: string): string {
  return cause instanceof Error && cause.message ? cause.message : fallback
}

function abortError(): Error {
  const error = new Error("Extension tool invocation was cancelled")
  error.name = "AbortError"
  return error
}

function emptyLogTail(): ExtensionLogTail {
  return Object.freeze({ text: "", retainedBytes: 0, omittedBytes: 0 })
}

function validateTimeouts(timeouts: ExtensionHostTimeouts): void {
  for (const [name, value] of Object.entries(timeouts)) {
    if (!Number.isSafeInteger(value) || value <= 0) throw new Error(`Extension host ${name} must be a positive integer`)
  }
}

class DeadlineError extends Error {
  constructor(message: string) {
    super(message)
    this.name = "DeadlineError"
  }
}

function within<T>(operation: Promise<T>, timeoutMs: number, message: string): Promise<T> {
  return until(operation, Date.now() + timeoutMs, message)
}

function until<T>(operation: Promise<T>, deadline: number, message: string): Promise<T> {
  const remaining = Math.max(0, deadline - Date.now())
  let timeout: ReturnType<typeof setTimeout> | undefined
  const expired = new Promise<never>((_, reject) => {
    timeout = setTimeout(() => reject(new DeadlineError(message)), remaining)
    timeout.unref?.()
  })
  return Promise.race([operation, expired]).finally(() => {
    if (timeout) clearTimeout(timeout)
  })
}

async function ignoreDeadline(operation: Promise<unknown>, deadline: number): Promise<void> {
  try {
    await until(operation, deadline, "Extension process settlement deadline exceeded")
  } catch {
    // The next teardown stage owns escalation.
  }
}

interface Deferred<T> {
  readonly promise: Promise<T>
  resolve(value: T): void
  reject(cause: unknown): void
}

type VoidDeferred = Omit<Deferred<void>, "resolve"> & { resolve(): void }

function deferred<T>(): Deferred<T> {
  let resolve!: (value: T) => void
  let reject!: (cause: unknown) => void
  const promise = new Promise<T>((resolvePromise, rejectPromise) => {
    resolve = resolvePromise
    reject = rejectPromise
  })
  void promise.catch(() => {})
  return { promise, resolve, reject }
}

function assertNever(value: never): never {
  throw new Error(`Unhandled extension host state: ${String(value)}`)
}
