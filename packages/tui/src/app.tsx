import { useTerminalDimensions } from "@opentui/react"
import type { AgentSession } from "@openzi/coding-agent"

import { SessionProvider } from "./session-context.js"
import { SessionScreen } from "./session-screen.js"
import { ThemeProvider, useTheme, ziTheme } from "./theme.js"

export interface AppProps {
  session: AgentSession
  onExit: () => void
}

export function App({ session, onExit }: AppProps) {
  return (
    <ThemeProvider theme={ziTheme}>
      <AppSurface>
        <SessionProvider key={session.sessionId} session={session}>
          <SessionScreen onExit={onExit} />
        </SessionProvider>
      </AppSurface>
    </ThemeProvider>
  )
}

function AppSurface({ children }: { children: React.ReactNode }) {
  const { width, height } = useTerminalDimensions()
  const theme = useTheme()

  return (
    <box width={width} height={height} flexDirection="column" backgroundColor={theme.surface.app}>
      {children}
    </box>
  )
}
