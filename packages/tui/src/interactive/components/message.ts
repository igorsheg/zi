import {
  BoxRenderable,
  CodeRenderable,
  MarkdownRenderable,
  type MarkdownOptions,
  type Renderable,
  StyledText,
  type SyntaxStyle,
  TextAttributes,
  TextRenderable,
  type RenderContext
} from "@opentui/core"
import type { AgentMessage } from "@openzi/coding-agent"

import type { Theme } from "../../theme.js"
import { createCommandToolBlock, createReadToolBlock, createToolBlock, formatToolTitle } from "./tool-block.js"

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

export interface MessageRenderOptions {
  readonly theme: Theme
  readonly syntaxStyle: SyntaxStyle
  readonly toolCall?: ToolCallPresentation
}

export interface ToolCallPresentation {
  readonly name: string
  readonly args: unknown
}

export function createMessageView(
  ctx: RenderContext,
  message: AgentMessage,
  options: MessageRenderOptions
): Renderable | undefined {
  switch (message.role) {
    case "user":
      return createUserMessage(ctx, textContent(message.content), options.theme)
    case "assistant":
      return createAssistantMessage(ctx, message, options.theme, options.syntaxStyle)
    case "toolResult":
      return createToolResultView(ctx, message, options.toolCall, options.theme)
    case "bashExecution":
      return createCommandToolBlock(
        ctx,
        { title: `$ ${message.command}`, output: message.output, status: message.exitCode === 0 ? "done" : "failed" },
        options.theme
      )
    case "custom":
      return message.display
        ? createPanelMessage(ctx, textContent(message.content), options.theme.text.custom, options.theme)
        : undefined
    case "branchSummary":
    case "compactionSummary":
      return createPanelMessage(ctx, message.summary, options.theme.text.muted, options.theme)
    default:
      return assertNever(message)
  }
}

function createUserMessage(ctx: RenderContext, content: string, theme: Theme): BoxRenderable {
  const root = new BoxRenderable(ctx, {
    width: "100%",
    paddingTop: 1,
    paddingBottom: 1,
    paddingLeft: 1,
    paddingRight: 1,
    marginBottom: 1,
    backgroundColor: theme.surface.userMessage,
    flexShrink: 0
  })
  root.add(new TextRenderable(ctx, { fg: theme.text.primary, content }))
  return root
}

type AssistantMessage = Extract<AgentMessage, { role: "assistant" }>

function createAssistantMessage(
  ctx: RenderContext,
  message: AssistantMessage,
  theme: Theme,
  syntaxStyle: SyntaxStyle
): BoxRenderable {
  const visible = message.content.some(part =>
    part.type === "thinking" ? part.thinking.trim().length > 0 : part.type === "text" && part.text.trim().length > 0
  )
  const root = new BoxRenderable(ctx, {
    paddingLeft: 1,
    paddingRight: 1,
    marginBottom: visible || message.errorMessage ? 1 : 0,
    flexDirection: "column",
    flexShrink: 0
  })

  for (let index = 0; index < message.content.length; index++) {
    const part = message.content[index]
    if (!part) continue
    if (part.type === "thinking") {
      const followedByAnswer = message.content
        .slice(index + 1)
        .some(candidate => candidate.type === "text" && candidate.text.trim().length > 0)
      const block = new BoxRenderable(ctx, { flexShrink: 0, marginBottom: followedByAnswer ? 1 : 0 })
      block.add(
        new TextRenderable(ctx, {
          fg: theme.text.thinking,
          attributes: TextAttributes.ITALIC,
          content: part.thinking.trimEnd()
        })
      )
      root.add(block)
      continue
    }
    if (part.type === "toolCall" || !part.text.trim()) continue
    const block = new BoxRenderable(ctx, { flexShrink: 0 })
    block.add(
      new MarkdownRenderable(ctx, {
        content: part.text.trim(),
        syntaxStyle,
        fg: theme.text.primary,
        bg: theme.surface.app,
        conceal: true,
        streaming: markdownStreamingWorkaround,
        internalBlockMode: "top-level",
        tableOptions: { style: "grid" },
        renderNode: renderMarkdownNode
      })
    )
    root.add(block)
  }

  if (message.errorMessage) {
    root.add(new TextRenderable(ctx, { fg: theme.text.error, content: message.errorMessage }))
  }
  return root
}

type ToolResultMessage = Extract<AgentMessage, { role: "toolResult" }>

function createToolResultView(
  ctx: RenderContext,
  message: ToolResultMessage,
  call: ToolCallPresentation | undefined,
  theme: Theme
): BoxRenderable {
  const name = call?.name ?? message.toolName
  const options = {
    title: formatToolTitle(name, call?.args),
    output: textContent(message.content),
    status: message.isError ? ("failed" as const) : ("done" as const)
  }

  if (name === "bash") return createCommandToolBlock(ctx, options, theme)
  if (name === "read") return createReadToolBlock(ctx, options, theme)
  return createToolBlock(ctx, options, theme)
}

function createPanelMessage(ctx: RenderContext, content: string, color: string, theme: Theme): BoxRenderable {
  const root = new BoxRenderable(ctx, {
    paddingTop: 1,
    paddingBottom: 1,
    paddingLeft: 1,
    paddingRight: 1,
    marginBottom: 1,
    backgroundColor: theme.surface.panel,
    flexShrink: 0
  })
  root.add(new TextRenderable(ctx, { fg: color, content }))
  return root
}

function textContent(content: string | readonly { type: string; text?: string; mimeType?: string }[]): string {
  if (typeof content === "string") return content
  return content.map(part => part.text ?? (part.mimeType ? `[image: ${part.mimeType}]` : "")).join("\n")
}

function assertNever(value: never): never {
  throw new Error(`Unexpected message: ${String(value)}`)
}
