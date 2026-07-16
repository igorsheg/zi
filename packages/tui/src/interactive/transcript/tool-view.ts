import { BoxRenderable, fg, StyledText, TextRenderable, type RenderContext } from "@opentui/core"
import { projectToolDisplay, type ToolDisplay, type ToolDisplayNotice } from "@openzi/coding-agent"

import { wrapToCells } from "../../components/cell-text.js"
import { glyphs } from "../../glyphs.js"
import type { Theme } from "../../theme.js"
import type { ActiveTool } from "../interactive-store.js"

export type ToolStatus = ActiveTool["status"]

const toolRailTone = {
  preparing: "muted",
  ready: "accent",
  running: "accent",
  done: "success",
  failed: "error",
  aborted: "error"
} as const satisfies Record<ToolStatus, keyof Theme["text"]>

const toolSuffix = {
  preparing: " (preparing)",
  ready: " (waiting)",
  running: "",
  done: "",
  failed: " (error)",
  aborted: " (aborted)"
} as const satisfies Record<ToolStatus, string>

export interface ToolBlockOptions {
  readonly title: string
  readonly output?: string
  readonly status: ToolStatus
}

export function createToolBlock(ctx: RenderContext, options: ToolBlockOptions, theme: Theme): BoxRenderable {
  return createToolFrame(ctx, options, headPreview(options.output, 10), "default", theme)
}

export function createCommandToolBlock(ctx: RenderContext, options: ToolBlockOptions, theme: Theme): BoxRenderable {
  return createToolFrame(ctx, options, tailPreview(options.output, 5), "shell", theme)
}

export function createReadToolBlock(ctx: RenderContext, options: ToolBlockOptions, theme: Theme): BoxRenderable {
  const lines = options.status === "done" ? [] : headPreview(options.output, 10)
  return createToolFrame(ctx, options, lines, "default", theme)
}

const maxExpandedVisualLines = 200

type LineTone = "output" | "muted" | "warning" | "success" | "error"

interface PresentationLine {
  readonly text: string
  readonly tone: LineTone
}

interface ToolViewPresentation {
  readonly title: string
  readonly titleTone: "default" | "shell"
  readonly status: ToolStatus
  readonly direction: "head" | "tail"
  readonly limit: number
  readonly lines: readonly PresentationLine[]
}

export class ToolCallView {
  readonly root: BoxRenderable

  readonly #ctx: RenderContext
  readonly #theme: Theme
  readonly #title: TextRenderable
  readonly #expandHint: string | undefined
  readonly #lines: TextRenderable[] = []
  #top: TextRenderable | undefined
  #bottom: TextRenderable | undefined
  #renderedLines: readonly PresentationLine[] = []
  #renderedStatus: ToolStatus | undefined
  #tool: ActiveTool
  #presentation: ToolViewPresentation
  #expanded = false
  #contentWidth = 0
  #startedAt: number | undefined
  #endedAt: number | undefined
  #elapsedValue: string | undefined

