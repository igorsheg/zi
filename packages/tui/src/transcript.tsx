import { MessageView } from "./message.js"
import { useSessionView } from "./session-context.js"
import { ActiveToolView } from "./tool-block.js"

// Pi messages and provider content blocks are ordered but do not have stable IDs.
/* oxlint-disable react/no-array-index-key */

export function Transcript() {
  const { session, activeTools } = useSessionView()
  const { messages, streamingMessage } = session.state

  return (
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
      {streamingMessage ? <MessageView message={streamingMessage} /> : null}
      {activeTools.map(tool => (
        <ActiveToolView key={tool.id} tool={tool} />
      ))}
    </scrollbox>
  )
}
