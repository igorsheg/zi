import { basename, isAbsolute, relative, resolve } from "node:path"
import { pathToFileURL } from "node:url"

import { BoxRenderable, fg, link, StyledText, TextAttributes, TextRenderable, type RenderContext } from "@opentui/core"
import {
  splitTextLines,
  type ToolBody,
  type ToolHeader,
  type ToolNotice,
  type ToolPresentation,
  type ToolPresentationSource,
  type ToolPreviewPolicy,
  type ToolPreviewWindow
} from "@openzi/coding-agent"

import { textWidth, truncateToCells, wrapHeadToCells, wrapTailToCells } from "../../components/cell-text.js"
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

type LineTone = "output" | "normal" | "muted" | "warning" | "success" | "error"

interface PresentationLine {
  readonly text: string
  readonly tone: LineTone
  readonly prefix?: string
  readonly prefixTone?: LineTone
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
  readonly #action: TextRenderable
  readonly #theme: Theme
  readonly #expandHint: string | undefined
  #frame: ToolViewFrame
  #body: OwnedToolBodyView | undefined
  #expanded = false
  #contentWidth = 76
  #startedAt: number | undefined
  #endedAt: number | undefined
  #timingValue: string | undefined
  #actionHint: string | undefined

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
    this.#header = new ToolHeaderView(
      ctx,
      frame.presentation.header,
      frame.status,
      isFoldable(frame.presentation),
      hasCompactBody(frame.presentation),
      theme,
      cwd
    )
    this.#notices = new ToolNoticeView(ctx, frame.presentation.notices, theme, cwd)
    this.#action = new TextRenderable(ctx, { fg: theme.text.muted, visible: false, wrapMode: "word" })
    this.root.add(this.#header.root)
    this.#body = frame.presentation.body
      ? createBodyView(ctx, frame.presentation.body, frame.presentation.preview, frame.status, theme, expandHint)
      : undefined
    if (this.#body) this.root.add(this.#body.root)
    this.root.add(this.#notices.root)
    this.root.add(this.#action)
    this.#trackTiming(undefined, frame.status)
    this.#syncTiming()
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

    let changed = this.#header.update(
      frame.presentation.header,
      frame.status,
      isFoldable(frame.presentation),
      hasCompactBody(frame.presentation)
    )
    if (this.#syncBody(frame.presentation.body, frame.presentation.preview, frame.status)) changed = true
    if (this.#notices.update(frame.presentation.notices)) changed = true
    if (this.#syncTiming()) changed = true
    return changed
  }

  refreshElapsed(): boolean {
    if (!this.isRunning) return false
    return this.#syncTiming()
  }

  setExpanded(expanded: boolean): boolean {
    if (expanded === this.#expanded) return false
    this.#expanded = expanded
    this.#header.setExpanded(expanded)
    this.#body?.setExpanded(expanded)
    this.#notices.setExpanded(expanded)
    this.#syncTiming()
    return true
  }

  setActionHint(hint: string | undefined): boolean {
    if (hint === this.#actionHint) return false
    this.#actionHint = hint
    this.#action.visible = hint !== undefined
    if (hint !== undefined) this.#action.content = `  ${hint}`
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

  #syncTiming(): boolean {
    const timing = this.#timingText()
    if (timing === this.#timingValue) return false
    this.#timingValue = timing
    return this.#header.setTiming(timing)
  }

  #timingText(): string | undefined {
    if (this.#frame.presentation.timing === "hidden" || this.#startedAt === undefined) return undefined
    const running = this.#endedAt === undefined
    if (!running && !this.#expanded) return undefined
    const elapsed = `${(((this.#endedAt ?? performance.now()) - this.#startedAt) / 1_000).toFixed(1)}s`
    return !running && this.#frame.presentation.timing === "started" ? `started in ${elapsed}` : elapsed
  }
}

class ToolHeaderView {
  readonly root: BoxRenderable

  readonly #theme: Theme
  readonly #cwd: string
  readonly #primary: BoxRenderable
  readonly #bullet: TextRenderable
  readonly #label: TextRenderable
  readonly #subject: TextRenderable
  readonly #details: TextRenderable
  readonly #delta: TextRenderable
  readonly #status: TextRenderable
  readonly #timing: TextRenderable
  readonly #secondaryRow: BoxRenderable
  readonly #secondary: TextRenderable
  #header: ToolHeader
  #toolStatus: ToolStatus
  #foldable: boolean
  #compactBodyVisible: boolean
  #expanded = false
  #timingText: string | undefined
  #width = 76

  constructor(
    ctx: RenderContext,
    header: ToolHeader,
    status: ToolStatus,
    foldable: boolean,
    compactBodyVisible: boolean,
    theme: Theme,
    cwd: string
  ) {
    this.#header = header
    this.#toolStatus = status
    this.#foldable = foldable
    this.#compactBodyVisible = compactBodyVisible
    this.#theme = theme
    this.#cwd = cwd
    this.root = new BoxRenderable(ctx, { flexDirection: "column", flexShrink: 0 })
    this.#primary = new BoxRenderable(ctx, { flexDirection: "row", flexShrink: 0 })
    this.#bullet = new TextRenderable(ctx, { selectable: false, wrapMode: "none", flexShrink: 0 })
    this.#label = new TextRenderable(ctx, { selectable: false, wrapMode: "none", flexShrink: 0 })
    this.#subject = new TextRenderable(ctx, { fg: theme.text.primary, wrapMode: "none", flexShrink: 1 })
    this.#details = new TextRenderable(ctx, {
      selectable: false,
      fg: theme.text.muted,
      wrapMode: "none",
      flexShrink: 0
    })
    this.#delta = new TextRenderable(ctx, { selectable: false, wrapMode: "none", flexShrink: 0 })
    this.#status = new TextRenderable(ctx, { selectable: false, wrapMode: "none", flexShrink: 0 })
    this.#timing = new TextRenderable(ctx, { selectable: false, fg: theme.text.muted, wrapMode: "none" })
    this.#secondaryRow = new BoxRenderable(ctx, { flexDirection: "row", flexShrink: 0, visible: false })
    this.#secondary = new TextRenderable(ctx, { fg: theme.text.primary, wrapMode: "word", flexShrink: 1 })

    this.#primary.add(this.#bullet)
    this.#primary.add(this.#label)
    this.#primary.add(this.#subject)
    this.#primary.add(this.#details)
    this.#primary.add(this.#delta)
    this.#primary.add(this.#status)
    this.#primary.add(this.#timing)
    this.#secondaryRow.add(new TextRenderable(ctx, { selectable: false, content: "  ", wrapMode: "none" }))
    this.#secondaryRow.add(this.#secondary)
    this.root.add(this.#primary)
    this.root.add(this.#secondaryRow)
    this.#render()
  }

  update(header: ToolHeader, status: ToolStatus, foldable: boolean, compactBodyVisible: boolean): boolean {
    if (
      sameHeader(header, this.#header) &&
      status === this.#toolStatus &&
      foldable === this.#foldable &&
      compactBodyVisible === this.#compactBodyVisible
    ) {
      return false
    }
    this.#header = header
    this.#toolStatus = status
    this.#foldable = foldable
    this.#compactBodyVisible = compactBodyVisible
    this.#render()
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
    const header = this.#header
    const status = header.status ?? lifecycleStatus(this.#toolStatus)
    this.#bullet.content = this.#expanded && this.#foldable ? glyphs.toolExpanded : toolGlyph(this.#toolStatus)
    this.#bullet.fg = statusColor(this.#toolStatus, this.#theme)
    this.#label.content = new StyledText([
      {
        ...fg(this.#theme.text.primary)(`${header.label}${header.subject ? " " : ""}`),
        attributes: TextAttributes.BOLD
      }
    ])
    const details = this.#detailsText(status)
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

    const showSecondary =
      header.secondary !== undefined &&
      (this.#expanded ||
        this.#compactBodyVisible ||
        this.#toolStatus === "running" ||
        this.#toolStatus === "failed" ||
        this.#toolStatus === "aborted")
    this.#secondaryRow.visible = showSecondary
    if (showSecondary) {
      this.#secondary.content = subjectContent(
        header.secondary,
        this.#theme,
        this.#cwd,
        Math.max(1, this.#width - 2),
        false
      )
    }
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

abstract class RowBodyView implements OwnedToolBodyView {
  readonly root: BoxRenderable
  abstract readonly type: ToolBody["type"]

  readonly #ctx: RenderContext
  readonly #theme: Theme
  readonly #expandHint: string | undefined
  readonly #rows: TextRenderable[] = []
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
      Math.max(1, this.#width - textWidth(glyphs.toolBody)),
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

    const railChanged = this.#renderedStatus !== this.#status
    if (this.#rows.length > lines.length && this.#ctx.hasSelection) this.#ctx.clearSelection()
    while (this.#rows.length > lines.length) {
      const row = this.#rows.pop()!
      this.root.remove(row)
      row.destroyRecursively()
    }
    while (this.#rows.length < lines.length) {
      const row = new TextRenderable(this.#ctx, { wrapMode: "none", bg: this.#theme.surface.panel })
      this.root.add(row)
      this.#rows.push(row)
    }
    for (let index = 0; index < lines.length; index++) {
      const line = lines[index]!
      const current = this.#rendered[index]
      if (
        !railChanged &&
        current?.text === line.text &&
        current.tone === line.tone &&
        current.prefix === line.prefix &&
        current.prefixTone === line.prefixTone
      ) {
        continue
      }
      this.#rows[index]!.content = previewLine(line, this.#status, this.#theme)
    }
    this.#rendered = lines.map(line => ({ ...line }))
    this.#renderedStatus = this.#status
  }

  #clearRows(): void {
    if (this.#rows.length > 0 && this.#ctx.hasSelection) this.#ctx.clearSelection()
    for (const row of this.#rows.splice(0)) {
      this.root.remove(row)
      row.destroyRecursively()
    }
    this.#rendered = []
    this.#renderedStatus = undefined
  }
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
    const tone = body.tone === "normal" ? "normal" : body.tone
    return applyDirectionalPreview(textLineSource(body.text, width, tone), policy, expandHint)
  }
}

class ToolNoticeView {
  readonly root: BoxRenderable

  readonly #ctx: RenderContext
  readonly #theme: Theme
  readonly #cwd: string
  readonly #rows: NoticeRowView[] = []
  #notices: readonly ToolNotice[]
  #expanded = false

  constructor(ctx: RenderContext, notices: readonly ToolNotice[], theme: Theme, cwd: string) {
    this.#ctx = ctx
    this.#notices = notices
    this.#theme = theme
    this.#cwd = cwd
    this.root = new BoxRenderable(ctx, { flexDirection: "column", flexShrink: 0 })
    this.#reconcile(this.#visibleNotices())
  }

  update(notices: readonly ToolNotice[]): boolean {
    if (sameNotices(this.#notices, notices)) return false
    this.#notices = notices
    this.#reconcile(this.#visibleNotices())
    return true
  }

  setExpanded(expanded: boolean): boolean {
    if (expanded === this.#expanded) return false
    this.#expanded = expanded
    this.#reconcile(this.#visibleNotices())
    return true
  }

  #visibleNotices(): readonly ToolNotice[] {
    return this.#expanded ? this.#notices : this.#notices.filter(notice => notice.visibility === "always")
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
      this.#label.content = "  "
      this.#label.fg = color
      this.#value.content = notice.text
      this.#value.fg = color
      this.#closing.content = ""
      return
    }
    this.#label.content = `  ${notice.label}: `
    this.#label.fg = color
    this.#value.content = new StyledText([fg(color)(link(fileUrl(this.#cwd, notice.path))(notice.path))])
    this.#closing.content = ""
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
      tone: "normal",
      prefix: `${index === 0 && firstLineVisible ? String(line).padStart(digits) : " ".repeat(digits)} │ `,
      prefixTone: "muted"
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

function omissionLine(label: string, expandHint: string | undefined): PresentationLine {
  return { text: `… ${label}${expandHint ? ` · ${expandHint} details` : ""}`, tone: "muted" }
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
  const prefixWidth = line.prefix ? textWidth(line.prefix) : 0
  const contentWidth = Math.max(1, width - prefixWidth)
  const wrapped =
    direction === "head"
      ? wrapHeadToCells(line.text, contentWidth, limit)
      : wrapTailToCells(line.text, contentWidth, limit)
  const firstLineVisible = direction === "head" || !wrapped.hasMore
  return {
    lines: wrapped.lines.map((text, index) => ({
      ...line,
      text,
      ...(line.prefix ? { prefix: index === 0 && firstLineVisible ? line.prefix : " ".repeat(prefixWidth) } : {})
    })),
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
      output.push(numberedDiffLine(content, newLine++, " ", "normal", digits))
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
  return {
    text,
    tone,
    prefix: `${String(line).padStart(digits)} ${marker} `,
    prefixTone: tone === "normal" ? "muted" : tone
  }
}

function proposedDiffLine(line: string): PresentationLine {
  if (line.startsWith("-")) return { text: line.slice(1), tone: "error", prefix: "− ", prefixTone: "error" }
  if (line.startsWith("+")) return { text: line.slice(1), tone: "success", prefix: "+ ", prefixTone: "success" }
  return { text: line, tone: "muted" }
}

function previewLine(line: PresentationLine, status: ToolStatus, theme: Theme): StyledText {
  return new StyledText([
    fg(railColor(status, theme))(glyphs.toolBody),
    ...(line.prefix ? [fg(lineColor(line.prefixTone ?? "muted", theme))(line.prefix)] : []),
    fg(lineColor(line.tone, theme))(line.text)
  ])
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
      return theme.text.primary
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
      return glyphs.toolPreparing
    case "running":
      return glyphs.toolRunning
    case "ready":
    case "done":
    case "failed":
    case "aborted":
      return glyphs.tool
    default:
      return assertNever(status)
  }
}

function isFoldable(presentation: ToolPresentation): boolean {
  return (
    presentation.body !== undefined ||
    presentation.header.secondary !== undefined ||
    presentation.notices.some(notice => notice.visibility === "detailed")
  )
}

function hasCompactBody(presentation: ToolPresentation): boolean {
  return presentation.body !== undefined && presentation.preview.compact.type !== "hidden"
}

function isTerminal(status: ToolStatus | undefined): boolean {
  return status === "done" || status === "failed" || status === "aborted"
}

function assertNever(value: never): never {
  throw new Error(`Unexpected tool view value: ${String(value)}`)
}
