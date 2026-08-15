import type {
  AgentSession,
  AgentSessionEvent,
  QueuedInputs,
  RetryStatus,
  CompactionStatus,
  ContextUsage
} from "../agent-session.js"
import type { AgentMessage } from "../messages.js"
import type { CustomEntry, CustomMessageEntry, SessionEntry } from "../session-manager.js"
import {
  decodeRpcRequest,
  maxRpcCompletionErrorBytes,
  maxRpcCompletionTextBytes,
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
  | { readonly type: "extension_command"; readonly name: string; readonly phase: "executing" | "cancelling" }

export interface RpcSessionState {
  readonly sessionId: string
  readonly activity: RpcSessionActivity
  readonly model: RpcModelState
  readonly thinkingLevel: AgentSession["thinkingLevel"]
  readonly supportedThinkingLevels: readonly AgentSession["thinkingLevel"][]
  readonly steeringMode: AgentSession["steeringMode"]
  readonly followUpMode: AgentSession["followUpMode"]
  readonly queuedInputs: QueuedInputs
  readonly workPlan: AgentSession["workPlan"]
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

export type RpcSessionEntry =
  | Extract<SessionEntry, { readonly type: "message" }>
  | Extract<SessionEntry, { readonly type: "model_change" }>
  | Extract<SessionEntry, { readonly type: "thinking_level_change" }>
  | Extract<SessionEntry, { readonly type: "retry" }>
  | Extract<SessionEntry, { readonly type: "compaction" }>
  | Extract<SessionEntry, { readonly type: "subagent" }>
  | Extract<SessionEntry, { readonly type: "subagent_work_result" }>
  | Extract<SessionEntry, { readonly type: "background_task_result" }>
  | Extract<SessionEntry, { readonly type: "work_plan" }>
  | CustomEntry
  | CustomMessageEntry

export type RpcSessionEvent =
  | Exclude<AgentSessionEvent, { type: "model_changed" | "entry_appended" }>
  | { readonly type: "model_changed"; readonly model: RpcModel }
  | { readonly type: "entry_appended"; readonly entry: RpcSessionEntry }

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

type RpcAssistantMessage = Extract<AgentMessage, { readonly role: "assistant" }>

type CompletionObservation = {
  readonly revision: number
  readonly latest: RpcAssistantMessage | undefined
  readonly messageCount: number
}

type CompletionWatch = {
  readonly id: string
  revision: number
  latest: RpcAssistantMessage | undefined
  settled: CompletionObservation | undefined
}

type RpcConnection = { eventMode: "all" | "none" | "activity"; completion: CompletionWatch | undefined }

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
  // Connection-owned event projection. Default remains "all" for compatibility.
  let eventMode: "all" | "none" | "activity" = "all"
  const connection: RpcConnection = {
    get eventMode() {
      return eventMode
    },
    set eventMode(mode: "all" | "none" | "activity") {
      eventMode = mode
    },
    completion: undefined
  }
  const operations = new Set<Promise<void>>()
  const admittedRequestIds = new Set<string>()
  const stopped = deferred<void>()
  const currentState = (): ConnectionState => state
  const output = new RpcOutput(transport.writer, message => stop({ type: "output_error", message }))

  const send = (body: FrameBody, droppable = false, onSettled?: () => void): void => {
    if (state.type === "closed") {
      onSettled?.()
      return
    }
    sequence++
    const frame = { version: rpcProtocolVersion, sequence, ...body }
    if (droppable) output.enqueueDroppable(frame)
    else output.enqueue(frame, onSettled)
  }
  const stop = (reason: Exclude<RpcModeResult, { type: "settlement_error" }>): void => {
    if (state.type !== "open") return
    state = { type: "stopping", reason }
    stopped.resolve()
  }
  const unsubscribe = session.subscribe(event => {
    if (event.type === "message_end" && event.message.role === "assistant" && connection.completion) {
      connection.completion.latest = event.message
    }
    if (event.type === "agent_settled" && connection.completion) {
      connection.completion.settled = {
        revision: connection.completion.revision,
        latest: connection.completion.latest,
        messageCount: session.messages.length
      }
    }
    if (state.type === "open" && eventMode !== "none") {
      send({ type: "session_event", event: projectEvent(event) }, eventMode === "activity")
    }
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
  admittedRequestIds.clear()

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

    if (admittedRequestIds.has(request.id)) {
      send({
        type: "protocol_error",
        code: "invalid_request",
        message: "RPC request id is already in flight",
        id: request.id
      })
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
    admittedRequestIds.add(request.id)
    let slotReleased = false
    const releaseSlot = (): void => {
      if (slotReleased) return
      slotReleased = true
      admittedRequestIds.delete(request.id)
      if (isInterruption) interruptActive = false
      else normalOperations--
    }
    const settleResponse = (completion: ReturnType<typeof deferred<void>>): void => {
      releaseSlot()
      completion.resolve()
    }
    const operation = handleRequest(session, request, connection)
      .then(async operationResult => {
        const responseSettled = deferred<void>()
        if (state.type === "open" || state.type === "stopping") {
          send(
            { type: "response", id: request.id, method: request.method, ok: true, result: operationResult },
            false,
            () => settleResponse(responseSettled)
          )
        } else {
          settleResponse(responseSettled)
        }
        await responseSettled.promise
        return undefined
      })
      .catch(async cause => {
        if (state.type !== "closed") {
          const failure = operationFailure(cause)
          const responseSettled = deferred<void>()
          sendFailure(request, failure.code, failure.message, () => settleResponse(responseSettled))
          await responseSettled.promise
        }
        return undefined
      })
      .finally(() => {
        operations.delete(operation)
        releaseSlot()
      })
    operations.add(operation)
  }

  function sendFailure(
    request: RpcRequest,
    code: "capacity" | "not_found" | "operation_failed",
    message: string,
    onSettled?: () => void
  ): void {
    send(
      { type: "response", id: request.id, method: request.method, ok: false, error: { code, message } },
      false,
      onSettled
    )
  }
}

async function handleRequest(session: AgentSession, request: RpcRequest, connection: RpcConnection): Promise<unknown> {
  switch (request.method) {
    case "session.get_state":
      return sessionState(session)
    case "session.get_messages":
      return messagePage(session, request.params.start, request.params.limit)
    case "session.prompt": {
      const completionId = request.params.completionId
      const participatesInWork =
        request.params.delivery === "direct" || request.params.delivery === "continue" || session.isStreaming
      const tracksCompletion = completionId !== undefined && participatesInWork
      const previousCompletion = connection.completion ? { ...connection.completion } : undefined
      if (completionId === undefined && participatesInWork) connection.completion = undefined
      if (tracksCompletion && previousCompletion?.id !== completionId) {
        connection.completion = { id: completionId, revision: 0, latest: undefined, settled: undefined }
      }
      if (tracksCompletion && connection.completion?.id === completionId) {
        connection.completion.revision++
        connection.completion.settled = undefined
      }
      try {
        if (request.params.delivery === "direct") {
          const settlement = session.prompt(request.params.text)
          void settlement.catch(() => {})
        } else if (request.params.delivery === "steer") {
          session.steer(request.params.text)
        } else if (request.params.delivery === "follow_up") {
          session.followUp(request.params.text)
        } else {
          // continue: child AgentSession decides idle->direct vs running->follow-up atomically.
          const settlement = session.prompt(request.params.text, { streamingBehavior: "followUp" })
          void settlement.catch(() => {})
        }
      } catch (cause) {
        connection.completion = previousCompletion
        throw cause
      }
      const completionRevision =
        completionId !== undefined && connection.completion?.id === completionId
          ? connection.completion.revision
          : undefined
      return { delivery: request.params.delivery, ...(completionRevision !== undefined ? { completionRevision } : {}) }
    }
    case "session.interrupt":
      await session.abort()
      return {}
    case "session.await_idle":
      if (!request.params) {
        await session.waitForIdle()
        return {}
      }
      return awaitCompletion(session, connection, request.params.completionId)
    case "connection.set_events":
      // Applied synchronously in input order before the response is emitted.
      connection.eventMode = request.params.mode
      return { mode: request.params.mode }
    case "command.list":
      return { commands: session.listExtensionCommands() }
    case "command.invoke": {
      if (!session.listExtensionCommands().some(command => command.name === request.params.name)) {
        throw new RpcOperationError("not_found", `Command not found: ${request.params.name}`)
      }
      const message = await session.invokeExtensionCommand(request.params.name, request.params.arguments)
      return message === undefined ? {} : { message }
    }
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
  const extensionCommand = session.extensionCommandStatus
  let activity: RpcSessionActivity
  if (session.isAborting && extensionCommand.type === "idle") activity = { type: "aborting" }
  else if (extensionCommand.type === "running") {
    activity = { type: "extension_command", name: extensionCommand.name, phase: extensionCommand.phase }
  } else if (compaction.type === "running") {
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
    workPlan: session.workPlan,
    messageCount: session.messages.length,
    ...(streamingMessage ? { streamingMessage } : {}),
    compaction,
    retry: session.retryStatus,
    contextUsage: session.contextUsage
  }
}

async function awaitCompletion(
  session: AgentSession,
  connection: RpcConnection,
  completionId: string
): Promise<unknown> {
  while (true) {
    // A newer admission can cross an earlier idle observation before this continuation runs.
    // The synchronous agent_settled snapshot keeps text and revision from different runs from mixing.
    // oxlint-disable-next-line no-await-in-loop
    await session.waitForIdle()
    const watch = connection.completion
    if (watch?.id !== completionId) throw new Error(`Completion watch is not active: ${completionId}`)
    if (watch.settled) return completionResult(watch.settled)
    if (!session.isStreaming) throw new Error(`Completion watch has no settled observation: ${completionId}`)
  }
}

function completionResult(observation: CompletionObservation): unknown {
  const message = observation.latest
  if (!message) {
    return { completionRevision: observation.revision, messageCount: observation.messageCount, completion: null }
  }
  let text = ""
  for (const part of message.content) {
    if (part.type === "text") text += part.text
  }
  const clipped = clipUtf8(text, maxRpcCompletionTextBytes)
  const error =
    typeof message.errorMessage === "string"
      ? clipUtf8(message.errorMessage, maxRpcCompletionErrorBytes).text
      : undefined
  return {
    completionRevision: observation.revision,
    messageCount: observation.messageCount,
    completion: {
      text: clipped.text,
      stopReason: message.stopReason,
      originalBytes: clipped.originalBytes,
      omittedBytes: clipped.omittedBytes,
      ...(error !== undefined ? { error } : {})
    }
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

function clipUtf8(
  text: string,
  maxBytes: number
): { readonly text: string; readonly originalBytes: number; readonly omittedBytes: number } {
  const encoded = Buffer.from(text)
  const originalBytes = encoded.byteLength
  if (originalBytes <= maxBytes) return { text, originalBytes, omittedBytes: 0 }
  let end = maxBytes
  while (end > 0 && (encoded[end]! & 0xc0) === 0x80) end--
  return { text: encoded.subarray(0, end).toString("utf8"), originalBytes, omittedBytes: originalBytes - end }
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
  #queue: Array<{ readonly line: string; readonly bytes: number; readonly settle?: () => void }> = []
  #head = 0
  #pendingBytes = 0
  #running: Promise<void> | undefined
  #failure: string | undefined
  #closed = false

  constructor(writer: RpcWriter, onFailure: (message: string) => void) {
    this.#writer = writer
    this.#onFailure = onFailure
  }

  enqueue(frame: RpcServerFrame, settle?: () => void): void {
    this.#enqueue(frame, "required", settle)
  }

  enqueueDroppable(frame: RpcServerFrame): void {
    this.#enqueue(frame, "droppable")
  }

  #enqueue(frame: RpcServerFrame, mode: "required" | "droppable", settle?: () => void): void {
    if (this.#closed || this.#failure) {
      settle?.()
      return
    }
    let line: string
    try {
      line = `${JSON.stringify(frame)}\n`
    } catch {
      if (mode === "required") this.#fail("Could not serialize RPC output")
      settle?.()
      return
    }
    const bytes = Buffer.byteLength(line)
    if (bytes > maxRpcFrameBytes) {
      if (mode === "required") this.#fail(`RPC output records cannot exceed ${maxRpcFrameBytes} bytes`)
      settle?.()
      return
    }
    if (
      this.#queue.length - this.#head >= maxRpcPendingOutputRecords ||
      this.#pendingBytes + bytes > maxRpcPendingOutputBytes
    ) {
      if (mode === "required") this.#fail("RPC output exceeded its pending-write bound")
      settle?.()
      return
    }
    this.#queue.push({ line, bytes, ...(settle ? { settle } : {}) })
    this.#pendingBytes += bytes
    this.#running ??= Promise.resolve().then(() => this.#drain())
  }

  async settle(): Promise<string | undefined> {
    await this.#running
    return this.#failure
  }

  close(): void {
    this.#closed = true
    this.#settlePending()
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
        const write = this.#writer.write(item.line)
        // oxlint-disable-next-line no-await-in-loop
        if (write) await write
      } catch {
        this.#fail("Could not write RPC output")
        break
      }
      if (this.#closed) break
      item.settle?.()
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
    this.#settlePending()
    this.#queue = []
    this.#head = 0
    this.#pendingBytes = 0
    this.#onFailure(message)
  }

  #settlePending(): void {
    for (let index = this.#head; index < this.#queue.length; index++) this.#queue[index]?.settle?.()
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
