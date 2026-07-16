import {
  type Agent,
  type AgentEvent,
  type AgentMessage,
  type AgentTool,
  type QueueMode,
  type ThinkingLevel
} from "@earendil-works/pi-agent-core"
import {
  clampThinkingLevel,
  cleanupSessionResources,
  getSupportedThinkingLevels,
  type Api,
  type ImageContent,
  type Model
} from "@earendil-works/pi-ai"

import type {
  Authentication,
  AuthenticationInteraction,
  AuthenticationMethod,
  AuthenticationMethodType
} from "./authentication.js"
import type { StoredCredential } from "./credential-store.js"
import type { ModelRegistry } from "./model-registry.js"
import { expandPromptTemplate, type PromptTemplate } from "./prompt-templates.js"
import type { ResourceDiagnostic } from "./resource-diagnostics.js"
import type { SessionResources } from "./resource-loader.js"
import type { SessionEntry, SessionManager } from "./session-manager.js"
import type { SessionShell, ShellDemotionResult, ShellKillResult, ShellTaskSnapshot } from "./session-shell.js"
import type { SettingsManager, SettingsScope } from "./settings-manager.js"
import { expandSkillCommand, type Skill } from "./skills.js"
import type { SlashCommand } from "./slash-commands.js"
import { buildSystemPrompt } from "./system-prompt.js"

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
  | { type: "steering_mode_changed"; mode: QueueMode }
  | { type: "follow_up_mode_changed"; mode: QueueMode }
  | { type: "shell_task_changed"; taskId: string }
  | {
      type: "authentication_changed"
      status: "logged_in" | "logged_out"
      providerId: string
      method?: AuthenticationMethodType
    }

export interface ModelChoice {
  readonly model: Model<Api>
  readonly configured: boolean
}

export interface PromptOptions {
  images?: ImageContent[]
  streamingBehavior?: PendingInputDelivery
}

/** Message byte counts are UTF-8 JSON sizes, not estimates of engine heap allocation. */
export interface AgentSessionMemoryDiagnostics {
  readonly committedMessages: number
  readonly committedMessageBytes: number
  readonly streamingMessageBytes: number
  readonly queuedInputs: number
  readonly queuedInputBytes: number
  readonly subscribers: number
}

export interface QueueModeMutation {
  readonly scope: SettingsScope
  readonly requested: QueueMode
  readonly effective: QueueMode
}

export interface ThinkingLevelMutation {
  readonly scope: SettingsScope
  readonly requested: ThinkingLevel
  readonly effective: ThinkingLevel
}

export interface AgentSessionConfig {
  agent: Agent
  sessionManager: SessionManager
  settingsManager: SettingsManager
  authentication: Authentication
  modelRegistry: ModelRegistry
  resources: SessionResources
  shell?: SessionShell
  model?: Model<Api>
  apiKeyProvider?: string
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

type ModelMutationState = { type: "none" } | { type: "validating"; operationId: number }

export type SessionModelState =
  | { readonly type: "unselected" }
  | { readonly type: "selected"; readonly model: Model<Api> }

interface PendingInput {
  readonly id: number
  readonly runId: number
  readonly delivery: PendingInputDelivery
  readonly text: string
  readonly images: readonly ImageContent[]
  readonly bytes: number
  readonly message: AgentMessage
}

interface CommittedMessageMemory {
  readonly count: number
  readonly bytes: number
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
  readonly #authentication: Authentication
  readonly #modelRegistry: ModelRegistry
  readonly #resources: SessionResources
  readonly #shell: SessionShell | undefined
  readonly #apiKeyProvider: string | undefined
  readonly #listeners = new Set<(event: AgentSessionEvent) => void>()
  readonly #unsubscribeAgent: () => void
  readonly #unsubscribeShell: (() => void) | undefined
  #activity: Activity = { type: "idle" }
  #pending: PendingInput[] = []
  #pendingBytes = 0
  #nextRunId = 0
  #nextEntryId = 0
  #nextModelOperationId = 0
  #modelMutation: ModelMutationState = { type: "none" }
  #modelState: SessionModelState
  #modelChoicesPromise: Promise<readonly ModelChoice[]> | undefined
  #committedMessageMemory: CommittedMessageMemory | undefined

