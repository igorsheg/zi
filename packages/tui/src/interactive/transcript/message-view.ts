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
import type { ActiveTool } from "../interactive-store.js"
import {
  createCommandToolBlock,
  createReadToolBlock,
  createToolBlock,
  formatToolTitle,
  preparingTool,
  ToolCallView
} from "./tool-view.js"

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
      return new StreamingAssistantView(ctx, message, options.theme, options.syntaxStyle).root
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
  | { readonly kind: "tool"; readonly tool: ActiveTool }
  | { readonly kind: "omitted-tools"; readonly count: number }
type StreamingPartView =
  | {
      readonly kind: "thinking"
      readonly root: BoxRenderable
      readonly content: TextRenderable
      value: string
      followedByAnswer: boolean
    }
  | { readonly kind: "answer"; readonly root: BoxRenderable; readonly content: MarkdownRenderable; value: string }
  | {
      readonly kind: "tool"
      readonly root: BoxRenderable
      readonly id: string
      readonly view: ToolCallView
      tool: ActiveTool
    }
  | { readonly kind: "omitted-tools"; readonly root: TextRenderable; count: number }

export interface AssistantToolViewOwner {
  includes(id: string): boolean
  create(owner: StreamingAssistantView, id: string, name: string, args: unknown): ToolCallView
  release(owner: StreamingAssistantView, id: string, view: ToolCallView): void
}

export class StreamingAssistantView {
  readonly root: BoxRenderable

  readonly #ctx: RenderContext
  readonly #theme: Theme
  readonly #syntaxStyle: SyntaxStyle
  readonly #toolViews: AssistantToolViewOwner | undefined
  readonly #parts: StreamingPartView[] = []
  #error: TextRenderable | undefined
  #errorValue: string | undefined
  #hasBottomMargin = false

  constructor(
    ctx: RenderContext,
    message: AssistantMessage,
    theme: Theme,
    syntaxStyle: SyntaxStyle,
    toolViews?: AssistantToolViewOwner
  ) {
    this.#ctx = ctx
    this.#theme = theme
    this.#syntaxStyle = syntaxStyle
    this.#toolViews = toolViews
    this.root = new BoxRenderable(ctx, {
      id: "streaming-assistant",
      paddingLeft: 1,
      paddingRight: 1,
      flexDirection: "column",
      flexShrink: 0
    })
    this.update(message)
  }

  get toolCallIds(): readonly string[] {
    return this.#parts.filter(part => part.kind === "tool").map(part => part.id)
  }

  detachTool(id: string, view: ToolCallView): boolean {
    const index = this.#parts.findIndex(part => part.kind === "tool" && part.id === id && part.view === view)
    if (index < 0) return false
    const [part] = this.#parts.splice(index, 1)
    if (!part || part.kind !== "tool") return false
    this.root.remove(part.root)
    this.#syncBottomMargin()
    return true
  }

  omitTool(id: string, view: ToolCallView): boolean {
    const index = this.#parts.findIndex(part => part.kind === "tool" && part.id === id && part.view === view)
    if (index < 0) return false

    const [part] = this.#parts.splice(index, 1)
    if (!part || part.kind !== "tool") return false
    this.root.remove(part.root)
    this.#toolViews?.release(this, part.id, part.view)
    part.view.destroy()

    const omitted = this.#parts.find(candidate => candidate.kind === "omitted-tools")
    if (omitted?.kind === "omitted-tools") {
      omitted.count++
      omitted.root.content = omittedToolsText(omitted.count)
    } else {
      const marker = this.#createPart({ kind: "omitted-tools", count: 1 })
      const anchor = this.#parts[index]?.root ?? this.#error
      if (anchor) this.root.insertBefore(marker.root, anchor)
      else this.root.add(marker.root)
      this.#parts.splice(index, 0, marker)
    }
    this.#syncBottomMargin()
    return true
  }

