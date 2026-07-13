import type { AgentMessage } from "@openzi/coding-agent"
import { TextAttributes } from "@opentui/core"

export function MessageView({ message }: { message: AgentMessage }) {
  switch (message.role) {
    case "user":
      return (
        <box padding={1} flexShrink={0}>
          <text fg="#C9D1D9">{textContent(message.content)}</text>
        </box>
      )
    case "assistant":
      return (
        <box paddingLeft={1} paddingRight={1} flexDirection="column" flexShrink={0}>
          {message.content.map((part, index) => {
            if (part.type === "thinking") {
              return (
                <text key={index} fg="#7D8590" attributes={TextAttributes.ITALIC}>
                  {part.thinking}
                </text>
              )
            }
            if (part.type === "toolCall") {
              return (
                <text key={index} fg="#79C0FF">
                  {part.name} {toolDetail(part.arguments)}
                </text>
              )
            }
            return <text key={index}>{part.text}</text>
          })}
          {message.errorMessage ? <text fg="#F85149">{message.errorMessage}</text> : null}
        </box>
      )
    case "toolResult":
      return (
        <box paddingLeft={1} flexShrink={0}>
          <text fg={message.isError ? "#F85149" : "#7D8590"}>
            {message.toolName} {textContent(message.content)}
          </text>
        </box>
      )
    case "bashExecution":
      return (
        <box paddingLeft={1} flexShrink={0}>
          <text fg={message.exitCode === 0 ? "#7D8590" : "#F85149"}>
            {message.command}\n{message.output}
          </text>
        </box>
      )
    case "custom":
      return message.display ? (
        <box paddingLeft={1} flexShrink={0}>
          <text>{textContent(message.content)}</text>
        </box>
      ) : null
    case "branchSummary":
    case "compactionSummary":
      return (
        <box padding={1} flexShrink={0}>
          <text fg="#7D8590">{message.summary}</text>
        </box>
      )
  }
}

function textContent(content: string | readonly { type: string; text?: string; mimeType?: string }[]): string {
  if (typeof content === "string") return content
  return content.map((part) => part.text ?? (part.mimeType ? `[image: ${part.mimeType}]` : "")).join("\n")
}

function toolDetail(args: Record<string, unknown>): string {
  const value = args.path ?? args.command ?? args.file_path
  return value === undefined ? "" : String(value)
}
