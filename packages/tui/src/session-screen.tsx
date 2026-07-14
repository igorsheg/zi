import { useKeyboard } from "@opentui/react"

import { MessageView } from "./message.js"
import { Prompt } from "./prompt.js"
import { useSessionView } from "./session-context.js"
import { ToolExecutionView } from "./tool-execution.js"

// Transcript messages are append-only; pi messages do not have stable IDs.
/* oxlint-disable react/no-array-index-key */

export function SessionScreen() {
  const { session, tools } = useSessionView()
  const state = session.state
  const messages = state.streamingMessage ? [...state.messages, state.streamingMessage] : state.messages

  useKeyboard(key => {
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
        scrollbarOptions={{ visible: false }}>
        {messages.map((message, index) => (
          <MessageView key={`${message.role}-${message.timestamp}-${index}`} message={message} />
        ))}
        {tools.map(tool => (
          <ToolExecutionView key={tool.id} tool={tool} />
        ))}
      </scrollbox>
      <Prompt />
    </box>
  )
}
