import type { ThinkingLevel } from "@earendil-works/pi-agent-core"
import type { ExtensionShutdownReason } from "@with-zi/extension-api"

import type { AgentSession, AgentSessionEvent } from "../agent-session.js"
import { isZiAgentMessage, type AgentMessage } from "../messages.js"
import { maxRpcCompletionErrorBytes, maxRpcCompletionTextBytes } from "../rpc/protocol.js"
import type { ToolSurface } from "../tool-surface.js"
import type { PeerRelay } from "./peer.js"
import { clipUtf8 } from "./text.js"
import { defaultSubagentWorkTimeoutMs, isSubagentWorkTimeout } from "./work-policy.js"

export const workTimeoutSettlementMs = 10_000
export const interruptSettlementMs = 10_000
export const childCloseSettlementMs = 8_000
export const maxChildTranscriptMessages = 200
export const maxChildTranscriptBytes = 8 * 1024 * 1024
export const maxChildTranscriptTools = 64
export const maxChildTranscriptToolBytes = 256 * 1024
export const maxChildTranscriptToolsBytes = 1024 * 1024

export type ChildLifecycleState =
  | { readonly type: "idle"; readonly nextWorkCycle: number }
  | { readonly type: "queued"; readonly workCycle: number; readonly admittedAt: number; readonly prompt: string }
  | { readonly type: "running"; readonly workCycle: number; readonly startedAt: number }
  | {
      readonly type: "interrupting"
      readonly workCycle: number
      readonly startedAt: number
      readonly requestedAt: number
      readonly reason: "requested" | "work_timeout"
    }
  | { readonly type: "closing"; readonly reason: string; readonly requestedAt: number }
  | { readonly type: "exited"; readonly outcome: ChildExitOutcome }

export type ChildExitOutcome =
  | { readonly type: "closed"; readonly code: 0 }
  | { readonly type: "failed"; readonly message: string; readonly code: null }
  | { readonly type: "forced"; readonly message: string }

export type SubagentCompletionStatus = "completed" | "failed" | "cancelled"

export type SubagentWorkCycleErrorCode =
  | "assignment_failed"
  | "work_cycle_timeout"
  | "interrupt_settlement_timeout"
  | "missing_assistant"
  | "provider_error"
  | "missing_final_answer"
  | "incomplete_final_answer"
  | "child_forced_settlement"
  | "child_failed"
  | "child_exited"

interface SubagentCompletionBase {
  readonly name: string
  readonly workCycle: number
  readonly text: string
  readonly originalBytes: number
  readonly omittedBytes: number
  readonly truncated: boolean
  readonly durationMs: number
}

export type SubagentCompletion = SubagentCompletionBase &
  (
    | { readonly status: "completed"; readonly reason?: never; readonly error?: never }
    | { readonly status: "cancelled"; readonly reason?: never; readonly error?: never }
    | { readonly status: "failed"; readonly reason: SubagentWorkCycleErrorCode; readonly error?: string | undefined }
  )

export type ChildSnapshot = {
  readonly name: string
  readonly lifecycle: ChildLifecycleState["type"]
  readonly workCycle?: number | undefined
  readonly elapsedMs?: number | undefined
  readonly sessionId?: string | undefined
  readonly completion?: SubagentCompletion | undefined
}

export type ChildTranscriptTool = {
  readonly id: string
  readonly name: string
  readonly args: unknown
  readonly status: "running" | "done" | "failed"
  readonly result?: unknown
}

export type ChildTranscriptSnapshot = {
  readonly name: string
  readonly messages: readonly AgentMessage[]
  readonly streamingMessage?: AgentMessage
  readonly activeTools: readonly ChildTranscriptTool[]
  readonly omittedMessages: number
  readonly omittedBytes: number
}

interface ChildTranscriptMessages {
  readonly messages: readonly AgentMessage[]
  readonly omittedMessages: number
  readonly omittedBytes: number
}

export interface SubagentChildSession {
  readonly session: AgentSession
  dispose(reason: ExtensionShutdownReason): Promise<void>
}

export interface SubagentChildSessionRequest {
  readonly name: string
  readonly model: string
  readonly thinkingLevel: ThinkingLevel
  readonly apiKey?: string
  readonly toolSurface: ToolSurface
  readonly peerRelay: PeerRelay
  readonly signal?: AbortSignal
}

export type CreateSubagentChildSession = (request: SubagentChildSessionRequest) => Promise<SubagentChildSession>

