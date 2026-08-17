import type {
  AbortedQueuedInputs,
  AgentSession,
  AgentSessionEvent,
  ImageContent,
  PendingInputDelivery,
  QueuedInputs,
  ShellDemotionResult
} from "@with-zi/coding-agent"
import { atom, computed, type ReadableAtom } from "nanostores"

interface ActiveToolIdentity {
  readonly id: string
  readonly name: string
  readonly args: unknown
}

export type ActiveTool =
  | (ActiveToolIdentity & { readonly status: "preparing" })
  | (ActiveToolIdentity & { readonly status: "ready" })
  | (ActiveToolIdentity & { readonly status: "running"; readonly result?: unknown })
  | (ActiveToolIdentity & { readonly status: "done"; readonly result: unknown })
  | (ActiveToolIdentity & { readonly status: "failed"; readonly result: unknown })
  | (ActiveToolIdentity & { readonly status: "aborted"; readonly result: unknown })

export interface TranscriptProjectionState {
  readonly promptRevision: number
  readonly transcriptRevision: number
  readonly tools: ReadonlyMap<string, ActiveTool>
}

export interface PromptSubmission {
  readonly text: string
  readonly images: readonly ImageContent[]
  readonly delivery: PendingInputDelivery
}

export type InterruptSubmission = Omit<PromptSubmission, "delivery">

export type AutomaticCompactionNoticeEvent =
  | { readonly type: "failed"; readonly message: string }
  | { readonly type: "completed" }

export interface InteractiveState {
  readonly session: AgentSession
  readonly generation: number
  readonly promptRevision: number
  readonly transcriptRevision: number
  readonly tools: ReadonlyMap<string, ActiveTool>
}

export interface InteractiveStore {
  readonly $state: ReadableAtom<InteractiveState>
  readonly $generation: ReadableAtom<number>
  readonly $promptRevision: ReadableAtom<number>
  readonly $transcriptRevision: ReadableAtom<number>
  readonly $activeTools: ReadableAtom<ReadonlyMap<string, ActiveTool>>
  getSession(): AgentSession
  replaceSession(session: AgentSession): void
  submit(submission: PromptSubmission): Promise<void>
  interruptAndSubmit(submission: InterruptSubmission): Promise<void>
  restoreQueuedInputs(): QueuedInputs
  abortAndRestoreQueuedInputs(): AbortedQueuedInputs
  backgroundForegroundShellTask(): ShellDemotionResult
  subscribeAutomaticCompaction(listener: (event: AutomaticCompactionNoticeEvent) => void): () => void
  dispose(): void
}

const maxActiveTools = 64

