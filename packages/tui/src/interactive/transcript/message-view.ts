import {
  BoxRenderable,
  CodeRenderable,
  createTextAttributes,
  fg,
  MarkdownRenderable,
  type MarkdownOptions,
  type Renderable,
  StyledText,
  type SyntaxStyle,
  TextAttributes,
  TextRenderable,
  type RenderContext
} from "@opentui/core"
import { projectToolPresentation, type AgentMessage } from "@with-zi/coding-agent"
import stringWidth from "string-width"

import type { Theme } from "../../theme.js"
import type { ActiveTool } from "../interactive-store.js"
import {
  visibleAssistantParts,
  type AssistantMessage,
  type AssistantProjectionPart as StreamingPart,
  type AssistantToolInclusion
} from "./assistant-projection.js"
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
  readonly expandHint?: string
}

export interface ToolCallPresentation {
  readonly name: string
  readonly args: unknown
}

type ItemMessage = Exclude<AgentMessage, { readonly role: "assistant" }>
type CompactionSummaryMessage = Extract<ItemMessage, { readonly role: "compactionSummary" }>

export function createMessageItemView(
  ctx: RenderContext,
  message: ItemMessage,
  options: MessageRenderOptions
): TranscriptItemView | undefined {
  switch (message.role) {
    case "user":
      return ownItem(ctx, createUserMessage(ctx, userContent(message.content), options.theme))
    case "toolResult":
      return createToolResultView(
        ctx,
        message,
        options.toolCall,
        options.theme,
        options.syntaxStyle,
        options.cwd ?? "",
        options.expandHint
      )
    case "bashExecution":
      return createBashExecutionView(
        ctx,
        message,
        options.theme,
        options.syntaxStyle,
        options.cwd ?? "",
        options.expandHint
      )
    case "custom":
      return message.display
        ? ownItem(ctx, createPanelMessage(ctx, customPanelContent(message), options.theme.text.custom, options.theme))
        : undefined
    case "compactionSummary":
      return new CompactionSummaryView(ctx, message, options.theme, options.syntaxStyle, options.expandHint)
    case "branchSummary":
      return new ExpandableSummaryView(ctx, {
        label: "branch",
        collapsed: expandHint => branchCollapsedText(expandHint, options.theme),
        expandedMarkdown: `**Branch Summary**\n\n${message.summary}`,
        theme: options.theme,
        syntaxStyle: options.syntaxStyle,
        ...(options.expandHint === undefined ? {} : { expandHint: options.expandHint })
      })
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

export interface AssistantToolViewOwner extends AssistantToolInclusion {
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
    const parts = visibleAssistantParts(message, this.#toolViews)
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
      new ToolCallView(this.#ctx, tool.id, toolFrame(tool), this.#theme, this.#syntaxStyle, this.#cwd)
    if (this.#toolViews) this.#toolViews.update(view, tool)
    return { kind: "tool", root: view.root, id: tool.id, view, tool }
  }
}

function createMarkdown(
  ctx: RenderContext,
  content: string,
  theme: Theme,
  syntaxStyle: SyntaxStyle,
  streaming: boolean,
  fgColor: string = theme.text.primary,
  bgColor: string = theme.surface.app
): MarkdownRenderable {
  return new MarkdownRenderable(ctx, {
    content,
    syntaxStyle,
    fg: fgColor,
    bg: bgColor,
    conceal: true,
    streaming,
    internalBlockMode: "top-level",
    tableOptions: { style: "grid" },
    renderNode: renderMarkdownNode
  })
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
  syntaxStyle: SyntaxStyle,
  cwd: string,
  expandHint?: string
): ToolCallView {
  const source: ActiveTool = {
    id: message.toolCallId,
    name: call?.name ?? message.toolName,
    args: call?.args,
    result: { content: message.content, details: message.details },
    status: message.isError ? "failed" : "done"
  }
  return new ToolCallView(ctx, source.id, toolFrame(source), theme, syntaxStyle, cwd, expandHint)
}

function createBashExecutionView(
  ctx: RenderContext,
  message: Extract<AgentMessage, { role: "bashExecution" }>,
  theme: Theme,
  syntaxStyle: SyntaxStyle,
  cwd: string,
  expandHint?: string
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
    syntaxStyle,
    cwd,
    expandHint
  )
}

class CompactionSummaryView implements TranscriptItemView {
  readonly root: BoxRenderable

  readonly #ctx: RenderContext
  readonly #message: CompactionSummaryMessage
  readonly #theme: Theme
  readonly #syntaxStyle: SyntaxStyle
  readonly #expandHint: string | undefined
  readonly #divider: TextRenderable
  #dividerText = ""
  #body: Renderable | undefined
  #expanded = false

  constructor(
    ctx: RenderContext,
    message: CompactionSummaryMessage,
    theme: Theme,
    syntaxStyle: SyntaxStyle,
    expandHint: string | undefined
  ) {
    this.#ctx = ctx
    this.#message = message
    this.#theme = theme
    this.#syntaxStyle = syntaxStyle
    this.#expandHint = expandHint
    this.root = new BoxRenderable(ctx, {
      width: "100%",
      paddingTop: 1,
      paddingBottom: 1,
      marginTop: 0,
      marginBottom: 1,
      flexDirection: "column",
      flexShrink: 0
    })
    this.#divider = new TextRenderable(ctx, {
      width: "100%",
      height: 1,
      fg: theme.text.custom,
      content: "",
      wrapMode: "none",
      flexShrink: 0
    })
    this.root.add(this.#divider)
    this.#syncDivider()
    this.root.onSizeChange = this.#syncDivider
  }

  setExpanded(expanded: boolean): boolean {
    if (expanded === this.#expanded) return false
    this.#expanded = expanded
    this.#renderBody()
    return true
  }

  destroy(): void {
    if (this.#ctx.hasSelection) this.#ctx.clearSelection()
    this.root.onSizeChange = undefined
    this.root.destroyRecursively()
  }

  readonly #syncDivider = (): void => {
    const width = this.root.width || this.#ctx.width
    const presentation = compactionDividerPresentation(
      this.#message.tokensBefore,
      this.#message.estimatedTokensAfter,
      this.#expanded ? undefined : this.#expandHint,
      width
    )
    const text = presentation.text + "─".repeat(Math.max(0, width - stringWidth(presentation.text)))
    if (text === this.#dividerText) return
    this.#dividerText = text
    const labelStart = text.indexOf(presentation.label)
    this.#divider.content = new StyledText([
      fg(this.#theme.text.custom)(text.slice(0, labelStart)),
      { ...fg(this.#theme.text.custom)(presentation.label), attributes: TextAttributes.BOLD },
      fg(this.#theme.text.custom)(text.slice(labelStart + presentation.label.length))
    ])
  }

  #renderBody(): void {
    if (this.#ctx.hasSelection) this.#ctx.clearSelection()
    if (this.#body) {
      this.root.remove(this.#body)
      this.#body.destroyRecursively()
      this.#body = undefined
    }
    this.#syncDivider()
    if (!this.#expanded) return
    this.#body = createMarkdown(
      this.#ctx,
      this.#message.summary,
      this.#theme,
      this.#syntaxStyle,
      markdownStreamingWorkaround,
      this.#theme.text.custom,
      "transparent"
    )
    this.#body.marginTop = 1
    this.root.add(this.#body)
  }
}

interface CompactionDividerPresentation {
  readonly label: string
  readonly text: string
}

function compactionDividerPresentation(
  tokensBefore: number,
  estimatedTokensAfter: number,
  expandHint: string | undefined,
  width: number
): CompactionDividerPresentation {
  const metrics = `${formatCompactTokenCount(tokensBefore)} → ~${formatCompactTokenCount(estimatedTokensAfter)}`
  const fullLabel = "Conversation compacted"
  const shortLabel = "Compacted"
  const candidates: CompactionDividerPresentation[] = expandHint
    ? [
        { label: fullLabel, text: `─────── ${fullLabel} • ${metrics} tokens • ${expandHint} to expand ` },
        { label: fullLabel, text: `─────── ${fullLabel} • ${metrics} • ${expandHint} expand ` },
        { label: shortLabel, text: `─────── ${shortLabel} • ${metrics} • ${expandHint} ` },
        { label: shortLabel, text: `── ${shortLabel} • ${expandHint} ` }
      ]
    : [
        { label: fullLabel, text: `─────── ${fullLabel} • ${metrics} tokens ` },
        { label: fullLabel, text: `─────── ${fullLabel} • ${metrics} ` },
        { label: shortLabel, text: `─────── ${shortLabel} • ${metrics} ` },
        { label: shortLabel, text: `── ${shortLabel} ` }
      ]
  return candidates.find(candidate => stringWidth(candidate.text) <= width) ?? { label: shortLabel, text: shortLabel }
}

function formatCompactTokenCount(tokens: number): string {
  if (tokens < 1_000) return String(tokens)
  if (tokens < 1_000_000) return `${Math.round(tokens / 1_000)}k`
  return `${(tokens / 1_000_000).toFixed(1).replace(/\.0$/, "")}m`
}

interface ExpandableSummaryOptions {
  readonly label: string
  readonly collapsed: (expandHint: string | undefined) => StyledText
  readonly expandedMarkdown: string
  readonly theme: Theme
  readonly syntaxStyle: SyntaxStyle
  readonly expandHint?: string
}

class ExpandableSummaryView implements TranscriptItemView {
  readonly root: BoxRenderable

  readonly #ctx: RenderContext
  readonly #theme: Theme
  readonly #syntaxStyle: SyntaxStyle
  readonly #collapsed: (expandHint: string | undefined) => StyledText
  readonly #expandedMarkdown: string
  readonly #expandHint: string | undefined
  #body: Renderable | undefined
  #expanded = false

  constructor(ctx: RenderContext, options: ExpandableSummaryOptions) {
    this.#ctx = ctx
    this.#theme = options.theme
    this.#syntaxStyle = options.syntaxStyle
    this.#collapsed = options.collapsed
    this.#expandedMarkdown = options.expandedMarkdown
    this.#expandHint = options.expandHint
    this.root = new BoxRenderable(ctx, {
      paddingTop: 1,
      paddingBottom: 1,
      paddingLeft: 1,
      paddingRight: 1,
      marginTop: 0,
      marginBottom: 1,
      backgroundColor: options.theme.surface.panel,
      flexDirection: "column",
      flexShrink: 0
    })
    this.root.add(
      new TextRenderable(ctx, {
        content: new StyledText([
          { ...fg(options.theme.text.custom)(`[${options.label}]`), attributes: TextAttributes.BOLD }
        ]),
        marginBottom: 1
      })
    )
    this.#renderBody()
  }

  setExpanded(expanded: boolean): boolean {
    if (expanded === this.#expanded) return false
    this.#expanded = expanded
    this.#renderBody()
    return true
  }

  destroy(): void {
    if (this.#ctx.hasSelection) this.#ctx.clearSelection()
    this.root.destroyRecursively()
  }

  #renderBody(): void {
    if (this.#ctx.hasSelection) this.#ctx.clearSelection()
    if (this.#body) {
      this.root.remove(this.#body)
      this.#body.destroyRecursively()
      this.#body = undefined
    }
    this.#body = this.#expanded
      ? createMarkdown(
          this.#ctx,
          this.#expandedMarkdown,
          this.#theme,
          this.#syntaxStyle,
          markdownStreamingWorkaround,
          this.#theme.text.custom,
          this.#theme.surface.panel
        )
      : new TextRenderable(this.#ctx, { content: this.#collapsed(this.#expandHint), wrapMode: "word" })
    this.root.add(this.#body)
  }
}

function branchCollapsedText(expandHint: string | undefined, theme: Theme): StyledText {
  if (!expandHint) return new StyledText([fg(theme.text.custom)("Branch summary")])
  return new StyledText([
    fg(theme.text.custom)("Branch summary ("),
    fg(theme.text.dim)(expandHint),
    fg(theme.text.custom)(" to expand)")
  ])
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
