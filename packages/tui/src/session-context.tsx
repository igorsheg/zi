import type { AgentSession, AgentSessionEvent } from "@openzi/coding-agent"
import { createContext, type ReactNode, use, useEffect, useMemo, useReducer } from "react"

export interface ToolExecution {
  id: string
  name: string
  args: unknown
  result?: unknown
  status: "running" | "done" | "failed"
}

interface SessionView {
  session: AgentSession
  tools: readonly ToolExecution[]
}

interface ViewState {
  tools: Map<string, ToolExecution>
}

const SessionContext = createContext<SessionView | undefined>(undefined)

export function SessionProvider(props: { session: AgentSession; children: ReactNode }) {
  const [state, dispatch] = useReducer(reduce, { tools: new Map() })
  useEffect(() => props.session.subscribe(dispatch), [props.session])
  const value = useMemo(() => ({ session: props.session, tools: [...state.tools.values()] }), [props.session, state])
  return <SessionContext value={value}>{props.children}</SessionContext>
}

export function useSessionView(): SessionView {
  const value = use(SessionContext)
  if (!value) throw new Error("useSessionView must be used inside SessionProvider")
  return value
}

export function useSession(): AgentSession {
  return useSessionView().session
}

function reduce(state: ViewState, event: AgentSessionEvent): ViewState {
  const tools = new Map(state.tools)
  if (event.type === "tool_execution_start") {
    tools.set(event.toolCallId, { id: event.toolCallId, name: event.toolName, args: event.args, status: "running" })
  } else if (event.type === "tool_execution_update") {
    const tool = tools.get(event.toolCallId)
    if (tool) tools.set(event.toolCallId, { ...tool, result: event.partialResult })
  } else if (event.type === "tool_execution_end") {
    const tool = tools.get(event.toolCallId)
    if (tool) {
      tools.set(event.toolCallId, { ...tool, result: event.result, status: event.isError ? "failed" : "done" })
    }
  } else if (event.type === "message_end" && event.message.role === "toolResult") {
    tools.delete(event.message.toolCallId)
  }
  return { tools }
}
