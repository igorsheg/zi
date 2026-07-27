import {
  type Agent,
  type AgentEvent,
  type AgentLoopTurnUpdate,
  type AgentMessage as PiAgentMessage,
  type AgentTool,
  type PrepareNextTurnContext,
  type QueueMode,
  type ThinkingLevel
} from "@earendil-works/pi-agent-core"
import {
  clampThinkingLevel,
  cleanupSessionResources,
  getSupportedThinkingLevels,
  isContextOverflow,
  isRetryableAssistantError,
  type Api,
  type AssistantMessage,
  type ImageContent,
  type Model
} from "@earendil-works/pi-ai"
import type { ExtensionShutdownReason, ExtensionStartReason } from "@with-zi/extension-api"

import type {
  Authentication,
  AuthenticationInteraction,
  AuthenticationMethod,
  AuthenticationMethodType
} from "./authentication.js"
import {
  assertCustomInstructions,
  effectiveCompactionSettings,
  estimateMessageTokens,
  generateCompactionSummary,
  maxCompactionOperationMs,
  normalizeCompactionError,
  prepareCompaction,
  shouldCompact,
  validateCompactionReduction,
  type CompactionPlan,
  type EffectiveCompactionSettings,
  type SummaryRequest,
  type SummarySampler
} from "./compaction.js"
import {
  advanceContextUsage,
  estimateContextUsage,
  type AvailableContextUsage,
  type ContextUsage
} from "./context-usage.js"
import type { StoredCredential } from "./credential-store.js"
import { DEFAULT_THINKING_LEVEL } from "./defaults.js"
import type { ExtensionHost, ExtensionHostSnapshot } from "./extensions/host.js"
import { admitExtensionTools } from "./extensions/tools.js"
import { isZiAgentMessage, type AgentMessage } from "./messages.js"
import type { ModelRegistry } from "./model-registry.js"
import { type ProjectFileSearch, type ProjectFileSearchResult } from "./project-file-search.js"
import { expandPromptTemplate, type PromptTemplate } from "./prompt-templates.js"
import type { ResourceDiagnostic } from "./resource-diagnostics.js"
import type { SessionResources } from "./resource-loader.js"
import { boundedRetryError, retryAbortedMessage, retryDelayMs, waitForRetryDelay } from "./retry.js"
import type {
  CompactionDetails,
  CompactionEntry,
  CompactionReason,
  SessionEntry,
  SessionJournalMemoryDiagnostics,
  SessionManager,
  SessionPromptHistoryEntry
} from "./session-manager.js"
import type { SessionShell, ShellDemotionResult, ShellKillResult, ShellTaskSnapshot } from "./session-shell.js"
import type { SettingsManager, SettingsScope } from "./settings-manager.js"
import { expandSkillCommand, type Skill } from "./skills.js"
import type { SlashCommand } from "./slash-commands.js"
import { buildSystemPrompt } from "./system-prompt.js"

export type { ContextUsage } from "./context-usage.js"

export const maxPendingInputCount = 32
export const maxPendingInputBytes = 8 * 1024 * 1024
export { maxRetryDelayMs, maxRetryErrorBytes } from "./retry.js"

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

export interface CompactionResult {
  readonly reason: CompactionReason
  readonly summary: string
  readonly firstKeptEntryId: string
  readonly tokensBefore: number
  readonly estimatedTokensAfter: number
  readonly compactedEntries: number
  readonly details: CompactionDetails
}

export type CompactionStatus =
  | { readonly type: "idle" }
  | { readonly type: "running"; readonly operationId: number; readonly reason: CompactionReason }

export type RetryStatus =
  | { readonly type: "idle" }
  | ({ readonly type: "waiting"; readonly source: "agent" } & RetrySchedule)
  | ({
      readonly type: "waiting"
      readonly source: "compaction"
      readonly operationId: number
      readonly reason: CompactionReason
    } & RetrySchedule)

export type CompactionOutcome =
  | { readonly type: "completed"; readonly result: CompactionResult }
  | { readonly type: "cancelled" }
  | { readonly type: "failed"; readonly message: string }

export type AgentSessionEvent =
  | Exclude<AgentEvent, { type: "agent_end" }>
  | { type: "agent_end"; messages: AgentMessage[]; willRetry: boolean }
  | { type: "agent_settled" }
  | {
      type: "auto_retry_start"
      attempt: number
      maxAttempts: number
      delayMs: number
      retryAt: number
      errorMessage: string
    }
  | { type: "auto_retry_end"; success: boolean; attempt: number; finalError?: string }
  | {
      type: "summarization_retry_scheduled"
      operationId: number
      reason: CompactionReason
      attempt: number
      maxAttempts: number
      delayMs: number
      retryAt: number
      errorMessage: string
    }
  | { type: "summarization_retry_attempt_start"; operationId: number; reason: CompactionReason }
  | { type: "summarization_retry_finished"; operationId: number; reason: CompactionReason }
  | { type: "compaction_start"; operationId: number; reason: CompactionReason }
  | { type: "compaction_end"; operationId: number; reason: CompactionReason; outcome: CompactionOutcome }
  | { type: "compaction_enabled_changed"; enabled: boolean }
  | { type: "retry_enabled_changed"; enabled: boolean }
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
  readonly journal: SessionJournalMemoryDiagnostics
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

export interface CompactionEnabledMutation {
  readonly scope: SettingsScope
  readonly requested: boolean
  readonly effective: boolean
}

export interface RetryEnabledMutation {
  readonly scope: SettingsScope
  readonly requested: boolean
  readonly effective: boolean
}

