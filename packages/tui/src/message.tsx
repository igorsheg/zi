import { TextAttributes } from "@opentui/core"
import type { AgentMessage } from "@openzi/coding-agent"

import { useSyntaxStyle, useTheme } from "./theme.js"
import { CommandToolBlock, ToolBlock } from "./tool-block.js"

// Provider content blocks are ordered and append-only; text and thinking blocks have no IDs.
/* oxlint-disable react/no-array-index-key */

// OpenTUI 0.4.3 drops the trailing block when streaming is false; pinned OpenCode also keeps it enabled.
const markdownStreamingWorkaround = true

export function MessageView({ message }: { message: AgentMessage }) {
  switch (message.role) {
    case "user":
      return <UserMessage message={message} />
    case "assistant":
      return <AssistantMessage message={message} />
    case "toolResult":
      return (
        <ToolBlock
          title={message.toolName}
          output={textContent(message.content)}
          status={message.isError ? "failed" : "done"}
        />
      )
    case "bashExecution":
      return (
        <CommandToolBlock
          title={`$ ${message.command}`}
          output={message.output}
          status={message.exitCode === 0 ? "done" : "failed"}
        />
      )
    case "custom":
      return message.display ? <CustomMessage content={textContent(message.content)} /> : null
    case "branchSummary":
    case "compactionSummary":
      return <SummaryMessage summary={message.summary} />
  }
  return null
}

type UserAgentMessage = Extract<AgentMessage, { role: "user" }>

function UserMessage({ message }: { message: UserAgentMessage }) {
  const theme = useTheme()
  return (
    <box
      width="100%"
      paddingTop={1}
      paddingBottom={1}
      paddingLeft={1}
      paddingRight={1}
      marginBottom={1}
      backgroundColor={theme.surface.userMessage}
      flexShrink={0}>
      <text fg={theme.text.primary}>{textContent(message.content)}</text>
    </box>
  )
}

type AssistantAgentMessage = Extract<AgentMessage, { role: "assistant" }>

function AssistantMessage({ message }: { message: AssistantAgentMessage }) {
  const theme = useTheme()
  const syntaxStyle = useSyntaxStyle()
  return (
    <box
      paddingLeft={1}
      paddingRight={1}
      marginBottom={message.content.length > 0 || message.errorMessage ? 1 : 0}
      flexDirection="column"
      flexShrink={0}>
      {message.content.map((part, index) => {
        if (part.type === "thinking") {
          return (
            <text key={index} fg={theme.text.thinking} attributes={TextAttributes.ITALIC}>
              {part.thinking}
            </text>
          )
        }
        if (part.type === "toolCall") {
          return (
            <text key={part.id} fg={theme.text.primary}>
              {part.name} {toolDetail(part.arguments)}
            </text>
          )
        }
        return part.text.trim() ? (
          <box key={index} flexShrink={0}>
            <markdown
              content={part.text.trim()}
              syntaxStyle={syntaxStyle}
              fg={theme.text.primary}
              bg={theme.surface.app}
              conceal
              streaming={markdownStreamingWorkaround}
              internalBlockMode="top-level"
              tableOptions={{ style: "grid" }}
            />
          </box>
        ) : null
      })}
      {message.errorMessage ? <text fg={theme.text.error}>{message.errorMessage}</text> : null}
    </box>
  )
}

function CustomMessage({ content }: { content: string }) {
  const theme = useTheme()
  return (
    <box
      paddingTop={1}
      paddingBottom={1}
      paddingLeft={1}
      paddingRight={1}
      marginBottom={1}
      backgroundColor={theme.surface.panel}
      flexShrink={0}>
      <text fg={theme.text.custom}>{content}</text>
    </box>
  )
}

function SummaryMessage({ summary }: { summary: string }) {
  const theme = useTheme()
  return (
    <box
      paddingTop={1}
      paddingBottom={1}
      paddingLeft={1}
      paddingRight={1}
      marginBottom={1}
      backgroundColor={theme.surface.panel}
      flexShrink={0}>
      <text fg={theme.text.muted}>{summary}</text>
    </box>
  )
}

function textContent(content: string | readonly { type: string; text?: string; mimeType?: string }[]): string {
  if (typeof content === "string") return content
  return content.map(part => part.text ?? (part.mimeType ? `[image: ${part.mimeType}]` : "")).join("\n")
}

function toolDetail(args: Record<string, unknown>): string {
  return displayValue(args.path ?? args.command ?? args.file_path)
}

function displayValue(value: unknown): string {
  if (typeof value === "string") return value
  if (typeof value === "number" || typeof value === "boolean") return String(value)
  return ""
}
