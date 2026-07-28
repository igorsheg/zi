import type {
  AgentSession,
  AgentSessionEvent,
  QueuedInputs,
  RetryStatus,
  CompactionStatus,
  ContextUsage
} from "../agent-session.js"
import type { AgentMessage } from "../messages.js"
import {
  decodeRpcRequest,
  maxRpcFrameBytes,
  maxRpcMessagePageBytes,
  rpcProtocolVersion,
  RpcFramingError,
  RpcLineDecoder,
  RpcRequestError,
  type RpcMethod,
  type RpcProtocolErrorCode,
  type RpcRequest
} from "./protocol.js"

export const maxRpcInFlightOperations = 32
export const maxRpcPendingOutputRecords = 1024
export const maxRpcPendingOutputBytes = 32 * 1024 * 1024
export const rpcModeSettlementTimeoutMs = 5_000

export interface RpcWriter {
  write(chunk: string): void | Promise<void>
}

export interface RpcModeTransport {
  readonly input: AsyncIterable<Uint8Array>
  readonly writer: RpcWriter
  readonly signal?: AbortSignal
}

export type RpcModeResult =
  | { readonly type: "eof" }
  | { readonly type: "cancelled" }
  | { readonly type: "input_error"; readonly message: string }
  | { readonly type: "output_error"; readonly message: string }
  | { readonly type: "settlement_error"; readonly message: string }

export interface RpcModel {
  readonly provider: string
  readonly id: string
  readonly name: string
  readonly reasoning: boolean
  readonly input: readonly ("text" | "image")[]
  readonly contextWindow: number
  readonly maxTokens: number
}

export type RpcModelState = { readonly type: "unselected" } | { readonly type: "selected"; readonly model: RpcModel }

export type RpcSessionActivity =
  | { readonly type: "idle" }
  | { readonly type: "running" }
  | { readonly type: "aborting" }
  | { readonly type: "compacting"; readonly operationId: number; readonly reason: string }

export interface RpcSessionState {
  readonly sessionId: string
  readonly activity: RpcSessionActivity
  readonly model: RpcModelState
  readonly thinkingLevel: AgentSession["thinkingLevel"]
  readonly supportedThinkingLevels: readonly AgentSession["thinkingLevel"][]
  readonly steeringMode: AgentSession["steeringMode"]
  readonly followUpMode: AgentSession["followUpMode"]
  readonly queuedInputs: QueuedInputs
  readonly messageCount: number
  readonly streamingMessage?: AgentMessage
  readonly compaction: CompactionStatus
  readonly retry: RetryStatus
  readonly contextUsage: ContextUsage
}

export interface RpcMessagePage {
  readonly start: number
  readonly total: number
  readonly nextStart: number | null
  readonly messages: readonly AgentMessage[]
}

export type RpcSessionEvent =
  | Exclude<AgentSessionEvent, { type: "model_changed" }>
  | { readonly type: "model_changed"; readonly model: RpcModel }

interface RpcFrameBase {
  readonly version: 1
  readonly sequence: number
}

export type RpcServerFrame =
  | (RpcFrameBase & { readonly type: "ready"; readonly state: RpcSessionState })
  | (RpcFrameBase & { readonly type: "session_event"; readonly event: RpcSessionEvent })
  | (RpcFrameBase & {
      readonly type: "protocol_error"
      readonly code: RpcProtocolErrorCode | "invalid_framing"
      readonly message: string
      readonly id?: string
    })
  | (RpcFrameBase & {
      readonly type: "response"
      readonly id: string
      readonly method: RpcMethod
      readonly ok: true
      readonly result: unknown
    })
  | (RpcFrameBase & {
      readonly type: "response"
      readonly id: string
      readonly method: RpcMethod
      readonly ok: false
      readonly error: { readonly code: "capacity" | "not_found" | "operation_failed"; readonly message: string }
    })