export interface AgentSessionConfig {
  agent: Agent
  sessionManager: SessionManager
  settingsManager: SettingsManager
  authentication: Authentication
  modelRegistry: ModelRegistry
  resources: SessionResources
  projectFileSearch: ProjectFileSearch
  tools: readonly AgentTool[]
  extensionHost?: ExtensionHost
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

interface RetrySchedule {
  readonly attempt: number
  readonly maxAttempts: number
  readonly delayMs: number
  readonly retryAt: number
  readonly errorMessage: string
}

type CompactionStage = { readonly type: "sampling" } | ({ readonly type: "retry_wait" } & RetrySchedule)

type RunPhase =
  | { readonly type: "agent" }
  | ({ readonly type: "retry_wait"; readonly controller: AbortController } & RetrySchedule)
  | {
      readonly type: "compacting"
      readonly operationId: number
      readonly reason: "threshold" | "overflow"
      readonly controller: AbortController
      readonly stage: CompactionStage
    }
  | { readonly type: "compaction_committed"; readonly operationId: number; readonly reason: "threshold" | "overflow" }

type RunningActivity = {
  readonly type: "running"
  readonly runId: number
  readonly phase: RunPhase
  readonly autoCompactions: number
  readonly overflowRecoveries: 0 | 1
  readonly retryAttempts: number
  readonly thresholdSuppressed: boolean
  readonly settled: Promise<void>
}

type Activity =
  | { type: "idle" }
  | RunningActivity
  | { type: "aborting"; runId: number; settled: Promise<void> }
  | {
      type: "compacting"
      operationId: number
      reason: "manual"
      controller: AbortController
      stage: CompactionStage
      settled: Promise<void>
    }
  | { type: "compaction_committed"; operationId: number; reason: "manual"; settled: Promise<void> }
  | { type: "failed"; runId: number; cause: unknown }
  | { type: "disposed"; settled: Promise<void> }

type ExtensionLifecycleState =
  | { readonly type: "absent" }
  | { readonly type: "unbound"; readonly host: ExtensionHost }
  | { readonly type: "starting"; readonly host: ExtensionHost; readonly settled: Promise<void> }
  | { readonly type: "started"; readonly host: ExtensionHost }
  | { readonly type: "disposing"; readonly host: ExtensionHost; readonly settled: Promise<void> }
  | { readonly type: "disposed"; readonly settled: Promise<void> }

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

interface ContextUsageCache {
  readonly model: Model<Api>
  readonly messageCount: number
  readonly usage: AvailableContextUsage
}

interface Settlement<T = void> {
  readonly promise: Promise<T>
  resolve(value: T): void
  reject(cause: unknown): void
}

interface PreparedCompaction {
  readonly model: Model<Api>
  readonly settings: EffectiveCompactionSettings
  readonly leafId: string | undefined
  readonly plan: CompactionPlan
}

interface CommittedCompaction {
  readonly marker: CompactionEntry
  readonly result: CompactionResult
}

const emptyQueue = (): QueuedInputs => Object.freeze({ steering: Object.freeze([]), followUp: Object.freeze([]) })

export class AgentSession {
  readonly sessionManager: SessionManager
  readonly settingsManager: SettingsManager

  readonly #agent: Agent
  readonly #authentication: Authentication
  readonly #modelRegistry: ModelRegistry
  readonly #resources: SessionResources
  readonly #projectFileSearch: ProjectFileSearch
  readonly #extensionHost: ExtensionHost | undefined
  readonly #shell: SessionShell | undefined
  readonly #apiKeyProvider: string | undefined
  readonly #listeners = new Set<(event: AgentSessionEvent) => void>()
  readonly #unsubscribeAgent: () => void
  readonly #unsubscribeShell: (() => void) | undefined
  readonly #unbindExtensionTools: (() => void) | undefined
  #activeTools: readonly AgentTool[]
  #activity: Activity = { type: "idle" }
  #extensionLifecycle: ExtensionLifecycleState
  #pending: PendingInput[] = []
  #pendingBytes = 0
  #nextRunId = 0
  #nextEntryId = 0
  #nextModelOperationId = 0
  #nextCompactionOperationId = 0
  #modelMutation: ModelMutationState = { type: "none" }
  #modelState: SessionModelState
  #modelChoicesPromise: Promise<readonly ModelChoice[]> | undefined
  #committedMessageMemory: CommittedMessageMemory | undefined
  #contextUsageCache: ContextUsageCache | undefined

