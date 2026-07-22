import { basename, isAbsolute, relative, resolve } from "node:path"
import { pathToFileURL } from "node:url"

import { BoxRenderable, fg, link, StyledText, TextAttributes, TextRenderable, type RenderContext } from "@opentui/core"
import {
  maxExpandedToolRows,
  maxToolPreviewRows,
  splitTextLines,
  type ToolBody,
  type ToolHeader,
  type ToolNotice,
  type ToolPresentation,
  type ToolPresentationSource,
  type ToolPreviewPolicy,
  type ToolPreviewWindow
} from "@with-zi/coding-agent"

import {
  openTuiTabIndicator,
  openTuiTabWidth,
  textWidth,
  truncateToCells,
  wrapHeadToCells,
  wrapTailToCells,
  wrapToCells
} from "../../components/cell-text.js"
import { createColorRamp } from "../../components/color-ramp.js"
import { glyphs } from "../../glyphs.js"
import type { Theme } from "../../theme.js"
import type { TranscriptItemView } from "./item.js"

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

const runningMarkerFrameMs = 100
const runningMarkerFrames = [0, 1, 2, 3, 4, 3, 2, 1] as const

type LineTone = "output" | "context" | "muted" | "warning" | "success" | "error"

interface PresentationLine {
  readonly text: string
  readonly tone: LineTone
  readonly gutter?: string
  readonly gutterTone?: LineTone
  readonly marker?: string
  readonly markerTone?: LineTone
  readonly selectable?: boolean
}

interface OwnedToolBodyView {
  readonly root: BoxRenderable
  readonly type: ToolBody["type"]
  readonly hasVisibleRows: boolean
  update(body: ToolBody): boolean
  setPreview(preview: ToolPreviewPolicy): boolean
  setExpanded(expanded: boolean): boolean
  setStatus(status: ToolStatus): boolean
  setWidth(width: number): boolean
  destroy(): void
}

export class ToolCallView implements TranscriptItemView {
  readonly root: BoxRenderable

  readonly #ctx: RenderContext
  readonly #header: ToolHeaderView
  readonly #secondary: ToolSecondaryView
  readonly #separator: TextRenderable
  readonly #notices: ToolNoticeView
  readonly #action: ToolActionHintView
  readonly #cap: TextRenderable
  readonly #theme: Theme
  readonly #expandHint: string | undefined
  #frame: ToolViewFrame
  #body: OwnedToolBodyView | undefined
  #expanded = false
  #embedded = false
  #contentWidth = 76
  #startedAt: number | undefined
  #endedAt: number | undefined
  #timingValue: string | undefined
  #chromeStatus: ToolStatus

