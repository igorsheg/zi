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
import type {
  ExtensionContext,
  ExtensionCustomEntry,
  ExtensionMessageDelivery,
  ExtensionShutdownReason,
  ExtensionStartReason,
  ExtensionSubagentProfile,
  ExtensionSubagentSnapshot
} from "@with-zi/extension-api"

import type {
  Authentication,
  AuthenticationInteraction,
  AuthenticationMethod,
  AuthenticationMethodType
} from "./authentication.js"
import type { CodeMode } from "./code-mode/code-mode.js"
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
import { discoverExtensionLoadPlan, extensionDiscoveryDiagnostic } from "./extensions/discovery.js"
import type { ExtensionHost, ExtensionHostSnapshot, ExtensionReloadResult } from "./extensions/host.js"
import { validateActiveExtensionToolCatalog, type ExtensionToolRegistration } from "./extensions/protocol.js"
import { admitExtensionTools } from "./extensions/tools.js"
import { isZiAgentMessage, type AgentMessage } from "./messages.js"
import type { ModelRegistry } from "./model-registry.js"
import type { ZiPaths } from "./paths.js"
import type { ProcessTreeTracker } from "./processes/process-tree.js"
import { type ProjectFileSearch, type ProjectFileSearchResult } from "./project-file-search.js"
import type { ProjectConfigurationAdmission } from "./project-trust.js"
import { expandPromptTemplate, type PromptTemplate } from "./prompt-templates.js"
import { maxResourceDiagnostics, type ResourceDiagnostic } from "./resource-diagnostics.js"
import type { ResourceLoader, SessionResources } from "./resource-loader.js"
import { boundedRetryError, retryAbortedMessage, retryDelayMs, waitForRetryDelay } from "./retry.js"
import {
  isSessionJson,
  sessionEntryToContextMessage,
  validateCustomMessageInput,
  type CompactionDetails,
  type CompactionEntry,
  type CompactionReason,
  type CustomEntry,
  type CustomMessageEntry,
  type CustomMessageInput,
  type SessionEntry,
  type SessionJournalMemoryDiagnostics,
  type SessionJson,
  type SessionManager,
  type SessionPromptHistoryEntry
} from "./session-manager.js"
import type { SessionShell, ShellDemotionResult, ShellKillResult, ShellTaskSnapshot } from "./session-shell.js"
import type { SettingsError, SettingsManager, SettingsScope } from "./settings-manager.js"
import { expandSkillCommand, type Skill } from "./skills.js"
import { builtinSlashCommands, type SlashCommand } from "./slash-commands.js"
import type { SubagentSnapshot, SubagentSupervisor } from "./subagents/supervisor.js"
import { createSubagentTools } from "./subagents/tools.js"
import { buildSystemPrompt } from "./system-prompt.js"

export type { ContextUsage } from "./context-usage.js"

export const maxPendingInputCount = 32
export const maxPendingInputBytes = 8 * 1024 * 1024
export { maxRetryDelayMs, maxRetryErrorBytes } from "./retry.js"

export type PendingInputDelivery = "steer" | "followUp"

export type CustomMessageDelivery =
  | { readonly type: "append" }
  | { readonly type: "trigger_turn" }
  | { readonly type: "steer" }
  | { readonly type: "follow_up" }
  | { readonly type: "next_turn" }

export type CustomMessageAdmission =
  | { readonly type: "appended"; readonly entry: CustomMessageEntry }
  | { readonly type: "queued"; readonly delivery: "steer" | "follow_up" | "next_turn" }
  | { readonly type: "turn_started"; readonly entry: CustomMessageEntry; readonly settled: Promise<void> }

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
  | { type: "codex_fast_mode_changed"; enabled: boolean }
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

export interface CodexFastModeMutation {
  readonly requested: boolean
  readonly effective: boolean
}

export interface SessionReloadDeps {
  readonly resourceLoader: ResourceLoader
  readonly paths: ZiPaths
  readonly project: ProjectConfigurationAdmission
  readonly extensionPaths: readonly string[]
}

export interface SessionReloadResult {
  readonly resources: SessionResources
  readonly extensions: ExtensionReloadResult | undefined
  readonly settingsErrors: readonly SettingsError[]
}