type ConnectionState =
  | { readonly type: "open" }
  | { readonly type: "stopping"; readonly reason: Exclude<RpcModeResult, { type: "settlement_error" }> }
  | { readonly type: "closed"; readonly result: RpcModeResult }

type FrameBody =
  | { readonly type: "ready"; readonly state: RpcSessionState }
  | { readonly type: "session_event"; readonly event: RpcSessionEvent }
  | {
      readonly type: "protocol_error"
      readonly code: RpcProtocolErrorCode | "invalid_framing"
      readonly message: string
      readonly id?: string
    }
  | {
      readonly type: "response"
      readonly id: string
      readonly method: RpcMethod
      readonly ok: true
      readonly result: unknown
    }
  | {
      readonly type: "response"
      readonly id: string
      readonly method: RpcMethod
      readonly ok: false
      readonly error: { readonly code: "capacity" | "not_found" | "operation_failed"; readonly message: string }
    }

/** Owns one bounded, versioned RPC connection over an authoritative AgentSession. */
export async function runRpcMode(session: AgentSession, transport: RpcModeTransport): Promise<RpcModeResult> {
  let state: ConnectionState = { type: "open" }
  let sequence = 0
  let normalOperations = 0
  let interruptActive = false
  const operations = new Set<Promise<void>>()
  const stopped = deferred<void>()
  const currentState = (): ConnectionState => state
  const output = new RpcOutput(transport.writer, message => stop({ type: "output_error", message }))

  const send = (body: FrameBody): void => {
    if (state.type === "closed") return
    sequence++
    output.enqueue({ version: rpcProtocolVersion, sequence, ...body })
  }
  const stop = (reason: Exclude<RpcModeResult, { type: "settlement_error" }>): void => {
    if (state.type !== "open") return
    state = { type: "stopping", reason }
    stopped.resolve()
  }

  const unsubscribe = session.subscribe(event => {
    if (state.type === "open") send({ type: "session_event", event: projectEvent(event) })
  })
  const removeAbort = listenForAbort(transport.signal, () => stop({ type: "cancelled" }))
  const decoder = new RpcLineDecoder()
  const iterator = transport.input[Symbol.asyncIterator]()
  let inputRelease = Promise.resolve()

  try {
    send({ type: "ready", state: sessionState(session) })

    while (state.type === "open") {
      // The connection owns one sequential read; parallel reads would reorder JSONL framing.
      // oxlint-disable-next-line no-await-in-loop
      const next: IteratorResult<Uint8Array> | typeof stoppedInput = await Promise.race([
        iterator.next(),
        stopped.promise.then<typeof stoppedInput>(() => stoppedInput)
      ])
      if (next === stoppedInput) break
      if (next.done) {
        try {
          for (const line of decoder.finish()) admitLine(line)
          stop({ type: "eof" })
        } catch (cause) {
          framingFailure(cause)
        }
        break
      }
      try {
        for (const line of decoder.push(next.value)) admitLine(line)
      } catch (cause) {
        framingFailure(cause)
      }
    }
  } catch (cause) {
    stop({ type: "input_error", message: errorMessage(cause, "Could not read RPC input") })
  } finally {
    removeAbort()
    inputRelease = releaseInput(iterator)
  }

  if (currentState().type === "open") stop({ type: "eof" })
  const stoppingState = currentState()
  if (stoppingState.type !== "stopping") throw new Error("RPC connection entered an invalid stopping state")
  const stoppingReason = stoppingState.reason

  const shutdown = session.abortAndDiscardQueuedInputs().catch(() => {})
  const settlement = Promise.allSettled([inputRelease, shutdown, ...operations]).then(() => undefined)
  const settled = await settleWithin(settlement, rpcModeSettlementTimeoutMs)
  unsubscribe()

  if (!settled) {
    output.close()
    state = {
      type: "closed",
      result: {
        type: "settlement_error",
        message: `RPC resources did not settle within ${rpcModeSettlementTimeoutMs}ms`
      }
    }
    return state.result
  }

  const outputSettlement = output.settle()
  if (
    !(await settleWithin(
      outputSettlement.then(() => undefined),
      rpcModeSettlementTimeoutMs
    ))
  ) {
    output.close()
    state = {
      type: "closed",
      result: { type: "settlement_error", message: `RPC output did not settle within ${rpcModeSettlementTimeoutMs}ms` }
    }
    return state.result
  }
  const outputFailure = await outputSettlement
  output.close()
  const finalResult: RpcModeResult = outputFailure ? { type: "output_error", message: outputFailure } : stoppingReason
  state = { type: "closed", result: finalResult }
  return finalResult

  function framingFailure(cause: unknown): void {
    const message = cause instanceof RpcFramingError ? cause.message : "Could not decode RPC input"
    send({ type: "protocol_error", code: "invalid_framing", message })
    stop({ type: "input_error", message })
  }

  function admitLine(line: string): void {
    if (state.type !== "open") return
    let value: unknown
    try {
      value = JSON.parse(line)
    } catch {
      send({ type: "protocol_error", code: "invalid_json", message: "RPC input must contain one JSON object per line" })
      return
    }

    let request: RpcRequest
    try {
      request = decodeRpcRequest(value)
    } catch (cause) {
      if (cause instanceof RpcRequestError) {
        send({
          type: "protocol_error",
          code: cause.code,
          message: cause.message,
          ...(cause.requestId ? { id: cause.requestId } : {})
        })
      } else {
        send({ type: "protocol_error", code: "invalid_request", message: "Invalid RPC request" })
      }
      return
    }

    if (request.method === "session.interrupt") {
      if (interruptActive) {
        sendFailure(request, "capacity", "An interruption request is already active")
        return
      }
      interruptActive = true
      launch(request, true)
      return
    }
    if (normalOperations >= maxRpcInFlightOperations) {
      sendFailure(request, "capacity", `RPC accepts at most ${maxRpcInFlightOperations} in-flight operations`)
      return
    }
    normalOperations++
    launch(request, false)
  }

  function launch(request: RpcRequest, isInterruption: boolean): void {
    const operation = handleRequest(session, request)
      .then(operationResult => {
        if (state.type === "open" || state.type === "stopping") {
          send({ type: "response", id: request.id, method: request.method, ok: true, result: operationResult })
        }
        return undefined
      })
      .catch(cause => {
        if (state.type !== "closed") {
          const failure = operationFailure(cause)
          sendFailure(request, failure.code, failure.message)
        }
      })
      .finally(() => {
        operations.delete(operation)
        if (isInterruption) interruptActive = false
        else normalOperations--
      })
    operations.add(operation)
  }

  function sendFailure(
    request: RpcRequest,
    code: "capacity" | "not_found" | "operation_failed",
    message: string
  ): void {
    send({ type: "response", id: request.id, method: request.method, ok: false, error: { code, message } })
  }
}

