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
import { createCommandToolBlock, createReadToolBlock, createToolBlock, formatToolTitle } from "./tool-view.js"

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
type StreamingPart =
  | { readonly kind: "thinking"; readonly content: string; readonly followedByAnswer: boolean }
  | { readonly kind: "answer"; readonly content: string }
type StreamingPartView =
  | {
      readonly kind: "thinking"
      readonly root: BoxRenderable
      readonly content: TextRenderable
      value: string
      followedByAnswer: boolean
    }
  | { readonly kind: "answer"; readonly root: BoxRenderable; readonly content: MarkdownRenderable; value: string }

export class StreamingAssistantView {
  readonly root: BoxRenderable

  readonly #ctx: RenderContext
  readonly #theme: Theme
  readonly #syntaxStyle: SyntaxStyle
  readonly #parts: StreamingPartView[] = []
  #error: TextRenderable | undefined
  #errorValue: string | undefined
  #hasBottomMargin = false

  constructor(ctx: RenderContext, message: AssistantMessage, theme: Theme, syntaxStyle: SyntaxStyle) {
    this.#ctx = ctx
    this.#theme = theme
    this.#syntaxStyle = syntaxStyle
    this.root = new BoxRenderable(ctx, {
      id: "streaming-assistant",
      paddingLeft: 1,
      paddingRight: 1,
      flexDirection: "column",
      flexShrink: 0
    })
    this.update(message)
  }

  update(message: AssistantMessage): boolean {
    const parts = visibleStreamingParts(message)
    const error = message.errorMessage || undefined
    let firstChangedKind = Math.min(parts.length, this.#parts.length)
    for (let index = 0; index < firstChangedKind; index++) {
      if (parts[index]?.kind !== this.#parts[index]?.kind) {
        firstChangedKind = index
        break
      }
    }

    let changed = firstChangedKind !== parts.length || firstChangedKind !== this.#parts.length
    while (this.#parts.length > firstChangedKind) {
      const part = this.#parts.pop()
      if (!part) break
      this.root.remove(part.root)
      part.root.destroyRecursively()
    }

    for (let index = 0; index < firstChangedKind; index++) {
      const part = parts[index]
      const view = this.#parts[index]
      if (!part || !view) continue
      if (part.content !== view.value) {
        view.content.content = part.content
        view.value = part.content
        changed = true
      }
      if (part.kind === "thinking" && view.kind === "thinking" && part.followedByAnswer !== view.followedByAnswer) {
        view.root.marginBottom = part.followedByAnswer ? 1 : 0
        view.followedByAnswer = part.followedByAnswer
        changed = true
      }
    }

    for (let index = firstChangedKind; index < parts.length; index++) {
      const part = parts[index]
      if (!part) continue
      const view = this.#createPart(part)
      if (this.#error) this.root.insertBefore(view.root, this.#error)
      else this.root.add(view.root)
      this.#parts.push(view)
      changed = true
    }

    if (error !== this.#errorValue) {
      if (error === undefined) {
        if (this.#error) {
          this.root.remove(this.#error)
          this.#error.destroyRecursively()
          this.#error = undefined
        }
      } else if (this.#error) {
        this.#error.content = error
      } else {
        this.#error = new TextRenderable(this.#ctx, { fg: this.#theme.text.error, content: error })
        this.root.add(this.#error)
      }
      this.#errorValue = error
      changed = true
    }

    const hasBottomMargin = parts.length > 0 || error !== undefined
    if (hasBottomMargin !== this.#hasBottomMargin) {
      this.root.marginBottom = hasBottomMargin ? 1 : 0
      this.#hasBottomMargin = hasBottomMargin
      changed = true
    }
    return changed
  }

  destroy(): void {
    this.root.destroyRecursively()
  }

  #createPart(part: StreamingPart): StreamingPartView {
    if (part.kind === "thinking") {
      const root = new BoxRenderable(this.#ctx, { flexShrink: 0, marginBottom: part.followedByAnswer ? 1 : 0 })
      const content = new TextRenderable(this.#ctx, {
        fg: this.#theme.text.thinking,
        attributes: TextAttributes.ITALIC,
        content: part.content
      })
      root.add(content)
      return { kind: "thinking", root, content, value: part.content, followedByAnswer: part.followedByAnswer }
    }

    const root = new BoxRenderable(this.#ctx, { flexShrink: 0 })
    const content = createMarkdown(this.#ctx, part.content, this.#theme, this.#syntaxStyle, true)
    root.add(content)
    return { kind: "answer", root, content, value: part.content }
  }
}

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
    block.add(createMarkdown(ctx, part.text.trim(), theme, syntaxStyle, markdownStreamingWorkaround))
    root.add(block)
  }

  if (message.errorMessage) {
    root.add(new TextRenderable(ctx, { fg: theme.text.error, content: message.errorMessage }))
  }
  return root
}

function createMarkdown(
  ctx: RenderContext,
  content: string,
  theme: Theme,
  syntaxStyle: SyntaxStyle,
  streaming: boolean
): MarkdownRenderable {
  return new MarkdownRenderable(ctx, {
    content,
    syntaxStyle,
    fg: theme.text.primary,
    bg: theme.surface.app,
    conceal: true,
    streaming,
    internalBlockMode: "top-level",
    tableOptions: { style: "grid" },
    renderNode: renderMarkdownNode
  })
}

function visibleStreamingParts(message: AssistantMessage): StreamingPart[] {
  const parts: StreamingPart[] = []
  for (let index = 0; index < message.content.length; index++) {
    const part = message.content[index]
    if (!part) continue
    if (part.type === "thinking") {
      if (!part.thinking.trim()) continue
      const followedByAnswer = message.content
        .slice(index + 1)
        .some(candidate => candidate.type === "text" && candidate.text.trim().length > 0)
      parts.push({ kind: "thinking", content: part.thinking.trimEnd(), followedByAnswer })
      continue
    }
    if (part.type === "text" && part.text.trim()) parts.push({ kind: "answer", content: part.text.trim() })
  }
  return parts
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