  constructor(ctx: RenderContext, tool: ActiveTool, theme: Theme, expandHint?: string) {
    this.#ctx = ctx
    this.#theme = theme
    this.#expandHint = expandHint
    this.#tool = tool
    this.#trackTiming(undefined, tool.status)
    this.#elapsedValue = this.#elapsedNotice()
    this.#presentation = toolPresentation(tool, this.#expanded, this.#elapsedValue)
    this.root = new BoxRenderable(ctx, {
      id: `active-tool:${tool.id}`,
      paddingLeft: 1,
      paddingRight: 1,
      flexDirection: "column",
      flexShrink: 0,
      marginBottom: 1
    })
    this.#title = new TextRenderable(ctx, {
      fg: titleColor(this.#presentation.titleTone, theme),
      wrapMode: "word",
      content: toolTitle(this.#presentation)
    })
    this.root.add(this.#title)
    this.root.onSizeChange = () => this.#syncWidth()
    this.#renderPreview()
  }

  get isRunning(): boolean {
    return this.#tool.status === "running"
  }

  update(tool: ActiveTool): boolean {
    if (tool === this.#tool) return false
    const previousStatus = this.#tool.status
    this.#tool = tool
    this.#trackTiming(previousStatus, tool.status)
    this.#elapsedValue = this.#elapsedNotice()
    return this.#apply(toolPresentation(tool, this.#expanded, this.#elapsedValue))
  }

  refreshElapsed(): boolean {
    if (!this.isRunning) return false
    const elapsed = this.#elapsedNotice()
    if (elapsed === this.#elapsedValue) return false
    this.#elapsedValue = elapsed
    return this.#apply(toolPresentation(this.#tool, this.#expanded, elapsed))
  }

  setExpanded(expanded: boolean): boolean {
    if (expanded === this.#expanded) return false
    this.#expanded = expanded
    this.#elapsedValue = this.#elapsedNotice()
    const changed = this.#apply(toolPresentation(this.#tool, expanded, this.#elapsedValue))
    if (!changed) this.#renderPreview()
    return true
  }

  setEmbedded(embedded: boolean): void {
    this.root.paddingLeft = embedded ? 0 : 1
    this.root.paddingRight = embedded ? 0 : 1
  }

  destroy(): void {
    if (this.#ctx.hasSelection) this.#ctx.clearSelection()
    this.root.destroyRecursively()
  }

  #apply(next: ToolViewPresentation): boolean {
    const current = this.#presentation
    if (samePresentation(current, next)) return false
    if (toolTitle(current) !== toolTitle(next)) this.#title.content = toolTitle(next)
    if (current.titleTone !== next.titleTone) this.#title.fg = titleColor(next.titleTone, this.#theme)
    this.#presentation = next
    this.#renderPreview()
    return true
  }

  #syncWidth(): void {
    const width = Math.max(1, this.root.width - 4)
    if (width === this.#contentWidth) return
    this.#contentWidth = width
    this.#renderPreview()
  }

  #renderPreview(): void {
    const presentation = this.#presentation
    const width = this.#contentWidth || 76
    const lines = visualPreview(
      presentation.lines,
      width,
      this.#expanded ? maxExpandedVisualLines : presentation.limit,
      presentation.direction,
      this.#expanded ? undefined : this.#expandHint
    )
    this.#reconcileLines(lines, presentation.status)
  }

  #reconcileLines(lines: readonly PresentationLine[], status: ToolStatus): void {
    if (lines.length === 0) {
      this.#destroyPreview()
      return
    }

    const rail = railColor(status, this.#theme)
    const railChanged = this.#renderedStatus !== status
    if (!this.#top) {
      this.#top = new TextRenderable(this.#ctx, { fg: rail, content: glyphs.toolTop })
      this.#bottom = new TextRenderable(this.#ctx, { fg: rail, content: glyphs.toolBottom })
      this.root.add(this.#top)
      this.root.add(this.#bottom)
    } else if (railChanged) {
      this.#top.fg = rail
      this.#bottom!.fg = rail
    }

    if (this.#lines.length > lines.length && this.#ctx.hasSelection) this.#ctx.clearSelection()
    while (this.#lines.length > lines.length) {
      const line = this.#lines.pop()!
      this.root.remove(line)
      line.destroyRecursively()
    }
    while (this.#lines.length < lines.length) {
      const line = new TextRenderable(this.#ctx, { wrapMode: "none" })
      this.root.insertBefore(line, this.#bottom)
      this.#lines.push(line)
    }
    for (let index = 0; index < lines.length; index++) {
      const line = lines[index]!
      const current = this.#renderedLines[index]
      if (!railChanged && current?.text === line.text && current.tone === line.tone) continue
      this.#lines[index]!.content = previewLine(line, status, this.#theme)
    }
    this.#renderedLines = lines.map(line => ({ ...line }))
    this.#renderedStatus = status
  }

  #destroyPreview(): void {
    if ((this.#lines.length > 0 || this.#top || this.#bottom) && this.#ctx.hasSelection) this.#ctx.clearSelection()
    for (const line of this.#lines.splice(0)) {
      this.root.remove(line)
      line.destroyRecursively()
    }
    if (this.#top) {
      this.root.remove(this.#top)
      this.#top.destroyRecursively()
      this.#top = undefined
    }
    if (this.#bottom) {
      this.root.remove(this.#bottom)
      this.#bottom.destroyRecursively()
      this.#bottom = undefined
    }
    this.#renderedLines = []
    this.#renderedStatus = undefined
  }

  #trackTiming(previous: ToolStatus | undefined, next: ToolStatus): void {
    if (next === "running" && previous !== "running" && this.#startedAt === undefined) {
      this.#startedAt = performance.now()
    }
    if (isTerminal(next) && !isTerminal(previous) && this.#startedAt !== undefined) {
      this.#endedAt = performance.now()
    }
  }

  #elapsedNotice(): string | undefined {
    if (this.#startedAt === undefined) return undefined
    const end = this.#endedAt ?? performance.now()
    const label = this.#endedAt === undefined ? "Elapsed" : "Took"
    return `${label} ${((end - this.#startedAt) / 1_000).toFixed(1)}s`
  }
}

export { ToolCallView as ActiveToolView }

export function createActiveToolView(
  ctx: RenderContext,
  tool: ActiveTool,
  theme: Theme,
  expandHint?: string
): ToolCallView {
  return new ToolCallView(ctx, tool, theme, expandHint)
}

export function preparingTool(id: string, name: string, args: unknown): ActiveTool {
  return { id, name, args, status: "preparing" }
}

export function completedTool(id: string, name: string, args: unknown, result: unknown, isError: boolean): ActiveTool {
  return { id, name, args, result, status: isError ? "failed" : "done" }
}

function toolPresentation(tool: ActiveTool, expanded: boolean, elapsed: string | undefined): ToolViewPresentation {
  const display = projectToolDisplay({
    name: tool.name,
    args: tool.args,
    ...("result" in tool ? { result: tool.result } : {}),
    isError: tool.status === "failed" || tool.status === "aborted"
  })
  const base = displayPresentation(display, tool.status, expanded)
  if (!elapsed || (tool.status !== "running" && !isTerminal(tool.status))) return base
  return { ...base, lines: [...base.lines, { text: elapsed, tone: "muted" }] }
}

function displayPresentation(display: ToolDisplay, status: ToolStatus, expanded: boolean): ToolViewPresentation {
  switch (display.type) {
    case "command":
      return {
        title: `$ ${display.command || "…"}${display.timeout ? ` (timeout ${display.timeout}s)` : ""}`,
        titleTone: "shell",
        status,
        direction: "tail",
        limit: 5,
        lines: [...textLines(display.output, "output"), ...noticeLines(display.notices)]
      }
    case "read": {
      const start = display.offset ?? 1
      const range =
        display.offset === undefined && display.limit === undefined
          ? ""
          : `:${start}${display.limit === undefined ? "" : `-${start + display.limit - 1}`}`
      const showOutput = expanded || status === "failed" || status === "aborted"
      return {
        title: `read ${display.path || "…"}${range}`,
        titleTone: "default",
        status,
        direction: "head",
        limit: 10,
        lines: [
          ...(showOutput ? textLines(display.output, status === "failed" ? "error" : "output") : []),
          ...noticeLines(display.notices)
        ]
      }
    }
    case "write": {
      const content = textLines(display.content, "output")
      if (display.contentTruncated) {
        const detail =
          display.contentShownLines < display.contentLines
            ? `${display.contentLines} total lines in arguments`
            : `${formatBytes(display.contentBytes)} of arguments`
        content.push({ text: `… (${detail})`, tone: "muted" })
      }
      if (display.error) content.push(...textLines(display.error, "error"))
      return {
        title: `write ${display.path || "…"}`,
        titleTone: "default",
        status,
        direction: "head",
        limit: 10,
        lines: content
      }
    }
    case "edit": {
      const lines: PresentationLine[] = display.diff
        ? display.diff
            .split("\n")
            .map(line => ({
              text: line,
              tone:
                line.startsWith("+") && !line.startsWith("+++")
                  ? "success"
                  : line.startsWith("-") && !line.startsWith("---")
                    ? "error"
                    : "muted"
            }))
        : []
      if (!display.diff) {
        for (const change of display.changes) {
          lines.push(...textLines(change.oldText, "error", "- "))
          lines.push(...textLines(change.newText, "success", "+ "))
        }
      }
      if (display.changesTruncated) lines.push({ text: "… more replacements", tone: "muted" })
      if (display.diffTruncated) lines.push({ text: "… diff truncated at 2,000 lines or 50 KiB", tone: "warning" })
      if (display.error) lines.push(...textLines(display.error, "error"))
      return { title: `edit ${display.path || "…"}`, titleTone: "default", status, direction: "head", limit: 12, lines }
    }
    case "generic":
      return {
        title: display.name,
        titleTone: "default",
        status,
        direction: "head",
        limit: 10,
        lines: [
          ...textLines(display.args, "muted"),
          ...textLines(display.output, status === "failed" || status === "aborted" ? "error" : "output"),
          ...noticeLines(display.notices)
        ]
      }
    default:
      return assertNever(display)
  }
}

function visualPreview(
  source: readonly PresentationLine[],
  width: number,
  limit: number,
  direction: "head" | "tail",
  expandHint: string | undefined
): PresentationLine[] {
  if (direction === "head") {
    const output: PresentationLine[] = []
    for (const line of source) {
      for (const wrapped of wrapLine(line, width)) {
        if (output.length === limit) return [...output, omissionLine("more output", expandHint)]
        output.push(wrapped)
      }
    }
    return output
  }

  const output: PresentationLine[] = []
  for (let index = source.length - 1; index >= 0; index--) {
    const wrapped = wrapLine(source[index]!, width)
    for (let part = wrapped.length - 1; part >= 0; part--) {
      if (output.length === limit) return [omissionLine("earlier output", expandHint), ...output]
      output.unshift(wrapped[part]!)
    }
  }
  return output
}

function wrapLine(line: PresentationLine, width: number): PresentationLine[] {
  return wrapToCells(line.text, width).map(text => ({ text, tone: line.tone }))
}

function omissionLine(label: string, expandHint: string | undefined): PresentationLine {
  return { text: expandHint ? `… ${expandHint} to expand · ${label}` : `… ${label}`, tone: "muted" }
}

function textLines(text: string, tone: LineTone, prefix = ""): PresentationLine[] {
  if (!text) return []
  return text
    .replace(/[\r\n]+$/, "")
    .split(/\r?\n/)
    .map(line => ({ text: `${prefix}${line}`, tone }))
}

function noticeLines(notices: readonly ToolDisplayNotice[]): PresentationLine[] {
  return notices.map(notice => ({ text: `[${notice.text}]`, tone: notice.tone }))
}

function samePresentation(left: ToolViewPresentation, right: ToolViewPresentation): boolean {
  return (
    left.title === right.title &&
    left.titleTone === right.titleTone &&
    left.status === right.status &&
    left.direction === right.direction &&
    left.limit === right.limit &&
    left.lines.length === right.lines.length &&
    left.lines.every((line, index) => line.text === right.lines[index]?.text && line.tone === right.lines[index]?.tone)
  )
}

function createToolFrame(
  ctx: RenderContext,
  options: ToolBlockOptions,
  lines: readonly string[],
  titleTone: "default" | "shell",
  theme: Theme
): BoxRenderable {
  const rail = railColor(options.status, theme)
  const root = new BoxRenderable(ctx, {
    paddingLeft: 1,
    paddingRight: 1,
    flexDirection: "column",
    flexShrink: 0,
    marginBottom: 1
  })
  root.add(
    new TextRenderable(ctx, {
      fg: titleColor(titleTone, theme),
      content: `${options.title}${toolSuffix[options.status]}`
    })
  )

  if (lines.length > 0) {
    root.add(new TextRenderable(ctx, { fg: rail, content: glyphs.toolTop }))
    for (const line of lines) {
      root.add(new TextRenderable(ctx, { content: previewLine({ text: line, tone: "output" }, options.status, theme) }))
    }
    root.add(new TextRenderable(ctx, { fg: rail, content: glyphs.toolBottom }))
  }
  return root
}

function toolTitle(presentation: ToolViewPresentation): string {
  return `${presentation.title}${toolSuffix[presentation.status]}`
}

function titleColor(tone: ToolViewPresentation["titleTone"], theme: Theme): string {
  return tone === "shell" ? theme.text.shell : theme.text.primary
}

function railColor(status: ToolStatus, theme: Theme): string {
  return theme.text[toolRailTone[status]]
}

function previewLine(line: PresentationLine, status: ToolStatus, theme: Theme): StyledText {
  return new StyledText([fg(railColor(status, theme))(glyphs.toolBody), fg(lineColor(line.tone, theme))(line.text)])
}

function lineColor(tone: LineTone, theme: Theme): string {
  switch (tone) {
    case "output":
      return theme.text.toolOutput
    case "muted":
      return theme.text.muted
    case "warning":
      return theme.text.warning
    case "success":
      return theme.text.success
    case "error":
      return theme.text.error
    default:
      return assertNever(tone)
  }
}

function headPreview(output: string | undefined, limit: number): string[] {
  const lines = outputLines(output)
  if (lines.length <= limit) return lines
  return [...lines.slice(0, limit), `... (${lines.length - limit} more lines)`]
}

function tailPreview(output: string | undefined, limit: number): string[] {
  const lines = outputLines(output)
  if (lines.length <= limit) return lines
  return [`... (${lines.length - limit} earlier lines)`, ...lines.slice(-limit)]
}

function outputLines(output: string | undefined): string[] {
  return output ? output.replace(/[\r\n]+$/, "").split(/\r?\n/) : []
}

export function formatToolTitle(name: string, args: unknown): string {
  const display = projectToolDisplay({ name, args, isError: false })
  return displayPresentation(display, "done", false).title
}

function formatBytes(bytes: number): string {
  return bytes >= 1024 ? `${Math.ceil(bytes / 1024)} KiB` : `${bytes} bytes`
}

function isTerminal(status: ToolStatus | undefined): boolean {
  return status === "done" || status === "failed" || status === "aborted"
}

function assertNever(value: never): never {
  throw new Error(`Unexpected tool presentation: ${String(value)}`)
}