async function handleRequest(session: AgentSession, request: RpcRequest): Promise<unknown> {
  switch (request.method) {
    case "session.get_state":
      return sessionState(session)
    case "session.get_messages":
      return messagePage(session, request.params.start, request.params.limit)
    case "session.prompt":
      if (request.params.delivery === "direct") {
        const settlement = session.prompt(request.params.text)
        void settlement.catch(() => {})
      } else if (request.params.delivery === "steer") {
        session.steer(request.params.text)
      } else {
        session.followUp(request.params.text)
      }
      return { delivery: request.params.delivery }
    case "session.interrupt":
      await session.abort()
      return {}
    case "session.await_idle":
      await session.waitForIdle()
      return {}
    case "model.list": {
      const choices = await session.listModelChoices()
      return { models: choices.map(projectModelChoice) }
    }
    case "model.select": {
      const choices = await session.listModelChoices()
      const choice = choices.find(
        candidate => candidate.model.provider === request.params.provider && candidate.model.id === request.params.id
      )
      if (!choice) {
        throw new RpcOperationError("not_found", `Model not found: ${request.params.provider}/${request.params.id}`)
      }
      await session.setModel(choice.model)
      return { model: projectModel(choice.model) }
    }
    case "thinking.list":
      return { levels: session.getSupportedThinkingLevels() }
    case "thinking.select":
      return session.setThinkingLevel(request.params.level, request.params.scope)
    default:
      return assertNever(request)
  }
}