export interface SubagentChildOptions {
  readonly name: string
  readonly owner: SubagentChildSession
  readonly workTimeoutMs?: number
  readonly workTimeoutSettlementMs?: number
  readonly interruptSettlementMs?: number
  readonly closeSettlementMs?: number
  readonly onStateChange?: () => void
  readonly onCompletion?: (completion: SubagentCompletion) => void
  readonly onPresentationChange?: () => void
}

type Deadline =
  | { readonly type: "none" }
  | { readonly type: "work"; readonly workCycle: number; readonly timer: ReturnType<typeof setTimeout> }
  | { readonly type: "settling"; readonly workCycle: number; readonly timer: ReturnType<typeof setTimeout> }

export class SubagentChild {
  readonly name: string
  readonly #owner: SubagentChildSession
  readonly #session: AgentSession
  readonly #workTimeoutMs: number
  readonly #workTimeoutSettlementMs: number
  readonly #interruptSettlementMs: number
  readonly #closeSettlementMs: number
  readonly #onStateChange: (() => void) | undefined
  readonly #onCompletion: ((completion: SubagentCompletion) => void) | undefined
  readonly #onPresentationChange: (() => void) | undefined
  readonly #unsubscribe: () => void
  #state: ChildLifecycleState = { type: "idle", nextWorkCycle: 1 }
  #latestCompletion: SubagentCompletion | undefined
  #closeSettlement: Promise<void> | undefined
  #deadline: Deadline = { type: "none" }
  #cycleObservation = 0
  #transcriptMessages: ChildTranscriptMessages | undefined
  #transcriptMessageBytes: number[] = []
  #transcriptRetainedBytes = 0
  #transcriptSourceCount = 0
  #transcriptSourceLast: AgentMessage | undefined
  #transcriptOmittedMessages = 0
  #transcriptOmittedBytes = 0
  #transcriptMessagesChanged = true
  #transcriptInvalidated = true
  #streamingMessage: AgentMessage | undefined
  #tools = new Map<string, ChildTranscriptTool>()