interface AgentSessionConfig {
  agent: Agent
  sessionManager: SessionManager
  settingsManager: SettingsManager
  authentication: Authentication
  modelRegistry: ModelRegistry
  resources: SessionResources
  projectFileSearch: ProjectFileSearch
  tools: readonly AgentTool[]
  reload: SessionReloadDeps
  codeMode?: CodeMode
  extensionHost?: ExtensionHost
  extensionContext: ExtensionContext
  shell?: SessionShell
  subagentSupervisor?: SubagentSupervisor
  processTreeTracker?: ProcessTreeTracker
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

type ProviderStart = { readonly type: "pending"; readonly controller: AbortController } | { readonly type: "active" }

type RunningActivity = {
  readonly type: "running"
  readonly runId: number
  readonly providerStart: ProviderStart
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
  | {
      type: "extension_command"
      operationId: number
      name: string
      controller: AbortController
      settled: Promise<void>
    }
  | { type: "reloading"; operationId: number; settled: Promise<void> }
  | { type: "failed"; runId: number; cause: unknown }
  | { type: "disposed"; settled: Promise<void> }

type ExtensionLifecycleState =
  | { readonly type: "absent" }
  | { readonly type: "unbound"; readonly host: ExtensionHost }
  | { readonly type: "starting"; readonly host: ExtensionHost; readonly settled: Promise<void> }
  | { readonly type: "started"; readonly host: ExtensionHost }
  | { readonly type: "shutdown"; readonly host: ExtensionHost; readonly settled: Promise<void> }
  | { readonly type: "disposing"; readonly host: ExtensionHost; readonly settled: Promise<void> }
  | { readonly type: "disposed"; readonly settled: Promise<void> }

type ModelMutationState = { type: "none" } | { type: "validating"; operationId: number }

export type SessionModelState =
  | { readonly type: "unselected" }
  | { readonly type: "selected"; readonly model: Model<Api> }

interface PendingUserInput {
  readonly type: "user"
  readonly id: number
  readonly runId: number
  readonly delivery: PendingInputDelivery
  readonly text: string
  readonly images: readonly ImageContent[]
  readonly bytes: number
  readonly message: AgentMessage
}

type PendingCustomInput =
  | {
      readonly type: "custom"
      readonly id: number
      readonly runId: number
      readonly delivery: PendingInputDelivery
      readonly bytes: number
      readonly message: RuntimeCustomMessage
    }
  | {
      readonly type: "custom"
      readonly id: number
      readonly delivery: "nextTurn"
      readonly bytes: number
      readonly message: RuntimeCustomMessage
    }

type PendingInput = PendingUserInput | PendingCustomInput

type PendingMessageCancellation = "interrupt" | "restore"

type QueueRestoreCancellationState =
  | { readonly type: "none" }
  | { readonly type: "awaiting_synthetic_failure"; readonly runId: number }
  | { readonly type: "suppressing_synthetic_failure"; readonly runId: number; readonly message: AssistantMessage }

type RuntimeCustomMessage = Extract<AgentMessage, { role: "custom" }> & { readonly details?: SessionJson }

type RunStart =
  | { readonly type: "prompt"; readonly messages: readonly AgentMessage[] }
  | { readonly type: "continuation" }

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

export interface ExtensionCommand extends SlashCommand {
  readonly extensionId: string
}

interface ExtensionToolSelection {
  readonly registrations: readonly ExtensionToolRegistration[]
  readonly active: ReadonlySet<ExtensionToolRegistration>
}

export class AgentSession {
  readonly sessionManager: SessionManager
  readonly settingsManager: SettingsManager

  readonly #agent: Agent
  readonly #authentication: Authentication
  readonly #modelRegistry: ModelRegistry
  readonly #reload: SessionReloadDeps
  readonly #projectFileSearch: ProjectFileSearch
  readonly #codeMode: CodeMode | undefined
  readonly #extensionHost: ExtensionHost | undefined
  readonly #extensionContext: ExtensionContext
  readonly #shell: SessionShell | undefined
  readonly #subagents: SubagentSupervisor | undefined
  readonly #processTreeTracker: ProcessTreeTracker | undefined
  readonly #apiKeyProvider: string | undefined
  readonly #listeners = new Set<(event: AgentSessionEvent) => void>()
  readonly #unsubscribeAgent: () => void
  readonly #unsubscribeShell: (() => void) | undefined
  readonly #unsubscribeSubagents: (() => void) | undefined
  readonly #unbindExtensionCatalog: (() => void) | undefined
  readonly #unbindExtensionSessionOperations: (() => void) | undefined
  #resources: SessionResources
  #baseTools: readonly AgentTool[]
  #extensionToolSelection: ExtensionToolSelection = { registrations: Object.freeze([]), active: new Set() }
  #activity: Activity = { type: "idle" }
  #extensionLifecycle: ExtensionLifecycleState
  #pending: PendingInput[] = []
  #pendingBytes = 0
  readonly #cancelledPendingMessages = new Map<PiAgentMessage, PendingMessageCancellation>()
  #queueRestoreCancellation: QueueRestoreCancellationState = { type: "none" }
  #nextRunId = 0
  #nextEntryId = 0
  #nextModelOperationId = 0
  #nextCompactionOperationId = 0
  #nextExtensionCommandOperationId = 0
  #nextReloadOperationId = 0
  #modelMutation: ModelMutationState = { type: "none" }
  #modelState: SessionModelState
  #modelChoicesPromise: Promise<readonly ModelChoice[]> | undefined
  #committedMessageMemory: CommittedMessageMemory | undefined
  #contextUsageCache: ContextUsageCache | undefined
  #extensionCommandRevision = 0

  constructor(config: AgentSessionConfig) {
    this.#agent = config.agent
    this.#authentication = config.authentication
    this.#modelRegistry = config.modelRegistry
    this.#reload = config.reload
    this.#resources = config.resources
    this.#projectFileSearch = config.projectFileSearch
    this.#codeMode = config.codeMode
    this.#extensionHost = config.extensionHost
    this.#extensionContext = config.extensionContext
    this.#baseTools = Object.freeze([...config.tools])
    this.#extensionLifecycle = config.extensionHost
      ? { type: "unbound", host: config.extensionHost }
      : { type: "absent" }
    this.#shell = config.shell
    this.#subagents = config.subagentSupervisor
    this.#processTreeTracker = config.processTreeTracker
    this.#apiKeyProvider = config.apiKeyProvider
    this.sessionManager = config.sessionManager
    this.settingsManager = config.settingsManager
    this.#modelState = config.model ? { type: "selected", model: config.model } : { type: "unselected" }
    this.#agent.prepareNextTurnWithContext = (context, signal) => this.#prepareNextTurn(context, signal)
    this.#unsubscribeAgent = this.#agent.subscribe(event => this.#handleAgentEvent(event))
    this.#applyExtensionCatalog()
    this.#unbindExtensionCatalog = config.extensionHost?.bindCatalog(() => this.#applyExtensionCatalog())
    this.#unbindExtensionSessionOperations = config.extensionHost?.bindSessionOperations({
      getEntries: customType => this.#getExtensionCustomEntries(customType).map(extensionCustomEntry),
      appendEntry: (customType, data) => extensionCustomEntry(this.#appendExtensionCustomEntry(customType, data)),
      sendMessage: (message, delivery) => {
        this.#sendExtensionCustomMessage(message, delivery)
      },
      getActiveTools: extensionId => this.#getExtensionActiveTools(extensionId),
      setActiveTools: (extensionId, names) => this.#setExtensionActiveTools(extensionId, names),
      ...(this.#subagents
        ? {
            subagents: {
              waitTimeoutMs: this.#subagents.waitTimeoutMs,
              listProfiles: () => this.#subagentProfiles(),
              spawn: (_extensionId, profile, name, prompt, signal) =>
                this.#spawnSubagentFromProfile(profile, name, prompt, signal),
              send: (_extensionId, name, text) => this.#requireSubagents().send(name, text),
              continue: (_extensionId, name, text) => this.#requireSubagents().continue(name, text),
              wait: (_extensionId, names, timeoutMs, signal) =>
                this.#requireSubagents()
                  .wait(names, timeoutMs, signal)
                  .then(snapshots => snapshots.map(extensionSubagentSnapshot)),
              interrupt: (_extensionId, name) => this.#requireSubagents().interrupt(name),
              close: (_extensionId, name) => this.#requireSubagents().close(name).then(extensionSubagentSnapshot),
              list: () => this.#requireSubagents().snapshots().map(extensionSubagentSnapshot)
            }
          }
        : {})
    })
    this.#unsubscribeSubagents = this.#subagents?.subscribe(event => {
      if (event.type !== "entry_appended") return
      try {
        this.#emit({ type: "entry_appended", entry: event.entry })
      } catch {
        // Process ownership cannot cross into an observer.
      }
    })
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

