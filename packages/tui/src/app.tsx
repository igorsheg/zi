import type { AgentSession } from "@openzi/coding-agent"
import { useTerminalDimensions } from "@opentui/react"
import { SessionProvider } from "./session-context.js"
import { SessionScreen } from "./session-screen.js"

export interface AppProps {
  session?: AgentSession
  cwd: string
}

export function App(props: AppProps) {
  const dimensions = useTerminalDimensions()

  return (
    <box width={dimensions.width} height={dimensions.height} flexDirection="column" backgroundColor="#000000">
      {props.session ? (
        <SessionProvider session={props.session}>
          <SessionScreen />
        </SessionProvider>
      ) : (
        <box flexGrow={1} justifyContent="flex-end" flexDirection="column">
          <box
            border
            borderStyle="rounded"
            borderColor="#6E7681"
            backgroundColor="#090E13"
            title={props.cwd}
          >
            <text fg="#7D8590">No model configured. The coding-agent bootstrap is the next vertical slice.</text>
          </box>
        </box>
      )}
    </box>
  )
}
