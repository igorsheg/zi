import { isAbsolute, relative, resolve } from "node:path"
import { pathToFileURL } from "node:url"

import { BoxRenderable, fg, link, StyledText, TextRenderable, type RenderContext } from "@opentui/core"
import type {
  ToolBody,
  ToolHeader,
  ToolNotice,
  ToolPresentation,
  ToolPresentationSource,
  ToolPreviewPolicy
} from "@openzi/coding-agent"

import { textWidth, truncateToCells, wrapToCells } from "../../components/cell-text.js"
import { glyphs } from "../../glyphs.js"
import type { Theme } from "../../theme.js"

export type ToolStatus = ToolPresentationSource["status"]

export interface ToolViewFrame {
  readonly status: ToolStatus
  readonly presentation: ToolPresentation
}

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

type LineTone = "output" | "normal" | "muted" | "warning" | "success" | "error"

interface PresentationLine {
  readonly text: string
  readonly tone: LineTone
}

interface OwnedToolBodyView {
  readonly root: BoxRenderable
  readonly type: ToolBody["type"]
  update(body: ToolBody): boolean
  setPreview(preview: ToolPreviewPolicy): boolean
  setExpanded(expanded: boolean): boolean
  setStatus(status: ToolStatus): boolean
  setWidth(width: number): boolean
  destroy(): void
}

export class ToolCallView {
  readonly root: BoxRenderable

  readonly #ctx: RenderContext
  readonly #header: ToolHeaderView
  readonly #notices: ToolNoticeView
  readonly #elapsed: TextRenderable
  readonly #theme: Theme
  readonly #expandHint: string | undefined
  #frame: ToolViewFrame
  #body: OwnedToolBodyView | undefined
  #expanded = false
  #contentWidth = 76
  #startedAt: number | undefined
  #endedAt: number | undefined
  #elapsedValue: string | undefined

