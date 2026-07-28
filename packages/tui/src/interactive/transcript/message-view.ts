import {
  BoxRenderable,
  CodeRenderable,
  createTextAttributes,
  MarkdownRenderable,
  type MarkdownOptions,
  type Renderable,
  StyledText,
  type SyntaxStyle,
  TextRenderable,
  type RenderContext
} from "@opentui/core"
import { projectToolPresentation, type AgentMessage } from "@with-zi/coding-agent"

import type { Theme } from "../../theme.js"
import type { ActiveTool } from "../interactive-store.js"
import type { TranscriptItemView } from "./item.js"
import { ToolCallView, type ToolViewFrame } from "./tool-view.js"

// OpenTUI 0.4.5 drops Markdown blocks from the immediate frame when streaming is false.
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
      attributes: createTextAttributes({
        bold: true,
        italic: style?.italic ?? false,
        underline: style?.underline ?? false,
        dim: style?.dim ?? false
      })
    }
  ])
  return renderable
}

export interface MessageRenderOptions {
  readonly theme: Theme
  readonly syntaxStyle: SyntaxStyle
  readonly toolCall?: ToolCallPresentation
  readonly cwd?: string
}

export interface ToolCallPresentation {
  readonly name: string
  readonly args: unknown
}

type ItemMessage = Exclude<AgentMessage, { readonly role: "assistant" }>

export function createMessageItemView(
  ctx: RenderContext,
  message: ItemMessage,
  options: MessageRenderOptions
): TranscriptItemView | undefined {
  switch (message.role) {
    case "user":
      return ownItem(ctx, createUserMessage(ctx, userContent(message.content), options.theme))
    case "toolResult":
      return createToolResultView(ctx, message, options.toolCall, options.theme, options.cwd ?? "")
    case "bashExecution":
      return createBashExecutionView(ctx, message, options.theme, options.cwd ?? "")
    case "custom":
      return message.display
        ? ownItem(ctx, createPanelMessage(ctx, customPanelContent(message), options.theme.text.custom, options.theme))
        : undefined
    case "branchSummary":
    case "compactionSummary":
      return ownItem(ctx, createPanelMessage(ctx, message.summary, options.theme.text.muted, options.theme))
    default:
      return assertNever(message)
  }
}

function ownItem(ctx: RenderContext, root: Renderable): TranscriptItemView {
  return {
    root,
    destroy() {
      if (ctx.hasSelection) ctx.clearSelection()
      root.destroyRecursively()
    }
  }
}

function createUserMessage(ctx: RenderContext, content: string, theme: Theme): BoxRenderable {
  const root = new BoxRenderable(ctx, {
    width: "100%",
    paddingTop: 1,
    paddingBottom: 1,
    paddingLeft: 1,
    paddingRight: 1,
    marginTop: 0,
    marginBottom: 1,
    backgroundColor: theme.surface.userMessage,
    flexShrink: 0
  })
  root.add(new TextRenderable(ctx, { fg: theme.text.primary, content }))
  return root
}

type AssistantMessage = Extract<AgentMessage, { role: "assistant" }>
type StreamingPart =
  | { readonly kind: "thinking"; readonly content: string }
  | { readonly kind: "answer"; readonly content: string }
  | { readonly kind: "tool"; readonly tool: ActiveTool }
  | { readonly kind: "omitted-tools"; readonly count: number }
type StreamingPartView =
  | { readonly kind: "thinking"; readonly root: BoxRenderable; readonly content: MarkdownRenderable; value: string }
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
  create(owner: StreamingAssistantView, tool: ActiveTool): ToolCallView
  update(view: ToolCallView, tool: ActiveTool): boolean
  release(owner: StreamingAssistantView, id: string, view: ToolCallView): void
}

export class StreamingAssistantView {
  readonly root: BoxRenderable

  readonly #ctx: RenderContext
  readonly #theme: Theme
  readonly #syntaxStyle: SyntaxStyle
  readonly #thinkingSyntaxStyle: SyntaxStyle
  readonly #toolViews: AssistantToolViewOwner | undefined
  readonly #cwd: string
  readonly #parts: StreamingPartView[] = []
  #error: TextRenderable | undefined
  #errorValue: string | undefined