  constructor(config: AgentSessionConfig) {
    this.#agent = config.agent
    this.#authentication = config.authentication
    this.#modelRegistry = config.modelRegistry
    this.#resources = config.resources
    this.#projectFileSearch = config.projectFileSearch
    this.#extensionHost = config.extensionHost
    this.#activeTools = Object.freeze([...config.tools])
    this.#extensionLifecycle = config.extensionHost
      ? { type: "unbound", host: config.extensionHost }
      : { type: "absent" }
    this.#shell = config.shell
    this.#apiKeyProvider = config.apiKeyProvider
    this.sessionManager = config.sessionManager
    this.settingsManager = config.settingsManager
    this.#modelState = config.model ? { type: "selected", model: config.model } : { type: "unselected" }
    this.#agent.prepareNextTurnWithContext = (context, signal) => this.#prepareNextTurn(context, signal)
    this.#unsubscribeAgent = this.#agent.subscribe(event => this.#handleAgentEvent(event))
    this.#unbindExtensionTools = config.extensionHost?.bindToolCatalog(() => this.#applyActiveTools())
    this.#unsubscribeShell = this.#shell?.subscribe(taskId => {
      try {
        this.#emit({ type: "shell_task_changed", taskId })
      } catch {
        // Process ownership cannot cross into an observer.
      }
    })
  }

  get messages(): readonly AgentMessage[] {
    return this.sessionManager.presentationMessages()
  }

  get streamingMessage(): AgentMessage | undefined {
    const message = this.#agent.state.streamingMessage
    if (!message) return undefined
    if (!isZiAgentMessage(message)) throw new Error("Invalid Zi streaming message")
    return message
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

  get compactionStatus(): CompactionStatus {
    const activity = this.#activity
    if (activity.type === "compacting") {
      return { type: "running", operationId: activity.operationId, reason: activity.reason }
    }
    if (activity.type === "running" && activity.phase.type === "compacting") {
      return { type: "running", operationId: activity.phase.operationId, reason: activity.phase.reason }
    }
    return { type: "idle" }
  }

  get retryStatus(): RetryStatus {
    const activity = this.#activity
    if (activity.type === "running" && activity.phase.type === "retry_wait") {
      const { attempt, maxAttempts, delayMs, retryAt, errorMessage } = activity.phase
      return { type: "waiting", source: "agent", attempt, maxAttempts, delayMs, retryAt, errorMessage }
    }
    if (activity.type === "compacting" && activity.stage.type === "retry_wait") {
      const { attempt, maxAttempts, delayMs, retryAt, errorMessage } = activity.stage
      return {
        type: "waiting",
        source: "compaction",
        operationId: activity.operationId,
        reason: activity.reason,
        attempt,
        maxAttempts,
        delayMs,
        retryAt,
        errorMessage
      }
    }
    if (
      activity.type === "running" &&
      activity.phase.type === "compacting" &&
      activity.phase.stage.type === "retry_wait"
    ) {
      const { attempt, maxAttempts, delayMs, retryAt, errorMessage } = activity.phase.stage
      return {
        type: "waiting",
        source: "compaction",
        operationId: activity.phase.operationId,
        reason: activity.phase.reason,
        attempt,
        maxAttempts,
        delayMs,
        retryAt,
        errorMessage
      }
    }
    return { type: "idle" }
  }

  get isStreaming(): boolean {
    return this.#activity.type === "running" || this.#activity.type === "aborting"
  }

  get isAborting(): boolean {
    return (
      this.#activity.type === "aborting" ||
      (this.#activity.type === "compacting" && this.#activity.controller.signal.aborted) ||
      (this.#activity.type === "running" &&
        (this.#activity.phase.type === "compacting" || this.#activity.phase.type === "retry_wait") &&
        this.#activity.phase.controller.signal.aborted)
    )
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
    const messages = this.#ownedMessages()
    if (!this.#committedMessageMemory || this.#committedMessageMemory.count !== messages.length) {
      this.#committedMessageMemory = measureCommittedMessages(messages)
    }
    return {
      committedMessages: this.#committedMessageMemory.count,
      committedMessageBytes: this.#committedMessageMemory.bytes,
      streamingMessageBytes: this.streamingMessage ? serializedMessageBytes(this.streamingMessage) : 0,
      queuedInputs: this.#pending.length,
      queuedInputBytes: this.#pendingBytes,
      subscribers: this.#listeners.size,
      journal: this.sessionManager.memoryDiagnostics
    }
  }

  get contextUsage(): ContextUsage {
    if (this.#modelState.type === "unselected") return { type: "unavailable", reason: "no_model" }
    const model = this.#modelState.model
    if (model.contextWindow <= 0) return { type: "unavailable", reason: "unknown_window" }

    const messages = this.#ownedMessages()
    const cached = this.#contextUsageCache
    if (cached?.model === model && cached.messageCount === messages.length) return cached.usage

    const usage = estimateContextUsage(messages, model.contextWindow, this.sessionManager.activeUsageAnchorIndex())
    this.#contextUsageCache = { model, messageCount: messages.length, usage }
    return usage
  }

  getContextUsage(): AvailableContextUsage | undefined {
    const usage = this.contextUsage
    return usage.type === "unavailable" ? undefined : usage
  }

  get sessionId(): string {
    return this.sessionManager.sessionId
  }

  latestPromptHistoryEntry(): SessionPromptHistoryEntry | undefined {
    return this.sessionManager.latestPromptHistoryEntry()
  }

  olderPromptHistoryEntry(entryId: string): SessionPromptHistoryEntry | undefined {
    return this.sessionManager.olderPromptHistoryEntry(entryId)
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

  compact(customInstructions?: string): Promise<CompactionResult> {
    this.#assertIdle("compact context")
    if (this.#modelMutation.type !== "none") {
      throw new Error("Cannot compact context while a model change is active")
    }
    if (this.#pending.length > 0) throw new Error("Cannot compact context while queued input is pending")
    assertCustomInstructions(customInstructions)
    const prepared = this.#prepareCompaction()
    if (!prepared) throw new Error("Nothing to compact")

    const operationId = ++this.#nextCompactionOperationId
    const controller = new AbortController()
    const settlement = createSettlement<CompactionResult>()
    this.#activity = {
      type: "compacting",
      operationId,
      reason: "manual",
      controller,
      stage: { type: "sampling" },
      settled: settlement.promise.then(
        () => undefined,
        () => undefined
      )
    }
    this.#emitAll([{ type: "compaction_start", operationId, reason: "manual" }])
    void this.#driveManualCompaction(operationId, controller, prepared, customInstructions, settlement)
    return settlement.promise
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
        this.#activity = {
          type: "running",
          runId,
          phase: { type: "agent" },
          autoCompactions: 0,
          overflowRecoveries: 0,
          retryAttempts: 0,
          thresholdSuppressed: false,
          settled: settlement.promise
        }
        void this.#drive(runId, expandedText, options.images, settlement)
        return settlement.promise
      }
      case "running":
        if (!options.streamingBehavior) throw new Error("streamingBehavior is required while the agent is running")
        this.#enqueue(options.streamingBehavior, text, options.images)
        return Promise.resolve()
      case "aborting":
        throw new Error("Cannot prompt while the agent is aborting")
      case "compacting":
      case "compaction_committed":
        throw new Error("Cannot prompt while context compaction is active")
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
    if (this.#activity.type === "compacting" || this.#activity.type === "compaction_committed") {
      throw new Error("Cannot restore queued inputs while context compaction is active")
    }
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
        const { runId, settled, phase } = this.#activity
        const queued = this.#detachQueuedInputs()
        this.#activity = { type: "aborting", runId, settled }
        try {
          this.#emitQueue()
        } finally {
          if (phase.type === "compacting" || phase.type === "retry_wait") phase.controller.abort()
          this.#agent.abort()
        }
        return { ...queued, settled: authenticationWasIdle ? settled : settleTogether(settled, authenticationSettled) }
      }
      case "compacting": {
        const { settled, controller } = this.#activity
        const queued = this.#detachQueuedInputs()
        this.#emitQueue()
        controller.abort()
        return { ...queued, settled: authenticationWasIdle ? settled : settleTogether(settled, authenticationSettled) }
      }
      case "compaction_committed": {
        const { settled } = this.#activity
        return {
          ...emptyQueue(),
          settled: authenticationWasIdle ? settled : settleTogether(settled, authenticationSettled)
        }
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
      case "running": {
        const { runId, settled, phase } = this.#activity
        if (phase.type === "compacting" || phase.type === "compaction_committed") {
          this.#activity = { type: "aborting", runId, settled }
          if (phase.type === "compacting") phase.controller.abort()
        } else if (phase.type === "retry_wait") {
          phase.controller.abort()
        }
        this.#agent.abort()
        return authenticationWasIdle ? settled : settleTogether(settled, authenticationSettled)
      }
      case "compacting": {
        const { settled, controller } = this.#activity
        controller.abort()
        return authenticationWasIdle ? settled : settleTogether(settled, authenticationSettled)
      }
      case "compaction_committed": {
        const { settled } = this.#activity
        return authenticationWasIdle ? settled : settleTogether(settled, authenticationSettled)
      }
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

  get extensionHostSnapshot(): ExtensionHostSnapshot | undefined {
    const state = this.#extensionLifecycle
    return state.type === "absent" || state.type === "disposed" ? undefined : state.host.snapshot()
  }

  assertExtensionLifecycleUnbound(): void {
    const state = this.#extensionLifecycle
    if (state.type === "absent" || state.type === "unbound") return
    throw new Error("AgentSession extension lifecycle is already bound")
  }

  startExtensionLifecycle(reason: ExtensionStartReason): Promise<void> {
    const state = this.#extensionLifecycle
    if (state.type === "absent" || state.type === "started") return Promise.resolve()
    if (state.type === "starting") return state.settled
    if (state.type === "disposing" || state.type === "disposed") {
      return Promise.reject(new Error("Cannot start extensions after session disposal"))
    }

    const operation = createSettlement()
    const starting: ExtensionLifecycleState = { type: "starting", host: state.host, settled: operation.promise }
    this.#extensionLifecycle = starting
    void state.host.sessionStart(reason).then(
      () => {
        if (this.#extensionLifecycle === starting) {
          this.#extensionLifecycle = { type: "started", host: state.host }
        }
        operation.resolve()
        return undefined
      },
      cause => {
        if (this.#extensionLifecycle === starting) this.#extensionLifecycle = state
        operation.reject(cause)
        return undefined
      }
    )
    return operation.promise
  }

  assertReplaceable(): void {
    this.#assertIdle("replace the session")
    if (this.#modelMutation.type !== "none")
      throw new Error("Cannot replace the session while a model change is active")
    if (this.#pending.length > 0) throw new Error("Cannot replace the session while queued input is pending")
  }

  waitForIdle(): Promise<void> {
    const searchSettled = this.#projectFileSearch.waitForIdle()
    const extensionsSettled = this.#extensionSettlement()
    switch (this.#activity.type) {
      case "running":
      case "aborting":
      case "compacting":
      case "compaction_committed":
      case "disposed":
        return settleAll([this.#activity.settled, this.#authentication.waitForIdle(), searchSettled, extensionsSettled])
      case "idle":
      case "failed":
        return settleAll([this.#authentication.waitForIdle(), searchSettled, extensionsSettled])
      default:
        return assertNever(this.#activity)
    }
  }

  searchProjectFiles(query: string, signal: AbortSignal): Promise<ProjectFileSearchResult> {
    this.#assertOpen()
    return this.#projectFileSearch.search(query, signal)
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

      const preferredThinking =
        this.#modelState.type === "selected" && this.#modelState.model.reasoning
          ? this.thinkingLevel
          : (this.settingsManager.getDefaultThinkingLevel() ?? DEFAULT_THINKING_LEVEL)
      const effectiveThinking = clampThinkingLevel(model, preferredThinking)
      const thinkingChanged = effectiveThinking !== this.thinkingLevel
      this.sessionManager.appendModelChange(model.provider, model.id)
      if (thinkingChanged) this.sessionManager.appendThinkingLevelChange(effectiveThinking)
      this.settingsManager.setDefaultModelAndProvider(model.provider, model.id)
      if (thinkingChanged && (model.reasoning || effectiveThinking !== "off")) {
        this.settingsManager.setDefaultThinkingLevel(effectiveThinking)
      }
      this.#agent.state.model = model
      this.#agent.state.thinkingLevel = effectiveThinking
      this.#modelState = { type: "selected", model }
      this.#contextUsageCache = undefined
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

  setCompactionEnabled(requested: boolean, scope: SettingsScope): CompactionEnabledMutation {
    this.#assertOpen()
    if (typeof requested !== "boolean") throw new Error(`Invalid compaction setting: ${String(requested)}`)
    assertSettingsScope(scope)
    if (scope === "global") this.settingsManager.updateGlobal({ compactionEnabled: requested })
    else this.settingsManager.updateProject({ compactionEnabled: requested })
    const effective = this.settingsManager.get().compactionEnabled
    this.#emitAll([{ type: "compaction_enabled_changed", enabled: effective }])
    return Object.freeze({ scope, requested, effective })
  }

  setRetryEnabled(requested: boolean, scope: SettingsScope): RetryEnabledMutation {
    this.#assertOpen()
    if (typeof requested !== "boolean") throw new Error(`Invalid retry setting: ${String(requested)}`)
    assertSettingsScope(scope)
    if (scope === "global") this.settingsManager.updateGlobal({ retryEnabled: requested })
    else this.settingsManager.updateProject({ retryEnabled: requested })
    const effective = this.settingsManager.get().retryEnabled
    this.#emitAll([{ type: "retry_enabled_changed", enabled: effective }])
    return Object.freeze({ scope, requested, effective })
  }

  setThinkingLevel(requested: ThinkingLevel, scope: SettingsScope = "global"): ThinkingLevelMutation {
    this.#assertIdle("change thinking level")
    assertThinkingLevel(requested)
    assertSettingsScope(scope)
    const persisted = clampThinkingLevel(this.model, requested)
    if (this.model.reasoning || persisted !== "off") {
      this.settingsManager.setDefaultThinkingLevel(persisted, scope)
    }
    const effective = clampThinkingLevel(
      this.model,
      this.settingsManager.getDefaultThinkingLevel() ?? DEFAULT_THINKING_LEVEL
    )
    if (effective !== this.thinkingLevel) {
      this.sessionManager.appendThinkingLevelChange(effective)
      this.#agent.state.thinkingLevel = effective
      this.#emitAll([{ type: "thinking_level_changed", level: effective }])
    }
    return Object.freeze({ scope, requested, effective })
  }

  setActiveTools(tools: readonly AgentTool[]): void {
    this.#assertIdle("change tools")
    this.#activeTools = Object.freeze([...tools])
    this.#applyActiveTools()
  }

  #applyActiveTools(): void {
    const tools = admitExtensionTools(this.#activeTools, this.#extensionHost)
    this.#agent.state.tools = [...tools]
    this.#agent.state.systemPrompt = buildSystemPrompt(this.sessionManager.header.cwd, this.#resources, tools)
  }

  dispose(reason: ExtensionShutdownReason = "quit"): void {
    if (this.#activity.type === "disposed") return
    this.#modelMutation = { type: "none" }
    const currentActivity = this.#activity
    const activeSettled =
      currentActivity.type === "running" ||
      currentActivity.type === "aborting" ||
      currentActivity.type === "compacting" ||
      currentActivity.type === "compaction_committed"
        ? currentActivity.settled
        : Promise.resolve()
    this.#pending = []
    this.#pendingBytes = 0
    this.#agent.clearAllQueues()
    if (currentActivity.type === "compacting") currentActivity.controller.abort()
    if (
      currentActivity.type === "running" &&
      (currentActivity.phase.type === "compacting" || currentActivity.phase.type === "retry_wait")
    ) {
      currentActivity.phase.controller.abort()
    }
    this.#agent.abort()
    this.#unbindExtensionTools?.()
    const settled = settleAll([
      activeSettled,
      this.#authentication.dispose(),
      this.#projectFileSearch.dispose(),
      this.#shell?.dispose() ?? Promise.resolve(),
      this.#disposeExtensions(reason)
    ])
    this.#activity = { type: "disposed", settled }
    this.#unsubscribeAgent()
    this.#unsubscribeShell?.()
    this.#listeners.clear()
    cleanupSessionResources(this.sessionId)
    void settled.catch(() => {})
  }

  #extensionSettlement(): Promise<void> {
    const state = this.#extensionLifecycle
    switch (state.type) {
      case "absent":
      case "unbound":
      case "started":
        return Promise.resolve()
      case "starting":
      case "disposing":
      case "disposed":
        return state.settled
      default:
        return assertNever(state)
    }
  }

  #disposeExtensions(reason: ExtensionShutdownReason): Promise<void> {
    const state = this.#extensionLifecycle
    if (state.type === "absent") {
      const settled = Promise.resolve()
      this.#extensionLifecycle = { type: "disposed", settled }
      return settled
    }
    if (state.type === "disposing" || state.type === "disposed") return state.settled

    const operation = createSettlement()
    const disposing: ExtensionLifecycleState = { type: "disposing", host: state.host, settled: operation.promise }
    this.#extensionLifecycle = disposing
    const shutdown = async (): Promise<void> => {
      try {
        if (state.type === "started") await state.host.sessionShutdown(reason)
      } finally {
        await state.host.dispose(reason)
      }
    }
    void shutdown()
      .then(
        () => {
          operation.resolve()
          return undefined
        },
        cause => {
          operation.reject(cause)
          return undefined
        }
      )
      .finally(() => {
        if (this.#extensionLifecycle === disposing) {
          this.#extensionLifecycle = { type: "disposed", settled: operation.promise }
        }
      })
    return operation.promise
  }

  async #drive(runId: number, text: string, images: ImageContent[] | undefined, settlement: Settlement): Promise<void> {
    let failure: { cause: unknown } | undefined
    try {
      await this.#compactBeforePrompt(runId, text, images)
      if (this.#canContinue(runId)) await this.#agent.prompt(text, images)
      while (this.#canContinue(runId)) {
        // Core runs are sequential: overflow recovery and each queued continuation own one run at a time.
        // oxlint-disable-next-line no-await-in-loop
        const overflow = await this.#recoverOverflow(runId)
        if (overflow === "recovered") continue
        if (overflow === "stop") break
        // oxlint-disable-next-line no-await-in-loop
        const retry = await this.#retryAssistant(runId)
        if (retry === "retry") {
          // oxlint-disable-next-line no-await-in-loop
          await this.#agent.continue()
          continue
        }
        if (!this.#agent.hasQueuedMessages()) break
        // oxlint-disable-next-line no-await-in-loop
        await this.#agent.continue()
      }
    } catch (cause) {
      failure = { cause }
    }

    try {
      if (failure) this.#finishExceptionalRetry(runId, failure.cause)
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

  async #driveManualCompaction(
    operationId: number,
    controller: AbortController,
    prepared: PreparedCompaction,
    customInstructions: string | undefined,
    settlement: Settlement<CompactionResult>
  ): Promise<void> {
    try {
      const committed = await this.#performCompaction(operationId, "manual", controller, prepared, customInstructions)
      const active = this.#activity
      if (active.type === "compacting" && active.operationId === operationId) {
        this.#activity = { type: "compaction_committed", operationId, reason: "manual", settled: active.settled }
      }
      this.#emitAll([
        { type: "entry_appended", entry: committed.marker },
        {
          type: "compaction_end",
          operationId,
          reason: "manual",
          outcome: { type: "completed", result: committed.result }
        }
      ])
      if (this.#isManualCompactionCommitted(operationId)) this.#activity = { type: "idle" }
      settlement.resolve(committed.result)
    } catch (cause) {
      const cancelled = controller.signal.aborted || !this.#isManualCompaction(operationId)
      if (this.#isManualCompaction(operationId)) this.#activity = { type: "idle" }
      const failure = normalizeCompactionError(cancelled ? "Compaction cancelled" : cause)
      this.#emitAll([
        {
          type: "compaction_end",
          operationId,
          reason: "manual",
          outcome: cancelled ? { type: "cancelled" } : { type: "failed", message: failure.message }
        }
      ])
      settlement.reject(failure)
    }
  }

  async #compactBeforePrompt(runId: number, text: string, images: ImageContent[] | undefined): Promise<void> {
    const activity = this.#runningAgentActivity(runId)
    if (!activity || !this.settingsManager.get().compactionEnabled) return

    const lastAssistant = this.#lastAssistantMessage()
    if (lastAssistant) {
      await this.#compactAfterAssistant(runId, lastAssistant, { retryOverflow: false, countOverflowRecovery: false })
    }
    if (!this.#runningAgentActivity(runId)) return

    const settings = this.#effectiveCompactionSettings()
    const usage = this.contextUsage
    if (!settings || usage.type === "unavailable") return
    const prospective = estimateMessageTokens(userMessage(text, images ?? []))
    if (!shouldCompact(usage.tokens + prospective, settings)) return
    await this.#runAutomaticCompaction(runId, "threshold")
  }

  async #prepareNextTurn(
    context: PrepareNextTurnContext,
    signal: AbortSignal | undefined
  ): Promise<AgentLoopTurnUpdate | undefined> {
    const activity = this.#activity
    if (activity.type !== "running" || activity.phase.type !== "agent" || signal?.aborted) return undefined

    const activeTools = this.#agent.state.tools
    const contextTools = context.context.tools ?? []
    const toolsChanged =
      activeTools.length !== contextTools.length || activeTools.some((tool, index) => tool !== contextTools[index])
    const synchronizedContext = toolsChanged
      ? { ...context.context, systemPrompt: this.#agent.state.systemPrompt, tools: [...activeTools] }
      : undefined
    const synchronized = synchronizedContext ? { context: synchronizedContext } : undefined

    if (activity.thresholdSuppressed || !this.settingsManager.get().compactionEnabled) return synchronized
    const settings = this.#effectiveCompactionSettings()
    const usage = this.contextUsage
    if (!settings || usage.type === "unavailable") return synchronized
    const queuedTokens = this.#pending.reduce((tokens, input) => tokens + estimateMessageTokens(input.message), 0)
    if (!shouldCompact(usage.tokens + queuedTokens, settings)) return synchronized

    const outcome = await this.#runAutomaticCompaction(activity.runId, "threshold", undefined, signal)
    if (outcome !== "completed" || !this.#canContinue(activity.runId)) return synchronized
    return { context: { ...(synchronizedContext ?? context.context), messages: [...this.#agent.state.messages] } }
  }

  async #recoverOverflow(runId: number): Promise<"none" | "recovered" | "stop"> {
    const activity = this.#runningAgentActivity(runId)
    const message = this.#lastAssistantMessage()
    if (!message) return "none"
    try {
      const outcome = await this.#compactAfterAssistant(runId, message, {
        retryOverflow: true,
        countOverflowRecovery: true
      })
      if (outcome === "stop" && activity && activity.retryAttempts > 0) {
        this.#finishFailedRetry(runId, activity.retryAttempts, message.errorMessage || "Unknown provider error")
      }
      return outcome
    } catch (cause) {
      if (activity && activity.retryAttempts > 0) {
        this.#finishFailedRetry(runId, activity.retryAttempts, message.errorMessage || "Unknown provider error")
      }
      throw cause
    }
  }

  #finishExceptionalRetry(runId: number, cause: unknown): void {
    const activity = this.#activity
    if (activity.type !== "running" || activity.runId !== runId || activity.retryAttempts === 0) return
    this.#finishFailedRetry(runId, activity.retryAttempts, cause instanceof Error ? cause.message : String(cause))
  }

  #finishFailedRetry(runId: number, attempt: number, finalError: string): void {
    const activity = this.#activity
    if (activity.type === "running" && activity.runId === runId) {
      this.#activity = { ...activity, retryAttempts: 0 }
    }
    this.#emitAll([{ type: "auto_retry_end", success: false, attempt, finalError: boundedRetryError(finalError) }])
  }

  async #retryAssistant(runId: number): Promise<"none" | "retry"> {
    const activity = this.#runningAgentActivity(runId)
    const message = this.#lastAssistantMessage()
    if (
      !activity ||
      !message ||
      message.role !== "assistant" ||
      message.stopReason !== "error" ||
      !this.#isSelectedModelMessage(message) ||
      isContextOverflow(message, this.model.contextWindow)
    ) {
      return "none"
    }

    const settings = this.settingsManager.get()
    const retryable = isRetryableAssistantError(message)
    if (!settings.retryEnabled || !retryable || activity.retryAttempts >= settings.retryMaxRetries) {
      if (activity.retryAttempts > 0) {
        this.#activity = { ...activity, retryAttempts: 0 }
        this.#emitAll([
          {
            type: "auto_retry_end",
            success: false,
            attempt: activity.retryAttempts,
            finalError: boundedRetryError(message.errorMessage || "Unknown provider error")
          }
        ])
      }
      return "none"
    }

    const attempt = activity.retryAttempts + 1
    const failureEntry = this.sessionManager
      .retainedEntries()
      .findLast(entry => entry.type === "message" && entry.message === message)
    if (!failureEntry) return "none"
    const marker = this.sessionManager.appendRetry(failureEntry.id, attempt)
    this.#removeRuntimeMessage(message)
    const delayMs = retryDelayMs(settings.retryBaseDelayMs, attempt)
    const retryAt = Date.now() + delayMs
    const errorMessage = boundedRetryError(message.errorMessage || "Unknown provider error")
    const controller = new AbortController()
    this.#activity = {
      ...activity,
      retryAttempts: attempt,
      phase: {
        type: "retry_wait",
        attempt,
        maxAttempts: settings.retryMaxRetries,
        delayMs,
        retryAt,
        errorMessage,
        controller
      }
    }
    this.#emitAll([
      { type: "entry_appended", entry: marker },
      { type: "auto_retry_start", attempt, maxAttempts: settings.retryMaxRetries, delayMs, retryAt, errorMessage }
    ])

    const elapsed = await waitForRetryDelay(delayMs, controller.signal)
    const current = this.#activity
    if (
      !elapsed ||
      current.type !== "running" ||
      current.runId !== runId ||
      current.phase.type !== "retry_wait" ||
      current.phase.controller !== controller
    ) {
      if (current.type === "running" && current.runId === runId && current.phase.type === "retry_wait") {
        this.#activity = { ...current, retryAttempts: 0, phase: { type: "agent" } }
      }
      this.#emitAll([{ type: "auto_retry_end", success: false, attempt, finalError: "Retry cancelled" }])
      return "none"
    }

    this.#activity = { ...current, phase: { type: "agent" } }
    return "retry"
  }

  async #compactAfterAssistant(
    runId: number,
    message: AgentMessage,
    options: { readonly retryOverflow: boolean; readonly countOverflowRecovery: boolean }
  ): Promise<"none" | "recovered" | "stop"> {
    const activity = this.#runningAgentActivity(runId)
    if (!activity || message.role !== "assistant" || !this.#isSelectedModelMessage(message)) return "none"
    if (!isContextOverflow(message, this.model.contextWindow)) return "none"
    if (!this.settingsManager.get().compactionEnabled) return "stop"

    const shouldRetry = options.retryOverflow && message.stopReason !== "stop"
    if (shouldRetry && activity.overflowRecoveries === 1) {
      throw new Error(
        "Context still exceeds the model window after one recovery; use /compact, select a larger-context model, or start a new session."
      )
    }

    const failureEntry =
      message.stopReason === "error"
        ? this.sessionManager.retainedEntries().findLast(entry => entry.type === "message" && entry.message === message)
        : undefined
    if (message.stopReason === "error" && !failureEntry) return "stop"

    if (failureEntry) this.#removeRuntimeMessage(message)
    const outcome = await this.#runAutomaticCompaction(
      runId,
      "overflow",
      failureEntry?.id,
      undefined,
      options.countOverflowRecovery && shouldRetry
    )
    if (outcome !== "completed" || !this.#canContinue(runId)) return shouldRetry ? "stop" : "none"
    if (!shouldRetry) return "none"

    const last = this.#agent.state.messages.at(-1)
    if (!last || (last.role !== "user" && last.role !== "toolResult")) return "stop"
    await this.#agent.continue()
    return "recovered"
  }

  async #runAutomaticCompaction(
    runId: number,
    reason: "threshold" | "overflow",
    excludedFailureEntryId?: string,
    runSignal?: AbortSignal,
    countOverflowRecovery = reason === "overflow"
  ): Promise<"completed" | "noop" | "failed" | "cancelled"> {
    const current = this.#runningAgentActivity(runId)
    if (!current || current.autoCompactions >= 4 || (reason === "threshold" && current.thresholdSuppressed))
      return "noop"
    if (reason === "overflow" && current.overflowRecoveries === 1) return "noop"

    let prepared: PreparedCompaction | undefined
    try {
      prepared = this.#prepareCompaction(excludedFailureEntryId)
    } catch {
      return "failed"
    }
    if (!prepared) return "noop"

    const operationId = ++this.#nextCompactionOperationId
    const controller = new AbortController()
    const abort = () => controller.abort()
    runSignal?.addEventListener("abort", abort, { once: true })
    this.#activity = {
      ...current,
      phase: { type: "compacting", operationId, reason, controller, stage: { type: "sampling" } },
      autoCompactions: current.autoCompactions + 1,
      overflowRecoveries: reason === "overflow" && countOverflowRecovery ? 1 : current.overflowRecoveries
    }
    this.#emitAll([{ type: "compaction_start", operationId, reason }])

    try {
      const committed = await this.#performCompaction(operationId, reason, controller, prepared)
      if (this.#isAutomaticCompaction(runId, operationId)) {
        const active = this.#activity
        this.#activity = { ...active, phase: { type: "compaction_committed", operationId, reason } }
      }
      this.#emitAll([
        { type: "entry_appended", entry: committed.marker },
        { type: "compaction_end", operationId, reason, outcome: { type: "completed", result: committed.result } }
      ])
      if (this.#isAutomaticCompactionCommitted(runId, operationId)) {
        const active = this.#activity
        this.#activity = { ...active, phase: { type: "agent" } }
      }
      return "completed"
    } catch (cause) {
      const cancelled = controller.signal.aborted || !this.#isAutomaticCompaction(runId, operationId)
      if (this.#isAutomaticCompaction(runId, operationId)) {
        const active = this.#activity
        this.#activity = {
          ...active,
          phase: { type: "agent" },
          thresholdSuppressed: active.thresholdSuppressed || (reason === "threshold" && !cancelled)
        }
      }
      const failure = normalizeCompactionError(cause)
      this.#emitAll([
        {
          type: "compaction_end",
          operationId,
          reason,
          outcome: cancelled ? { type: "cancelled" } : { type: "failed", message: failure.message }
        }
      ])
      return cancelled ? "cancelled" : "failed"
    } finally {
      runSignal?.removeEventListener("abort", abort)
    }
  }

  #prepareCompaction(excludedFailureEntryId?: string): PreparedCompaction | undefined {
    if (this.#modelState.type === "unselected") throw new Error("No model selected. Use /login, then /model.")
    if (!this.#authentication.isIdle) throw new Error("Cannot compact context while authentication is active")
    const model = this.#modelState.model
    const settings = this.#effectiveCompactionSettings()
    if (!settings) throw new Error("Selected model does not report a usable context window")
    const usage = this.contextUsage
    if (usage.type === "unavailable") throw new Error("Context usage is unavailable for the selected model")
    const preparation = prepareCompaction(
      this.sessionManager.retainedEntries(),
      settings,
      { tokens: usage.tokens, quality: usage.type },
      excludedFailureEntryId
    )
    if (preparation.type === "nothing_to_compact") return undefined
    return { model, settings, leafId: this.sessionManager.retainedEntries().at(-1)?.id, plan: preparation.plan }
  }

  #effectiveCompactionSettings(): EffectiveCompactionSettings | undefined {
    if (this.#modelState.type === "unselected") return undefined
    const settings = this.settingsManager.get()
    return effectiveCompactionSettings(this.#modelState.model, {
      reserveTokens: settings.compactionReserveTokens,
      keepRecentTokens: settings.compactionKeepRecentTokens
    })
  }

  async #performCompaction(
    operationId: number,
    reason: CompactionReason,
    controller: AbortController,
    prepared: PreparedCompaction,
    customInstructions?: string
  ): Promise<CommittedCompaction> {
    const deadline = new AbortController()
    const timeout = setTimeout(() => deadline.abort(), maxCompactionOperationMs)
    const signal = AbortSignal.any([controller.signal, deadline.signal])
    try {
      const summary = await generateCompactionSummary(
        prepared.plan,
        prepared.model,
        prepared.settings,
        customInstructions,
        this.thinkingLevel,
        (request, requestSignal) => {
          // Pi 9b3a2059: summaries are standalone requests, not continuations of the agent's routing/cache session.
          const sessionId = crypto.randomUUID()
          const sample: SummarySampler = (sampleRequest, sampleSignal) =>
            settleBeforeAbort(
              Promise.resolve(
                this.#agent.streamFn(prepared.model, sampleRequest.context, {
                  maxTokens: sampleRequest.maxTokens,
                  signal: sampleSignal,
                  cacheRetention: "none",
                  sessionId,
                  ...(sampleRequest.thinkingLevel ? { reasoning: sampleRequest.thinkingLevel } : {})
                })
              ).then(stream => stream.result()),
              sampleSignal
            )
          return this.#sampleCompactionWithRetry(operationId, reason, prepared.model, request, requestSignal, sample)
        },
        signal
      )
      const estimatedTokensAfter = validateCompactionReduction(prepared.plan, summary)
      this.#assertCompactionCommit(operationId, prepared, signal)

      const marker = this.sessionManager.appendCompaction({
        reason,
        summary,
        firstKeptEntryId: prepared.plan.firstKeptEntryId,
        tokensBefore: prepared.plan.tokensBefore,
        estimatedTokensAfter,
        details: prepared.plan.details,
        ...(prepared.plan.excludedFailureEntryId
          ? { excludedFailureEntryId: prepared.plan.excludedFailureEntryId }
          : {})
      })
      this.#agent.state.messages = this.sessionManager.activeMessages()
      this.#committedMessageMemory = undefined
      this.#contextUsageCache = undefined
      const result = Object.freeze({
        reason,
        summary,
        firstKeptEntryId: prepared.plan.firstKeptEntryId,
        tokensBefore: prepared.plan.tokensBefore,
        estimatedTokensAfter,
        compactedEntries: prepared.plan.compactedEntries,
        details: prepared.plan.details
      })
      return Object.freeze({ marker, result })
    } catch (cause) {
      if (deadline.signal.aborted && !controller.signal.aborted) {
        throw new Error(`Compaction timed out after ${maxCompactionOperationMs / 60_000} minutes`, { cause })
      }
      throw cause
    } finally {
      clearTimeout(timeout)
    }
  }

  async #sampleCompactionWithRetry(
    operationId: number,
    reason: CompactionReason,
    model: Model<Api>,
    request: SummaryRequest,
    signal: AbortSignal,
    sample: SummarySampler
  ): Promise<AssistantMessage> {
    const settings = this.settingsManager.get()
    let attempt = 0
    let retryStarted = false
    try {
      for (;;) {
        // oxlint-disable-next-line no-await-in-loop
        const response = await sample(request, signal)
        const retryable =
          response.stopReason === "error" &&
          !isContextOverflow(response, model.contextWindow) &&
          isRetryableAssistantError(response)
        if (!settings.retryEnabled || !retryable || attempt >= settings.retryMaxRetries) return response

        attempt++
        retryStarted = true
        const delayMs = retryDelayMs(settings.retryBaseDelayMs, attempt)
        const retryAt = Date.now() + delayMs
        const errorMessage = boundedRetryError(response.errorMessage || "Unknown provider error")
        const stage: CompactionStage = {
          type: "retry_wait",
          attempt,
          maxAttempts: settings.retryMaxRetries,
          delayMs,
          retryAt,
          errorMessage
        }
        if (!this.#setCompactionStage(operationId, stage)) return retryAbortedMessage(response)
        this.#emitAll([
          {
            type: "summarization_retry_scheduled",
            operationId,
            reason,
            attempt,
            maxAttempts: settings.retryMaxRetries,
            delayMs,
            retryAt,
            errorMessage
          }
        ])

        if (
          // oxlint-disable-next-line no-await-in-loop
          !(await waitForRetryDelay(delayMs, signal)) ||
          !this.#setCompactionStage(operationId, { type: "sampling" })
        ) {
          return retryAbortedMessage(response)
        }
        this.#emitAll([{ type: "summarization_retry_attempt_start", operationId, reason }])
      }
    } finally {
      if (retryStarted) this.#finishSummarizationRetry(operationId, reason)
    }
  }

  #setCompactionStage(operationId: number, stage: CompactionStage): boolean {
    const activity = this.#activity
    if (activity.type === "compacting" && activity.operationId === operationId) {
      this.#activity = { ...activity, stage }
      return true
    }
    if (
      activity.type === "running" &&
      activity.phase.type === "compacting" &&
      activity.phase.operationId === operationId
    ) {
      this.#activity = { ...activity, phase: { ...activity.phase, stage } }
      return true
    }
    return false
  }

  #finishSummarizationRetry(operationId: number, reason: CompactionReason): void {
    this.#setCompactionStage(operationId, { type: "sampling" })
    this.#emitAll([{ type: "summarization_retry_finished", operationId, reason }])
  }

  #assertCompactionCommit(operationId: number, prepared: PreparedCompaction, signal: AbortSignal): void {
    if (signal.aborted) throw new Error("Compaction cancelled")
    const active =
      this.#isManualCompaction(operationId) ||
      (this.#activity.type === "running" &&
        this.#activity.phase.type === "compacting" &&
        this.#activity.phase.operationId === operationId)
    if (!active) throw new Error("Compaction completion is stale")
    if (this.#modelState.type !== "selected" || this.#modelState.model !== prepared.model) {
      throw new Error("Compaction model changed before commit")
    }
    if (this.sessionManager.retainedEntries().at(-1)?.id !== prepared.leafId) {
      throw new Error("Session changed before compaction could commit")
    }
  }

  #runningAgentActivity(runId: number): RunningActivity | undefined {
    const activity = this.#activity
    return activity.type === "running" && activity.runId === runId && activity.phase.type === "agent"
      ? activity
      : undefined
  }

  #isManualCompaction(operationId: number): boolean {
    return this.#activity.type === "compacting" && this.#activity.operationId === operationId
  }

  #isManualCompactionCommitted(operationId: number): boolean {
    return this.#activity.type === "compaction_committed" && this.#activity.operationId === operationId
  }

  #isAutomaticCompaction(runId: number, operationId: number): boolean {
    return (
      this.#activity.type === "running" &&
      this.#activity.runId === runId &&
      this.#activity.phase.type === "compacting" &&
      this.#activity.phase.operationId === operationId
    )
  }

  #isAutomaticCompactionCommitted(runId: number, operationId: number): boolean {
    return (
      this.#activity.type === "running" &&
      this.#activity.runId === runId &&
      this.#activity.phase.type === "compaction_committed" &&
      this.#activity.phase.operationId === operationId
    )
  }

  #canContinue(runId: number): boolean {
    return this.#activity.type === "running" && this.#activity.runId === runId && this.#activity.phase.type === "agent"
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
      case "compacting":
      case "compaction_committed":
        throw new Error("Cannot queue input while context compaction is active")
      case "failed":
        throw new Error("Restore or discard queued inputs from the failed run before queueing again")
      case "disposed":
        throw new Error("AgentSession is disposed")
      default:
        return assertNever(this.#activity)
    }
  }

  #ownedMessages(): AgentMessage[] {
    // Pi can append only base provider messages; Zi is the sole producer of its stricter summary variant.
    // oxlint-disable-next-line typescript/no-unsafe-type-assertion
    return this.#agent.state.messages as AgentMessage[]
  }

  #lastAssistantMessage(): AssistantMessage | undefined {
    return this.#ownedMessages().findLast((message): message is AssistantMessage => message.role === "assistant")
  }

  #isSelectedModelMessage(message: AgentMessage): boolean {
    return (
      this.#modelState.type === "selected" &&
      message.role === "assistant" &&
      message.provider === this.#modelState.model.provider &&
      message.model === this.#modelState.model.id
    )
  }

  #removeRuntimeMessage(message: AgentMessage): void {
    const messages = this.#ownedMessages()
    const index = messages.lastIndexOf(message)
    if (index >= 0) this.#agent.state.messages = messages.toSpliced(index, 1)
  }

  async #handleAgentEvent(event: AgentEvent): Promise<void> {
    if (event.type === "message_start" && event.message.role === "user") this.#removeDelivered(event.message)
    if (event.type === "message_end") {
      if (!isZiAgentMessage(event.message)) throw new Error("Invalid Zi agent message")
      const entry = this.sessionManager.appendMessage(event.message)
      this.#recordCommittedMessage(entry.message)
      this.#emit({ type: "entry_appended", entry })
    }
    if (event.type === "agent_end") {
      const messages: AgentMessage[] = []
      for (const message of event.messages) {
        if (!isZiAgentMessage(message)) throw new Error("Invalid Zi agent message")
        messages.push(message)
      }
      this.#emit({ type: "agent_end", messages, willRetry: this.#willRetryAfterAgentEnd(event) })
    } else {
      this.#emit(event)
    }
    if (event.type === "message_end" && event.message.role === "assistant" && event.message.stopReason !== "error") {
      this.#finishRetryResponse(event.message)
    }
  }

  #willRetryAfterAgentEnd(event: Extract<AgentEvent, { type: "agent_end" }>): boolean {
    const activity = this.#activity
    const settings = this.settingsManager.get()
    if (
      activity.type !== "running" ||
      activity.phase.type !== "agent" ||
      !settings.retryEnabled ||
      activity.retryAttempts >= settings.retryMaxRetries
    ) {
      return false
    }
    const message = event.messages.findLast(candidate => candidate.role === "assistant")
    return (
      message?.role === "assistant" &&
      !isContextOverflow(message, this.model.contextWindow) &&
      isRetryableAssistantError(message)
    )
  }

  #finishRetryResponse(message: Extract<AgentMessage, { role: "assistant" }>): void {
    const activity = this.#activity
    if (activity.type !== "running" || activity.retryAttempts === 0) return
    this.#activity = { ...activity, retryAttempts: 0 }
    this.#emitAll([
      { type: "auto_retry_end", success: message.stopReason !== "aborted", attempt: activity.retryAttempts }
    ])
  }

  #recordCommittedMessage(message: AgentMessage): void {
    const messages = this.#ownedMessages()
    const memory = this.#committedMessageMemory
    if (memory) {
      this.#committedMessageMemory =
        messages.length === memory.count + 1 && messages.at(-1) === message
          ? { count: messages.length, bytes: memory.bytes + serializedMessageBytes(message) }
          : undefined
    }

    const context = this.#contextUsageCache
    if (!context) return
    if (
      this.#modelState.type === "unselected" ||
      context.model !== this.#modelState.model ||
      messages.length !== context.messageCount + 1 ||
      messages.at(-1) !== message
    ) {
      this.#contextUsageCache = undefined
      return
    }
    this.#contextUsageCache = {
      model: context.model,
      messageCount: messages.length,
      usage: advanceContextUsage(context.usage, message, context.model.contextWindow)
    }
  }

  #removeDelivered(message: PiAgentMessage): void {
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

function settleBeforeAbort<T>(operation: Promise<T>, signal: AbortSignal): Promise<T> {
  if (signal.aborted) return Promise.reject(new Error("Compaction cancelled"))
  return new Promise<T>((resolve, reject) => {
    const onAbort = () => reject(new Error("Compaction cancelled"))
    signal.addEventListener("abort", onAbort, { once: true })
    void operation.then(
      value => {
        signal.removeEventListener("abort", onAbort)
        resolve(value)
        return undefined
      },
      cause => {
        signal.removeEventListener("abort", onAbort)
        reject(cause)
        return undefined
      }
    )
  })
}

async function settleTogether(first: Promise<void>, second: Promise<void>): Promise<void> {
  await Promise.all([first, second])
}

async function settleAll(operations: readonly Promise<void>[]): Promise<void> {
  const outcomes = await Promise.allSettled(operations)
  const failure = outcomes.find((outcome): outcome is PromiseRejectedResult => outcome.status === "rejected")
  if (failure) throw failure.reason
}

function createSettlement<T = void>(): Settlement<T> {
  let resolve!: (value: T) => void
  let reject!: (cause: unknown) => void
  const promise = new Promise<T>((resolvePromise, rejectPromise) => {
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