  getLastAssistantText(): string | undefined {
    // Behavioral provenance: pi-coding-agent 73414d08, AgentSession.getLastAssistantText().
    const message = this.messages.findLast((candidate): candidate is AssistantMessage => {
      if (candidate.role !== "assistant") return false
      return candidate.stopReason !== "aborted" || candidate.content.length > 0
    })
    if (!message) return undefined

    let text = ""
    for (const content of message.content) {
      if (content.type === "text") text += content.text
    }
    return text.trim() || undefined
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
      (this.#activity.type === "extension_command" && this.#activity.controller.signal.aborted) ||
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
    const diagnostics = [...this.#resources.diagnostics]
    const resources = new Map(this.#resources.subagentProfiles.map(profile => [profile.name, profile]))
    const collisions: ResourceDiagnostic[] = []
    for (const registered of this.#extensionHost?.subagentCatalog() ?? []) {
      const winner = resources.get(registered.name)
      if (!winner) continue
      collisions.push(
        Object.freeze({
          type: "collision",
          resource: "subagent-profile",
          name: registered.name,
          winnerPath: winner.filePath,
          loserPath: registered.source.entryPath
        })
      )
    }
    const remaining = maxResourceDiagnostics - diagnostics.length
    if (collisions.length <= remaining) return Object.freeze([...diagnostics, ...collisions])
    if (remaining <= 0) return Object.freeze(diagnostics)
    diagnostics.push(...collisions.slice(0, remaining - 1))
    diagnostics.push(
      Object.freeze({
        type: "limit",
        resource: "discovery",
        limit: maxResourceDiagnostics,
        message: `Resource diagnostics are limited to ${maxResourceDiagnostics} entries`
      })
    )
    return Object.freeze(diagnostics)
  }

  get extensionCommandRevision(): number {
    return this.#extensionCommandRevision
  }

  get extensionCommandStatus():
    | { readonly type: "idle" }
    | { readonly type: "running"; readonly name: string; readonly phase: "executing" | "cancelling" } {
    const activity = this.#activity
    if (activity.type !== "extension_command") return { type: "idle" }
    return {
      type: "running",
      name: activity.name,
      phase: activity.controller.signal.aborted ? "cancelling" : "executing"
    }
  }

  listExtensionCommands(): readonly ExtensionCommand[] {
    return Object.freeze(
      (this.#extensionHost?.commandCatalog() ?? []).map(command =>
        Object.freeze({
          name: command.name,
          description: command.description,
          ...(command.argumentHint === undefined ? {} : { argumentHint: command.argumentHint }),
          extensionId: command.source.id
        })
      )
    )
  }

  invokeExtensionCommand(name: string, arguments_: string): Promise<string | undefined> {
    this.#assertIdle("run an extension command")
    if (this.#modelMutation.type !== "none") {
      throw new Error("Cannot run an extension command while a model change is active")
    }
    if (this.#pending.length > 0) throw new Error("Cannot run an extension command while queued input is pending")
    const lifecycle = this.#extensionLifecycle
    if (lifecycle.type !== "started") {
      throw new Error(`Cannot run an extension command while extension lifecycle is ${lifecycle.type}`)
    }
    if (!lifecycle.host.commandCatalog().some(command => command.name === name)) {
      throw new Error(`Unknown extension command: ${name}`)
    }

    const operationId = ++this.#nextExtensionCommandOperationId
    const controller = new AbortController()
    const operation = createSettlement<string | undefined>()
    this.#activity = {
      type: "extension_command",
      operationId,
      name,
      controller,
      settled: operation.promise.then(
        () => undefined,
        () => undefined
      )
    }
    void Promise.resolve()
      .then(() => lifecycle.host.invokeCommand(name, arguments_, controller.signal))
      .then(
        value => operation.resolve(value),
        cause => operation.reject(cause)
      )
    return operation.promise.finally(() => {
      if (this.#ownsExtensionCommand(operationId)) this.#activity = { type: "idle" }
    })
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

  appendCustomEntry(customType: string, data?: SessionJson): CustomEntry {
    this.#assertCustomStateAppend()
    const entry = this.sessionManager.appendCustomEntry(customType, data)
    this.#emitAll([{ type: "entry_appended", entry }])
    return entry
  }

  getCustomEntries(customType: string): readonly CustomEntry[] {
    this.#assertOpen()
    return this.sessionManager.customEntries(customType)
  }

  #getExtensionCustomEntries(customType: string): readonly CustomEntry[] {
    if (this.#activity.type === "reloading" || this.#extensionLifecycle.type === "shutdown") {
      return this.sessionManager.customEntries(customType)
    }
    return this.getCustomEntries(customType)
  }

  #appendExtensionCustomEntry(customType: string, data?: SessionJson): CustomEntry {
    if (this.#activity.type === "reloading") {
      const entry =
        data === undefined
          ? this.sessionManager.appendCustomEntry(customType)
          : this.sessionManager.appendCustomEntry(customType, data)
      this.#emitAll([{ type: "entry_appended", entry }])
      return entry
    }
    if (this.#extensionLifecycle.type === "shutdown") {
      return data === undefined
        ? this.sessionManager.appendCustomEntry(customType)
        : this.sessionManager.appendCustomEntry(customType, data)
    }
    return this.appendCustomEntry(customType, data)
  }

  #subagentProfiles(): readonly ExtensionSubagentProfile[] {
    const profiles = new Map<string, ExtensionSubagentProfile>()
    for (const resource of this.#resources.subagentProfiles) profiles.set(resource.name, resource)
    for (const registered of this.#extensionHost?.subagentCatalog() ?? []) {
      if (!profiles.has(registered.name)) profiles.set(registered.name, registered)
    }
    return Object.freeze([...profiles.values()])
  }

  async #spawnSubagentFromProfile(
    profileName: string,
    name: string,
    prompt: string,
    signal?: AbortSignal
  ): Promise<string> {
    const resource = this.#resources.subagentProfiles.find(candidate => candidate.name === profileName)
    const registered = this.#extensionHost?.subagentCatalog().find(candidate => candidate.name === profileName)
    const profile = resource ?? registered
    if (!profile) throw new Error(`Unknown subagent profile: ${profileName}`)
    const source = resource?.filePath ?? registered?.source.entryPath
    let model: string | undefined
    if (profile.model) {
      const resolved = this.#modelRegistry.find(profile.model)
      let available = false
      try {
        available =
          resolved !== undefined &&
          (resolved.provider === this.#apiKeyProvider || (await this.#modelRegistry.isConfigured(resolved)))
      } catch (cause) {
        throw new Error(
          `Subagent profile ${profileName}${source ? ` from ${source}` : ""} requests unavailable model: ${profile.model}`,
          { cause }
        )
      }
      if (!resolved || !available) {
        throw new Error(
          `Subagent profile ${profileName}${source ? ` from ${source}` : ""} requests unavailable model: ${profile.model}`
        )
      }
      model = `${resolved.provider}/${resolved.id}`
    }
    const task = `${profile.instructions.trimEnd()}\n\nTask:\n${prompt}`
    return this.#requireSubagents().spawn(name, task, signal, {
      ...(model ? { model } : {}),
      ...(profile.thinking ? { thinkingLevel: profile.thinking } : {})
    })
  }

  #requireSubagents(): SubagentSupervisor {
    if (!this.#subagents) throw new Error("Subagent session operations are unavailable")
    return this.#subagents
  }

  #sendExtensionCustomMessage(message: CustomMessageInput, delivery: ExtensionMessageDelivery): void {
    if (this.#activity.type === "reloading") {
      if (delivery !== "append") {
        throw new Error("Only append custom messages are allowed while reloading")
      }
      const committed = this.#appendCustomMessage(message)
      this.#publishCustomMessage(committed)
      return
    }
    this.sendCustomMessage(message, extensionMessageDelivery(delivery))
  }