export function createInteractiveStore(session: AgentSession): InteractiveStore {
  const $state = atom(initialInteractiveState(session))
  const $generation = computed($state, state => state.generation)
  const $promptRevision = computed($state, state => state.promptRevision)
  const $transcriptRevision = computed($state, state => state.transcriptRevision)
  const $activeTools = computed($state, state => state.tools)
  let unsubscribeSession: (() => void) | undefined
  const automaticCompactionListeners = new Set<(event: AutomaticCompactionNoticeEvent) => void>()
  let disposed = false

  const currentSession = (): AgentSession => {
    if (disposed) throw new Error("InteractiveStore is disposed")
    return $state.get().session
  }

  const subscribeSession = (activeSession: AgentSession) =>
    activeSession.subscribe(event => {
      if (disposed || activeSession !== $state.get().session) return
      const current = $state.get()
      const next = transitionInteractiveState(current, event)
      if (next !== current) $state.set(next)
      if (event.type === "compaction_end") {
        const noticeEvent = compactionNoticeEvent(event)
        if (noticeEvent) {
          for (const listener of automaticCompactionListeners) {
            try {
              listener(noticeEvent)
            } catch {
              // Presentation observers cannot change the admitted session transition.
            }
          }
        }
      }
    })
  unsubscribeSession = subscribeSession(session)

  return {
    $state,
    $generation,
    $promptRevision,
    $transcriptRevision,
    $activeTools,
    getSession() {
      return $state.get().session
    },
    replaceSession(nextSession) {
      if (disposed) throw new Error("InteractiveStore is disposed")
      const state = $state.get()
      if (nextSession === state.session) return
      const release = subscribeSession(nextSession)
      unsubscribeSession?.()
      unsubscribeSession = release
      $state.set({
        session: nextSession,
        generation: state.generation + 1,
        promptRevision: 0,
        transcriptRevision: 0,
        tools: new Map()
      })
    },
    submit({ text, images, delivery }) {
      const activeSession = currentSession()
      return activeSession.prompt(text, {
        ...(images.length === 0 ? {} : { images: [...images] }),
        ...(activeSession.isStreaming ? { streamingBehavior: delivery } : {})
      })
    },
    interruptAndSubmit({ text, images }) {
      return currentSession().interruptAndPrompt(text, images.length === 0 ? undefined : [...images])
    },
    restoreQueuedInputs() {
      return currentSession().takeQueuedInputs()
    },
    abortAndRestoreQueuedInputs() {
      return currentSession().takeQueuedInputsAndAbort()
    },
    backgroundForegroundShellTask() {
      return currentSession().demoteForegroundShellTask()
    },
    subscribeAutomaticCompaction(listener) {
      if (disposed) throw new Error("InteractiveStore is disposed")
      automaticCompactionListeners.add(listener)
      return () => automaticCompactionListeners.delete(listener)
    },
    dispose() {
      if (disposed) return
      disposed = true
      unsubscribeSession?.()
      unsubscribeSession = undefined
      automaticCompactionListeners.clear()
    }
  }
}

export function compactionNoticeEvent(event: AgentSessionEvent): AutomaticCompactionNoticeEvent | undefined {
  if (event.type !== "compaction_end") return undefined
  if (event.outcome.type === "completed") return { type: "completed" }
  if (event.reason !== "manual" && event.outcome.type === "failed") {
    return { type: "failed", message: event.outcome.message }
  }
  return undefined
}

export function initialInteractiveState(session: AgentSession): InteractiveState {
  return { session, generation: 0, promptRevision: 0, transcriptRevision: 0, tools: new Map() }
}

export function transitionInteractiveState(state: InteractiveState, event: AgentSessionEvent): InteractiveState {
  const projection = transitionTranscriptProjection(state, event)
  return { session: state.session, generation: state.generation, ...projection }
}

export function transitionTranscriptProjection(
  state: TranscriptProjectionState,
  event: AgentSessionEvent
): TranscriptProjectionState {
  let tools = state.tools
  let promptRevision = state.promptRevision
  let transcriptRevision = state.transcriptRevision

  switch (event.type) {
    case "tool_execution_start": {
      transcriptRevision++
      const tool = tools.get(event.toolCallId)
      if (tool?.status === "running") break
      const nextTools = new Map(tools)
      admitTool(nextTools, { id: event.toolCallId, name: event.toolName, args: event.args, status: "running" })
      tools = nextTools
      break
    }
    case "tool_execution_update": {
      transcriptRevision++
      const tool = tools.get(event.toolCallId)
      if (tool?.status !== "running") break
      const nextTools = new Map(tools)
      nextTools.set(event.toolCallId, { ...tool, result: event.partialResult })
      tools = nextTools
      break
    }
    case "tool_execution_end": {
      transcriptRevision++
      const tool = tools.get(event.toolCallId)
      if (tool?.status !== "running") break
      const nextTools = new Map(tools)
      nextTools.set(event.toolCallId, { ...tool, result: event.result, status: event.isError ? "failed" : "done" })
      tools = nextTools
      break
    }
    case "message_update":
      transcriptRevision++
      tools = updatePreparingTool(tools, event)
      break
    case "message_end":
      promptRevision++
      transcriptRevision++
      if (event.message.role === "assistant") {
        tools = completeToolArguments(tools, event.message)
      } else if (event.message.role === "toolResult" && tools.has(event.message.toolCallId)) {
        const nextTools = new Map(tools)
        nextTools.delete(event.message.toolCallId)
        tools = nextTools
      }
      break
    case "message_start":
      transcriptRevision++
      break
    case "agent_end":
      promptRevision++
      if ([...tools.values()].some(tool => !isTerminalTool(tool))) {
        const nextTools = new Map(tools)
        for (const [id, tool] of nextTools) {
          if (isTerminalTool(tool)) continue
          nextTools.set(id, {
            ...tool,
            status: "aborted",
            result: { content: [{ type: "text", text: "Operation aborted" }] }
          })
        }
        tools = nextTools
        transcriptRevision++
      }
      break
    case "compaction_end":
      promptRevision++
      if (event.outcome.type === "completed") {
        tools = new Map()
        transcriptRevision++
      }
      break
    case "agent_start":
    case "agent_settled":
    case "auto_retry_start":
    case "auto_retry_end":
    case "summarization_retry_scheduled":
    case "summarization_retry_attempt_start":
    case "summarization_retry_finished":
    case "compaction_start":
    case "compaction_enabled_changed":
    case "retry_enabled_changed":
    case "codex_fast_mode_changed":
    case "queue_update":
    case "authentication_changed":
    case "model_changed":
    case "thinking_level_changed":
    case "steering_mode_changed":
    case "follow_up_mode_changed":
    case "shell_task_changed":
    case "agent_changed":
    case "work_plan_changed":
      promptRevision++
      break
    case "turn_start":
    case "turn_end":
    case "entry_appended":
    case "mcp_server_changed":
      break
    default:
      assertNever(event)
  }

  return { promptRevision, transcriptRevision, tools }
}