  constructor(ctx: RenderContext, id: string, frame: ToolViewFrame, theme: Theme, cwd: string, expandHint?: string) {
    this.#ctx = ctx
    this.#frame = frame
    this.#chromeStatus = frame.status
    this.#theme = theme
    this.#expandHint = expandHint
    this.root = new BoxRenderable(ctx, {
      id: `active-tool:${id}`,
      paddingLeft: 1,
      paddingRight: 1,
      flexDirection: "column",
      flexShrink: 0,
      marginTop: 0,
      marginBottom: 1
    })
    this.#header = new ToolHeaderView(ctx, frame.presentation.header, frame.status, theme, cwd)
    this.#secondary = new ToolSecondaryView(
      ctx,
      frame.presentation.header.secondary,
      frame.status,
      theme,
      cwd,
      expandHint
    )
    this.#separator = new TextRenderable(ctx, {
      selectable: false,
      content: glyphs.toolSeparator,
      fg: railColor(frame.status, theme),
      visible: false,
      wrapMode: "none"
    })
    this.#notices = new ToolNoticeView(ctx, frame.presentation.notices, frame.status, theme, cwd, expandHint)
    this.#action = new ToolActionHintView(ctx, frame.status, theme)
    this.#cap = new TextRenderable(ctx, {
      selectable: false,
      content: glyphs.toolCap,
      fg: railColor(frame.status, theme),
      visible: false,
      wrapMode: "none"
    })

    this.root.add(this.#header.root)
    this.root.add(this.#secondary.root)
    this.root.add(this.#separator)
    this.#body = frame.presentation.body
      ? createBodyView(ctx, frame.presentation.body, frame.presentation.preview, frame.status, theme, expandHint)
      : undefined
    this.#contentWidth = Math.max(1, ctx.width - 2)
    this.#header.setWidth(this.#contentWidth)
    this.#secondary.setWidth(this.#contentWidth)
    this.#body?.setWidth(this.#contentWidth)
    this.#notices.setWidth(this.#contentWidth)
    this.#action.setWidth(this.#contentWidth)
    if (this.#body) this.root.add(this.#body.root)
    this.root.add(this.#notices.root)
    this.root.add(this.#action.root)
    this.root.add(this.#cap)
    this.#trackTiming(undefined, frame.status)
    this.#syncTiming()
    this.#syncChrome()
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
    if (this.#secondary.update(frame.presentation.header.secondary, frame.status)) changed = true
    if (this.#syncBody(frame.presentation.body, frame.presentation.preview, frame.status)) changed = true
    if (this.#notices.update(frame.presentation.notices)) changed = true
    if (this.#notices.setStatus(frame.status)) changed = true
    if (this.#action.setStatus(frame.status)) changed = true
    if (this.#syncTiming()) changed = true
    if (this.#syncChrome()) changed = true
    return changed
  }

  refreshRunning(now: number): boolean {
    if (!this.isRunning) return false
    let changed = this.#syncTiming(now)
    if (this.#header.refreshRunningMarker(now)) changed = true
    return changed
  }

  setExpanded(expanded: boolean): boolean {
    if (expanded === this.#expanded) return false
    this.#expanded = expanded
    this.#header.setExpanded(expanded)
    this.#secondary.setExpanded(expanded)
    this.#body?.setExpanded(expanded)
    this.#notices.setExpanded(expanded)
    this.#syncTiming()
    this.#syncChrome()
    return true
  }

  setActionHint(hint: string | undefined): boolean {
    if (!this.#action.setHint(hint)) return false
    this.#syncChrome()
    return true
  }

  setEmbedded(embedded: boolean): void {
    if (embedded === this.#embedded) return
    this.#embedded = embedded
    this.root.paddingLeft = embedded ? 0 : 1
    this.root.paddingRight = embedded ? 0 : 1
    this.#syncWidth()
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

  #syncChrome(): boolean {
    const status = this.#frame.status
    const evidenceVisible =
      (this.#body?.hasVisibleRows ?? false) || this.#notices.hasVisibleRows || this.#action.hasVisibleRows
    const secondaryVisible =
      this.#frame.presentation.header.secondary !== undefined &&
      (this.#expanded || evidenceVisible || status === "running" || status === "failed" || status === "aborted")
    let changed = this.#secondary.setVisible(secondaryVisible)
    const separatorVisible = this.#secondary.hasVisibleRows && evidenceVisible
    const capVisible = this.#secondary.hasVisibleRows || evidenceVisible
    if (this.#separator.visible !== separatorVisible) {
      this.#separator.visible = separatorVisible
      changed = true
    }
    if (this.#cap.visible !== capVisible) {
      this.#cap.visible = capVisible
      changed = true
    }
    if (status !== this.#chromeStatus) {
      const color = railColor(status, this.#theme)
      this.#separator.fg = color
      this.#cap.fg = color
      this.#chromeStatus = status
      changed = true
    }
    return changed
  }

  #syncWidth(): void {
    const width = Math.max(1, this.root.width - (this.#embedded ? 0 : 2))
    if (width === this.#contentWidth) return
    this.#contentWidth = width
    this.#header.setWidth(width)
    this.#secondary.setWidth(width)
    this.#body?.setWidth(width)
    this.#notices.setWidth(width)
    this.#action.setWidth(width)
  }

  #trackTiming(previous: ToolStatus | undefined, next: ToolStatus): void {
    if (next === "running" && previous !== "running" && this.#startedAt === undefined) {
      this.#startedAt = performance.now()
    }
    if (isTerminal(next) && !isTerminal(previous) && this.#startedAt !== undefined) {
      this.#endedAt = performance.now()
    }
  }

  #syncTiming(now = performance.now()): boolean {
    const timing = this.#timingText(now)
    if (timing === this.#timingValue) return false
    this.#timingValue = timing
    return this.#header.setTiming(timing)
  }

  #timingText(now: number): string | undefined {
    if (this.#frame.presentation.timing === "hidden" || this.#startedAt === undefined) return undefined
    const running = this.#endedAt === undefined
    if (!running && !this.#expanded) return undefined
    const elapsed = `${(((this.#endedAt ?? now) - this.#startedAt) / 1_000).toFixed(1)}s`
    return !running && this.#frame.presentation.timing === "started" ? `started in ${elapsed}` : elapsed
  }
}

class ToolHeaderView {
  readonly root: BoxRenderable

  readonly #theme: Theme
  readonly #cwd: string
  readonly #bullet: TextRenderable
  readonly #label: TextRenderable
  readonly #subject: TextRenderable
  readonly #details: TextRenderable
  readonly #delta: TextRenderable
  readonly #status: TextRenderable
  readonly #timing: TextRenderable
  readonly #runningMarkerColors: ReturnType<typeof createColorRamp>
  #header: ToolHeader
  #toolStatus: ToolStatus
  #runningMarkerFrame: number | undefined
  #expanded = false
  #timingText: string | undefined
  #width = 76

  constructor(ctx: RenderContext, header: ToolHeader, status: ToolStatus, theme: Theme, cwd: string) {
    this.#header = header
    this.#toolStatus = status
    this.#theme = theme
    this.#cwd = cwd
    this.#runningMarkerColors = createColorRamp(theme.text.dim, theme.text.accent, 5)
    this.root = new BoxRenderable(ctx, { flexDirection: "row", flexShrink: 0 })
    this.#bullet = new TextRenderable(ctx, { selectable: false, wrapMode: "none", flexShrink: 0 })
    this.#label = new TextRenderable(ctx, { selectable: false, wrapMode: "none", flexShrink: 0 })
    this.#subject = new TextRenderable(ctx, {
      fg: theme.text.primary,
      wrapMode: "none",
      tabIndicator: openTuiTabIndicator,
      flexShrink: 1
    })
    this.#details = new TextRenderable(ctx, {
      selectable: false,
      fg: theme.text.muted,
      wrapMode: "none",
      flexShrink: 0
    })
    this.#delta = new TextRenderable(ctx, { selectable: false, wrapMode: "none", flexShrink: 0 })
    this.#status = new TextRenderable(ctx, { selectable: false, wrapMode: "none", flexShrink: 0 })
    this.#timing = new TextRenderable(ctx, { selectable: false, fg: theme.text.muted, wrapMode: "none" })

    this.root.add(this.#bullet)
    this.root.add(this.#label)
    this.root.add(this.#subject)
    this.root.add(this.#details)
    this.root.add(this.#delta)
    this.root.add(this.#status)
    this.root.add(this.#timing)
    this.#render()
  }

  update(header: ToolHeader, status: ToolStatus): boolean {
    if (sameHeader(header, this.#header) && status === this.#toolStatus) return false
    this.#header = header
    this.#toolStatus = status
    if (status !== "running") this.#runningMarkerFrame = undefined
    this.#render()
    return true
  }

  refreshRunningMarker(now: number): boolean {
    if (this.#toolStatus !== "running") return false
    const frame = Math.floor(now / runningMarkerFrameMs) % runningMarkerFrames.length
    if (frame === this.#runningMarkerFrame) return false
    this.#runningMarkerFrame = frame
    this.#bullet.fg = this.#runningMarkerColors[runningMarkerFrames[frame]!]!
    return true
  }

  setExpanded(expanded: boolean): boolean {
    if (expanded === this.#expanded) return false
    this.#expanded = expanded
    this.#render()
    return true
  }

  setTiming(timing: string | undefined): boolean {
    if (timing === this.#timingText) return false
    this.#timingText = timing
    this.#renderContent()
    return true
  }

  setWidth(width: number): boolean {
    if (width === this.#width) return false
    this.#width = width
    this.#render()
    return true
  }

  #render(): void {
    this.#renderMarker()
    this.#renderContent()
  }

  #renderMarker(): void {
    this.#bullet.content = toolGlyph(this.#toolStatus)
    this.#bullet.fg =
      this.#runningMarkerFrame === undefined
        ? statusColor(this.#toolStatus, this.#theme)
        : this.#runningMarkerColors[runningMarkerFrames[this.#runningMarkerFrame]!]!
  }

  #renderContent(): void {
    const header = this.#header
    const status = header.status ?? lifecycleStatus(this.#toolStatus)
    this.#label.content = new StyledText([
      {
        ...fg(this.#theme.text.primary)(`${header.label}${header.subject ? " " : ""}`),
        attributes: TextAttributes.BOLD
      }
    ])
    const details = this.#detailsText(status)
    this.#subject.visible = header.subject !== undefined
    this.#subject.content = subjectContent(
      header.subject,
      this.#theme,
      this.#cwd,
      this.#subjectWidth(status, details),
      !this.#expanded
    )
    this.#subject.wrapMode = this.#expanded ? "word" : "none"
    this.#details.visible = details.length > 0
    this.#details.content = details
    const delta = !this.#expanded ? header.delta : undefined
    this.#delta.visible = delta !== undefined
    if (delta) {
      this.#delta.content = new StyledText([
        fg(this.#theme.diff.added)(` +${delta.added}`),
        fg(this.#theme.text.muted)("/"),
        fg(this.#theme.diff.removed)(`-${delta.removed}`)
      ])
    }
    this.#status.visible = status !== undefined
    this.#status.content = status === undefined ? "" : ` · ${status}`
    this.#status.fg = statusColor(this.#toolStatus, this.#theme)
    this.#timing.visible = this.#timingText !== undefined
    this.#timing.content = this.#timingText === undefined ? "" : ` · ${this.#timingText}`
  }

  #detailsText(status: string | undefined): string {
    const header = this.#header
    const minimumSubjectWidth = header.subject ? 16 : 0
    const reserved =
      2 +
      textWidth(header.label) +
      (header.subject ? 1 : 0) +
      minimumSubjectWidth +
      this.#deltaWidth() +
      (status ? textWidth(status) + 3 : 0) +
      (this.#timingText ? textWidth(this.#timingText) + 3 : 0)
    const available = Math.max(0, this.#width - reserved)
    let details = ""
    for (const detail of header.details) {
      const next = `${details} · ${detail}`
      if (textWidth(next) > available) break
      details = next
    }
    return details
  }

  #subjectWidth(status: string | undefined, details: string): number {
    const header = this.#header
    const fixed =
      3 +
      textWidth(header.label) +
      (header.subject ? 1 : 0) +
      textWidth(details) +
      this.#deltaWidth() +
      (status ? textWidth(status) + 3 : 0) +
      (this.#timingText ? textWidth(this.#timingText) + 3 : 0)
    return Math.max(1, this.#width - fixed)
  }

  #deltaWidth(): number {
    const delta = !this.#expanded ? this.#header.delta : undefined
    return delta ? textWidth(` +${delta.added}/-${delta.removed}`) : 0
  }
}

interface SecondaryLine {
  readonly type: "path" | "task" | "text" | "omission"
  readonly text: string
  readonly linkPath?: string
}

class ToolSecondaryView {
  readonly root: BoxRenderable

  readonly #ctx: RenderContext
  readonly #theme: Theme
  readonly #cwd: string
  readonly #expandHint: string | undefined
  readonly #command: SecondaryCommandView
  readonly #rows: SecondaryRowView[] = []
  #subject: ToolHeader["secondary"]
  #status: ToolStatus
  #visible = false
  #expanded = false
  #width = 76

  constructor(
    ctx: RenderContext,
    subject: ToolHeader["secondary"],
    status: ToolStatus,
    theme: Theme,
    cwd: string,
    expandHint?: string
  ) {
    this.#ctx = ctx
    this.#subject = subject
    this.#status = status
    this.#theme = theme
    this.#cwd = cwd
    this.#expandHint = expandHint
    this.root = new BoxRenderable(ctx, { flexDirection: "column", flexShrink: 0 })
    this.#command = new SecondaryCommandView(ctx, status, theme)
    this.root.add(this.#command.root)
  }

  get hasVisibleRows(): boolean {
    return this.#command.hasVisibleRows || this.#rows.length > 0
  }

  update(subject: ToolHeader["secondary"], status: ToolStatus): boolean {
    const contentChanged = !sameSubject(subject, this.#subject)
    const statusChanged = status !== this.#status
    if (!contentChanged && !statusChanged) return false
    this.#subject = subject
    this.#status = status
    this.#command.setStatus(status)
    for (const row of this.#rows) row.setStatus(status)
    if (contentChanged) this.#render()
    return true
  }

  setVisible(visible: boolean): boolean {
    if (visible === this.#visible) return false
    this.#visible = visible
    this.#render()
    return true
  }

  setExpanded(expanded: boolean): boolean {
    if (expanded === this.#expanded) return false
    this.#expanded = expanded
    this.#render()
    return true
  }

  setWidth(width: number): boolean {
    if (width === this.#width) return false
    this.#width = width
    this.#render()
    return true
  }

  #render(): void {
    const subject = this.#visible ? this.#subject : undefined
    const limit = this.#expanded ? maxExpandedToolRows : maxToolPreviewRows
    const omission = densityOmission("more context", this.#expanded, this.#expandHint)
    if (subject?.type === "command") {
      this.#clearRows()
      this.#command.update(subject.text, subject.prompt, this.#width, limit, omission)
      return
    }

    this.#command.hide()
    const lines = subject ? secondaryLines(subject, this.#cwd, this.#width, limit, omission) : []
    this.#reconcileRows(lines)
  }

  #reconcileRows(lines: readonly SecondaryLine[]): void {
    if (this.#rows.length > lines.length && this.#ctx.hasSelection) this.#ctx.clearSelection()
    while (this.#rows.length > lines.length) {
      const row = this.#rows.pop()!
      this.root.remove(row.root)
      row.root.destroyRecursively()
    }
    while (this.#rows.length < lines.length) {
      const row = new SecondaryRowView(this.#ctx, this.#status, this.#theme, this.#cwd)
      this.root.add(row.root)
      this.#rows.push(row)
    }
    for (let index = 0; index < lines.length; index++) this.#rows[index]!.update(lines[index]!, this.#status)
  }

  #clearRows(): void {
    this.#reconcileRows([])
  }
}

class SecondaryCommandView {
  readonly root: BoxRenderable

  readonly #ctx: RenderContext
  readonly #theme: Theme
  readonly #commandRow: BoxRenderable
  readonly #rail: TextRenderable
  readonly #prompt: TextRenderable
  readonly #content: TextRenderable
  readonly #omission: SecondaryRowView
  #status: ToolStatus
  #rowCount = 0

  constructor(ctx: RenderContext, status: ToolStatus, theme: Theme) {
    this.#ctx = ctx
    this.#status = status
    this.#theme = theme
    this.root = new BoxRenderable(ctx, { flexDirection: "column", flexShrink: 0 })
    this.#commandRow = new BoxRenderable(ctx, { flexDirection: "row", flexShrink: 0, visible: false })
    this.#rail = new TextRenderable(ctx, { selectable: false, wrapMode: "none", flexShrink: 0 })
    this.#prompt = new TextRenderable(ctx, { selectable: false, fg: theme.text.dim, wrapMode: "none", flexShrink: 0 })
    this.#content = new TextRenderable(ctx, { wrapMode: "char", tabIndicator: openTuiTabIndicator, flexShrink: 0 })
    this.#commandRow.add(this.#rail)
    this.#commandRow.add(this.#prompt)
    this.#commandRow.add(this.#content)
    this.#omission = new SecondaryRowView(ctx, status, theme, "")
    this.#omission.root.visible = false
    this.root.add(this.#commandRow)
    this.root.add(this.#omission.root)
  }

  get hasVisibleRows(): boolean {
    return this.#rowCount > 0
  }

  update(text: string, prompt: boolean, width: number, limit: number, omission: string): void {
    const promptWidth = prompt ? 2 : 0
    const contentWidth = Math.max(openTuiTabWidth, width - textWidth(glyphs.toolRail) - promptWidth)
    const projection = commandProjection(text, contentWidth, limit)
    this.#rowCount = projection.rows + (projection.omitted ? 1 : 0)
    this.#commandRow.visible = projection.rows > 0
    this.#omission.root.visible = projection.omitted
    if (projection.rows > 0) {
      this.#rail.content = Array.from({ length: projection.rows }, () => glyphs.toolRail).join("\n")
      this.#rail.fg = railColor(this.#status, this.#theme)
      this.#prompt.visible = prompt
      if (prompt) {
        this.#prompt.content = Array.from({ length: projection.rows }, (_, index) => (index === 0 ? "$ " : "  ")).join(
          "\n"
        )
      }
      this.#content.width = contentWidth
      this.#content.content = commandContent(projection.text, false, this.#theme, contentWidth, false)
    }
    if (projection.omitted) {
      this.#omission.update({ type: "omission", text: omission }, this.#status)
    }
  }

  hide(): void {
    if (this.#rowCount > 0 && this.#ctx.hasSelection) this.#ctx.clearSelection()
    this.#rowCount = 0
    this.#commandRow.visible = false
    this.#omission.root.visible = false
  }

  setStatus(status: ToolStatus): void {
    if (status === this.#status) return
    this.#status = status
    this.#rail.fg = railColor(status, this.#theme)
    this.#omission.setStatus(status)
  }
}

class SecondaryRowView {
  readonly root: BoxRenderable

  readonly #theme: Theme
  readonly #cwd: string
  readonly #rail: TextRenderable
  readonly #content: TextRenderable
  #line: SecondaryLine | undefined
  #status: ToolStatus

  constructor(ctx: RenderContext, status: ToolStatus, theme: Theme, cwd: string) {
    this.#status = status
    this.#theme = theme
    this.#cwd = cwd
    this.root = new BoxRenderable(ctx, { flexDirection: "row", flexShrink: 0 })
    this.#rail = new TextRenderable(ctx, {
      selectable: false,
      content: glyphs.toolRail,
      fg: railColor(status, theme),
      wrapMode: "none",
      flexShrink: 0
    })
    this.#content = new TextRenderable(ctx, { wrapMode: "none", tabIndicator: openTuiTabIndicator, flexShrink: 1 })
    this.root.add(this.#rail)
    this.root.add(this.#content)
  }

  update(line: SecondaryLine, status: ToolStatus): void {
    this.setStatus(status)
    if (this.#line?.type === line.type && this.#line.text === line.text && this.#line.linkPath === line.linkPath) return
    this.#line = line
    this.#content.selectable = line.type !== "omission"
    switch (line.type) {
      case "path":
        this.#content.content = new StyledText([
          fg(this.#theme.text.primary)(link(fileUrl(this.#cwd, line.linkPath ?? line.text))(line.text))
        ])
        break
      case "task":
        this.#content.content = new StyledText([fg(this.#theme.text.accent)(line.text)])
        break
      case "text":
        this.#content.content = line.text
        this.#content.fg = this.#theme.text.primary
        break
      case "omission":
        this.#content.content = line.text
        this.#content.fg = this.#theme.text.muted
        break
      default:
        assertNever(line.type)
    }
  }

  setStatus(status: ToolStatus): void {
    if (status === this.#status) return
    this.#status = status
    this.#rail.fg = railColor(status, this.#theme)
  }
}

interface CommandProjection {
  readonly text: string
  readonly rows: number
  readonly omitted: boolean
}

function commandProjection(text: string, width: number, limit: number): CommandProjection {
  const full = commandHead(text, width, limit)
  if (!full.hasMore) return { text, rows: full.rows, omitted: false }
  const head = commandHead(text, width, Math.max(0, limit - 1))
  return { text: head.text, rows: head.rows, omitted: true }
}

function commandHead(
  text: string,
  width: number,
  limit: number
): { readonly text: string; readonly rows: number; readonly hasMore: boolean } {
  const logicalLines = text.length === 0 ? [] : text.split("\n")
  let output = ""
  let rows = 0
  for (let index = 0; index < logicalLines.length; index++) {
    if (rows === limit) return { text: output, rows, hasMore: true }
    const wrapped = wrapHeadToCells(logicalLines[index]!, width, limit - rows)
    if (index > 0) output += "\n"
    output += wrapped.lines.join("")
    rows += wrapped.lines.length
    if (wrapped.hasMore || (rows === limit && index < logicalLines.length - 1)) {
      return { text: output, rows, hasMore: true }
    }
  }
  return { text: output, rows, hasMore: false }
}

function secondaryLines(
  subject: Exclude<NonNullable<ToolHeader["secondary"]>, { readonly type: "command" }>,
  cwd: string,
  width: number,
  limit: number,
  omission: string
): SecondaryLine[] {
  const available = Math.max(1, width - textWidth(glyphs.toolRail))
  switch (subject.type) {
    case "path":
      return [{ type: "path", text: displayPath(cwd, subject.path, available, false), linkPath: subject.path }]
    case "task":
      return boundedSecondaryLines("task", subject.id, available, limit, omission)
    case "text":
      return boundedSecondaryLines("text", subject.text, available, limit, omission)
    default:
      return assertNever(subject)
  }
}

function boundedSecondaryLines(
  type: "task" | "text",
  text: string,
  width: number,
  limit: number,
  omission: string
): SecondaryLine[] {
  const full = wrappedHead(text, width, limit)
  if (!full.hasMore) return full.lines.map(line => ({ type, text: line }))
  const head = wrappedHead(text, width, Math.max(0, limit - 1))
  return [...head.lines.map(line => ({ type, text: line })), { type: "omission", text: omission }]
}

function wrappedHead(
  text: string,
  width: number,
  limit: number
): { readonly lines: readonly string[]; readonly hasMore: boolean } {
  const output: string[] = []
  const logicalLines = splitTextLines(text)
  for (let index = 0; index < logicalLines.length; index++) {
    const wrapped = wrapHeadToCells(logicalLines[index]!, width, limit - output.length)
    output.push(...wrapped.lines)
    if (wrapped.hasMore || (output.length === limit && index < logicalLines.length - 1)) {
      return { lines: output, hasMore: true }
    }
  }
  return { lines: output, hasMore: false }
}

abstract class RowBodyView implements OwnedToolBodyView {
  readonly root: BoxRenderable
  abstract readonly type: ToolBody["type"]

  readonly #ctx: RenderContext
  readonly #theme: Theme
  readonly #expandHint: string | undefined
  readonly #rows: PresentationRowView[] = []
  #body: ToolBody
  #preview: ToolPreviewPolicy
  #status: ToolStatus
  #expanded = false
  #width = 76

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

  get hasVisibleRows(): boolean {
    return this.#rows.length > 0
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
    for (const row of this.#rows) row.setStatus(status)
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

  protected abstract projectLines(
    width: number,
    policy: Exclude<ToolPreviewWindow, { readonly type: "hidden" }>,
    expandHint: string | undefined
  ): PresentationLine[]

  #render(): void {
    const policy = this.#expanded ? this.#preview.detailed : this.#preview.compact
    if (policy.type === "hidden") {
      this.#reconcile([])
      return
    }
    const lines = this.projectLines(
      Math.max(1, this.#width - textWidth(glyphs.toolRail)),
      policy,
      this.#expanded ? undefined : this.#expandHint
    )
    this.#reconcile(lines)
  }

  #reconcile(lines: readonly PresentationLine[]): void {
    if (this.#rows.length > lines.length && this.#ctx.hasSelection) this.#ctx.clearSelection()
    while (this.#rows.length > lines.length) {
      const row = this.#rows.pop()!
      this.root.remove(row.root)
      row.root.destroyRecursively()
    }
    while (this.#rows.length < lines.length) {
      const row = new PresentationRowView(this.#ctx, this.#status, this.#theme)
      this.root.add(row.root)
      this.#rows.push(row)
    }
    for (let index = 0; index < lines.length; index++) this.#rows[index]!.update(lines[index]!)
  }
}

class PresentationRowView {
  readonly root: BoxRenderable

  readonly #theme: Theme
  readonly #rail: TextRenderable
  readonly #gutter: TextRenderable
  readonly #marker: TextRenderable
  readonly #content: TextRenderable
  #line: PresentationLine | undefined
  #status: ToolStatus

  constructor(ctx: RenderContext, status: ToolStatus, theme: Theme) {
    this.#status = status
    this.#theme = theme
    this.root = new BoxRenderable(ctx, { flexDirection: "row", flexShrink: 0 })
    this.#rail = new TextRenderable(ctx, {
      selectable: false,
      content: glyphs.toolRail,
      fg: railColor(status, theme),
      wrapMode: "none",
      flexShrink: 0
    })
    this.#gutter = new TextRenderable(ctx, { selectable: false, wrapMode: "none", flexShrink: 0 })
    this.#marker = new TextRenderable(ctx, { wrapMode: "none", flexShrink: 0 })
    this.#content = new TextRenderable(ctx, { wrapMode: "none", tabIndicator: openTuiTabIndicator, flexShrink: 1 })
    this.root.add(this.#rail)
    this.root.add(this.#gutter)
    this.root.add(this.#marker)
    this.root.add(this.#content)
  }

  update(line: PresentationLine): void {
    if (samePresentationLine(line, this.#line)) return
    this.#line = { ...line }
    this.#gutter.visible = line.gutter !== undefined
    if (line.gutter !== undefined) this.#gutter.content = line.gutter
    this.#gutter.fg = lineColor(line.gutterTone ?? "muted", this.#theme)
    this.#marker.visible = line.marker !== undefined
    if (line.marker !== undefined) this.#marker.content = line.marker
    this.#marker.fg = lineColor(line.markerTone ?? "muted", this.#theme)
    this.#content.content = line.text
    this.#content.fg = lineColor(line.tone, this.#theme)
    this.#content.selectable = line.selectable !== false
  }

  setStatus(status: ToolStatus): void {
    if (status === this.#status) return
    this.#status = status
    this.#rail.fg = railColor(status, this.#theme)
  }
}

function samePresentationLine(left: PresentationLine, right: PresentationLine | undefined): boolean {
  return (
    right !== undefined &&
    left.text === right.text &&
    left.tone === right.tone &&
    left.gutter === right.gutter &&
    left.gutterTone === right.gutterTone &&
    left.marker === right.marker &&
    left.markerTone === right.markerTone &&
    left.selectable === right.selectable
  )
}

export class TerminalBodyView extends RowBodyView {
  readonly type = "terminal" as const

  protected projectLines(
    width: number,
    policy: Exclude<ToolPreviewWindow, { readonly type: "hidden" }>,
    expandHint: string | undefined
  ): PresentationLine[] {
    const body = this.body
    return body.type === "terminal"
      ? applyDirectionalPreview(textLineSource(body.text, width, "output"), policy, expandHint)
      : []
  }
}

export class SourceBodyView extends RowBodyView {
  readonly type = "source" as const

  protected projectLines(
    width: number,
    policy: Exclude<ToolPreviewWindow, { readonly type: "hidden" }>,
    expandHint: string | undefined
  ): PresentationLine[] {
    const body = this.body
    if (body.type !== "source") return []
    const source = splitTextLines(body.text)
    const startLine = body.startLine ?? 1
    const digits = String(startLine + Math.max(0, source.length - 1)).length
    const contentWidth = Math.max(1, width - digits - 3)
    return applyDirectionalPreview(
      {
        length: source.length,
        line(index, direction, limit) {
          return sourceLine(source[index]!, startLine + index, digits, contentWidth, direction, limit)
        }
      },
      policy,
      expandHint
    )
  }
}

export class DiffBodyView extends RowBodyView {
  readonly type = "diff" as const

  protected projectLines(
    width: number,
    policy: Exclude<ToolPreviewWindow, { readonly type: "hidden" }>,
    expandHint: string | undefined
  ): PresentationLine[] {
    const body = this.body
    return body.type === "diff" ? applyDirectionalPreview(diffLineSource(body.text, width), policy, expandHint) : []
  }
}

export class TextBodyView extends RowBodyView {
  readonly type = "text" as const

  protected projectLines(
    width: number,
    policy: Exclude<ToolPreviewWindow, { readonly type: "hidden" }>,
    expandHint: string | undefined
  ): PresentationLine[] {
    const body = this.body
    if (body.type !== "text") return []
    const tone = body.tone === "normal" ? "output" : body.tone
    return applyDirectionalPreview(textLineSource(body.text, width, tone), policy, expandHint)
  }
}

class ToolNoticeView {
  readonly root: BoxRenderable

  readonly #ctx: RenderContext
  readonly #theme: Theme
  readonly #cwd: string
  readonly #expandHint: string | undefined
  readonly #rows: NoticeLineView[] = []
  #notices: readonly ToolNotice[]
  #status: ToolStatus
  #expanded = false
  #width = 76

  constructor(
    ctx: RenderContext,
    notices: readonly ToolNotice[],
    status: ToolStatus,
    theme: Theme,
    cwd: string,
    expandHint?: string
  ) {
    this.#ctx = ctx
    this.#notices = notices
    this.#status = status
    this.#theme = theme
    this.#cwd = cwd
    this.#expandHint = expandHint
    this.root = new BoxRenderable(ctx, { flexDirection: "column", flexShrink: 0 })
    this.#render()
  }

  get hasVisibleRows(): boolean {
    return this.#rows.length > 0
  }

  update(notices: readonly ToolNotice[]): boolean {
    if (sameNotices(this.#notices, notices)) return false
    this.#notices = notices
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
    for (const row of this.#rows) row.setStatus(status)
    return true
  }

  setWidth(width: number): boolean {
    if (width === this.#width) return false
    this.#width = width
    this.#render()
    return true
  }

  #render(): void {
    const notices = this.#expanded ? this.#notices : this.#notices.filter(notice => notice.visibility === "always")
    const limit = this.#expanded ? maxExpandedToolRows : maxToolPreviewRows
    const omission = densityOmission("more notices", this.#expanded, this.#expandHint)
    const lines = projectedNoticeLines(notices, this.#width, limit, omission)
    if (this.#rows.length > lines.length && this.#ctx.hasSelection) this.#ctx.clearSelection()
    while (this.#rows.length > lines.length) {
      const row = this.#rows.pop()!
      this.root.remove(row.root)
      row.root.destroyRecursively()
    }
    while (this.#rows.length < lines.length) {
      const row = new NoticeLineView(this.#ctx, this.#status, this.#theme, this.#cwd)
      this.root.add(row.root)
      this.#rows.push(row)
    }
    for (let index = 0; index < lines.length; index++) this.#rows[index]!.update(lines[index]!)
  }
}

interface NoticeLine {
  readonly label: string
  readonly text: string
  readonly rows: number
  readonly contentWidth: number
  readonly tone: ToolNotice["tone"]
  readonly linkPath?: string
  readonly selectable?: boolean
}

class NoticeLineView {
  readonly root: BoxRenderable

  readonly #theme: Theme
  readonly #cwd: string
  readonly #rail: TextRenderable
  readonly #label: TextRenderable
  readonly #value: TextRenderable
  #status: ToolStatus

  constructor(ctx: RenderContext, status: ToolStatus, theme: Theme, cwd: string) {
    this.#status = status
    this.#theme = theme
    this.#cwd = cwd
    this.root = new BoxRenderable(ctx, { flexDirection: "row", flexShrink: 0 })
    this.#rail = new TextRenderable(ctx, {
      selectable: false,
      content: glyphs.toolRail,
      fg: railColor(status, theme),
      wrapMode: "none",
      flexShrink: 0
    })
    this.#label = new TextRenderable(ctx, { selectable: false, wrapMode: "none", flexShrink: 0 })
    this.#value = new TextRenderable(ctx, { wrapMode: "none", tabIndicator: openTuiTabIndicator, flexShrink: 0 })
    this.root.add(this.#rail)
    this.root.add(this.#label)
    this.root.add(this.#value)
  }

  update(line: NoticeLine): void {
    const color = noticeColor(line.tone, this.#theme)
    this.#rail.content = Array.from({ length: line.rows }, () => glyphs.toolRail).join("\n")
    this.#label.visible = line.label.length > 0
    if (line.label.length > 0) this.#label.content = line.label
    this.#label.fg = color
    this.#value.selectable = line.selectable !== false
    this.#value.width = line.contentWidth
    this.#value.wrapMode = line.linkPath ? "char" : "none"
    this.#value.fg = color
    this.#value.content = line.linkPath
      ? new StyledText([fg(color)(link(fileUrl(this.#cwd, line.linkPath))(line.text))])
      : line.text
  }

  setStatus(status: ToolStatus): void {
    if (status === this.#status) return
    this.#status = status
    this.#rail.fg = railColor(status, this.#theme)
  }
}

function projectedNoticeLines(
  notices: readonly ToolNotice[],
  width: number,
  limit: number,
  omission: string
): NoticeLine[] {
  const full = noticeHead(notices, width, limit)
  if (!full.hasMore) return [...full.lines]
  const head = noticeHead(notices, width, Math.max(0, limit - 1))
  return [
    ...head.lines,
    {
      label: "",
      text: omission,
      rows: 1,
      contentWidth: Math.max(1, width - textWidth(glyphs.toolRail)),
      tone: "muted",
      selectable: false
    }
  ]
}

interface NoticeHead {
  readonly lines: readonly NoticeLine[]
  readonly rows: number
  readonly hasMore: boolean
}

function noticeHead(notices: readonly ToolNotice[], width: number, limit: number): NoticeHead {
  const output: NoticeLine[] = []
  let rows = 0
  for (let index = 0; index < notices.length; index++) {
    if (rows === limit) return { lines: output, rows, hasMore: true }
    const notice = noticeLineHead(notices[index]!, width, limit - rows)
    output.push(...notice.lines)
    rows += notice.rows
    if (notice.hasMore || (rows === limit && index < notices.length - 1)) {
      return { lines: output, rows, hasMore: true }
    }
  }
  return { lines: output, rows, hasMore: false }
}

function noticeLineHead(notice: ToolNotice, width: number, limit: number): NoticeHead {
  const available = Math.max(1, width - textWidth(glyphs.toolRail))
  if (notice.type === "message") {
    const wrapped = wrappedHead(notice.text, available, limit)
    return {
      lines: wrapped.lines.map(text => ({ label: "", text, rows: 1, contentWidth: available, tone: notice.tone })),
      rows: wrapped.lines.length,
      hasMore: wrapped.hasMore
    }
  }

  const label = `${notice.label}: `
  const labelWidth = Math.min(textWidth(label), Math.max(0, available - openTuiTabWidth))
  const displayLabel = labelWidth === 0 ? "" : truncateToCells(label, labelWidth)
  const contentWidth = Math.max(openTuiTabWidth, available - labelWidth)
  const path = commandHead(notice.path, contentWidth, limit)
  return {
    lines:
      path.rows === 0
        ? []
        : [
            {
              label: displayLabel,
              text: path.hasMore ? path.text : notice.path,
              rows: path.rows,
              contentWidth,
              tone: notice.tone,
              linkPath: notice.path
            }
          ],
    rows: path.rows,
    hasMore: path.hasMore
  }
}

class ToolActionHintView {
  readonly root: TextRenderable

  readonly #theme: Theme
  #status: ToolStatus
  #hint: string | undefined
  #width = 76

  constructor(ctx: RenderContext, status: ToolStatus, theme: Theme) {
    this.#status = status
    this.#theme = theme
    this.root = new TextRenderable(ctx, {
      selectable: false,
      visible: false,
      wrapMode: "none",
      tabIndicator: openTuiTabIndicator,
      flexShrink: 0
    })
  }

  get hasVisibleRows(): boolean {
    return this.#hint !== undefined
  }

  setHint(hint: string | undefined): boolean {
    if (hint === this.#hint) return false
    this.#hint = hint
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

  #render(): void {
    this.root.visible = this.#hint !== undefined
    if (!this.#hint) return
    const lines = wrapToCells(this.#hint, Math.max(1, this.#width - textWidth(glyphs.toolRail)))
    const chunks = lines.flatMap((line, index) => [
      fg(railColor(this.#status, this.#theme))(glyphs.toolRail),
      fg(this.#theme.text.muted)(`${line}${index === lines.length - 1 ? "" : "\n"}`)
    ])
    this.root.content = new StyledText(chunks)
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

function subjectContent(
  subject: ToolHeader["subject"],
  theme: Theme,
  cwd: string,
  width: number,
  compact: boolean
): StyledText | string {
  if (!subject) return ""
  switch (subject.type) {
    case "command":
      return commandContent(subject.text, subject.prompt, theme, width, compact)
    case "path": {
      const display = displayPath(cwd, subject.path, width, compact)
      return new StyledText([fg(theme.text.primary)(link(fileUrl(cwd, subject.path))(display))])
    }
    case "task":
      return new StyledText([fg(theme.text.accent)(compact ? truncateToCells(subject.id, width) : subject.id)])
    case "text":
      return compact ? truncateToCells(subject.text.replace(/\s*\n\s*/g, " "), width) : subject.text
    default:
      return assertNever(subject)
  }
}

function commandContent(text: string, prompt: boolean, theme: Theme, width: number, compact: boolean): StyledText {
  const flat = compact ? text.replace(/\s*\n\s*/g, " ") : text
  const commandWidth = Math.max(1, width - (prompt ? 2 : 0))
  const command = compact ? truncateToCells(flat, commandWidth) : flat
  const chunks = prompt ? [fg(theme.text.dim)("$ ")] : []
  let expectsCommand = true
  for (const token of command.match(/'(?:[^']*)'|"(?:\\.|[^"])*"|&&|\|\||[|;&<>]+|\s+|[^\s'"|;&<>]+/g) ?? []) {
    if (/^\s+$/.test(token)) {
      chunks.push(fg(theme.text.primary)(token))
      continue
    }
    if (/^(?:&&|\|\||[|;&<>]+)$/.test(token)) {
      chunks.push(fg(theme.syntax.operator)(token))
      expectsCommand = true
      continue
    }
    if ((token.startsWith("'") && token.endsWith("'")) || (token.startsWith('"') && token.endsWith('"'))) {
      chunks.push(fg(theme.syntax.string)(token))
      expectsCommand = false
      continue
    }
    const color = expectsCommand ? theme.text.shell : token.startsWith("-") ? theme.text.muted : theme.text.primary
    chunks.push(fg(color)(token))
    expectsCommand = false
  }
  return new StyledText(chunks)
}

function displayPath(cwd: string, path: string, width: number, compact: boolean): string {
  const absolute = resolve(cwd || ".", path)
  const relativePath = isAbsolute(path) ? relative(cwd || ".", absolute) || "." : path
  const candidate = compact ? basename(relativePath) || relativePath : relativePath
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

interface DirectionalLineSource {
  readonly length: number
  line(index: number, direction: "head" | "tail", limit: number): CollectedLines
}

interface CollectedLines {
  readonly lines: readonly PresentationLine[]
  readonly hasMore: boolean
}

function textLineSource(text: string, width: number, tone: LineTone): DirectionalLineSource {
  const lines = splitTextLines(text)
  return {
    length: lines.length,
    line(index, direction, limit) {
      const wrapped =
        direction === "head"
          ? wrapHeadToCells(lines[index]!, width, limit)
          : wrapTailToCells(lines[index]!, width, limit)
      return { lines: wrapped.lines.map(value => ({ text: value, tone })), hasMore: wrapped.hasMore }
    }
  }
}

function sourceLine(
  text: string,
  line: number,
  digits: number,
  width: number,
  direction: "head" | "tail",
  limit: number
): CollectedLines {
  const wrapped = direction === "head" ? wrapHeadToCells(text, width, limit) : wrapTailToCells(text, width, limit)
  const firstLineVisible = direction === "head" || !wrapped.hasMore
  return {
    lines: wrapped.lines.map((value, index) => ({
      text: value,
      tone: "output",
      gutter: `${index === 0 && firstLineVisible ? String(line).padStart(digits) : " ".repeat(digits)} │ `,
      gutterTone: "muted"
    })),
    hasMore: wrapped.hasMore
  }
}

function applyDirectionalPreview(
  source: DirectionalLineSource,
  policy: Exclude<ToolPreviewWindow, { readonly type: "hidden" }>,
  expandHint: string | undefined
): PresentationLine[] {
  if (policy.type === "head") {
    const sample = collectHead(source, policy.rows)
    if (!sample.hasMore) return [...sample.lines]
    if (policy.rows <= 1) return [omissionLine("more output", expandHint)]
    return [...sample.lines.slice(0, policy.rows - 1), omissionLine("more output", expandHint)]
  }
  if (policy.type === "tail") {
    const sample = collectTail(source, policy.rows)
    if (!sample.hasMore) return [...sample.lines]
    if (policy.rows <= 1) return [omissionLine("earlier output", expandHint)]
    return [omissionLine("earlier output", expandHint), ...sample.lines.slice(-(policy.rows - 1))]
  }

  const retained = policy.head + policy.tail
  const sample = collectHead(source, retained)
  if (!sample.hasMore) return [...sample.lines]
  if (retained === 0) return [omissionLine("middle output", expandHint)]
  return [
    ...sample.lines.slice(0, policy.head),
    omissionLine("middle output", expandHint),
    ...collectTail(source, policy.tail).lines
  ]
}

function collectHead(source: DirectionalLineSource, limit: number): CollectedLines {
  const lines: PresentationLine[] = []
  for (let index = 0; index < source.length; index++) {
    const wrapped = source.line(index, "head", limit - lines.length)
    lines.push(...wrapped.lines)
    if (wrapped.hasMore || (lines.length === limit && index < source.length - 1)) {
      return { lines, hasMore: true }
    }
  }
  return { lines, hasMore: false }
}

function collectTail(source: DirectionalLineSource, limit: number): CollectedLines {
  const lines: PresentationLine[] = []
  for (let index = source.length - 1; index >= 0; index--) {
    const wrapped = source.line(index, "tail", limit - lines.length)
    lines.unshift(...wrapped.lines)
    if (wrapped.hasMore || (lines.length === limit && index > 0)) {
      return { lines, hasMore: true }
    }
  }
  return { lines, hasMore: false }
}

function densityOmission(label: string, expanded: boolean, expandHint: string | undefined): string {
  return `… ${label}${!expanded && expandHint ? ` · ${expandHint} details` : ""}`
}

function omissionLine(label: string, expandHint: string | undefined): PresentationLine {
  return { text: densityOmission(label, false, expandHint), tone: "muted", selectable: false }
}

interface ParsedHunkHeader {
  readonly oldStart: number
  readonly oldLines: number
  readonly newStart: number
  readonly newLines: number
}

function diffLineSource(diff: string, width: number): DirectionalLineSource {
  const lines = diffLogicalLines(diff)
  return {
    length: lines.length,
    line(index, direction, limit) {
      return presentationLineWindow(lines[index]!, width, direction, limit)
    }
  }
}

function presentationLineWindow(
  line: PresentationLine,
  width: number,
  direction: "head" | "tail",
  limit: number
): CollectedLines {
  const prefixWidth = textWidth(line.gutter ?? "") + textWidth(line.marker ?? "")
  const contentWidth = Math.max(1, width - prefixWidth)
  const wrapped =
    direction === "head"
      ? wrapHeadToCells(line.text, contentWidth, limit)
      : wrapTailToCells(line.text, contentWidth, limit)
  const firstLineVisible = direction === "head" || !wrapped.hasMore
  return {
    lines: wrapped.lines.map((text, index) =>
      index === 0 && firstLineVisible
        ? { ...line, text }
        : {
            text,
            tone: line.tone,
            ...(prefixWidth > 0 ? { gutter: " ".repeat(prefixWidth), gutterTone: "muted" as const } : {})
          }
    ),
    hasMore: wrapped.hasMore
  }
}

function diffLogicalLines(diff: string): PresentationLine[] {
  const lines = splitTextLines(diff)
  const headers = lines.map(parseHunkHeader).filter((header): header is ParsedHunkHeader => header !== undefined)
  const maxLine = headers.reduce(
    (maximum, header) =>
      Math.max(
        maximum,
        header.oldStart + Math.max(0, header.oldLines - 1),
        header.newStart + Math.max(0, header.newLines - 1)
      ),
    1
  )
  const digits = String(maxLine).length
  const output: PresentationLine[] = []
  let oldLine = 0
  let newLine = 0
  let inHunk = false
  let previousNewEnd: number | undefined

  for (const line of lines) {
    const header = parseHunkHeader(line)
    if (header) {
      const nextGap = previousNewEnd === undefined ? 0 : Math.max(0, header.newStart - previousNewEnd - 1)
      if (nextGap > 0) {
        output.push({ text: `… ${nextGap} unchanged ${nextGap === 1 ? "line" : "lines"}`, tone: "muted" })
      }
      oldLine = header.oldStart
      newLine = header.newStart
      previousNewEnd = header.newStart + header.newLines - 1
      inHunk = true
      continue
    }
    if (headers.length > 0 && !inHunk && (line.startsWith("---") || line.startsWith("+++"))) continue
    if (line.startsWith("\\ No newline")) {
      output.push({ text: "No newline at end of file", tone: "muted" })
      continue
    }

    if (!inHunk) {
      output.push(proposedDiffLine(line))
      continue
    }

    const marker = line[0]
    const content = line.slice(1)
    if (marker === "-") {
      output.push(numberedDiffLine(content, oldLine++, "−", "error", digits))
    } else if (marker === "+") {
      output.push(numberedDiffLine(content, newLine++, "+", "success", digits))
    } else if (marker === " ") {
      output.push(numberedDiffLine(content, newLine++, " ", "context", digits))
      oldLine++
    } else {
      output.push({ text: line, tone: "muted" })
    }
  }
  return output
}

function parseHunkHeader(line: string): ParsedHunkHeader | undefined {
  const match = /^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/.exec(line)
  if (!match) return undefined
  const values = [
    Number(match[1]),
    match[2] === undefined ? 1 : Number(match[2]),
    Number(match[3]),
    match[4] === undefined ? 1 : Number(match[4])
  ]
  if (values.some(value => !Number.isSafeInteger(value))) return undefined
  return { oldStart: values[0]!, oldLines: values[1]!, newStart: values[2]!, newLines: values[3]! }
}

function numberedDiffLine(
  text: string,
  line: number,
  marker: "−" | "+" | " ",
  tone: LineTone,
  digits: number
): PresentationLine {
  if (marker === " ") {
    return { text, tone, gutter: `${String(line).padStart(digits)}   `, gutterTone: "muted" }
  }
  return {
    text,
    tone,
    gutter: `${String(line).padStart(digits)} `,
    gutterTone: "muted",
    marker: `${marker} `,
    markerTone: tone
  }
}

function proposedDiffLine(line: string): PresentationLine {
  if (line.startsWith("-")) return { text: line.slice(1), tone: "error", marker: "− ", markerTone: "error" }
  if (line.startsWith("+")) return { text: line.slice(1), tone: "success", marker: "+ ", markerTone: "success" }
  return { text: line, tone: "muted" }
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
    case "context":
      return theme.diff.context
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
    sameSubject(left.secondary, right.secondary) &&
    sameDelta(left.delta, right.delta) &&
    left.status === right.status &&
    left.details.length === right.details.length &&
    left.details.every((value, index) => value === right.details[index])
  )
}

function sameDelta(left: ToolHeader["delta"], right: ToolHeader["delta"]): boolean {
  if (!left || !right) return left === right
  return left.added === right.added && left.removed === right.removed
}

function sameSubject(left: ToolHeader["subject"], right: ToolHeader["subject"]): boolean {
  if (!left || !right) return left === right
  switch (left.type) {
    case "command":
      return right.type === "command" && left.text === right.text && left.prompt === right.prompt
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
  return samePreviewWindow(left.compact, right.compact) && samePreviewWindow(left.detailed, right.detailed)
}

function samePreviewWindow(left: ToolPreviewWindow, right: ToolPreviewWindow): boolean {
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
  if (left.tone !== right.tone || left.visibility !== right.visibility) return false
  if (left.type === "message") return right.type === "message" && left.text === right.text
  return right.type === "path" && left.label === right.label && left.path === right.path
}

function lifecycleStatus(status: ToolStatus): string | undefined {
  switch (status) {
    case "ready":
      return "waiting"
    case "failed":
      return "failed"
    case "aborted":
      return "aborted"
    case "preparing":
    case "running":
    case "done":
      return undefined
    default:
      return assertNever(status)
  }
}

function toolGlyph(status: ToolStatus): string {
  switch (status) {
    case "preparing":
    case "ready":
      return glyphs.toolPreparing
    case "running":
      return glyphs.toolRunning
    case "done":
    case "failed":
    case "aborted":
      return glyphs.tool
    default:
      return assertNever(status)
  }
}

function isTerminal(status: ToolStatus | undefined): boolean {
  return status === "done" || status === "failed" || status === "aborted"
}

function assertNever(value: never): never {
  throw new Error(`Unexpected tool view value: ${String(value)}`)
}