  update(message: AssistantMessage): boolean {
    const parts = visibleStreamingParts(message, this.#toolViews)
    const error = message.errorMessage || undefined
    let firstChangedKind = Math.min(parts.length, this.#parts.length)
    for (let index = 0; index < firstChangedKind; index++) {
      if (partKey(parts[index]!) !== partViewKey(this.#parts[index]!)) {
        firstChangedKind = index
        break
      }
    }

    let changed = firstChangedKind !== parts.length || firstChangedKind !== this.#parts.length
    while (this.#parts.length > firstChangedKind) {
      const part = this.#parts.pop()
      if (!part) break
      this.root.remove(part.root)
      if (part.kind === "tool") {
        this.#toolViews?.release(this, part.id, part.view)
        part.view.destroy()
      } else {
        part.root.destroyRecursively()
      }
    }

    for (let index = 0; index < firstChangedKind; index++) {
      const part = parts[index]
      const view = this.#parts[index]
      if (!part || !view) continue
      if (part.kind === "tool" && view.kind === "tool") {
        if (part.tool !== view.tool) {
          if (view.view.update(part.tool)) changed = true
          view.tool = part.tool
        }
        continue
      }
      if (part.kind === "omitted-tools" && view.kind === "omitted-tools") {
        if (part.count !== view.count) {
          view.root.content = omittedToolsText(part.count)
          view.count = part.count
          changed = true
        }
        continue
      }
      if (
        part.kind === "tool" ||
        view.kind === "tool" ||
        part.kind === "omitted-tools" ||
        view.kind === "omitted-tools"
      ) {
        continue
      }
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

    if (this.#syncBottomMargin()) changed = true
    return changed
  }

  destroy(): void {
    for (const part of this.#parts) {
      if (part.kind === "tool") this.#toolViews?.release(this, part.id, part.view)
    }
    this.root.destroyRecursively()
    this.#parts.length = 0
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

    if (part.kind === "answer") {
      const root = new BoxRenderable(this.#ctx, { flexShrink: 0 })
      const content = createMarkdown(
        this.#ctx,
        part.content,
        this.#theme,
        this.#syntaxStyle,
        markdownStreamingWorkaround
      )
      root.add(content)
      return { kind: "answer", root, content, value: part.content }
    }

    if (part.kind === "omitted-tools") {
      const root = new TextRenderable(this.#ctx, {
        selectable: false,
        fg: this.#theme.text.muted,
        content: omittedToolsText(part.count)
      })
      return { kind: "omitted-tools", root, count: part.count }
    }

    const tool = part.tool
    const view =
      this.#toolViews?.create(this, tool.id, tool.name, tool.args) ??
      new ToolCallView(this.#ctx, preparingTool(tool.id, tool.name, tool.args), this.#theme)
    view.update(tool)
    view.root.marginTop = this.#parts.at(-1)?.kind === "tool" || this.#parts.length === 0 ? 0 : 1
    return { kind: "tool", root: view.root, id: tool.id, view, tool }
  }

  #syncBottomMargin(): boolean {
    const hasBottomMargin = this.#parts.at(-1)?.kind !== "tool" && (this.#parts.length > 0 || this.#error !== undefined)
    if (hasBottomMargin === this.#hasBottomMargin) return false
    this.root.marginBottom = hasBottomMargin ? 1 : 0
    this.#hasBottomMargin = hasBottomMargin
    return true
  }
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

const maxAssistantToolCalls = 64

function visibleStreamingParts(message: AssistantMessage, toolViews?: AssistantToolViewOwner): StreamingPart[] {
  const parts: StreamingPart[] = []
  let directToolCount = 0
  let omittedIndex: number | undefined
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
    if (part.type === "text" && part.text.trim()) {
      parts.push({ kind: "answer", content: part.text.trim() })
    } else if (part.type === "toolCall" && part.id) {
      const included = toolViews ? toolViews.includes(part.id) : directToolCount < maxAssistantToolCalls
      directToolCount++
      if (included) {
        parts.push({ kind: "tool", tool: toolFromMessage(message, part) })
      } else if (omittedIndex === undefined) {
        omittedIndex = parts.length
        parts.push({ kind: "omitted-tools", count: 1 })
      } else {
        const omitted = parts[omittedIndex]
        if (omitted?.kind === "omitted-tools") parts[omittedIndex] = { ...omitted, count: omitted.count + 1 }
      }
    }
  }
  return parts
}

function toolFromMessage(
  message: AssistantMessage,
  part: Extract<AssistantMessage["content"][number], { type: "toolCall" }>
): ActiveTool {
  if (message.stopReason === "aborted") {
    return {
      id: part.id,
      name: part.name,
      args: part.arguments,
      status: "aborted",
      result: { content: [{ type: "text", text: "Operation aborted" }] }
    }
  }
  if (message.stopReason === "error") {
    return {
      id: part.id,
      name: part.name,
      args: part.arguments,
      status: "failed",
      result: { content: [{ type: "text", text: message.errorMessage || "Error" }] }
    }
  }
  return preparingTool(part.id, part.name, part.arguments)
}

function omittedToolsText(count: number): string {
  return `… ${count} tool invocation${count === 1 ? "" : "s"} not rendered`
}

function partKey(part: StreamingPart): string {
  return part.kind === "tool" ? `tool:${part.tool.id}` : part.kind
}

function partViewKey(part: StreamingPartView): string {
  return part.kind === "tool" ? `tool:${part.id}` : part.kind
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
