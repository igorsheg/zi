import { useKeyboard } from "@opentui/react"

import { Prompt } from "./prompt.js"
import { useSession } from "./session-context.js"
import { Transcript } from "./transcript.js"

export function SessionScreen({ onExit }: { onExit: () => void }) {
  const session = useSession()

  useKeyboard(key => {
    if (key.name === "escape" && session.isStreaming) void session.abort()
  })

  return (
    <box flexDirection="column" flexGrow={1} minHeight={0}>
      <Transcript />
      <Prompt onExit={onExit} />
    </box>
  )
}