function updatePreparingTool(
  tools: ReadonlyMap<string, ActiveTool>,
  event: Extract<AgentSessionEvent, { type: "message_update" }>
): ReadonlyMap<string, ActiveTool> {
  const update = event.assistantMessageEvent
  if (update.type !== "toolcall_start" && update.type !== "toolcall_delta" && update.type !== "toolcall_end") {
    return tools
  }
  if (event.message.role !== "assistant") return tools
  const call = event.message.content[update.contentIndex]
  if (call?.type !== "toolCall" || !call.id) return tools

  const current = tools.get(call.id)
  if (current && current.status !== "preparing" && current.status !== "ready") return tools
  const nextTools = new Map(tools)
  admitTool(nextTools, { id: call.id, name: call.name, args: call.arguments, status: "preparing" })
  return nextTools
}

function completeToolArguments(
  tools: ReadonlyMap<string, ActiveTool>,
  message: Extract<AgentSessionEvent, { type: "message_end" }>["message"] & { role: "assistant" }
): ReadonlyMap<string, ActiveTool> {
  const calls = message.content.filter(part => part.type === "toolCall")
  if (calls.length === 0) return tools

  const nextTools = new Map(tools)
  const failed = message.stopReason === "error" || message.stopReason === "aborted"
  for (const call of calls) {
    if (!call.id) continue
    const current = nextTools.get(call.id)
    if (current && current.status !== "preparing" && current.status !== "ready") continue
    if (failed) {
      const text = message.stopReason === "aborted" ? "Operation aborted" : message.errorMessage || "Error"
      admitTool(nextTools, {
        id: call.id,
        name: call.name,
        args: call.arguments,
        status: message.stopReason === "aborted" ? "aborted" : "failed",
        result: { content: [{ type: "text", text }] }
      })
    } else {
      admitTool(nextTools, { id: call.id, name: call.name, args: call.arguments, status: "ready" })
    }
  }
  return nextTools
}

function admitTool(tools: Map<string, ActiveTool>, tool: ActiveTool): void {
  if (!tools.has(tool.id) && tools.size === maxActiveTools) {
    const oldest = tools.keys().next().value
    if (oldest !== undefined) tools.delete(oldest)
  }
  tools.set(tool.id, tool)
}

function isTerminalTool(tool: ActiveTool): boolean {
  return tool.status === "done" || tool.status === "failed" || tool.status === "aborted"
}

function assertNever(value: never): never {
  throw new Error(`Unexpected interactive event: ${String(value)}`)
}
