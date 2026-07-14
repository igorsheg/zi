import type { AgentMessage } from "@openzi/coding-agent"

import { MessageView, type ToolCallPresentation, ToolResultView } from "./message.js"
import { useSessionView } from "./session-context.js"
import { ActiveToolView } from "./tool-block.js"

// Pi messages and provider content blocks are ordered but do not have stable IDs.
/* oxlint-disable react/no-array-index-key */

export function Transcript() {
  const { session, activeTools } = useSessionView()
  const { messages, streamingMessage } = session.state
  const toolCalls = collectToolCalls(messages, streamingMessage)

  return (
    <scrollbox
      flexGrow={1}
      minHeight={0}
      stickyScroll
      stickyStart="bottom"
      viewportCulling
      scrollbarOptions={{ visible: false }}>
      {messages.map((message, index) => (
        <TranscriptMessage
          key={`${message.role}-${message.timestamp}-${index}`}
          message={message}
          toolCalls={toolCalls}
        />
      ))}
      {streamingMessage ? <MessageView message={streamingMessage} /> : null}
      {activeTools.map(tool => (
        <ActiveToolView key={tool.id} tool={tool} />
      ))}
    </scrollbox>
  )
}

function TranscriptMessage({
  message,
  toolCalls
}: {
  message: AgentMessage
  toolCalls: ReadonlyMap<string, ToolCallPresentation>
}) {
  return message.role === "toolResult" ? (
    <ToolResultView message={message} call={toolCalls.get(message.toolCallId)} />
  ) : (
    <MessageView message={message} />
  )
}

function collectToolCalls(
  messages: readonly AgentMessage[],
  streamingMessage: AgentMessage | undefined
): ReadonlyMap<string, ToolCallPresentation> {
  const calls = new Map<string, ToolCallPresentation>()
  for (const message of messages) collectAssistantToolCalls(calls, message)
  if (streamingMessage) collectAssistantToolCalls(calls, streamingMessage)
  return calls
}

function collectAssistantToolCalls(calls: Map<string, ToolCallPresentation>, message: AgentMessage): void {
  if (message.role !== "assistant") return
  for (const part of message.content) {
    if (part.type === "toolCall") calls.set(part.id, { name: part.name, args: part.arguments })
  }
}