  constructor(
    ctx: RenderContext,
    message: AssistantMessage,
    theme: Theme,
    syntaxStyle: SyntaxStyle,
    thinkingSyntaxStyle: SyntaxStyle,
    toolViews?: AssistantToolViewOwner,
    cwd = ""
  ) {
    this.#ctx = ctx
    this.#theme = theme
    this.#syntaxStyle = syntaxStyle
    this.#thinkingSyntaxStyle = thinkingSyntaxStyle
    this.#toolViews = toolViews
    this.#cwd = cwd
    this.root = new BoxRenderable(ctx, {
      id: "streaming-assistant",
      paddingLeft: 1,
      paddingRight: 1,
      flexDirection: "column",
      flexShrink: 0,
      marginTop: 0,
      marginBottom: 0
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
    return true
  }

  omitTool(id: string, view: ToolCallView): boolean {
    const index = this.#parts.findIndex(part => part.kind === "tool" && part.id === id && part.view === view)
    if (index < 0) return false

    const [part] = this.#parts.splice(index, 1)
    if (!part || part.kind !== "tool") return false
    this.root.remove(part.root)
    if (this.#toolViews) this.#toolViews.release(this, part.id, part.view)
    else part.view.destroy()

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
    if (this.#parts.length > firstChangedKind && this.#ctx.hasSelection) this.#ctx.clearSelection()
    while (this.#parts.length > firstChangedKind) {
      const part = this.#parts.pop()
      if (!part) break
      this.root.remove(part.root)
      if (part.kind === "tool") {
        if (this.#toolViews) this.#toolViews.release(this, part.id, part.view)
        else part.view.destroy()
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
          if (this.#toolViews?.update(view.view, part.tool) ?? view.view.update(toolFrame(part.tool))) changed = true
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
          if (this.#ctx.hasSelection) this.#ctx.clearSelection()
          this.root.remove(this.#error)
          this.#error.destroyRecursively()
          this.#error = undefined
        }
      } else if (this.#error) {
        this.#error.content = error
      } else {
        this.#error = new TextRenderable(this.#ctx, {
          fg: this.#theme.text.error,
          content: error,
          marginTop: 0,
          marginBottom: 1
        })
        this.root.add(this.#error)
      }
      this.#errorValue = error
      changed = true
    }

    return changed
  }

  destroy(): void {
    if (this.#ctx.hasSelection) this.#ctx.clearSelection()
    for (const part of this.#parts) {
      if (part.kind !== "tool") continue
      this.root.remove(part.root)
      if (this.#toolViews) this.#toolViews.release(this, part.id, part.view)
      else part.view.destroy()
    }
    this.root.destroyRecursively()
    this.#parts.length = 0
  }

  #createPart(part: StreamingPart): StreamingPartView {
    if (part.kind === "thinking") {
      const root = new BoxRenderable(this.#ctx, { flexShrink: 0, marginTop: 0, marginBottom: 1 })
      const content = createMarkdown(
        this.#ctx,
        part.content,
        this.#theme,
        this.#thinkingSyntaxStyle,
        markdownStreamingWorkaround
      )
      root.add(content)
      return { kind: "thinking", root, content, value: part.content }
    }

    if (part.kind === "answer") {
      const root = new BoxRenderable(this.#ctx, { flexShrink: 0, marginTop: 0, marginBottom: 1 })
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
        content: omittedToolsText(part.count),
        marginTop: 0,
        marginBottom: 1
      })
      return { kind: "omitted-tools", root, count: part.count }
    }

    const tool = part.tool
    const view =
      this.#toolViews?.create(this, tool) ??
      new ToolCallView(this.#ctx, tool.id, toolFrame(tool), this.#theme, this.#cwd)
    if (this.#toolViews) this.#toolViews.update(view, tool)
    return { kind: "tool", root: view.root, id: tool.id, view, tool }
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
  for (const part of message.content) {
    if (part.type === "thinking") {
      if (part.thinking.trim() || parts.at(-1)?.kind === "thinking") {
        appendAssistantText(parts, "thinking", part.thinking)
      }
      continue
    }
    if (part.type === "text" && (part.text.trim() || parts.at(-1)?.kind === "answer")) {
      appendAssistantText(parts, "answer", part.text)
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
  const visible: StreamingPart[] = []
  for (const part of parts) {
    if (part.kind === "thinking") {
      const content = part.content.trimEnd()
      if (content.trim()) visible.push({ kind: "thinking", content })
    } else if (part.kind === "answer") {
      const content = part.content.trim()
      if (content) visible.push({ kind: "answer", content })
    } else {
      visible.push(part)
    }
  }
  return visible
}

function appendAssistantText(parts: StreamingPart[], kind: "thinking" | "answer", content: string): void {
  const previous = parts.at(-1)
  if (previous?.kind === kind) {
    parts[parts.length - 1] = { kind, content: previous.content + content }
  } else {
    parts.push({ kind, content })
  }
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
  return { id: part.id, name: part.name, args: part.arguments, status: "preparing" }
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
  theme: Theme,
  cwd: string
): ToolCallView {
  const source: ActiveTool = {
    id: message.toolCallId,
    name: call?.name ?? message.toolName,
    args: call?.args,
    result: { content: message.content, details: message.details },
    status: message.isError ? "failed" : "done"
  }
  return new ToolCallView(ctx, source.id, toolFrame(source), theme, cwd)
}

function createBashExecutionView(
  ctx: RenderContext,
  message: Extract<AgentMessage, { role: "bashExecution" }>,
  theme: Theme,
  cwd: string
): ToolCallView {
  const status = message.exitCode === 0 ? ("done" as const) : ("failed" as const)
  return new ToolCallView(
    ctx,
    `bash-execution:${message.timestamp}`,
    {
      status,
      presentation: {
        header: {
          label: "Run",
          subject: { type: "command", text: message.command, prompt: false },
          details: [],
          ...(message.exitCode === 0 ? {} : { status: `exit ${message.exitCode}` })
        },
        ...(message.output ? { body: { type: "terminal" as const, text: message.output } } : {}),
        notices: [],
        preview: {
          compact: message.exitCode === 0 ? { type: "hidden" } : { type: "edges", head: 2, tail: 3 },
          detailed: { type: "edges", head: 80, tail: 119 }
        },
        timing: "hidden"
      }
    },
    theme,
    cwd
  )
}

function toolFrame(tool: ActiveTool): ToolViewFrame {
  return { status: tool.status, presentation: projectToolPresentation(tool) }
}

function createPanelMessage(ctx: RenderContext, content: string, color: string, theme: Theme): BoxRenderable {
  const root = new BoxRenderable(ctx, {
    paddingTop: 1,
    paddingBottom: 1,
    paddingLeft: 1,
    paddingRight: 1,
    marginTop: 0,
    marginBottom: 1,
    backgroundColor: theme.surface.panel,
    flexShrink: 0
  })
  root.add(new TextRenderable(ctx, { fg: color, content }))
  return root
}

function userContent(content: string | readonly { type: string; text?: string; mimeType?: string }[]): string {
  if (typeof content === "string") return content
  let output = ""
  let imageCount = 0
  let previousWasImage = false
  for (const part of content) {
    if (part.text !== undefined) {
      if (previousWasImage && output && !/\s$/.test(output) && !/^\s/.test(part.text)) output += " "
      output += part.text
      previousWasImage = false
      continue
    }
    if (!part.mimeType) continue
    if (output && !/\s$/.test(output)) output += " "
    output += `[image #${++imageCount}]`
    previousWasImage = true
  }
  return output
}

function customPanelContent(message: Extract<AgentMessage, { role: "custom" }>): string {
  const label = `[${message.customType}]`
  const body = textContent(message.content)
  return body ? `${label}\n${body}` : label
}

function textContent(content: string | readonly { type: string; text?: string; mimeType?: string }[]): string {
  if (typeof content === "string") return content
  return content.map(part => part.text ?? (part.mimeType ? `[image: ${part.mimeType}]` : "")).join("\n")
}

function assertNever(value: never): never {
  throw new Error(`Unexpected message: ${String(value)}`)
}