  constructor(options: SubagentChildOptions) {
    this.name = options.name
    this.#owner = options.owner
    this.#session = options.owner.session
    this.#workTimeoutMs = options.workTimeoutMs ?? defaultSubagentWorkTimeoutMs
    this.#workTimeoutSettlementMs = options.workTimeoutSettlementMs ?? workTimeoutSettlementMs
    this.#interruptSettlementMs = options.interruptSettlementMs ?? interruptSettlementMs
    this.#closeSettlementMs = options.closeSettlementMs ?? childCloseSettlementMs
    this.#onStateChange = options.onStateChange
    this.#onCompletion = options.onCompletion
    this.#onPresentationChange = options.onPresentationChange
    if (!isSubagentWorkTimeout(this.#workTimeoutMs)) throw new Error("Invalid subagent work timeout")
    if (!isPositiveTimeout(this.#workTimeoutSettlementMs)) throw new Error("Invalid work-timeout settlement bound")
    if (!isPositiveTimeout(this.#interruptSettlementMs)) throw new Error("Invalid interrupt settlement bound")
    if (!isPositiveTimeout(this.#closeSettlementMs)) throw new Error("Invalid child close settlement bound")
    this.#unsubscribe = this.#session.subscribe(event => this.#project(event))
  }

  get state(): ChildLifecycleState {
    return this.#state
  }

  snapshot(): ChildSnapshot {
    const state = this.#state
    const workCycle =
      state.type === "idle"
        ? Math.max(0, state.nextWorkCycle - 1)
        : state.type === "queued" || state.type === "running" || state.type === "interrupting"
          ? state.workCycle
          : undefined
    const startedAt =
      state.type === "queued"
        ? state.admittedAt
        : state.type === "running" || state.type === "interrupting"
          ? state.startedAt
          : undefined
    return Object.freeze({
      name: this.name,
      lifecycle: state.type,
      ...(workCycle === undefined ? {} : { workCycle }),
      ...(startedAt === undefined
        ? this.#latestCompletion
          ? { elapsedMs: this.#latestCompletion.durationMs }
          : {}
        : { elapsedMs: Math.max(0, Date.now() - startedAt) }),
      sessionId: this.#session.sessionId,
      ...(this.#latestCompletion ? { completion: this.#latestCompletion } : {})
    })
  }

  transcript(): ChildTranscriptSnapshot {
    const projection = this.#projectTranscriptMessages()
    return Object.freeze({
      name: this.name,
      messages: projection.messages,
      ...(this.#streamingMessage ? { streamingMessage: this.#streamingMessage } : {}),
      activeTools: Object.freeze([...this.#tools.values()].map(tool => Object.freeze({ ...tool }))),
      omittedMessages: projection.omittedMessages,
      omittedBytes: projection.omittedBytes
    })
  }

  queueCycle(prompt: string): number {
    const state = this.#state
    if (state.type !== "idle") throw new Error(`Subagent ${this.name} cannot queue work while ${state.type}`)
    const workCycle = state.nextWorkCycle
    this.#transition({ type: "queued", workCycle, admittedAt: Date.now(), prompt })
    return workCycle
  }

  startQueuedCycle(): void {
    const state = this.#state
    if (state.type !== "queued") throw new Error(`Subagent ${this.name} cannot start queued work while ${state.type}`)
    const startedAt = Date.now()
    this.#transition({ type: "running", workCycle: state.workCycle, startedAt })
    let settlement: Promise<void>
    try {
      settlement = this.#session.prompt(state.prompt)
    } catch (cause) {
      this.#publishCompletion({
        ...baseCompletion(this.name, state.workCycle, 0, "failed", "", "assignment_failed"),
        error: clipUtf8(cause instanceof Error ? cause.message : String(cause), maxRpcCompletionErrorBytes).text
      })
      this.#transition({ type: "idle", nextWorkCycle: state.workCycle + 1 })
      return
    }
    this.#armWorkDeadline(state.workCycle, startedAt)
    this.#observeCycle(state.workCycle, startedAt, settlement)
  }

  async send(text: string): Promise<void> {
    const state = this.#state
    if (state.type !== "idle" && state.type !== "queued" && state.type !== "running") {
      throw new Error(`Subagent ${this.name} cannot accept send while ${state.type}`)
    }
    this.#session.followUp(text)
  }

  assign(text: string): "queued" | "follow_up" {
    const state = this.#state
    if (state.type === "idle") {
      this.queueCycle(text)
      return "queued"
    }
    if (state.type === "queued") {
      this.#session.followUp(text)
      return "follow_up"
    }
    if (state.type !== "running") {
      throw new Error(`Subagent ${this.name} cannot accept work while ${state.type}`)
    }
    const wasStreaming = this.#session.isStreaming
    const settlement = this.#session.prompt(text, { streamingBehavior: "followUp" })
    if (!wasStreaming) this.#observeCycle(state.workCycle, state.startedAt, settlement)
    return "follow_up"
  }

  async interrupt(): Promise<"interrupted" | "already_idle"> {
    const state = this.#state
    if (state.type === "idle") return "already_idle"
    if (state.type === "queued") {
      this.#session.takeQueuedInputs()
      this.#publishCompletion(baseCompletion(this.name, state.workCycle, 0, "cancelled", ""))
      this.#transition({ type: "idle", nextWorkCycle: state.workCycle + 1 })
      return "interrupted"
    }
    if (state.type === "interrupting") return "interrupted"
    if (state.type !== "running") throw new Error(`Subagent ${this.name} cannot interrupt while ${state.type}`)
    this.#clearDeadline(state.workCycle)
    this.#transition({
      type: "interrupting",
      workCycle: state.workCycle,
      startedAt: state.startedAt,
      requestedAt: Date.now(),
      reason: "requested"
    })
    const deadline = setTimeout(() => this.#interruptSettlementExpired(state.workCycle), this.#interruptSettlementMs)
    deadline.unref?.()
    this.#deadline = { type: "settling", workCycle: state.workCycle, timer: deadline }
    await this.#session.abort()
    return "interrupted"
  }

  close(reason = "close"): Promise<void> {
    if (this.#closeSettlement) return this.#closeSettlement
    if (this.#state.type === "exited") return Promise.resolve()
    this.#clearDeadline()
    this.#transition({ type: "closing", reason, requestedAt: Date.now() })

    let disposal: Promise<void>
    try {
      disposal = this.#owner.dispose(shutdownReason(reason))
    } catch (cause) {
      disposal = Promise.reject(cause)
    }
    const settlement = settleChildClose(disposal, this.#closeSettlementMs).then(result => {
      this.#unsubscribe()
      switch (result.type) {
        case "settled":
          this.#transition({ type: "exited", outcome: { type: "closed", code: 0 } })
          return undefined
        case "failed":
          this.#transition({ type: "exited", outcome: { type: "failed", message: result.error.message, code: null } })
          return undefined
        case "forced": {
          const message = `Subagent ${this.name} disposal did not settle within ${this.#closeSettlementMs}ms`
          this.#transition({ type: "exited", outcome: { type: "forced", message } })
          return undefined
        }
      }
      return result
    })
    this.#closeSettlement = settlement
    return settlement
  }

  #observeCycle(workCycle: number, startedAt: number, settlement: Promise<void>): void {
    const observation = ++this.#cycleObservation
    const observed = settlement.then(
      () => this.#settleCycle(workCycle, startedAt, observation),
      () => this.#settleCycle(workCycle, startedAt, observation)
    )
    void observed.catch(() => {})
  }

  #settleCycle(workCycle: number, startedAt: number, observation: number): void {
    const state = this.#state
    if (
      observation !== this.#cycleObservation ||
      (state.type !== "running" && state.type !== "interrupting") ||
      state.workCycle !== workCycle
    )
      return
    this.#clearDeadline(workCycle)
    const observed = completionFromSession(this.name, workCycle, Date.now() - startedAt, this.#session)
    const completion =
      state.type === "interrupting" && state.reason === "work_timeout"
        ? failedCompletion(observed, "work_cycle_timeout", `Subagent work cycle exceeded ${this.#workTimeoutMs}ms`)
        : state.type === "interrupting"
          ? cancelledCompletion(observed)
          : observed
    this.#publishCompletion(completion)
    this.#transition({ type: "idle", nextWorkCycle: workCycle + 1 })
  }

  #armWorkDeadline(workCycle: number, startedAt: number): void {
    this.#clearDeadline()
    const timer = setTimeout(() => this.#workExpired(workCycle, startedAt), this.#workTimeoutMs)
    timer.unref?.()
    this.#deadline = { type: "work", workCycle, timer }
  }

  #workExpired(workCycle: number, startedAt: number): void {
    const state = this.#state
    if (state.type !== "running" || state.workCycle !== workCycle) return
    const timer = setTimeout(() => this.#workSettlementExpired(workCycle, startedAt), this.#workTimeoutSettlementMs)
    timer.unref?.()
    this.#deadline = { type: "settling", workCycle, timer }
    this.#transition({ type: "interrupting", workCycle, startedAt, requestedAt: Date.now(), reason: "work_timeout" })
    void this.#session.abort().catch(() => this.#workSettlementExpired(workCycle, startedAt))
  }

  #workSettlementExpired(workCycle: number, startedAt: number): void {
    const state = this.#state
    if (state.type !== "interrupting" || state.workCycle !== workCycle || state.reason !== "work_timeout") return
    const completion = baseCompletion(this.name, workCycle, Date.now() - startedAt, "failed", "", "work_cycle_timeout")
    this.#publishCompletion({ ...completion, error: `Subagent work cycle exceeded ${this.#workTimeoutMs}ms` })
    void this.close("work_timeout").catch(() => {})
  }

  #interruptSettlementExpired(workCycle: number): void {
    const state = this.#state
    if (state.type !== "interrupting" || state.workCycle !== workCycle || state.reason !== "requested") return
    const completion = baseCompletion(
      this.name,
      workCycle,
      Date.now() - state.startedAt,
      "failed",
      "",
      "interrupt_settlement_timeout"
    )
    this.#publishCompletion({ ...completion, error: `Subagent ${this.name} interruption did not settle` })
    void this.close("interrupt_settlement_timeout").catch(() => {})
  }

  #clearDeadline(workCycle?: number): void {
    const deadline = this.#deadline
    if (deadline.type === "none" || (workCycle !== undefined && deadline.workCycle !== workCycle)) return
    clearTimeout(deadline.timer)
    this.#deadline = { type: "none" }
  }

  #publishCompletion(completion: SubagentCompletion): void {
    if (this.#latestCompletion?.workCycle === completion.workCycle) return
    this.#latestCompletion = completion
    try {
      this.#onCompletion?.(completion)
    } catch {
      // Completion observation cannot take ownership of the child lifecycle.
    }
  }

  #project(event: AgentSessionEvent): void {
    switch (event.type) {
      case "message_start":
      case "message_update":
        if (isZiAgentMessage(event.message)) this.#streamingMessage = event.message
        break
      case "message_end":
        this.#streamingMessage = undefined
        this.#transcriptMessagesChanged = true
        if (isZiAgentMessage(event.message) && event.message.role === "toolResult") {
          this.#tools.delete(event.message.toolCallId)
        }
        break
      case "entry_appended":
        if (event.entry.type === "compaction") {
          this.#transcriptInvalidated = true
          this.#transcriptMessagesChanged = true
        }
        break
      case "agent_end":
      case "agent_settled":
        this.#streamingMessage = undefined
        break
      case "tool_execution_start":
        this.#setTool({ id: event.toolCallId, name: event.toolName, args: event.args, status: "running" })
        break
      case "tool_execution_update": {
        const tool = this.#tools.get(event.toolCallId)
        if (tool?.status === "running") this.#setTool({ ...tool, result: event.partialResult })
        break
      }
      case "tool_execution_end": {
        const tool = this.#tools.get(event.toolCallId)
        if (tool) this.#setTool({ ...tool, result: event.result, status: event.isError ? "failed" : "done" })
        break
      }
    }
    try {
      this.#onPresentationChange?.()
    } catch {
      // Presentation observation cannot take ownership of the child lifecycle.
    }
  }

  #projectTranscriptMessages(): ChildTranscriptMessages {
    const cached = this.#transcriptMessages
    if (!this.#transcriptMessagesChanged && cached) return cached

    const source = this.#session.messages
    const appendOnly =
      !this.#transcriptInvalidated &&
      this.#transcriptSourceCount <= source.length &&
      (this.#transcriptSourceCount === 0 || source[this.#transcriptSourceCount - 1] === this.#transcriptSourceLast)
    const messages = appendOnly && cached ? [...cached.messages] : []
    if (!appendOnly) {
      this.#transcriptMessageBytes = []
      this.#transcriptRetainedBytes = 0
      this.#transcriptOmittedMessages = 0
      this.#transcriptOmittedBytes = 0
      this.#transcriptSourceCount = 0
      this.#transcriptSourceLast = undefined
    }

    for (let index = this.#transcriptSourceCount; index < source.length; index++) {
      const message = source[index]
      if (!message) continue
      const bytes = Buffer.byteLength(JSON.stringify(message))
      messages.push(message)
      this.#transcriptMessageBytes.push(bytes)
      this.#transcriptRetainedBytes += bytes
      while (messages.length > maxChildTranscriptMessages || this.#transcriptRetainedBytes > maxChildTranscriptBytes) {
        messages.shift()
        const omittedBytes = this.#transcriptMessageBytes.shift()
        if (omittedBytes === undefined) break
        this.#transcriptRetainedBytes -= omittedBytes
        this.#transcriptOmittedMessages++
        this.#transcriptOmittedBytes += omittedBytes
      }
    }

    this.#transcriptSourceCount = source.length
    this.#transcriptSourceLast = source.at(-1)
    this.#transcriptMessagesChanged = false
    this.#transcriptInvalidated = false
    if (
      cached &&
      cached.omittedMessages === this.#transcriptOmittedMessages &&
      cached.omittedBytes === this.#transcriptOmittedBytes &&
      sameMessageReferences(cached.messages, messages)
    ) {
      return cached
    }

    const projection = Object.freeze({
      messages: Object.freeze(messages),
      omittedMessages: this.#transcriptOmittedMessages,
      omittedBytes: this.#transcriptOmittedBytes
    })
    this.#transcriptMessages = projection
    return projection
  }

  #setTool(tool: ChildTranscriptTool): void {
    if (Buffer.byteLength(JSON.stringify(tool)) > maxChildTranscriptToolBytes) {
      this.#tools.delete(tool.id)
      return
    }
    this.#tools.set(tool.id, tool)
    while (
      this.#tools.size > maxChildTranscriptTools ||
      transcriptToolBytes(this.#tools) > maxChildTranscriptToolsBytes
    ) {
      const oldest = this.#tools.keys().next().value
      if (oldest === undefined) break
      this.#tools.delete(oldest)
    }
  }

  #transition(next: ChildLifecycleState): void {
    this.#state = next
    try {
      this.#onStateChange?.()
    } catch {
      // State observation cannot take ownership of the child lifecycle.
    }
  }
}

function completionFromSession(
  name: string,
  workCycle: number,
  durationMs: number,
  session: AgentSession
): SubagentCompletion {
  const message = session.messages.findLast(
    (candidate): candidate is Extract<AgentMessage, { role: "assistant" }> => candidate.role === "assistant"
  )
  if (!message) return baseCompletion(name, workCycle, durationMs, "failed", "", "missing_assistant")
  let text = ""
  for (const content of message.content) if (content.type === "text") text += content.text
  const clipped = clipUtf8(text, maxRpcCompletionTextBytes)
  const fields = {
    text: clipped.text,
    originalBytes: clipped.originalBytes,
    omittedBytes: clipped.omittedBytes,
    truncated: message.stopReason === "length" || clipped.omittedBytes > 0
  }
  switch (message.stopReason) {
    case "aborted":
      return { ...baseCompletion(name, workCycle, durationMs, "cancelled", clipped.text), ...fields }
    case "error":
      return {
        ...baseCompletion(name, workCycle, durationMs, "failed", clipped.text, "provider_error"),
        ...fields,
        ...(message.errorMessage ? { error: clipUtf8(message.errorMessage, maxRpcCompletionErrorBytes).text } : {})
      }
    case "toolUse":
      return {
        ...baseCompletion(name, workCycle, durationMs, "failed", clipped.text, "missing_final_answer"),
        ...fields
      }
    case "pending":
      return {
        ...baseCompletion(name, workCycle, durationMs, "failed", clipped.text, "incomplete_final_answer"),
        ...fields
      }
    default:
      return { ...baseCompletion(name, workCycle, durationMs, "completed", clipped.text), ...fields }
  }
}

function failedCompletion(
  completion: SubagentCompletion,
  reason: SubagentWorkCycleErrorCode,
  error: string
): SubagentCompletion {
  return { ...completion, status: "failed", reason, error }
}

function cancelledCompletion(completion: SubagentCompletion): SubagentCompletion {
  return {
    name: completion.name,
    workCycle: completion.workCycle,
    status: "cancelled",
    text: completion.text,
    originalBytes: completion.originalBytes,
    omittedBytes: completion.omittedBytes,
    truncated: completion.truncated,
    durationMs: completion.durationMs
  }
}

function baseCompletion(
  name: string,
  workCycle: number,
  durationMs: number,
  status: "completed" | "cancelled",
  text: string
): Extract<SubagentCompletion, { readonly status: "completed" | "cancelled" }>
function baseCompletion(
  name: string,
  workCycle: number,
  durationMs: number,
  status: "failed",
  text: string,
  reason: SubagentWorkCycleErrorCode
): Extract<SubagentCompletion, { readonly status: "failed" }>
function baseCompletion(
  name: string,
  workCycle: number,
  durationMs: number,
  status: SubagentCompletionStatus,
  text: string,
  reason?: SubagentWorkCycleErrorCode
): SubagentCompletion {
  const common = {
    name,
    workCycle,
    text,
    originalBytes: Buffer.byteLength(text),
    omittedBytes: 0,
    truncated: false,
    durationMs: Math.max(0, durationMs)
  }
  if (status === "failed") {
    if (!reason) throw new Error("Failed subagent completion requires an error code")
    return { ...common, status, reason }
  }
  return { ...common, status }
}

function sameMessageReferences(left: readonly AgentMessage[], right: readonly AgentMessage[]): boolean {
  return left.length === right.length && left.every((message, index) => message === right[index])
}

function transcriptToolBytes(tools: ReadonlyMap<string, ChildTranscriptTool>): number {
  let bytes = 0
  for (const tool of tools.values()) bytes += Buffer.byteLength(JSON.stringify(tool))
  return bytes
}

function shutdownReason(reason: string): ExtensionShutdownReason {
  switch (reason) {
    case "session_disposed":
    case "quit":
      return "quit"
    case "new":
    case "resume":
    case "reload":
      return reason
    default:
      return "quit"
  }
}

type ChildCloseSettlement =
  | { readonly type: "settled" }
  | { readonly type: "failed"; readonly error: Error }
  | { readonly type: "forced" }

async function settleChildClose(disposal: Promise<void>, timeoutMs: number): Promise<ChildCloseSettlement> {
  let timeout: ReturnType<typeof setTimeout> | undefined
  const settled = disposal.then<ChildCloseSettlement, ChildCloseSettlement>(
    () => ({ type: "settled" }),
    cause => ({ type: "failed", error: cause instanceof Error ? cause : new Error(String(cause)) })
  )
  const forced = new Promise<ChildCloseSettlement>(resolve => {
    timeout = setTimeout(() => resolve({ type: "forced" }), timeoutMs)
  })
  const result = await Promise.race([settled, forced])
  if (timeout) clearTimeout(timeout)
  return result
}

function isPositiveTimeout(value: number): boolean {
  return Number.isSafeInteger(value) && value > 0
}
