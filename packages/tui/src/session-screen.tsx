import { useKeyboard } from "@opentui/react"
import { MessageView } from "./message.js"
import { Prompt } from "./prompt.js"
import { useSession } from "./session-context.js"

export function SessionScreen() {
  const session = useSession()
  const state = session.state
  const messages = state.streamingMessage ? [...state.messages, state.streamingMessage] : state.messages

  useKeyboard((key) => {
    if (key.name === "escape" && session.isStreaming) void session.abort()
  })

  return (
    <box flexDirection="column" flexGrow={1} minHeight={0}>
      <scrollbox
        flexGrow={1}
        minHeight={0}
        stickyScroll
        stickyStart="bottom"
        viewportCulling
        scrollbarOptions={{ visible: false }}
      >
        {messages.map((message, index) => (
          <MessageView key={`${message.timestamp}-${index}`} message={message} />
        ))}
      </scrollbox>
      <Prompt />
    </box>
  )
}