  constructor(ctx: RenderContext, id: string, frame: ToolViewFrame, theme: Theme, cwd: string, expandHint?: string) {
    this.#ctx = ctx
    this.#frame = frame
    this.#theme = theme
    this.#expandHint = expandHint
    this.root = new BoxRenderable(ctx, {
      id: `active-tool:${id}`,
      paddingLeft: 1,
      paddingRight: 1,
      flexDirection: "column",
      flexShrink: 0,
      marginBottom: 1
    })
    this.#header = new ToolHeaderView(ctx, frame.presentation.header, frame.status, theme, cwd)
    this.#notices = new ToolNoticeView(ctx, frame.presentation.notices, theme, cwd)
    this.#elapsed = new TextRenderable(ctx, { fg: theme.text.muted, visible: false, wrapMode: "word" })
    this.root.add(this.#header.root)
    this.#body = frame.presentation.body
      ? createBodyView(ctx, frame.presentation.body, frame.presentation.preview, frame.status, theme, expandHint)
      : undefined
    if (this.#body) this.root.add(this.#body.root)
    this.root.add(this.#notices.root)
    this.root.add(this.#elapsed)
    this.#trackTiming(undefined, frame.status)
    this.#syncElapsed()
    this.root.onSizeChange = () => this.#syncWidth()
  }

  get isRunning(): boolean {
    return this.#frame.status === "running"
  }

  update(frame: ToolViewFrame): boolean {
    if (frame === this.#frame) return false
    const previous = this.#frame
    this.#frame = frame
    this.#trackTiming(previous.status, frame.status)

    let changed = this.#header.update(frame.presentation.header, frame.status)
    if (this.#syncBody(frame.presentation.body, frame.presentation.preview, frame.status)) changed = true
    if (this.#notices.update(frame.presentation.notices)) changed = true
    if (this.#syncElapsed()) changed = true
    return changed
  }

  refreshElapsed(): boolean {
    if (!this.isRunning) return false
    return this.#syncElapsed()
  }

  setExpanded(expanded: boolean): boolean {
    if (expanded === this.#expanded) return false
    this.#expanded = expanded
    this.#body?.setExpanded(expanded)
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

  #syncBody(body: ToolBody | undefined, preview: ToolPreviewPolicy, status: ToolStatus): boolean {
    if (!body) {
      if (!this.#body) return false
      if (this.#ctx.hasSelection) this.#ctx.clearSelection()
      this.root.remove(this.#body.root)
      this.#body.destroy()
      this.#body = undefined
      return true
    }

    if (!this.#body || this.#body.type !== body.type) {
      if (this.#body) {
        if (this.#ctx.hasSelection) this.#ctx.clearSelection()
        this.root.remove(this.#body.root)
        this.#body.destroy()
      }
      this.#body = createBodyView(this.#ctx, body, preview, status, this.#theme, this.#expandHint)
      this.#body.setExpanded(this.#expanded)
      this.#body.setWidth(this.#contentWidth)
      this.root.insertBefore(this.#body.root, this.#notices.root)
      return true
    }

    let changed = this.#body.update(body)
    if (this.#body.setPreview(preview)) changed = true
    if (this.#body.setStatus(status)) changed = true
    return changed
  }

  #syncWidth(): void {
    const width = Math.max(1, this.root.width - 4)
    if (width === this.#contentWidth) return
    this.#contentWidth = width
    this.#header.setWidth(width)
    this.#body?.setWidth(width)
  }

  #trackTiming(previous: ToolStatus | undefined, next: ToolStatus): void {
    if (next === "running" && previous !== "running" && this.#startedAt === undefined) {
      this.#startedAt = performance.now()
    }
    if (isTerminal(next) && !isTerminal(previous) && this.#startedAt !== undefined) {
      this.#endedAt = performance.now()
    }
  }

  #syncElapsed(): boolean {
    const elapsed = this.#elapsedNotice()
    if (elapsed === this.#elapsedValue) return false
    this.#elapsedValue = elapsed
    this.#elapsed.visible = elapsed !== undefined
    if (elapsed !== undefined) this.#elapsed.content = elapsed
    return true
  }

  #elapsedNotice(): string | undefined {
    if (this.#startedAt === undefined) return undefined
    const end = this.#endedAt ?? performance.now()
    const label = this.#endedAt === undefined ? "Elapsed" : "Took"
    return `${label} ${((end - this.#startedAt) / 1_000).toFixed(1)}s`
  }
}

class ToolHeaderView {
  readonly root: BoxRenderable

  readonly #theme: Theme
  readonly #cwd: string
  readonly #label: TextRenderable
  readonly #subject: TextRenderable
  readonly #details: TextRenderable
  readonly #status: TextRenderable
  #header: ToolHeader
  #toolStatus: ToolStatus
  #width = 76

  constructor(ctx: RenderContext, header: ToolHeader, status: ToolStatus, theme: Theme, cwd: string) {
    this.#header = header
    this.#toolStatus = status
    this.#theme = theme
    this.#cwd = cwd
    this.root = new BoxRenderable(ctx, { flexDirection: "row", flexShrink: 0 })
    this.#label = new TextRenderable(ctx, { selectable: false, fg: theme.text.primary, wrapMode: "none" })
    this.#subject = new TextRenderable(ctx, { fg: theme.text.primary, wrapMode: "word", flexShrink: 1 })
    this.#details = new TextRenderable(ctx, { selectable: false, fg: theme.text.muted, wrapMode: "word" })
    this.#status = new TextRenderable(ctx, { selectable: false, fg: statusColor(status, theme), wrapMode: "none" })
    this.root.add(this.#label)
    this.root.add(this.#subject)
    this.root.add(this.#details)
    this.root.add(this.#status)
    this.#render()
  }

  update(header: ToolHeader, status: ToolStatus): boolean {
    if (sameHeader(header, this.#header) && status === this.#toolStatus) return false
    this.#header = header
    this.#toolStatus = status
    this.#render()
    return true
  }

  setWidth(width: number): boolean {
    if (width === this.#width) return false
    this.#width = width
    if (this.#header.subject?.type === "path") this.#render()
    return true
  }

  #render(): void {
    const header = this.#header
    this.#label.content = `${header.label}${header.subject ? " " : ""}`
    this.#subject.content = subjectContent(header.subject, this.#theme, this.#cwd, this.#subjectWidth())
    this.#details.visible = header.details.length > 0
    this.#details.content = header.details.length > 0 ? ` · ${header.details.join(" · ")}` : ""
    this.#status.content = toolSuffix[this.#toolStatus]
    this.#status.fg = statusColor(this.#toolStatus, this.#theme)
  }

  #subjectWidth(): number {
    const fixed = textWidth(this.#header.label) + textWidth(this.#header.details.join(" · ")) + 8
    return Math.max(8, this.#width - fixed)
  }
}

abstract class RowBodyView implements OwnedToolBodyView {
  readonly root: BoxRenderable
  abstract readonly type: ToolBody["type"]

  readonly #ctx: RenderContext
  readonly #theme: Theme
  readonly #expandHint: string | undefined
  readonly #rows: TextRenderable[] = []
  #top: TextRenderable | undefined
  #bottom: TextRenderable | undefined
  #body: ToolBody
  #preview: ToolPreviewPolicy
  #status: ToolStatus
  #expanded = false
  #width = 76
  #rendered: readonly PresentationLine[] = []
  #renderedStatus: ToolStatus | undefined

  constructor(
    ctx: RenderContext,
    body: ToolBody,
    preview: ToolPreviewPolicy,
    status: ToolStatus,
    theme: Theme,
    expandHint?: string
  ) {
    this.#ctx = ctx
    this.#body = body
    this.#preview = preview
    this.#status = status
    this.#theme = theme
    this.#expandHint = expandHint
    this.root = new BoxRenderable(ctx, { flexDirection: "column", flexShrink: 0 })
    this.#render()
  }

  update(body: ToolBody): boolean {
    if (sameBody(this.#body, body)) return false
    this.#body = body
    this.#render()
    return true
  }

  setPreview(preview: ToolPreviewPolicy): boolean {
    if (samePreview(this.#preview, preview)) return false
    this.#preview = preview
    this.#render()
    return true
  }

  setExpanded(expanded: boolean): boolean {
    if (expanded === this.#expanded) return false
    this.#expanded = expanded
    this.#render()
    return true
  }

  setStatus(status: ToolStatus): boolean {
    if (status === this.#status) return false
    this.#status = status
    this.#render()
    return true
  }

  setWidth(width: number): boolean {
    if (width === this.#width) return false
    this.#width = width
    this.#render()
    return true
  }

  destroy(): void {
    this.root.destroyRecursively()
  }

  protected get body(): ToolBody {
    return this.#body
  }

  protected abstract wrappedLines(width: number): PresentationLine[]

  #render(): void {
    const policy = this.#expanded ? expandedPreview(this.#preview) : this.#preview
    const lines = applyPreview(
      this.wrappedLines(Math.max(1, this.#width - 2)),
      policy,
      this.#expanded ? undefined : this.#expandHint
    )
    this.#reconcile(lines)
  }

  #reconcile(lines: readonly PresentationLine[]): void {
    if (lines.length === 0) {
      this.#clearRows()
      return
    }

    const rail = railColor(this.#status, this.#theme)
    const railChanged = this.#renderedStatus !== this.#status
    if (!this.#top) {
      this.#top = new TextRenderable(this.#ctx, { selectable: false, fg: rail, content: glyphs.toolTop })
      this.#bottom = new TextRenderable(this.#ctx, { selectable: false, fg: rail, content: glyphs.toolBottom })
      this.root.add(this.#top)
      this.root.add(this.#bottom)
    } else if (railChanged) {
      this.#top.fg = rail
      this.#bottom!.fg = rail
    }

    if (this.#rows.length > lines.length && this.#ctx.hasSelection) this.#ctx.clearSelection()
    while (this.#rows.length > lines.length) {
      const row = this.#rows.pop()!
      this.root.remove(row)
      row.destroyRecursively()
    }
    while (this.#rows.length < lines.length) {
      const row = new TextRenderable(this.#ctx, { wrapMode: "none" })
      this.root.insertBefore(row, this.#bottom)
      this.#rows.push(row)
    }
    for (let index = 0; index < lines.length; index++) {
      const line = lines[index]!
      const current = this.#rendered[index]
      if (!railChanged && current?.text === line.text && current.tone === line.tone) continue
      this.#rows[index]!.content = previewLine(line, this.#status, this.#theme)
    }
    this.#rendered = lines.map(line => ({ ...line }))
    this.#renderedStatus = this.#status
  }

  #clearRows(): void {
    if ((this.#rows.length > 0 || this.#top || this.#bottom) && this.#ctx.hasSelection) this.#ctx.clearSelection()
    for (const row of this.#rows.splice(0)) {
      this.root.remove(row)
      row.destroyRecursively()
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
    this.#rendered = []
    this.#renderedStatus = undefined
  }
}

export class TerminalBodyView extends RowBodyView {
  readonly type = "terminal" as const

  protected wrappedLines(width: number): PresentationLine[] {
    const body = this.body
    if (body.type !== "terminal") return []
    return wrapText(body.text, width, "output")
  }
}

export class SourceBodyView extends RowBodyView {
  readonly type = "source" as const

  protected wrappedLines(width: number): PresentationLine[] {
    const body = this.body
    if (body.type !== "source") return []
    const source = splitLines(body.text)
    const startLine = body.startLine ?? 1
    const digits = String(startLine + Math.max(0, source.length - 1)).length
    const gutter = digits + 3
    const contentWidth = Math.max(1, width - gutter)
    const output: PresentationLine[] = []
    for (let index = 0; index < source.length; index++) {
      const parts = wrapToCells(source[index]!, contentWidth)
      for (let part = 0; part < parts.length; part++) {
        const number = part === 0 ? String(startLine + index).padStart(digits) : " ".repeat(digits)
        output.push({ text: `${number} │ ${parts[part]}`, tone: part === 0 ? "normal" : "muted" })
      }
    }
    return output
  }
}

export class DiffBodyView extends RowBodyView {
  readonly type = "diff" as const

  protected wrappedLines(width: number): PresentationLine[] {
    const body = this.body
    if (body.type !== "diff") return []
    const output: PresentationLine[] = []
    for (const line of splitLines(body.text)) {
      const tone = diffTone(line)
      for (const wrapped of wrapToCells(line, width)) output.push({ text: wrapped, tone })
    }
    return output
  }
}

export class TextBodyView extends RowBodyView {
  readonly type = "text" as const

  protected wrappedLines(width: number): PresentationLine[] {
    const body = this.body
    if (body.type !== "text") return []
    return wrapText(body.text, width, body.tone === "normal" ? "normal" : body.tone)
  }
}

class ToolNoticeView {
  readonly root: BoxRenderable

  readonly #ctx: RenderContext
  readonly #theme: Theme
  readonly #cwd: string
  readonly #rows: NoticeRowView[] = []
  #notices: readonly ToolNotice[]

  constructor(ctx: RenderContext, notices: readonly ToolNotice[], theme: Theme, cwd: string) {
    this.#ctx = ctx
    this.#notices = notices
    this.#theme = theme
    this.#cwd = cwd
    this.root = new BoxRenderable(ctx, { flexDirection: "column", flexShrink: 0 })
    this.#reconcile(notices)
  }

  update(notices: readonly ToolNotice[]): boolean {
    if (sameNotices(this.#notices, notices)) return false
    this.#notices = notices
    this.#reconcile(notices)
    return true
  }

  #reconcile(notices: readonly ToolNotice[]): void {
    if (this.#rows.length > notices.length && this.#ctx.hasSelection) this.#ctx.clearSelection()
    while (this.#rows.length > notices.length) {
      const row = this.#rows.pop()!
      this.root.remove(row.root)
      row.root.destroyRecursively()
    }
    for (let index = 0; index < notices.length; index++) {
      const notice = notices[index]!
      const row = this.#rows[index]
      if (row?.type === notice.type) {
        row.update(notice)
        continue
      }
      if (row) {
        if (this.#ctx.hasSelection) this.#ctx.clearSelection()
        this.root.remove(row.root)
        row.root.destroyRecursively()
      }
      const next = new NoticeRowView(this.#ctx, notice, this.#theme, this.#cwd)
      if (row) {
        const anchor = this.#rows[index + 1]?.root
        if (anchor) this.root.insertBefore(next.root, anchor)
        else this.root.add(next.root)
        this.#rows[index] = next
      } else {
        this.root.add(next.root)
        this.#rows.push(next)
      }
    }
  }
}

class NoticeRowView {
  readonly root: BoxRenderable
  readonly type: ToolNotice["type"]

  readonly #theme: Theme
  readonly #cwd: string
  readonly #label: TextRenderable
  readonly #value: TextRenderable
  readonly #closing: TextRenderable
  #notice: ToolNotice

  constructor(ctx: RenderContext, notice: ToolNotice, theme: Theme, cwd: string) {
    this.type = notice.type
    this.#notice = notice
    this.#theme = theme
    this.#cwd = cwd
    this.root = new BoxRenderable(ctx, { flexDirection: "row", flexShrink: 0 })
    this.#label = new TextRenderable(ctx, { selectable: false, wrapMode: "none" })
    this.#value = new TextRenderable(ctx, { wrapMode: "word" })
    this.#closing = new TextRenderable(ctx, { selectable: false, wrapMode: "none" })
    this.root.add(this.#label)
    this.root.add(this.#value)
    this.root.add(this.#closing)
    this.#render()
  }

  update(notice: ToolNotice): boolean {
    if (sameNotice(this.#notice, notice)) return false
    this.#notice = notice
    this.#render()
    return true
  }

  #render(): void {
    const notice = this.#notice
    const color = noticeColor(notice.tone, this.#theme)
    if (notice.type === "message") {
      this.#label.content = "["
      this.#label.fg = color
      this.#value.content = notice.text
      this.#value.fg = color
      this.#closing.content = "]"
      this.#closing.fg = color
      return
    }
    this.#label.content = `[${notice.label}: `
    this.#label.fg = color
    this.#value.content = new StyledText([fg(color)(link(fileUrl(this.#cwd, notice.path))(notice.path))])
    this.#closing.content = "]"
    this.#closing.fg = color
  }
}

function createBodyView(
  ctx: RenderContext,
  body: ToolBody,
  preview: ToolPreviewPolicy,
  status: ToolStatus,
  theme: Theme,
  expandHint?: string
): OwnedToolBodyView {
  switch (body.type) {
    case "terminal":
      return new TerminalBodyView(ctx, body, preview, status, theme, expandHint)
    case "source":
      return new SourceBodyView(ctx, body, preview, status, theme, expandHint)
    case "diff":
      return new DiffBodyView(ctx, body, preview, status, theme, expandHint)
    case "text":
      return new TextBodyView(ctx, body, preview, status, theme, expandHint)
    default:
      return assertNever(body)
  }
}

function subjectContent(subject: ToolHeader["subject"], theme: Theme, cwd: string, width: number): StyledText | string {
  if (!subject) return ""
  switch (subject.type) {
    case "command":
      return new StyledText([fg(theme.text.shell)(`$ ${subject.text}`)])
    case "path": {
      const display = displayPath(cwd, subject.path, width)
      return new StyledText([fg(theme.text.primary)(link(fileUrl(cwd, subject.path))(display))])
    }
    case "task":
      return new StyledText([fg(theme.text.accent)(subject.id)])
    case "text":
      return subject.text
    default:
      return assertNever(subject)
  }
}

function displayPath(cwd: string, path: string, width: number): string {
  const absolute = resolve(cwd || ".", path)
  const candidate = isAbsolute(path) ? relative(cwd || ".", absolute) || "." : path
  if (textWidth(candidate) <= width) return candidate
  const tailWidth = Math.max(1, width - 1)
  const tail = truncateFromLeft(candidate, tailWidth)
  return `…${tail}`
}

function truncateFromLeft(value: string, width: number): string {
  if (textWidth(value) <= width) return value
  let output = ""
  for (const scalar of Array.from(value).toReversed()) {
    if (textWidth(`${scalar}${output}`) > width) break
    output = scalar + output
  }
  return output || truncateToCells(value, width)
}

function fileUrl(cwd: string, path: string): string {
  return pathToFileURL(resolve(cwd || ".", path)).href
}

function expandedPreview(preview: ToolPreviewPolicy): ToolPreviewPolicy {
  switch (preview.type) {
    case "hidden":
    case "head":
      return { type: "head", rows: 200 }
    case "tail":
      return { type: "tail", rows: 200 }
    case "edges": {
      const compactRows = preview.head + preview.tail
      if (compactRows === 0) return { type: "head", rows: 200 }
      const head = Math.round((200 * preview.head) / compactRows)
      return { type: "edges", head, tail: 200 - head }
    }
    default:
      return assertNever(preview)
  }
}

function applyPreview(
  source: readonly PresentationLine[],
  policy: ToolPreviewPolicy,
  expandHint: string | undefined
): PresentationLine[] {
  if (policy.type === "hidden") return []
  if (policy.type === "head") return headPreview(source, policy.rows, expandHint)
  if (policy.type === "tail") return tailPreview(source, policy.rows, expandHint)

  const limit = policy.head + policy.tail
  if (source.length <= limit) return [...source]
  if (limit <= 1) return [omissionLine("middle output", expandHint)]
  const head = Math.min(policy.head, limit - 1)
  const tail = Math.max(0, limit - head - 1)
  return [...source.slice(0, head), omissionLine("middle output", expandHint), ...(tail > 0 ? source.slice(-tail) : [])]
}

function headPreview(
  source: readonly PresentationLine[],
  rows: number,
  expandHint: string | undefined
): PresentationLine[] {
  if (source.length <= rows) return [...source]
  if (rows <= 1) return [omissionLine("more output", expandHint)]
  return [...source.slice(0, rows - 1), omissionLine("more output", expandHint)]
}

function tailPreview(
  source: readonly PresentationLine[],
  rows: number,
  expandHint: string | undefined
): PresentationLine[] {
  if (source.length <= rows) return [...source]
  if (rows <= 1) return [omissionLine("earlier output", expandHint)]
  return [omissionLine("earlier output", expandHint), ...source.slice(-(rows - 1))]
}

function omissionLine(label: string, expandHint: string | undefined): PresentationLine {
  return { text: expandHint ? `… ${expandHint} to expand · ${label}` : `… ${label}`, tone: "muted" }
}

function wrapText(text: string, width: number, tone: LineTone): PresentationLine[] {
  const output: PresentationLine[] = []
  for (const line of splitLines(text)) {
    for (const wrapped of wrapToCells(line, width)) output.push({ text: wrapped, tone })
  }
  return output
}

function splitLines(text: string): string[] {
  return text.replace(/[\r\n]+$/, "").split(/\r?\n/)
}

function diffTone(line: string): LineTone {
  if (line.startsWith("+") && !line.startsWith("+++")) return "success"
  if (line.startsWith("-") && !line.startsWith("---")) return "error"
  return "muted"
}

function previewLine(line: PresentationLine, status: ToolStatus, theme: Theme): StyledText {
  return new StyledText([fg(railColor(status, theme))(glyphs.toolBody), fg(lineColor(line.tone, theme))(line.text)])
}

function railColor(status: ToolStatus, theme: Theme): string {
  return theme.text[toolRailTone[status]]
}

function statusColor(status: ToolStatus, theme: Theme): string {
  return theme.text[toolRailTone[status]]
}

function lineColor(tone: LineTone, theme: Theme): string {
  switch (tone) {
    case "output":
      return theme.text.toolOutput
    case "normal":
      return theme.text.primary
    case "muted":
      return theme.text.muted
    case "warning":
      return theme.text.warning
    case "success":
      return theme.diff.added
    case "error":
      return theme.diff.removed
    default:
      return assertNever(tone)
  }
}

function noticeColor(tone: ToolNotice["tone"], theme: Theme): string {
  switch (tone) {
    case "muted":
      return theme.text.muted
    case "warning":
      return theme.text.warning
    case "error":
      return theme.text.error
    default:
      return assertNever(tone)
  }
}

function sameHeader(left: ToolHeader, right: ToolHeader): boolean {
  return (
    left.label === right.label &&
    sameSubject(left.subject, right.subject) &&
    left.details.length === right.details.length &&
    left.details.every((value, index) => value === right.details[index])
  )
}

function sameSubject(left: ToolHeader["subject"], right: ToolHeader["subject"]): boolean {
  if (!left || !right) return left === right
  switch (left.type) {
    case "command":
      return right.type === "command" && left.text === right.text
    case "text":
      return right.type === "text" && left.text === right.text
    case "path":
      return right.type === "path" && left.path === right.path
    case "task":
      return right.type === "task" && left.id === right.id
    default:
      return assertNever(left)
  }
}

function sameBody(left: ToolBody, right: ToolBody): boolean {
  switch (left.type) {
    case "terminal":
      return right.type === "terminal" && left.text === right.text
    case "source":
      return (
        right.type === "source" &&
        left.text === right.text &&
        left.path === right.path &&
        left.startLine === right.startLine
      )
    case "diff":
      return right.type === "diff" && left.text === right.text && left.path === right.path
    case "text":
      return right.type === "text" && left.text === right.text && left.tone === right.tone
    default:
      return assertNever(left)
  }
}

function samePreview(left: ToolPreviewPolicy, right: ToolPreviewPolicy): boolean {
  switch (left.type) {
    case "hidden":
      return right.type === "hidden"
    case "head":
      return right.type === "head" && left.rows === right.rows
    case "tail":
      return right.type === "tail" && left.rows === right.rows
    case "edges":
      return right.type === "edges" && left.head === right.head && left.tail === right.tail
    default:
      return assertNever(left)
  }
}

function sameNotices(left: readonly ToolNotice[], right: readonly ToolNotice[]): boolean {
  if (left.length !== right.length) return false
  return left.every((notice, index) => {
    const candidate = right[index]
    return candidate !== undefined && sameNotice(notice, candidate)
  })
}

function sameNotice(left: ToolNotice, right: ToolNotice): boolean {
  if (left.tone !== right.tone) return false
  if (left.type === "message") return right.type === "message" && left.text === right.text
  return right.type === "path" && left.label === right.label && left.path === right.path
}

function isTerminal(status: ToolStatus | undefined): boolean {
  return status === "done" || status === "failed" || status === "aborted"
}

function assertNever(value: never): never {
  throw new Error(`Unexpected tool view value: ${String(value)}`)
}