  constructor(config: AgentSessionConfig) {
    this.#agent = config.agent
    this.#authentication = config.authentication
    this.#modelRegistry = config.modelRegistry
    this.#resources = config.resources
    this.#shell = config.shell
    this.#apiKeyProvider = config.apiKeyProvider
    this.sessionManager = config.sessionManager
    this.settingsManager = config.settingsManager
    this.#modelState = config.model ? { type: "selected", model: config.model } : { type: "unselected" }
    this.#unsubscribeAgent = this.#agent.subscribe(event => this.#handleAgentEvent(event))
    this.#unsubscribeShell = this.#shell?.subscribe(taskId => {
      try {
        this.#emit({ type: "shell_task_changed", taskId })
      } catch {
        // Process ownership cannot cross into an observer.
      }
    })
  }

  get messages(): readonly AgentMessage[] {
    return this.#agent.state.messages
  }

  get streamingMessage(): AgentMessage | undefined {
    return this.#agent.state.streamingMessage
  }

  get modelState(): SessionModelState {
    return this.#modelState
  }

  get model(): Model<Api> {
    if (this.#modelState.type === "unselected") throw new Error("No model selected. Use /login, then /model.")
    return this.#modelState.model
  }

  get thinkingLevel(): ThinkingLevel {
    return this.#agent.state.thinkingLevel
  }

  get steeringMode(): QueueMode {
    return this.#agent.steeringMode
  }

  get followUpMode(): QueueMode {
    return this.#agent.followUpMode
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

  get shellTasks(): readonly ShellTaskSnapshot[] {
    return this.#shell?.snapshots() ?? []
  }

  demoteForegroundShellTask(): ShellDemotionResult {
    this.#assertOpen()
    return this.#shell?.demoteForeground() ?? { type: "none" }
  }

  killShellTask(taskId: string): Promise<ShellKillResult> {
    this.#assertOpen()
    return this.#shell?.kill(taskId) ?? Promise.resolve({ type: "not_found" })
  }

  get memoryDiagnostics(): AgentSessionMemoryDiagnostics {
    const messages = this.#agent.state.messages
    if (!this.#committedMessageMemory || this.#committedMessageMemory.count !== messages.length) {
      this.#committedMessageMemory = measureCommittedMessages(messages)
    }
    return {
      committedMessages: this.#committedMessageMemory.count,
      committedMessageBytes: this.#committedMessageMemory.bytes,
      streamingMessageBytes: this.streamingMessage ? serializedMessageBytes(this.streamingMessage) : 0,
      queuedInputs: this.#pending.length,
      queuedInputBytes: this.#pendingBytes,
      subscribers: this.#listeners.size
    }
  }

  get sessionId(): string {
    return this.sessionManager.sessionId
  }

  get resources(): SessionResources {
    return this.#resources
  }

  get skills(): readonly Skill[] {
    return this.#resources.skills
  }

  get promptTemplates(): readonly PromptTemplate[] {
    return this.#resources.promptTemplates
  }

  get resourceDiagnostics(): readonly ResourceDiagnostic[] {
    return this.#resources.diagnostics
  }

  listResourceCommands(): readonly SlashCommand[] {
    return [
      ...this.#resources.promptTemplates.map(template => ({
        name: template.name,
        description: template.description,
        ...(template.argumentHint ? { argumentHint: template.argumentHint } : {})
      })),
      ...this.#resources.skills.map(skill => ({ name: `skill:${skill.name}`, description: skill.description }))
    ]
  }

  listModelChoices(): Promise<readonly ModelChoice[]> {
    this.#assertOpen()
    if (this.#modelChoicesPromise) return this.#modelChoicesPromise

    const models = [...this.#modelRegistry.list()]
    const unresolved = models.filter(model => model.provider !== this.#apiKeyProvider)
    const load = this.#modelRegistry.resolveConfiguration(unresolved).then(configured => {
      let unresolvedIndex = 0
      return Object.freeze(
        models.map(model => {
          if (model.provider === this.#apiKeyProvider) return Object.freeze({ model, configured: true })
          const available = configured[unresolvedIndex] ?? false
          unresolvedIndex++
          return Object.freeze({ model, configured: available })
        })
      )
    })
    this.#modelChoicesPromise = load
    void load.then(
      () => this.#clearModelChoices(load),
      () => this.#clearModelChoices(load)
    )
    return load
  }

  authenticationMethods(): readonly AuthenticationMethod[] {
    this.#assertOpen()
    return this.#authentication.methods()
  }

  storedCredentials(): Promise<readonly StoredCredential[]> {
    this.#assertOpen()
    return this.#authentication.stored()
  }

  async login(
    providerId: string,
    method: AuthenticationMethodType,
    interaction: AuthenticationInteraction
  ): Promise<void> {
    this.#assertAuthenticationAllowed("log in")
    await this.#authentication.login(providerId, method, interaction)
    this.#emitAll([{ type: "authentication_changed", status: "logged_in", providerId, method }])

    if (this.#modelState.type === "unselected") {
      const preferred = this.#modelRegistry.list().find(model => model.provider === providerId)
      if (preferred) await this.setModel(preferred)
    }
  }

  async logout(providerId: string): Promise<void> {
    this.#assertAuthenticationAllowed("log out")
    await this.#authentication.logout(providerId)
    this.#emitAll([{ type: "authentication_changed", status: "logged_out", providerId }])
  }

  subscribe(listener: (event: AgentSessionEvent) => void): () => void {
    this.#listeners.add(listener)
    return () => this.#listeners.delete(listener)
  }

  prompt(text: string, options: PromptOptions = {}): Promise<void> {
    this.#assertOpen()
    if (this.#modelState.type === "unselected") throw new Error("No model selected. Use /login, then /model.")
    if (!this.#authentication.isIdle) throw new Error("Cannot prompt while authentication is active")
    switch (this.#activity.type) {
      case "idle": {
        const expandedText = this.#expandResourceInput(text)
        this.#modelMutation = { type: "none" }
        const runId = ++this.#nextRunId
        const settlement = createSettlement()
        this.#activity = { type: "running", runId, settled: settlement.promise }
        void this.#drive(runId, expandedText, options.images, settlement)
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
    const authenticationWasIdle = this.#authentication.isIdle
    const authenticationSettled = this.#authentication.cancel()
    switch (this.#activity.type) {
      case "idle": {
        const queued = this.#detachQueuedInputs()
        this.#emitQueue()
        return { ...queued, settled: authenticationSettled }
      }
      case "running": {
        const { runId, settled } = this.#activity
        const queued = this.#detachQueuedInputs()
        this.#activity = { type: "aborting", runId, settled }
        try {
          this.#emitQueue()
        } finally {
          this.#agent.abort()
        }
        return { ...queued, settled: authenticationWasIdle ? settled : settleTogether(settled, authenticationSettled) }
      }
      case "aborting":
        return {
          ...emptyQueue(),
          settled: authenticationWasIdle
            ? this.#activity.settled
            : settleTogether(this.#activity.settled, authenticationSettled)
        }
      case "failed": {
        const queued = this.#detachQueuedInputs()
        this.#activity = { type: "idle" }
        this.#emitQueue()
        return { ...queued, settled: authenticationSettled }
      }
      case "disposed":
        throw new Error("AgentSession is disposed")
      default:
        return assertNever(this.#activity)
    }
  }

  abortAndDiscardQueuedInputs(): Promise<void> {
    try {
      return this.takeQueuedInputsAndAbort().settled
    } catch (cause) {
      return this.waitForIdle().then(() => {
        throw cause
      })
    }
  }

  abort(): Promise<void> {
    const authenticationWasIdle = this.#authentication.isIdle
    const authenticationSettled = this.#authentication.cancel()
    switch (this.#activity.type) {
      case "running":
      case "aborting": {
        const { settled } = this.#activity
        this.#agent.abort()
        return authenticationWasIdle ? settled : settleTogether(settled, authenticationSettled)
      }
      case "idle":
      case "failed":
        this.#agent.abort()
        return authenticationSettled
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
        return settleTogether(this.#activity.settled, this.#authentication.waitForIdle())
      case "idle":
      case "failed":
        return this.#authentication.waitForIdle()
      default:
        return assertNever(this.#activity)
    }
  }

  getSupportedThinkingLevels(): readonly ThinkingLevel[] {
    return this.#modelState.type === "selected" ? getSupportedThinkingLevels(this.#modelState.model) : ["off"]
  }

  async setModel(model: Model<Api>): Promise<void> {
    this.#assertIdle("change model")
    const operationId = ++this.#nextModelOperationId
    this.#modelMutation = { type: "validating", operationId }

    try {
      const configured = model.provider === this.#apiKeyProvider || (await this.#modelRegistry.isConfigured(model))
      if (this.#modelMutation.type !== "validating" || this.#modelMutation.operationId !== operationId) {
        throw new Error("Model change was superseded")
      }
      this.#assertIdle("change model")
      if (!configured) throw new Error(`Model ${model.provider}/${model.id} is not authenticated`)

      const effectiveThinking = clampThinkingLevel(model, this.thinkingLevel)
      const thinkingChanged = effectiveThinking !== this.thinkingLevel
      this.sessionManager.appendModelChange(model.provider, model.id)
      if (thinkingChanged) this.sessionManager.appendThinkingLevelChange(effectiveThinking)
      this.settingsManager.updateGlobal({ model: `${model.provider}/${model.id}`, thinkingLevel: effectiveThinking })
      this.#agent.state.model = model
      this.#agent.state.thinkingLevel = effectiveThinking
      this.#modelState = { type: "selected", model }
      const events: AgentSessionEvent[] = []
      if (thinkingChanged) events.push({ type: "thinking_level_changed", level: effectiveThinking })
      events.push({ type: "model_changed", model })
      this.#emitAll(events)
    } finally {
      if (this.#modelMutation.type === "validating" && this.#modelMutation.operationId === operationId) {
        this.#modelMutation = { type: "none" }
      }
    }
  }

  setSteeringMode(requested: QueueMode, scope: SettingsScope): QueueModeMutation {
    this.#assertOpen()
    assertQueueMode(requested)
    assertSettingsScope(scope)
    if (scope === "global") this.settingsManager.updateGlobal({ steeringMode: requested })
    else this.settingsManager.updateProject({ steeringMode: requested })
    const effective = this.settingsManager.get().steeringMode
    if (effective !== this.#agent.steeringMode) {
      this.#agent.steeringMode = effective
      this.#emitAll([{ type: "steering_mode_changed", mode: effective }])
    }
    return Object.freeze({ scope, requested, effective })
  }

  setFollowUpMode(requested: QueueMode, scope: SettingsScope): QueueModeMutation {
    this.#assertOpen()
    assertQueueMode(requested)
    assertSettingsScope(scope)
    if (scope === "global") this.settingsManager.updateGlobal({ followUpMode: requested })
    else this.settingsManager.updateProject({ followUpMode: requested })
    const effective = this.settingsManager.get().followUpMode
    if (effective !== this.#agent.followUpMode) {
      this.#agent.followUpMode = effective
      this.#emitAll([{ type: "follow_up_mode_changed", mode: effective }])
    }
    return Object.freeze({ scope, requested, effective })
  }

  setThinkingLevel(requested: ThinkingLevel, scope: SettingsScope = "global"): ThinkingLevelMutation {
    this.#assertIdle("change thinking level")
    assertThinkingLevel(requested)
    assertSettingsScope(scope)
    const persisted = clampThinkingLevel(this.model, requested)
    if (scope === "global") this.settingsManager.updateGlobal({ thinkingLevel: persisted })
    else this.settingsManager.updateProject({ thinkingLevel: persisted })
    const effective = clampThinkingLevel(this.model, this.settingsManager.get().thinkingLevel)
    this.settingsManager.applyRuntime({ thinkingLevel: effective })
    if (effective !== this.thinkingLevel) {
      this.sessionManager.appendThinkingLevelChange(effective)
      this.#agent.state.thinkingLevel = effective
      this.#emitAll([{ type: "thinking_level_changed", level: effective }])
    }
    return Object.freeze({ scope, requested, effective })
  }

  setActiveTools(tools: readonly AgentTool[]): void {
    this.#assertIdle("change tools")
    const activeTools = [...tools]
    const systemPrompt = buildSystemPrompt(this.sessionManager.header.cwd, this.#resources, activeTools)
    this.#agent.state.tools = activeTools
    this.#agent.state.systemPrompt = systemPrompt
  }

  dispose(): void {
    if (this.#activity.type === "disposed") return
    this.#modelMutation = { type: "none" }
    const activeSettled =
      this.#activity.type === "running" || this.#activity.type === "aborting"
        ? this.#activity.settled
        : Promise.resolve()
    this.#pending = []
    this.#pendingBytes = 0
    this.#agent.clearAllQueues()
    this.#agent.abort()
    const settled = settleAll([
      activeSettled,
      this.#authentication.dispose(),
      this.#shell?.dispose() ?? Promise.resolve()
    ])
    this.#activity = { type: "disposed", settled }
    this.#unsubscribeAgent()
    this.#unsubscribeShell?.()
    this.#listeners.clear()
    cleanupSessionResources(this.sessionId)
    void settled.catch(() => {})
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
    const expandedText = this.#expandResourceInput(text)
    const retainedImages = (images ?? []).map(cloneImage)
    const bytes = retainedBytes(expandedText, retainedImages)
    if (this.#pending.length === maxPendingInputCount || this.#pendingBytes + bytes > maxPendingInputBytes) {
      throw new QueueCapacityError()
    }

    const message = userMessage(expandedText, retainedImages)
    const entry: PendingInput = {
      id: ++this.#nextEntryId,
      runId,
      delivery,
      text: expandedText,
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

  #expandResourceInput(text: string): string {
    return expandPromptTemplate(expandSkillCommand(text, this.#resources.skills), this.#resources.promptTemplates)
  }

  #queueRunId(): number {
    if (!this.#authentication.isIdle) throw new Error("Cannot queue input while authentication is active")
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
      this.#recordCommittedMessage(event.message)
      const id = this.sessionManager.appendMessage(event.message)
      const entry = this.sessionManager.entries().find(candidate => candidate.id === id)
      if (entry) this.#emit({ type: "entry_appended", entry })
    }
    this.#emit(event)
  }

  #recordCommittedMessage(message: AgentMessage): void {
    const memory = this.#committedMessageMemory
    if (!memory) return
    const messages = this.#agent.state.messages
    if (messages.length !== memory.count + 1 || messages.at(-1) !== message) {
      this.#committedMessageMemory = undefined
      return
    }
    this.#committedMessageMemory = { count: messages.length, bytes: memory.bytes + serializedMessageBytes(message) }
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

  #clearModelChoices(load: Promise<readonly ModelChoice[]>): void {
    if (this.#modelChoicesPromise === load) this.#modelChoicesPromise = undefined
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

  #emitAll(events: readonly AgentSessionEvent[]): void {
    for (const event of events) {
      try {
        this.#emit(event)
      } catch {
        // The model transaction is already durable; one observer cannot turn a committed change into a failed operation.
      }
    }
  }

  #assertOpen(): void {
    if (this.#activity.type === "disposed") throw new Error("AgentSession is disposed")
  }

  #assertIdle(action: string): void {
    this.#assertOpen()
    if (this.#activity.type !== "idle") throw new Error(`Cannot ${action} while the agent is running`)
    if (!this.#authentication.isIdle) throw new Error(`Cannot ${action} while authentication is active`)
  }

  #assertAuthenticationAllowed(action: string): void {
    this.#assertIdle(action)
    if (this.#modelMutation.type !== "none") throw new Error(`Cannot ${action} while a model change is active`)
  }
}

async function settleTogether(first: Promise<void>, second: Promise<void>): Promise<void> {
  await Promise.all([first, second])
}

async function settleAll(operations: readonly Promise<void>[]): Promise<void> {
  const outcomes = await Promise.allSettled(operations)
  const failure = outcomes.find((outcome): outcome is PromiseRejectedResult => outcome.status === "rejected")
  if (failure) throw failure.reason
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

function measureCommittedMessages(messages: readonly AgentMessage[]): CommittedMessageMemory {
  let bytes = 0
  for (const message of messages) bytes += serializedMessageBytes(message)
  return { count: messages.length, bytes }
}

function serializedMessageBytes(message: AgentMessage): number {
  return Buffer.byteLength(JSON.stringify(message))
}

function retainedBytes(text: string, images: readonly ImageContent[]): number {
  let bytes = Buffer.byteLength(text)
  for (const image of images) bytes += Buffer.byteLength(image.mimeType) + Buffer.byteLength(image.data)
  return bytes
}

function assertQueueMode(value: unknown): asserts value is QueueMode {
  if (value !== "all" && value !== "one-at-a-time") throw new Error(`Invalid queue mode: ${String(value)}`)
}

function assertThinkingLevel(value: unknown): asserts value is ThinkingLevel {
  if (
    value !== "off" &&
    value !== "minimal" &&
    value !== "low" &&
    value !== "medium" &&
    value !== "high" &&
    value !== "xhigh" &&
    value !== "max"
  ) {
    throw new Error(`Invalid thinking level: ${String(value)}`)
  }
}

function assertSettingsScope(value: unknown): asserts value is SettingsScope {
  if (value !== "global" && value !== "project") throw new Error(`Invalid settings scope: ${String(value)}`)
}

function assertNever(value: never): never {
  throw new Error(`Unexpected activity: ${String(value)}`)
}