  sendCustomMessage(message: CustomMessageInput, delivery: CustomMessageDelivery): CustomMessageAdmission {
    switch (delivery.type) {
      case "append": {
        if (this.#activity.type !== "idle") throw new Error("Custom messages can only append while the agent is idle")
        const committed = this.#appendCustomMessage(message)
        this.#publishCustomMessage(committed)
        return { type: "appended", entry: committed.entry }
      }
      case "trigger_turn": {
        if (this.#activity.type !== "idle") {
          throw new Error("Custom messages can only trigger a turn while the agent is idle")
        }
        if (this.#modelState.type === "unselected") throw new Error("No model selected. Use /login, then /model.")
        if (!this.#authentication.isIdle) throw new Error("Cannot trigger a turn while authentication is active")
        const committed = this.#appendCustomMessage(message)
        const run = this.#beginRun()
        this.#publishCustomMessage(committed)
        void this.#drive(run.runId, { type: "continuation" }, run.settlement)
        return { type: "turn_started", entry: committed.entry, settled: run.settlement.promise }
      }
      case "steer":
        this.#enqueueCustom("steer", message)
        return { type: "queued", delivery: "steer" }
      case "follow_up":
        this.#enqueueCustom("followUp", message)
        return { type: "queued", delivery: "follow_up" }
      case "next_turn":
        this.#enqueueCustom("nextTurn", message)
        return { type: "queued", delivery: "next_turn" }
      default:
        return assertNever(delivery)
    }
  }

  async reload(): Promise<SessionReloadResult> {
    this.#assertReloadAdmissible()
    const operationId = ++this.#nextReloadOperationId
    const settlement = createSettlement()
    this.#activity = {
      type: "reloading",
      operationId,
      settled: settlement.promise.then(
        () => undefined,
        () => undefined
      )
    }

    try {
      this.settingsManager.reload()
      const settingsErrors = Object.freeze(this.settingsManager.drainErrors())
      this.#applyQueueModesFromSettings()

      const resources = await this.#reload.resourceLoader.load()
      if (!this.#ownsReload(operationId)) {
        settlement.resolve()
        return Object.freeze({ resources, extensions: undefined, settingsErrors })
      }
      this.#resources = resources
      this.#applyActiveTools()

      let extensions: ExtensionReloadResult | undefined
      if (this.#extensionHost) {
        const discovery = discoverExtensionLoadPlan(
          this.#reload.paths,
          this.#reload.project,
          this.#reload.extensionPaths
        )
        extensions = await this.#extensionHost.reload(
          {
            plan: discovery.plan,
            diagnostics: discovery.diagnostics.map(extensionDiscoveryDiagnostic),
            omittedDiagnostics: discovery.omittedDiagnostics
          },
          "reload",
          this.#extensionContext
        )
      }

      if (this.#ownsReload(operationId)) this.#activity = { type: "idle" }
      settlement.resolve()
      return Object.freeze({ resources, extensions, settingsErrors })
    } catch (cause) {
      if (this.#ownsReload(operationId)) this.#activity = { type: "idle" }
      settlement.reject(cause)
      throw cause
    }
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
        const run = this.#beginRun()
        const messages = [...this.#nextTurnCustomMessages(), userMessage(expandedText, options.images ?? [])]
        void this.#drive(run.runId, { type: "prompt", messages }, run.settlement)
        return run.settlement.promise
      }
      case "running":
        if (!options.streamingBehavior) throw new Error("streamingBehavior is required while the agent is running")
        this.#enqueueUser(options.streamingBehavior, text, options.images)
        return Promise.resolve()
      case "aborting":
        throw new Error("Cannot prompt while the agent is aborting")
      case "compacting":
      case "compaction_committed":
        throw new Error("Cannot prompt while context compaction is active")
      case "extension_command":
        throw new Error("Cannot prompt while an extension command is active")
      case "reloading":
        throw new Error("Cannot prompt while reload is active")
      case "failed":
        throw new Error("Restore or discard queued inputs from the failed run before prompting again")
      case "disposed":
        throw new Error("AgentSession is disposed")
      default:
        return assertNever(this.#activity)
    }
  }

  steer(text: string, images?: ImageContent[]): void {
    this.#enqueueUser("steer", text, images)
  }

  followUp(text: string, images?: ImageContent[]): void {
    this.#enqueueUser("followUp", text, images)
  }

  takeQueuedInputs(): QueuedInputs {
    this.#assertOpen()
    if (this.#activity.type === "aborting") throw new Error("Cannot restore queued inputs while the agent is aborting")
    if (this.#activity.type === "compacting" || this.#activity.type === "compaction_committed") {
      throw new Error("Cannot restore queued inputs while context compaction is active")
    }
    if (this.#activity.type === "extension_command") {
      throw new Error("Cannot restore queued inputs while an extension command is active")
    }
    if (this.#activity.type === "reloading") throw new Error("Cannot restore queued inputs while reload is active")
    const queued = this.#detachQueuedInputs("restore")
    if (this.#activity.type === "failed") this.#activity = { type: "idle" }
    this.#emitQueue()
    return queued
  }

  takeQueuedInputsAndAbort(): AbortedQueuedInputs {
    const authenticationWasIdle = this.#authentication.isIdle
    const authenticationSettled = this.#authentication.cancel()
    switch (this.#activity.type) {
      case "idle": {
        const queued = this.#detachQueuedInputs("interrupt")
        this.#emitQueue()
        return { ...queued, settled: authenticationSettled }
      }
      case "running": {
        const { runId, settled, providerStart, phase } = this.#activity
        const queued = this.#detachQueuedInputs("interrupt")
        this.#activity = { type: "aborting", runId, settled }
        try {
          this.#emitQueue()
        } finally {
          if (providerStart.type === "pending") providerStart.controller.abort()
          if (phase.type === "compacting" || phase.type === "retry_wait") phase.controller.abort()
          this.#agent.abort()
        }
        return { ...queued, settled: authenticationWasIdle ? settled : settleTogether(settled, authenticationSettled) }
      }
      case "compacting": {
        const { settled, controller } = this.#activity
        const queued = this.#detachQueuedInputs("interrupt")
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
        const queued = this.#detachQueuedInputs("interrupt")
        this.#activity = { type: "idle" }
        this.#emitQueue()
        return { ...queued, settled: authenticationSettled }
      }
      case "extension_command": {
        const { settled, controller } = this.#activity
        controller.abort()
        return {
          ...emptyQueue(),
          settled: authenticationWasIdle ? settled : settleTogether(settled, authenticationSettled)
        }
      }
      case "reloading": {
        const { settled } = this.#activity
        return {
          ...emptyQueue(),
          settled: authenticationWasIdle ? settled : settleTogether(settled, authenticationSettled)
        }
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
    if (this.#activity.type !== "disposed") this.#discardPendingCustomInputs()
    switch (this.#activity.type) {
      case "running": {
        const { runId, settled, providerStart, phase } = this.#activity
        if (providerStart.type === "pending") {
          this.#activity = { type: "aborting", runId, settled }
          providerStart.controller.abort()
          if (phase.type === "compacting") phase.controller.abort()
        } else if (phase.type === "compacting" || phase.type === "compaction_committed") {
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
      case "extension_command": {
        const { settled, controller } = this.#activity
        controller.abort()
        return authenticationWasIdle ? settled : settleTogether(settled, authenticationSettled)
      }
      case "reloading": {
        const { settled } = this.#activity
        return authenticationWasIdle ? settled : settleTogether(settled, authenticationSettled)
      }
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
    if (state.type === "shutdown" || state.type === "disposing" || state.type === "disposed") {
      return Promise.reject(new Error("Cannot start extensions after session disposal"))
    }

    const operation = createSettlement()
    const starting: ExtensionLifecycleState = { type: "starting", host: state.host, settled: operation.promise }
    this.#extensionLifecycle = starting
    void state.host.sessionStart(reason, this.#extensionContext).then(
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
      case "extension_command":
      case "reloading":
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

  setCodexFastMode(requested: boolean): CodexFastModeMutation {
    this.#assertOpen()
    if (typeof requested !== "boolean") throw new Error(`Invalid Codex Fast Mode setting: ${String(requested)}`)
    this.settingsManager.updateGlobal({ codexFastMode: requested })
    const effective = this.settingsManager.get().codexFastMode
    this.#emitAll([{ type: "codex_fast_mode_changed", enabled: effective }])
    return Object.freeze({ requested, effective })
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
    this.#baseTools = Object.freeze([...tools])
    this.#applyActiveTools()
  }

  #applyExtensionCatalog(): void {
    const host = this.#extensionHost
    const tools = host?.toolCatalog() ?? Object.freeze([])
    // Pi 73414d08 owns active selection in AgentSession. Registration identity lets Zi
    // preserve admission changes within a generation while reload restores new defaults.
    const previous = this.#extensionToolSelection
    const previousTools = new Set(previous.registrations)
    const activeTools = new Set<ExtensionToolRegistration>()
    for (const tool of tools) {
      if (previousTools.has(tool) ? previous.active.has(tool) : tool.active) activeTools.add(tool)
    }
    this.#extensionToolSelection = { registrations: tools, active: activeTools }
    if (host) {
      const rejectedCommands = host
        .commandCatalog()
        .filter(command => builtinSlashCommands.some(builtin => builtin.name === command.name))
        .map(command => ({
          command,
          message: `Extension command ${command.name} conflicts with a built-in command and was ignored`
        }))
      if (rejectedCommands.length > 0) host.rejectCommands(rejectedCommands)
    }
    this.#extensionCommandRevision++
    this.#applyActiveTools()
  }

  #getExtensionActiveTools(extensionId: string): readonly string[] {
    const selection = this.#extensionToolSelection
    return Object.freeze(
      selection.registrations
        .filter(tool => tool.source.id === extensionId && selection.active.has(tool))
        .map(tool => tool.name)
    )
  }

  #setExtensionActiveTools(extensionId: string, names: readonly string[]): void {
    const selection = this.#extensionToolSelection
    const byName = new Map(
      selection.registrations.filter(tool => tool.source.id === extensionId).map(tool => [tool.name, tool] as const)
    )
    const next = new Set(
      selection.registrations.filter(tool => tool.source.id !== extensionId && selection.active.has(tool))
    )
    for (const name of names) {
      const tool = byName.get(name)
      if (!tool) throw new Error(`Unknown or unadmitted extension tool: ${name}`)
      next.add(tool)
    }
    validateActiveExtensionToolCatalog([...next])
    this.#extensionToolSelection = { registrations: selection.registrations, active: next }
    this.#applyActiveTools()
  }

  #applyActiveTools(): void {
    const profiles = this.#subagentProfiles()
    const subagentTools = this.#subagents
      ? createSubagentTools(profiles, this.#subagents, (profile, name, prompt, signal) =>
          this.#spawnSubagentFromProfile(profile, name, prompt, signal)
        )
      : []
    const tools = admitExtensionTools(
      [...this.#baseTools, ...subagentTools],
      this.#extensionHost,
      this.#extensionToolSelection.active
    )
    this.#agent.state.tools = this.#codeMode ? [...tools, this.#codeMode.createTool(tools)] : [...tools]
    this.#agent.state.systemPrompt = buildSystemPrompt(
      this.sessionManager.header.cwd,
      this.#resources,
      tools,
      this.#codeMode !== undefined
    )
  }

  dispose(reason: ExtensionShutdownReason = "quit"): void {
    if (this.#activity.type === "disposed") return
    this.#modelMutation = { type: "none" }
    const currentActivity = this.#activity
    const activeSettled =
      currentActivity.type === "running" ||
      currentActivity.type === "aborting" ||
      currentActivity.type === "compacting" ||
      currentActivity.type === "compaction_committed" ||
      currentActivity.type === "extension_command" ||
      currentActivity.type === "reloading"
        ? currentActivity.settled
        : Promise.resolve()
    this.#pending = []
    this.#pendingBytes = 0
    this.#agent.clearAllQueues()
    if (currentActivity.type === "compacting" || currentActivity.type === "extension_command") {
      currentActivity.controller.abort()
    }
    if (currentActivity.type === "running") {
      if (currentActivity.providerStart.type === "pending") currentActivity.providerStart.controller.abort()
      if (currentActivity.phase.type === "compacting" || currentActivity.phase.type === "retry_wait") {
        currentActivity.phase.controller.abort()
      }
    }
    this.#agent.abort()
    this.#unbindExtensionCatalog?.()
    const processOwners = (async (): Promise<void> => {
      try {
        await settleAll([this.#subagents?.shutdown() ?? Promise.resolve(), this.#disposeExtensions(reason)])
      } finally {
        await this.#processTreeTracker?.dispose()
      }
    })()
    const settled = settleAll([
      activeSettled,
      this.#authentication.dispose(),
      this.#projectFileSearch.dispose(),
      this.#shell?.dispose() ?? Promise.resolve(),
      processOwners
    ])
    this.#activity = { type: "disposed", settled }
    this.#unsubscribeAgent()
    this.#unsubscribeShell?.()
    this.#unsubscribeSubagents?.()
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
      case "shutdown":
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
    if (state.type === "shutdown" || state.type === "disposing" || state.type === "disposed") {
      return state.settled
    }

    const operation = createSettlement()
    const shutdownState: ExtensionLifecycleState = { type: "shutdown", host: state.host, settled: operation.promise }
    this.#extensionLifecycle = shutdownState
    const shutdown = async (): Promise<void> => {
      try {
        if (state.type === "started") await state.host.sessionShutdown(reason)
      } finally {
        this.#unbindExtensionSessionOperations?.()
        this.#extensionLifecycle = { type: "disposing", host: state.host, settled: operation.promise }
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
        const current = this.#extensionLifecycle
        if ((current.type === "shutdown" || current.type === "disposing") && current.settled === operation.promise) {
          this.#extensionLifecycle = { type: "disposed", settled: operation.promise }
        }
      })
    return operation.promise
  }

  async #drive(runId: number, start: RunStart, settlement: Settlement): Promise<void> {
    let failure: { cause: unknown } | undefined
    try {
      await this.#compactBeforeMessages(runId, start.type === "prompt" ? start.messages : [])
      if (this.#activateProviderStart(runId)) {
        if (start.type === "prompt") await this.#runAgent(() => this.#agent.prompt([...start.messages]))
        else await this.#runAgent(() => this.#agent.continue())
      }
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
          await this.#runAgent(() => this.#agent.continue())
          continue
        }
        if (!this.#agent.hasQueuedMessages()) break
        // oxlint-disable-next-line no-await-in-loop
        await this.#runAgent(() => this.#agent.continue())
      }
    } catch (cause) {
      failure = { cause }
    }

    try {
      if (failure) this.#finishExceptionalRetry(runId, failure.cause)
      if (this.#isCurrentRun(runId)) {
        if (failure && this.#pending.some(entry => "runId" in entry && entry.runId === runId)) {
          this.#activity = { type: "failed", runId, cause: failure.cause }
        } else {
          this.#activity = { type: "idle" }
        }
        if (failure) this.#agent.clearAllQueues()
        this.#extensionHost?.publishAgentSettled()
        this.#emit({ type: "agent_settled" })
      }
    } catch (cause) {
      failure ??= { cause }
    } finally {
      this.#cancelledPendingMessages.clear()
      this.#queueRestoreCancellation = { type: "none" }
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

  async #compactBeforeMessages(runId: number, prospectiveMessages: readonly AgentMessage[]): Promise<void> {
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
    const prospective = prospectiveMessages.reduce((tokens, message) => tokens + estimateMessageTokens(message), 0)
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
    if (!this.#activateProviderStart(runId)) return "stop"
    await this.#runAgent(() => this.#agent.continue())
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
                this.#agent.streamFunction(prepared.model, sampleRequest.context, {
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

  #activateProviderStart(runId: number): boolean {
    const activity = this.#activity
    if (activity.type !== "running" || activity.runId !== runId || activity.phase.type !== "agent") return false
    if (activity.providerStart.type === "active") return true
    if (activity.providerStart.controller.signal.aborted) return false
    this.#activity = { ...activity, providerStart: { type: "active" } }
    return true
  }

  async #runAgent(operation: () => Promise<void>): Promise<void> {
    try {
      await operation()
    } finally {
      this.#cancelledPendingMessages.clear()
      this.#queueRestoreCancellation = { type: "none" }
    }
  }

  #beginRun(): { readonly runId: number; readonly settlement: Settlement } {
    this.#modelMutation = { type: "none" }
    const runId = ++this.#nextRunId
    const settlement = createSettlement()
    this.#activity = {
      type: "running",
      runId,
      providerStart: { type: "pending", controller: new AbortController() },
      phase: { type: "agent" },
      autoCompactions: 0,
      overflowRecoveries: 0,
      retryAttempts: 0,
      thresholdSuppressed: false,
      settled: settlement.promise
    }
    return { runId, settlement }
  }

  #appendCustomMessage(input: CustomMessageInput): {
    readonly entry: CustomMessageEntry
    readonly message: RuntimeCustomMessage
  } {
    const retained = customMessageInput(runtimeCustomMessage(input))
    const entry = this.sessionManager.appendCustomMessage(retained)
    const message = sessionEntryToContextMessage(entry)
    if (message?.role !== "custom" || !isRuntimeCustomMessage(message)) {
      throw new Error("Custom message projection is invalid")
    }
    this.#agent.state.messages = [...this.#ownedMessages(), message]
    this.#recordCommittedMessage(message)
    return { entry, message }
  }

  #publishCustomMessage(committed: {
    readonly entry: CustomMessageEntry
    readonly message: RuntimeCustomMessage
  }): void {
    this.#emitAll([
      { type: "entry_appended", entry: committed.entry },
      { type: "message_end", message: committed.message }
    ])
  }

  #enqueueUser(delivery: PendingInputDelivery, text: string, images: ImageContent[] | undefined): void {
    const runId = this.#queueRunId()
    const expandedText = this.#expandResourceInput(text)
    const retainedImages = (images ?? []).map(cloneImage)
    const bytes = retainedBytes(expandedText, retainedImages)
    this.#assertQueueCapacity(bytes)

    const message = userMessage(expandedText, retainedImages)
    const entry: PendingUserInput = {
      type: "user",
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

  #enqueueCustom(delivery: PendingInputDelivery | "nextTurn", input: CustomMessageInput): void {
    validateCustomMessageInput(input)
    const activity = this.#activity
    let target:
      | { readonly type: "next_turn" }
      | { readonly type: "active_run"; readonly runId: number; readonly delivery: PendingInputDelivery }
    if (delivery === "nextTurn") {
      if (activity.type !== "idle" && activity.type !== "running") {
        throw new Error("Cannot queue a custom message for the next turn in the current session state")
      }
      target = { type: "next_turn" }
    } else {
      if (activity.type !== "running" || activity.phase.type === "compaction_committed") {
        throw new Error(`Custom message delivery '${delivery}' requires an active agent run`)
      }
      target = { type: "active_run", runId: activity.runId, delivery }
    }

    const message = runtimeCustomMessage(input)
    const bytes = serializedMessageBytes(message)
    this.#assertQueueCapacity(bytes)
    const id = ++this.#nextEntryId
    if (target.type === "next_turn") {
      this.#pending.push({ type: "custom", id, delivery: "nextTurn", bytes, message })
    } else {
      this.#pending.push({ type: "custom", id, runId: target.runId, delivery: target.delivery, bytes, message })
      if (target.delivery === "steer") this.#agent.steer(message)
      else this.#agent.followUp(message)
    }
    this.#pendingBytes += bytes
    this.#emitQueue()
  }

  #assertQueueCapacity(bytes: number): void {
    if (this.#pending.length === maxPendingInputCount || this.#pendingBytes + bytes > maxPendingInputBytes) {
      throw new QueueCapacityError()
    }
  }

  #nextTurnCustomMessages(): readonly RuntimeCustomMessage[] {
    return this.#pending.flatMap(entry =>
      entry.type === "custom" && entry.delivery === "nextTurn" ? [entry.message] : []
    )
  }

  #discardPendingCustomInputs(): void {
    if (this.#pending.length === 0) return
    const runId =
      this.#activity.type === "running" || this.#activity.type === "aborting"
        ? this.#activity.runId
        : this.#activity.type === "idle"
          ? this.#nextRunId + 1
          : undefined
    let customRemoved = false
    const retained: PendingInput[] = []
    for (const entry of this.#pending) {
      if (entry.type === "custom") {
        customRemoved = true
        this.#pendingBytes -= entry.bytes
        if (runId !== undefined && this.#activity.type !== "idle") {
          this.#cancelledPendingMessages.set(entry.message, "interrupt")
        }
        continue
      }
      if (runId !== undefined && this.#activity.type !== "idle" && entry.runId === runId) {
        this.#cancelledPendingMessages.set(entry.message, "interrupt")
        retained.push({ ...entry, message: userMessage(entry.text, entry.images) })
      } else {
        retained.push(entry)
      }
    }
    this.#pending = retained
    this.#agent.clearAllQueues()
    if (runId !== undefined) {
      for (const entry of this.#pending) {
        if (entry.type !== "user" || entry.runId !== runId) continue
        if (entry.delivery === "steer") this.#agent.steer(entry.message)
        else this.#agent.followUp(entry.message)
      }
    }
    if (customRemoved) this.#emitAll([{ type: "queue_update", ...this.#queueSnapshot() }])
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
      case "extension_command":
        throw new Error("Cannot queue input while an extension command is active")
      case "reloading":
        throw new Error("Cannot queue input while reload is active")
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
    if (index < 0) return
    this.#agent.state.messages = messages.toSpliced(index, 1)
    this.#invalidateMessageCaches()
  }

  #replaceRuntimeMessage(source: AgentMessage, replacement: AgentMessage): void {
    const messages = this.#ownedMessages()
    const index = messages.lastIndexOf(source)
    if (index < 0) throw new Error("Committed custom message is missing from runtime context")
    this.#agent.state.messages = messages.toSpliced(index, 1, replacement)
    this.#invalidateMessageCaches()
  }

  #invalidateMessageCaches(): void {
    this.#committedMessageMemory = undefined
    this.#contextUsageCache = undefined
  }