function sessionState(session: AgentSession): RpcSessionState {
  const model: RpcModelState =
    session.modelState.type === "selected"
      ? { type: "selected", model: projectModel(session.modelState.model) }
      : { type: "unselected" }
  const compaction = session.compactionStatus
  let activity: RpcSessionActivity
  if (session.isAborting) activity = { type: "aborting" }
  else if (compaction.type === "running") {
    activity = { type: "compacting", operationId: compaction.operationId, reason: compaction.reason }
  } else if (session.isStreaming) activity = { type: "running" }
  else activity = { type: "idle" }
  const streamingMessage = session.streamingMessage

  return {
    sessionId: session.sessionId,
    activity,
    model,
    thinkingLevel: session.thinkingLevel,
    supportedThinkingLevels: session.getSupportedThinkingLevels(),
    steeringMode: session.steeringMode,
    followUpMode: session.followUpMode,
    queuedInputs: session.queuedInputs,
    messageCount: session.messages.length,
    ...(streamingMessage ? { streamingMessage } : {}),
    compaction,
    retry: session.retryStatus,
    contextUsage: session.contextUsage
  }
}

function messagePage(session: AgentSession, start: number, limit: number): RpcMessagePage {
  const all = session.messages
  const messages: AgentMessage[] = []
  let bytes = 256
  const end = Math.min(all.length, start + limit)
  for (let index = start; index < end; index++) {
    const message = all[index]
    if (!message) break
    const serialized = JSON.stringify(message)
    const messageBytes = Buffer.byteLength(serialized) + 1
    if (messageBytes > maxRpcMessagePageBytes) {
      throw new Error(`Session message ${index} exceeds the RPC page byte bound`)
    }
    if (messages.length > 0 && bytes + messageBytes > maxRpcMessagePageBytes) break
    messages.push(message)
    bytes += messageBytes
  }
  const nextStart = start + messages.length
  return { start, total: all.length, nextStart: nextStart < all.length ? nextStart : null, messages }
}

function projectEvent(event: AgentSessionEvent): RpcSessionEvent {
  if (event.type === "model_changed") return { type: "model_changed", model: projectModel(event.model) }
  return event
}

function projectModelChoice(
  choice: Awaited<ReturnType<AgentSession["listModelChoices"]>>[number]
): RpcModel & { readonly configured: boolean } {
  const model = choice.model
  return {
    provider: model.provider,
    id: model.id,
    name: model.name,
    reasoning: model.reasoning,
    input: Object.freeze([...model.input]),
    contextWindow: model.contextWindow,
    maxTokens: model.maxTokens,
    configured: choice.configured
  }
}

function projectModel(model: AgentSession["model"]): RpcModel {
  return {
    provider: model.provider,
    id: model.id,
    name: model.name,
    reasoning: model.reasoning,
    input: Object.freeze([...model.input]),
    contextWindow: model.contextWindow,
    maxTokens: model.maxTokens
  }
}

class RpcOperationError extends Error {
  readonly code: "not_found"

  constructor(code: "not_found", message: string) {
    super(message)
    this.name = "RpcOperationError"
    this.code = code
  }
}

class RpcOutput {
  readonly #writer: RpcWriter
  readonly #onFailure: (message: string) => void
  #queue: Array<{ readonly line: string; readonly bytes: number }> = []
  #head = 0
  #pendingBytes = 0
  #running: Promise<void> | undefined
  #failure: string | undefined
  #closed = false

