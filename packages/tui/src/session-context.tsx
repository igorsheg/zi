import type { AgentSession } from "@openzi/coding-agent"
import { createContext, type ReactNode, use, useEffect, useMemo, useReducer } from "react"

interface SessionContextValue {
  session: AgentSession
  revision: number
}

const SessionContext = createContext<SessionContextValue | undefined>(undefined)

export function SessionProvider(props: { session: AgentSession; children: ReactNode }) {
  const [revision, changed] = useReducer((value: number) => value + 1, 0)

  useEffect(() => props.session.subscribe(changed), [props.session])

  const value = useMemo(() => ({ session: props.session, revision }), [props.session, revision])
  return <SessionContext value={value}>{props.children}</SessionContext>
}

export function useSession(): AgentSession {
  const value = use(SessionContext)
  if (!value) throw new Error("useSession must be used inside SessionProvider")
  return value.session
}
