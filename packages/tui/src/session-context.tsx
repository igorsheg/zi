import type { AgentSession, AgentSessionEvent } from "@openzi/coding-agent"
import { createContext, type ReactNode, use, useLayoutEffect, useMemo, useReducer } from "react"

interface ActiveToolIdentity {
  id: string
  name: string
  args: unknown
}

export type ActiveTool =
  | (ActiveToolIdentity & { status: "running"; result?: unknown })
  | (ActiveToolIdentity & { status: "done"; result: unknown })
  | (ActiveToolIdentity & { status: "failed"; result: unknown })

interface SessionView {
  session: AgentSession
  activeTools: readonly ActiveTool[]
  transcriptRevision: number
}

interface SessionContextValue extends SessionView {
  renderRevision: number
}

interface SessionRenderState {
  revision: number
  transcriptRevision: number
  tools: Map<string, ActiveTool>
}

const SessionContext = createContext<SessionContextValue | undefined>(undefined)
const maxActiveTools = 64

export function SessionProvider({ session, children }: { session: AgentSession; children: ReactNode }) {
  const [state, dispatch] = useReducer(reduceSessionEvent, { revision: 0, transcriptRevision: 0, tools: new Map() })
  useLayoutEffect(() => session.subscribe(dispatch), [session])

  const value = useMemo(
    () => ({
      session,
      activeTools: [...state.tools.values()],
      renderRevision: state.revision,
      transcriptRevision: state.transcriptRevision
    }),
    [session, state]
  )
  return <SessionContext value={value}>{children}</SessionContext>
}

export function useSessionView(): SessionView {
  const value = use(SessionContext)
  if (!value) throw new Error("useSessionView must be used inside SessionProvider")
  return value
}

export function useSession(): AgentSession {
  return useSessionView().session
}

function reduceSessionEvent(state: SessionRenderState, event: AgentSessionEvent): SessionRenderState {
  let tools = state.tools
  let transcriptRevision = state.transcriptRevision

  switch (event.type) {
    case "tool_execution_start": {
      transcriptRevision++
      if (tools.has(event.toolCallId)) break
      tools = new Map(tools)
      if (tools.size === maxActiveTools) {
        const oldest = tools.keys().next().value
        if (oldest !== undefined) tools.delete(oldest)
      }
      tools.set(event.toolCallId, { id: event.toolCallId, name: event.toolName, args: event.args, status: "running" })
      break
    }
    case "tool_execution_update": {
      transcriptRevision++
      const tool = tools.get(event.toolCallId)
      if (tool?.status !== "running") break
      tools = new Map(tools)
      tools.set(event.toolCallId, { ...tool, result: event.partialResult })
      break
    }
    case "tool_execution_end": {
      transcriptRevision++
      const tool = tools.get(event.toolCallId)
      if (tool?.status !== "running") break
      tools = new Map(tools)
      tools.set(event.toolCallId, { ...tool, result: event.result, status: event.isError ? "failed" : "done" })
      break
    }
    case "message_end":
      transcriptRevision++
      if (event.message.role === "toolResult" && tools.has(event.message.toolCallId)) {
        tools = new Map(tools)
        tools.delete(event.message.toolCallId)
      }
      break
    case "message_start":
    case "message_update":
      transcriptRevision++
      break
    case "agent_start":
    case "agent_end":
    case "turn_start":
    case "turn_end":
    case "agent_settled":
    case "queue_update":
    case "entry_appended":
    case "model_changed":
    case "thinking_level_changed":
      break
    default:
      assertNever(event)
  }

  return { revision: state.revision + 1, transcriptRevision, tools }
}

function assertNever(value: never): never {
  throw new Error(`Unexpected session event: ${String(value)}`)
}