  async #handleAgentEvent(event: AgentEvent): Promise<void> {
    const queueRestore = this.#queueRestoreCancellation
    if (
      queueRestore.type === "awaiting_synthetic_failure" &&
      event.type === "message_start" &&
      event.message.role === "assistant"
    ) {
      this.#queueRestoreCancellation = {
        type: "suppressing_synthetic_failure",
        runId: queueRestore.runId,
        message: event.message
      }
      return
    }
    if (queueRestore.type === "suppressing_synthetic_failure") {
      if (event.type === "message_end" && event.message === queueRestore.message) {
        this.#removeRuntimeMessage(queueRestore.message)
        return
      }
      if (event.type === "turn_end" && event.message === queueRestore.message) return
      if (event.type === "agent_end" && event.messages.includes(queueRestore.message)) {
        const messages: AgentMessage[] = []
        for (const message of event.messages) {
          if (message === queueRestore.message) continue
          if (!isZiAgentMessage(message)) throw new Error("Invalid Zi agent message")
          messages.push(message)
        }
        this.#queueRestoreCancellation = { type: "none" }
        this.#emit({ type: "agent_end", messages, willRetry: false })
        return
      }
    }

    if (event.type === "message_start") {
      const cancellation = this.#cancelledPendingMessages.get(event.message)
      if (cancellation) {
        this.#cancelledPendingMessages.delete(event.message)
        if (cancellation === "restore") {
          const activity = this.#activity
          if (activity.type !== "running" && activity.type !== "aborting") {
            throw new Error("Queue restoration crossed its owning run")
          }
          this.#queueRestoreCancellation = { type: "awaiting_synthetic_failure", runId: activity.runId }
        }
        this.#agent.abort()
        throw new Error("Queued input was cancelled by interruption")
      }
    }
    if (event.type === "message_start" && (event.message.role === "user" || event.message.role === "custom")) {
      this.#removeDelivered(event.message)
    }

    let committedCustomEvent: Extract<AgentEvent, { type: "message_end" }> | undefined
    if (event.type === "message_end") {
      if (!isZiAgentMessage(event.message)) throw new Error("Invalid Zi agent message")
      if (event.message.role === "custom") {
        const input = customMessageInput(event.message)
        let entry: CustomMessageEntry
        try {
          entry = this.sessionManager.appendCustomMessage(input)
        } catch (cause) {
          this.#removeRuntimeMessage(event.message)
          throw cause
        }
        const message = sessionEntryToContextMessage(entry)
        if (message?.role !== "custom" || !isRuntimeCustomMessage(message)) {
          throw new Error("Custom message projection is invalid")
        }
        this.#replaceRuntimeMessage(event.message, message)
        this.#recordCommittedMessage(message)
        this.#emit({ type: "entry_appended", entry })
        committedCustomEvent = { ...event, message }
      } else {
        const entry = this.sessionManager.appendMessage(event.message)
        this.#recordCommittedMessage(entry.message)
        this.#emit({ type: "entry_appended", entry })
      }
    }
    if (event.type === "agent_start") this.#extensionHost?.publishAgentStart()
    if (event.type === "agent_end") {
      const messages: AgentMessage[] = []
      for (const message of event.messages) {
        if (!isZiAgentMessage(message)) throw new Error("Invalid Zi agent message")
        messages.push(message)
      }
      this.#emit({ type: "agent_end", messages, willRetry: this.#willRetryAfterAgentEnd(event) })
    } else if (committedCustomEvent) {
      this.#emit(committedCustomEvent)
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
    const index = this.#pending.findIndex(
      entry =>
        entry.message === message &&
        (entry.type === "custom" && entry.delivery === "nextTurn" ? true : entry.runId === runId)
    )
    if (index < 0) return
    const [entry] = this.#pending.splice(index, 1)
    if (!entry) return
    this.#pendingBytes -= entry.bytes
    this.#emitQueue()
  }

  #detachQueuedInputs(cancellation: PendingMessageCancellation): QueuedInputs {
    const queued = this.#queueSnapshot()
    if (this.#activity.type === "running" || this.#activity.type === "aborting") {
      for (const entry of this.#pending) this.#cancelledPendingMessages.set(entry.message, cancellation)
    }
    this.#pending = []
    this.#pendingBytes = 0
    this.#agent.clearAllQueues()
    return queued
  }

  #queueSnapshot(): QueuedInputs {
    const steering: QueuedInput[] = []
    const followUp: QueuedInput[] = []
    for (const entry of this.#pending) {
      if (entry.type !== "user") continue
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

  #assertCustomStateAppend(): void {
    switch (this.#activity.type) {
      case "idle":
      case "extension_command":
        return
      case "running":
        if (this.#activity.phase.type === "compacting" || this.#activity.phase.type === "compaction_committed") {
          throw new Error("Cannot append custom state while context compaction is active")
        }
        return
      case "aborting":
        throw new Error("Cannot append custom state while the agent is aborting")
      case "compacting":
      case "compaction_committed":
        throw new Error("Cannot append custom state while context compaction is active")
      case "reloading":
        throw new Error("Cannot append custom state while reload is active")
      case "failed":
        throw new Error("Cannot append custom state while the agent is failed")
      case "disposed":
        throw new Error("AgentSession is disposed")
      default:
        return assertNever(this.#activity)
    }
  }

  #assertReloadAdmissible(): void {
    this.#assertIdle("reload")
    if (this.#modelMutation.type !== "none") throw new Error("Cannot reload while a model change is active")
    if (this.#pending.length > 0) throw new Error("Cannot reload while queued input is pending")
    switch (this.#extensionLifecycle.type) {
      case "absent":
      case "started":
        break
      case "unbound":
        throw new Error("Cannot reload before extension lifecycle start")
      case "starting":
      case "shutdown":
      case "disposing":
      case "disposed":
        throw new Error(`Cannot reload while extension lifecycle is ${this.#extensionLifecycle.type}`)
      default:
        return assertNever(this.#extensionLifecycle)
    }
    const host = this.#extensionHost
    if (!host) return
    const status = host.snapshot().status
    if (status !== "disabled" && status !== "ready" && status !== "failed") {
      throw new Error(`Cannot reload while extension host is ${status}`)
    }
  }

  #ownsExtensionCommand(operationId: number): boolean {
    return this.#activity.type === "extension_command" && this.#activity.operationId === operationId
  }

  #ownsReload(operationId: number): boolean {
    return this.#activity.type === "reloading" && this.#activity.operationId === operationId
  }

  #applyQueueModesFromSettings(): void {
    const settings = this.settingsManager.get()
    if (settings.steeringMode !== this.#agent.steeringMode) {
      this.#agent.steeringMode = settings.steeringMode
      this.#emitAll([{ type: "steering_mode_changed", mode: settings.steeringMode }])
    }
    if (settings.followUpMode !== this.#agent.followUpMode) {
      this.#agent.followUpMode = settings.followUpMode
      this.#emitAll([{ type: "follow_up_mode_changed", mode: settings.followUpMode }])
    }
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

function extensionSubagentSnapshot(snapshot: SubagentSnapshot): ExtensionSubagentSnapshot {
  const completion = snapshot.completion
  return Object.freeze({
    name: snapshot.name,
    lifecycle: snapshot.lifecycle,
    resultReady: snapshot.completionDelivery === "durable",
    ...(completion
      ? {
          completion: Object.freeze({
            status: completion.status,
            text: completion.text,
            originalBytes: completion.originalBytes,
            omittedBytes: completion.omittedBytes,
            truncated: completion.truncated,
            durationMs: completion.durationMs,
            ...(completion.reason ? { reason: completion.reason } : {}),
            ...(completion.error ? { error: completion.error } : {})
          })
        }
      : {})
  })
}

function extensionCustomEntry(entry: CustomEntry): ExtensionCustomEntry {
  return Object.freeze({
    id: entry.id,
    timestamp: entry.timestamp,
    customType: entry.customType,
    ...(entry.data === undefined ? {} : { data: structuredClone(entry.data) })
  })
}

function extensionMessageDelivery(delivery: ExtensionMessageDelivery): CustomMessageDelivery {
  switch (delivery) {
    case "append":
    case "trigger_turn":
    case "steer":
    case "follow_up":
    case "next_turn":
      return { type: delivery }
    default:
      return assertNever(delivery)
  }
}

function runtimeCustomMessage(input: CustomMessageInput): RuntimeCustomMessage {
  validateCustomMessageInput(input)
  const content =
    typeof input.content === "string"
      ? input.content
      : input.content.map(part =>
          part.type === "text" ? { type: "text" as const, text: part.text } : cloneImage(part)
        )
  return {
    role: "custom",
    customType: input.customType,
    content,
    display: input.display,
    ...(input.details === undefined ? {} : { details: structuredClone(input.details) }),
    timestamp: Date.now()
  }
}

function customMessageInput(message: Extract<AgentMessage, { role: "custom" }>): CustomMessageInput {
  const input: unknown = {
    customType: message.customType,
    content: message.content,
    display: message.display,
    ...(message.details === undefined ? {} : { details: message.details })
  }
  validateCustomMessageInput(input)
  return input
}

function isRuntimeCustomMessage(message: AgentMessage): message is RuntimeCustomMessage {
  if (message.role !== "custom" || (message.details !== undefined && !isSessionJson(message.details))) return false
  try {
    customMessageInput(message)
    return true
  } catch {
    return false
  }
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
