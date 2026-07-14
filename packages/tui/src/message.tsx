import { CodeRenderable, type MarkdownOptions, StyledText, TextAttributes } from "@opentui/core"
import type { AgentMessage } from "@openzi/coding-agent"

import { useSyntaxStyle, useTheme } from "./theme.js"
import { CommandToolBlock, formatToolTitle, ReadToolBlock, ToolBlock } from "./tool-block.js"

// Provider content blocks are ordered and append-only; text and thinking blocks have no IDs.
/* oxlint-disable react/no-array-index-key */

// OpenTUI 0.4.3 drops the trailing block when streaming is false; pinned OpenCode also keeps it enabled.
const markdownStreamingWorkaround = true
const renderMarkdownNode: NonNullable<MarkdownOptions["renderNode"]> = (token, context) => {
  if (token.type !== "heading") return null
  const renderable = context.defaultRender()
  if (!(renderable instanceof CodeRenderable)) return renderable
  const style = context.syntaxStyle.getStyle("markup.heading")
  renderable.initialStyledText = new StyledText([
    {
      __isChunk: true,
      text: token.text,
      ...(style?.fg === undefined ? {} : { fg: style.fg }),
      ...(style?.bg === undefined ? {} : { bg: style.bg }),
      attributes: TextAttributes.BOLD
    }
  ])
  return renderable
}

export function MessageView({ message }: { message: AgentMessage }) {
  switch (message.role) {
    case "user":
      return <UserMessage message={message} />
    case "assistant":
      return <AssistantMessage message={message} />
    case "toolResult":
      return <ToolResultView message={message} />
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
  return assertNever(message)
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
  const visible = message.content.some(part =>
    part.type === "thinking" ? part.thinking.trim().length > 0 : part.type === "text" && part.text.trim().length > 0
  )
  return (
    <box
      paddingLeft={1}
      paddingRight={1}
      marginBottom={visible || message.errorMessage ? 1 : 0}
      flexDirection="column"
      flexShrink={0}>
      {message.content.map((part, index) => {
        if (part.type === "thinking") {
          const followedByAnswer = message.content
            .slice(index + 1)
            .some(candidate => candidate.type === "text" && candidate.text.trim().length > 0)
          return (
            <box key={index} flexShrink={0} marginBottom={followedByAnswer ? 1 : 0}>
              <text fg={theme.text.thinking} attributes={TextAttributes.ITALIC}>
                {part.thinking.trimEnd()}
              </text>
            </box>
          )
        }
        if (part.type === "toolCall") return null
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
              renderNode={renderMarkdownNode}
            />
          </box>
        ) : null
      })}
      {message.errorMessage ? <text fg={theme.text.error}>{message.errorMessage}</text> : null}
    </box>
  )
}

type ToolResultAgentMessage = Extract<AgentMessage, { role: "toolResult" }>

export interface ToolCallPresentation {
  name: string
  args: unknown
}

export function ToolResultView({
  message,
  call
}: {
  message: ToolResultAgentMessage
  call?: ToolCallPresentation | undefined
}) {
  const name = call?.name ?? message.toolName
  const props = {
    title: formatToolTitle(name, call?.args),
    output: textContent(message.content),
    status: message.isError ? ("failed" as const) : ("done" as const)
  }

  if (name === "bash") return <CommandToolBlock {...props} />
  if (name === "read") return <ReadToolBlock {...props} />
  return <ToolBlock {...props} />
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

function assertNever(value: never): never {
  throw new Error(`Unexpected message: ${String(value)}`)
}
