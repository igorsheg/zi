import {
  type Agent,
  type AgentEvent,
  type AgentMessage,
  type AgentTool,
  type ThinkingLevel
} from "@earendil-works/pi-agent-core"
import { cleanupSessionResources, type Api, type ImageContent, type Model } from "@earendil-works/pi-ai"

import type { SessionEntry, SessionManager } from "./session-manager.js"
import type { SettingsManager } from "./settings-manager.js"

export const maxPendingInputCount = 32
export const maxPendingInputBytes = 8 * 1024 * 1024

export type PendingInputDelivery = "steer" | "followUp"

export interface QueuedInput {
  readonly id: number
  readonly delivery: PendingInputDelivery
  readonly text: string
  readonly images: readonly ImageContent[]
  readonly bytes: number
}

export interface QueuedInputs {
  readonly steering: readonly QueuedInput[]
  readonly followUp: readonly QueuedInput[]
}

export interface AbortedQueuedInputs extends QueuedInputs {
  readonly settled: Promise<void>
}

export type AgentSessionEvent =
  | AgentEvent
  | { type: "agent_settled" }
  | ({ type: "queue_update" } & QueuedInputs)
  | { type: "entry_appended"; entry: SessionEntry }
  | { type: "model_changed"; model: Model<Api> }
  | { type: "thinking_level_changed"; level: ThinkingLevel }

export interface PromptOptions {
  images?: ImageContent[]
  streamingBehavior?: PendingInputDelivery
}

export interface AgentSessionConfig {
  agent: Agent
  sessionManager: SessionManager
  settingsManager: SettingsManager
}

export class QueueCapacityError extends Error {
  constructor() {
    super("Queue capacity exceeded (maximum 32 messages or 8 MiB).")
    this.name = "QueueCapacityError"
  }
}

type Activity =
  | { type: "idle" }
  | { type: "running"; runId: number; settled: Promise<void> }
  | { type: "aborting"; runId: number; settled: Promise<void> }
  | { type: "failed"; runId: number; cause: unknown }
  | { type: "disposed"; settled: Promise<void> }

interface PendingInput {
  readonly id: number
  readonly runId: number
  readonly delivery: PendingInputDelivery
  readonly text: string
  readonly images: readonly ImageContent[]
  readonly bytes: number
  readonly message: AgentMessage
}

interface Settlement {
  readonly promise: Promise<void>
  resolve(): void
  reject(cause: unknown): void
}

const emptyQueue = (): QueuedInputs => Object.freeze({ steering: Object.freeze([]), followUp: Object.freeze([]) })

export class AgentSession {
  readonly sessionManager: SessionManager
  readonly settingsManager: SettingsManager

  readonly #agent: Agent
  readonly #listeners = new Set<(event: AgentSessionEvent) => void>()
  readonly #unsubscribeAgent: () => void
  #activity: Activity = { type: "idle" }
  #pending: PendingInput[] = []
  #pendingBytes = 0
  #nextRunId = 0
  #nextEntryId = 0

  constructor(config: AgentSessionConfig) {
    this.#agent = config.agent
    this.sessionManager = config.sessionManager
    this.settingsManager = config.settingsManager
    this.#unsubscribeAgent = this.#agent.subscribe(event => this.#handleAgentEvent(event))
  }

  get messages(): readonly AgentMessage[] {
    return this.#agent.state.messages
  }

  get streamingMessage(): AgentMessage | undefined {
    return this.#agent.state.streamingMessage
  }

  get model(): Model<Api> {
    return this.#agent.state.model
  }

  get thinkingLevel(): ThinkingLevel {
    return this.#agent.state.thinkingLevel
  }

  get isStreaming(): boolean {
    return this.#activity.type === "running" || this.#activity.type === "aborting"
  }

  get isAborting(): boolean {
    return this.#activity.type === "aborting"
  }

  get queuedInputs(): QueuedInputs {
    return this.#queueSnapshot()
  }

  get sessionId(): string {
    return this.sessionManager.sessionId
  }

  subscribe(listener: (event: AgentSessionEvent) => void): () => void {
    this.#listeners.add(listener)
    return () => this.#listeners.delete(listener)
  }

