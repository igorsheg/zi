import type {
  AbortedQueuedInputs,
  AgentSession,
  AgentSessionEvent,
  ImageContent,
  PendingInputDelivery,
  QueuedInputs
} from "@openzi/coding-agent"
import { atom, computed, type ReadableAtom } from "nanostores"

interface ActiveToolIdentity {
  readonly id: string
  readonly name: string
  readonly args: unknown
}

export type ActiveTool =
  | (ActiveToolIdentity & { readonly status: "running"; readonly result?: unknown })
  | (ActiveToolIdentity & { readonly status: "done"; readonly result: unknown })
  | (ActiveToolIdentity & { readonly status: "failed"; readonly result: unknown })

export interface PromptSubmission {
  readonly text: string
  readonly images: readonly ImageContent[]
  readonly delivery: PendingInputDelivery
}

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
  restoreQueuedInputs(): QueuedInputs
  abortAndRestoreQueuedInputs(): AbortedQueuedInputs
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
    restoreQueuedInputs() {
      return currentSession().takeQueuedInputs()
    },
    abortAndRestoreQueuedInputs() {
      return currentSession().takeQueuedInputsAndAbort()
    },
    dispose() {
      if (disposed) return
      disposed = true
      unsubscribeSession?.()
      unsubscribeSession = undefined
    }
  }
}

export function initialInteractiveState(session: AgentSession): InteractiveState {
  return { session, generation: 0, promptRevision: 0, transcriptRevision: 0, tools: new Map() }
}

export function transitionInteractiveState(state: InteractiveState, event: AgentSessionEvent): InteractiveState {
  let tools = state.tools
  let promptRevision = state.promptRevision
  let transcriptRevision = state.transcriptRevision

  switch (event.type) {
    case "tool_execution_start": {
      transcriptRevision++
      if (tools.has(event.toolCallId)) break
      const nextTools = new Map(tools)
      if (nextTools.size === maxActiveTools) {
        const oldest = nextTools.keys().next().value
        if (oldest !== undefined) nextTools.delete(oldest)
      }
      nextTools.set(event.toolCallId, {
        id: event.toolCallId,
        name: event.toolName,
        args: event.args,
        status: "running"
      })
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
    case "message_end":
      transcriptRevision++
      if (event.message.role === "toolResult" && tools.has(event.message.toolCallId)) {
        const nextTools = new Map(tools)
        nextTools.delete(event.message.toolCallId)
        tools = nextTools
      }
      break
    case "message_start":
    case "message_update":
      transcriptRevision++
      break
    case "agent_start":
    case "agent_end":
    case "agent_settled":
    case "queue_update":
    case "authentication_changed":
    case "model_changed":
    case "thinking_level_changed":
    case "steering_mode_changed":
    case "follow_up_mode_changed":
      promptRevision++
      break
    case "turn_start":
    case "turn_end":
    case "entry_appended":
      break
    default:
      assertNever(event)
  }

  return { session: state.session, generation: state.generation, promptRevision, transcriptRevision, tools }
}

function assertNever(value: never): never {
  throw new Error(`Unexpected interactive event: ${String(value)}`)
}
