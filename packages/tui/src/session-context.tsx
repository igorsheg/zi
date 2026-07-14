import type { AgentSession, AgentSessionEvent } from "@openzi/coding-agent"
import { createContext, type ReactNode, use, useLayoutEffect, useMemo, useReducer } from "react"

export interface ActiveTool {
  id: string
  name: string
  args: unknown
  result?: unknown
  status: "running" | "done" | "failed"
}

interface SessionView {
  session: AgentSession
  activeTools: readonly ActiveTool[]
}

interface SessionContextValue extends SessionView {
  renderRevision: number
}

interface SessionRenderState {
  revision: number
  tools: Map<string, ActiveTool>
}

const SessionContext = createContext<SessionContextValue | undefined>(undefined)
const maxActiveTools = 64

export function SessionProvider({ session, children }: { session: AgentSession; children: ReactNode }) {
  const [state, dispatch] = useReducer(reduceSessionEvent, { revision: 0, tools: new Map() })
  useLayoutEffect(() => session.subscribe(dispatch), [session])

  const value = useMemo(
    () => ({ session, activeTools: [...state.tools.values()], renderRevision: state.revision }),
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

  if (event.type === "tool_execution_start") {
    tools = new Map(tools)
    if (!tools.has(event.toolCallId) && tools.size === maxActiveTools) {
      const oldest = tools.keys().next().value
      if (oldest !== undefined) tools.delete(oldest)
    }
    tools.set(event.toolCallId, { id: event.toolCallId, name: event.toolName, args: event.args, status: "running" })
  } else if (event.type === "tool_execution_update") {
    const tool = tools.get(event.toolCallId)
    if (tool) {
      tools = new Map(tools)
      tools.set(event.toolCallId, { ...tool, result: event.partialResult })
    }
  } else if (event.type === "tool_execution_end") {
    const tool = tools.get(event.toolCallId)
    if (tool) {
      tools = new Map(tools)
      tools.set(event.toolCallId, { ...tool, result: event.result, status: event.isError ? "failed" : "done" })
    }
  } else if (
    event.type === "message_end" &&
    event.message.role === "toolResult" &&
    tools.has(event.message.toolCallId)
  ) {
    tools = new Map(tools)
    tools.delete(event.message.toolCallId)
  }

  return { revision: state.revision + 1, tools }
}