  prompt(text: string, options: PromptOptions = {}): Promise<void> {
    switch (this.#activity.type) {
      case "idle": {
        const runId = ++this.#nextRunId
        const settlement = createSettlement()
        this.#activity = { type: "running", runId, settled: settlement.promise }
        void this.#drive(runId, text, options.images, settlement)
        return settlement.promise
      }
      case "running":
        if (!options.streamingBehavior) throw new Error("streamingBehavior is required while the agent is running")
        this.#enqueue(options.streamingBehavior, text, options.images)
        return Promise.resolve()
      case "aborting":
        throw new Error("Cannot prompt while the agent is aborting")
      case "failed":
        throw new Error("Restore or discard queued inputs from the failed run before prompting again")
      case "disposed":
        throw new Error("AgentSession is disposed")
      default:
        return assertNever(this.#activity)
    }
  }

  steer(text: string, images?: ImageContent[]): void {
    this.#enqueue("steer", text, images)
  }

  followUp(text: string, images?: ImageContent[]): void {
    this.#enqueue("followUp", text, images)
  }

  takeQueuedInputs(): QueuedInputs {
    this.#assertOpen()
    if (this.#activity.type === "aborting") throw new Error("Cannot restore queued inputs while the agent is aborting")
    const queued = this.#detachQueuedInputs()
    if (this.#activity.type === "failed") this.#activity = { type: "idle" }
    this.#emitQueue()
    return queued
  }

  takeQueuedInputsAndAbort(): AbortedQueuedInputs {
    switch (this.#activity.type) {
      case "idle": {
        const queued = this.#detachQueuedInputs()
        this.#emitQueue()
        return { ...queued, settled: Promise.resolve() }
      }
      case "running": {
        const { runId, settled } = this.#activity
        const queued = this.#detachQueuedInputs()
        this.#activity = { type: "aborting", runId, settled }
        this.#emitQueue()
        this.#agent.abort()
        return { ...queued, settled }
      }
      case "aborting":
        return { ...emptyQueue(), settled: this.#activity.settled }
      case "failed": {
        const queued = this.#detachQueuedInputs()
        this.#activity = { type: "idle" }
        this.#emitQueue()
        return { ...queued, settled: Promise.resolve() }
      }
      case "disposed":
        throw new Error("AgentSession is disposed")
      default:
        return assertNever(this.#activity)
    }
  }

  abort(): Promise<void> {
    switch (this.#activity.type) {
      case "running":
      case "aborting": {
        const { settled } = this.#activity
        this.#agent.abort()
        return settled
      }
      case "idle":
      case "failed":
        this.#agent.abort()
        return Promise.resolve()
      case "disposed":
        throw new Error("AgentSession is disposed")
      default:
        return assertNever(this.#activity)
    }
  }

  waitForIdle(): Promise<void> {
    switch (this.#activity.type) {
      case "running":
      case "aborting":
      case "disposed":
        return this.#activity.settled
      case "idle":
      case "failed":
        return Promise.resolve()
      default:
        return assertNever(this.#activity)
    }
  }

  async setModel(model: Model<Api>): Promise<void> {
    this.#assertIdle("change model")
    this.sessionManager.appendModelChange(model.provider, model.id)
    this.#agent.state.model = model
    this.#emit({ type: "model_changed", model })
  }

  setThinkingLevel(level: ThinkingLevel): void {
    this.#assertIdle("change thinking level")
    this.sessionManager.appendThinkingLevelChange(level)
    this.settingsManager.update({ thinkingLevel: level })
    this.#agent.state.thinkingLevel = level
    this.#emit({ type: "thinking_level_changed", level })
  }

  setActiveTools(tools: readonly AgentTool[]): void {
    this.#assertIdle("change tools")
    this.#agent.state.tools = [...tools]
  }

  dispose(): void {
    if (this.#activity.type === "disposed") return
    const settled =
      this.#activity.type === "running" || this.#activity.type === "aborting"
        ? this.#activity.settled
        : Promise.resolve()
    this.#pending = []
    this.#pendingBytes = 0
    this.#agent.clearAllQueues()
    this.#activity = { type: "disposed", settled }
    this.#agent.abort()
    this.#unsubscribeAgent()
    this.#listeners.clear()
    cleanupSessionResources(this.sessionId)
  }

  async #drive(runId: number, text: string, images: ImageContent[] | undefined, settlement: Settlement): Promise<void> {
    let failure: { cause: unknown } | undefined
    try {
      await this.#agent.prompt(text, images)
      // Core runs are sequential: each continuation decides which queued batch is eligible next.
      // oxlint-disable-next-line no-await-in-loop
      while (this.#canContinue(runId) && this.#agent.hasQueuedMessages()) await this.#agent.continue()
    } catch (cause) {
      failure = { cause }
    }

    try {
      if (this.#isCurrentRun(runId)) {
        if (failure && this.#pending.some(entry => entry.runId === runId)) {
          this.#activity = { type: "failed", runId, cause: failure.cause }
        } else {
          this.#activity = { type: "idle" }
        }
        if (failure) this.#agent.clearAllQueues()
        this.#emit({ type: "agent_settled" })
      }
    } catch (cause) {
      failure ??= { cause }
    } finally {
      if (failure) settlement.reject(failure.cause)
      else settlement.resolve()
    }
  }

  #canContinue(runId: number): boolean {
    return this.#activity.type === "running" && this.#activity.runId === runId
  }

  #isCurrentRun(runId: number): boolean {
    return (this.#activity.type === "running" || this.#activity.type === "aborting") && this.#activity.runId === runId
  }

  #enqueue(delivery: PendingInputDelivery, text: string, images: ImageContent[] | undefined): void {
    const runId = this.#queueRunId()
    const retainedImages = (images ?? []).map(cloneImage)
    const bytes = retainedBytes(text, retainedImages)
    if (this.#pending.length === maxPendingInputCount || this.#pendingBytes + bytes > maxPendingInputBytes) {
      throw new QueueCapacityError()
    }

    const message = userMessage(text, retainedImages)
    const entry: PendingInput = {
      id: ++this.#nextEntryId,
      runId,
      delivery,
      text,
      images: retainedImages,
      bytes,
      message
    }
    this.#pending.push(entry)
    this.#pendingBytes += bytes
    if (delivery === "steer") this.#agent.steer(message)
    else this.#agent.followUp(message)
    this.#emitQueue()
  }

  #queueRunId(): number {
    switch (this.#activity.type) {
      case "running":
        return this.#activity.runId
      case "idle":
        return this.#nextRunId + 1
      case "aborting":
        throw new Error("Cannot queue input while the agent is aborting")
      case "failed":
        throw new Error("Restore or discard queued inputs from the failed run before queueing again")
      case "disposed":
        throw new Error("AgentSession is disposed")
      default:
        return assertNever(this.#activity)
    }
  }

  async #handleAgentEvent(event: AgentEvent): Promise<void> {
    if (event.type === "message_start" && event.message.role === "user") this.#removeDelivered(event.message)
    if (event.type === "message_end") {
      const id = this.sessionManager.appendMessage(event.message)
      const entry = this.sessionManager.entries().find(candidate => candidate.id === id)
      if (entry) this.#emit({ type: "entry_appended", entry })
    }
    this.#emit(event)
  }

  #removeDelivered(message: AgentMessage): void {
    const runId =
      this.#activity.type === "running" || this.#activity.type === "aborting" ? this.#activity.runId : undefined
    if (runId === undefined) return
    const index = this.#pending.findIndex(entry => entry.runId === runId && entry.message === message)
    if (index < 0) return
    const [entry] = this.#pending.splice(index, 1)
    if (!entry) return
    this.#pendingBytes -= entry.bytes
    this.#emitQueue()
  }

  #detachQueuedInputs(): QueuedInputs {
    const queued = this.#queueSnapshot()
    this.#pending = []
    this.#pendingBytes = 0
    this.#agent.clearAllQueues()
    return queued
  }

  #queueSnapshot(): QueuedInputs {
    const steering: QueuedInput[] = []
    const followUp: QueuedInput[] = []
    for (const entry of this.#pending) {
      const snapshot = Object.freeze({
        id: entry.id,
        delivery: entry.delivery,
        text: entry.text,
        images: Object.freeze(entry.images.map(image => Object.freeze(cloneImage(image)))),
        bytes: entry.bytes
      })
      if (entry.delivery === "steer") steering.push(snapshot)
      else followUp.push(snapshot)
    }
    return Object.freeze({ steering: Object.freeze(steering), followUp: Object.freeze(followUp) })
  }

  #emitQueue(): void {
    this.#emit({ type: "queue_update", ...this.#queueSnapshot() })
  }

  #emit(event: AgentSessionEvent): void {
    let failure: { cause: unknown } | undefined
    for (const listener of this.#listeners) {
      try {
        listener(event)
      } catch (cause) {
        failure ??= { cause }
      }
    }
    if (failure) throw failure.cause
  }

  #assertOpen(): void {
    if (this.#activity.type === "disposed") throw new Error("AgentSession is disposed")
  }

  #assertIdle(action: string): void {
    this.#assertOpen()
    if (this.#activity.type !== "idle") throw new Error(`Cannot ${action} while the agent is running`)
  }
}

function createSettlement(): Settlement {
  let resolve!: () => void
  let reject!: (cause: unknown) => void
  const promise = new Promise<void>((resolvePromise, rejectPromise) => {
    resolve = resolvePromise
    reject = rejectPromise
  })
  return { promise, resolve, reject }
}

function userMessage(text: string, images: readonly ImageContent[]): AgentMessage {
  return { role: "user", content: [{ type: "text", text }, ...images], timestamp: Date.now() }
}

function cloneImage(image: ImageContent): ImageContent {
  return { type: "image", data: image.data, mimeType: image.mimeType }
}

function retainedBytes(text: string, images: readonly ImageContent[]): number {
  let bytes = Buffer.byteLength(text)
  for (const image of images) bytes += Buffer.byteLength(image.mimeType) + Buffer.byteLength(image.data)
  return bytes
}

function assertNever(value: never): never {
  throw new Error(`Unexpected activity: ${String(value)}`)
}
