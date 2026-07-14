import {
  type Agent,
  type AgentEvent,
  type AgentMessage,
  type AgentState,
  type AgentTool,
  type ThinkingLevel
} from "@earendil-works/pi-agent-core"
import { cleanupSessionResources, type Api, type ImageContent, type Model } from "@earendil-works/pi-ai"

import type { SessionEntry, SessionManager } from "./session-manager.js"
import type { SettingsManager } from "./settings-manager.js"

export type AgentSessionEvent =
  | AgentEvent
  | { type: "agent_settled" }
  | { type: "queue_update"; steering: readonly string[]; followUp: readonly string[] }
  | { type: "entry_appended"; entry: SessionEntry }
  | { type: "model_changed"; model: Model<Api> }
  | { type: "thinking_level_changed"; level: ThinkingLevel }

export interface PromptOptions {
  images?: ImageContent[]
  streamingBehavior?: "steer" | "followUp"
}

export interface AgentSessionConfig {
  agent: Agent
  sessionManager: SessionManager
  settingsManager: SettingsManager
}

export class AgentSession {
  readonly agent: Agent
  readonly sessionManager: SessionManager
  readonly settingsManager: SettingsManager

  readonly #listeners = new Set<(event: AgentSessionEvent) => void>()
  readonly #unsubscribeAgent: () => void
  readonly #steering: string[] = []
  readonly #followUp: string[] = []
  #run: Promise<void> | undefined
  #disposed = false

  constructor(config: AgentSessionConfig) {
    this.agent = config.agent
    this.sessionManager = config.sessionManager
    this.settingsManager = config.settingsManager
    this.#unsubscribeAgent = this.agent.subscribe(event => this.#handleAgentEvent(event))
  }

  get state(): AgentState {
    return this.agent.state
  }

  get model(): Model<Api> {
    return this.agent.state.model
  }

  get thinkingLevel(): ThinkingLevel {
    return this.agent.state.thinkingLevel
  }

  get isStreaming(): boolean {
    return this.#run !== undefined || this.agent.state.isStreaming
  }

  get sessionId(): string {
    return this.sessionManager.sessionId
  }

  subscribe(listener: (event: AgentSessionEvent) => void): () => void {
    this.#listeners.add(listener)
    return () => this.#listeners.delete(listener)
  }

  async prompt(text: string, options: PromptOptions = {}): Promise<void> {
    this.#assertOpen()
    if (this.#run) {
      if (!options.streamingBehavior) throw new Error("streamingBehavior is required while the agent is running")
      if (options.streamingBehavior === "steer") return this.steer(text, options.images)
      return this.followUp(text, options.images)
    }

    const run = this.agent.prompt(text, options.images)
    this.#run = run
    try {
      await run
    } finally {
      this.#run = undefined
      this.#emit({ type: "agent_settled" })
    }
  }

  async steer(text: string, images?: ImageContent[]): Promise<void> {
    this.#assertOpen()
    this.#steering.push(text)
    this.agent.steer(userMessage(text, images))
    this.#emitQueue()
  }

  async followUp(text: string, images?: ImageContent[]): Promise<void> {
    this.#assertOpen()
    this.#followUp.push(text)
    this.agent.followUp(userMessage(text, images))
    this.#emitQueue()
  }

  clearQueue(): void {
    this.#steering.length = 0
    this.#followUp.length = 0
    this.agent.clearAllQueues()
    this.#emitQueue()
  }

  async abort(): Promise<void> {
    this.agent.abort()
    await this.waitForIdle()
  }

  async waitForIdle(): Promise<void> {
    await this.#run
    await this.agent.waitForIdle()
  }

  async setModel(model: Model<Api>): Promise<void> {
    this.#assertIdle("change model")
    this.sessionManager.appendModelChange(model.provider, model.id)
    this.agent.state.model = model
    this.#emit({ type: "model_changed", model })
  }

  setThinkingLevel(level: ThinkingLevel): void {
    this.#assertIdle("change thinking level")
    this.sessionManager.appendThinkingLevelChange(level)
    this.settingsManager.update({ thinkingLevel: level })
    this.agent.state.thinkingLevel = level
    this.#emit({ type: "thinking_level_changed", level })
  }

  setActiveTools(tools: readonly AgentTool[]): void {
    this.#assertIdle("change tools")
    this.agent.state.tools = [...tools]
  }

  dispose(): void {
    if (this.#disposed) return
    this.#disposed = true
    this.agent.abort()
    this.#unsubscribeAgent()
    this.#listeners.clear()
    cleanupSessionResources(this.sessionId)
  }

  async #handleAgentEvent(event: AgentEvent): Promise<void> {
    if (event.type === "message_end") {
      const id = this.sessionManager.appendMessage(event.message)
      const entry = this.sessionManager.entries().find(candidate => candidate.id === id)
      if (entry) this.#emit({ type: "entry_appended", entry })
    }
    if (event.type === "message_start" && event.message.role === "user") this.#removeDelivered(event.message)
    this.#emit(event)
  }

  #removeDelivered(message: AgentMessage): void {
    const text = messageText(message)
    const steering = this.#steering.indexOf(text)
    if (steering >= 0) this.#steering.splice(steering, 1)
    const followUp = this.#followUp.indexOf(text)
    if (followUp >= 0) this.#followUp.splice(followUp, 1)
    if (steering >= 0 || followUp >= 0) this.#emitQueue()
  }

  #emitQueue(): void {
    this.#emit({ type: "queue_update", steering: [...this.#steering], followUp: [...this.#followUp] })
  }

  #emit(event: AgentSessionEvent): void {
    for (const listener of this.#listeners) listener(event)
  }

  #assertOpen(): void {
    if (this.#disposed) throw new Error("AgentSession is disposed")
  }

  #assertIdle(action: string): void {
    this.#assertOpen()
    if (this.isStreaming) throw new Error(`Cannot ${action} while the agent is running`)
  }
}

function userMessage(text: string, images: ImageContent[] = []): AgentMessage {
  return { role: "user", content: [{ type: "text", text }, ...images], timestamp: Date.now() }
}

function messageText(message: AgentMessage): string {
  if (message.role !== "user") return ""
  if (typeof message.content === "string") return message.content
  return message.content
    .filter(part => part.type === "text")
    .map(part => part.text)
    .join("\n")
}