  constructor(writer: RpcWriter, onFailure: (message: string) => void) {
    this.#writer = writer
    this.#onFailure = onFailure
  }

  enqueue(frame: RpcServerFrame): void {
    if (this.#closed || this.#failure) return
    let line: string
    try {
      line = `${JSON.stringify(frame)}\n`
    } catch {
      this.#fail("Could not serialize RPC output")
      return
    }
    const bytes = Buffer.byteLength(line)
    if (bytes > maxRpcFrameBytes) {
      this.#fail(`RPC output records cannot exceed ${maxRpcFrameBytes} bytes`)
      return
    }
    if (
      this.#queue.length - this.#head >= maxRpcPendingOutputRecords ||
      this.#pendingBytes + bytes > maxRpcPendingOutputBytes
    ) {
      this.#fail("RPC output exceeded its pending-write bound")
      return
    }
    this.#queue.push({ line, bytes })
    this.#pendingBytes += bytes
    this.#running ??= this.#drain()
  }

  async settle(): Promise<string | undefined> {
    await this.#running
    return this.#failure
  }

  close(): void {
    this.#closed = true
    this.#queue = []
    this.#head = 0
    this.#pendingBytes = 0
  }

  async #drain(): Promise<void> {
    while (!this.#failure && this.#head < this.#queue.length) {
      const item = this.#queue[this.#head]
      if (!item) break
      try {
        // One drain owns total protocol order and bounds outstanding writes.
        // oxlint-disable-next-line no-await-in-loop
        await this.#writer.write(item.line)
      } catch {
        this.#fail("Could not write RPC output")
        break
      }
      if (this.#closed) break
      this.#head++
      this.#pendingBytes -= item.bytes
      if (this.#head === this.#queue.length) {
        this.#queue = []
        this.#head = 0
      } else if (this.#head >= 256 && this.#head * 2 >= this.#queue.length) {
        this.#queue = this.#queue.slice(this.#head)
        this.#head = 0
      }
    }
    this.#running = undefined
  }

  #fail(message: string): void {
    if (this.#failure) return
    this.#failure = message
    this.#queue = []
    this.#head = 0
    this.#pendingBytes = 0
    this.#onFailure(message)
  }
}

function operationFailure(cause: unknown): {
  readonly code: "not_found" | "operation_failed"
  readonly message: string
} {
  if (cause instanceof RpcOperationError) return { code: cause.code, message: cause.message }
  return { code: "operation_failed", message: errorMessage(cause, "RPC operation failed") }
}

function releaseInput(iterator: AsyncIterator<Uint8Array>): Promise<void> {
  try {
    return Promise.resolve(iterator.return?.()).then(
      () => undefined,
      () => undefined
    )
  } catch {
    return Promise.resolve()
  }
}

function listenForAbort(signal: AbortSignal | undefined, listener: () => void): () => void {
  if (!signal) return () => {}
  if (signal.aborted) {
    listener()
    return () => {}
  }
  signal.addEventListener("abort", listener, { once: true })
  return () => signal.removeEventListener("abort", listener)
}

async function settleWithin(operation: Promise<void>, timeoutMs: number): Promise<boolean> {
  let timeout: ReturnType<typeof setTimeout> | undefined
  const result = await Promise.race([
    operation.then(() => true),
    new Promise<false>(resolve => {
      timeout = setTimeout(() => resolve(false), timeoutMs)
    })
  ])
  if (timeout) clearTimeout(timeout)
  return result
}

function errorMessage(cause: unknown, fallback: string): string {
  return cause instanceof Error ? cause.message : fallback
}

function deferred<T>() {
  let resolve!: (value: T | PromiseLike<T>) => void
  const promise = new Promise<T>(resolvePromise => {
    resolve = resolvePromise
  })
  return { promise, resolve }
}

function assertNever(value: never): never {
  throw new Error(`Unexpected RPC request: ${JSON.stringify(value)}`)
}

const stoppedInput: unique symbol = Symbol("stopped input")
