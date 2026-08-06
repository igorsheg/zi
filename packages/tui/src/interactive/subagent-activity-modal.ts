import { BoxRenderable, fg, StyledText, TextRenderable, type CliRenderer } from "@opentui/core"
import {
  projectToolPresentation,
  type SubagentSessionEvents,
  type SubagentSnapshot,
  type ToolSubject
} from "@with-zi/coding-agent"

import { textWidth, truncateToCells, wrapToCells } from "../components/cell-text.js"
import { glyphs } from "../glyphs.js"
import type { Theme } from "../theme.js"
import type { InteractiveKeybindings } from "./interactive-keybindings.js"
import { visibleAssistantParts, type AssistantMessage } from "./transcript/assistant-projection.js"
import { displayToolPath } from "./transcript/tool-subject.js"

/**
 * Live peek at one child session: a fixed-height dialog pinned where the
 * composer was, with the frame OpenTUI draws natively — the top rule carries
 * the child's identity, the bottom rule carries the only key affordance, and
 * neither costs a content row. The body is a ring buffer over the activity
 * tail and speaks the transcript's vocabulary: `◈ ` and `◆ ` markers over
 * labels from the same tool-presentation authority the parent transcript uses.
 */
export class SubagentActivityModalView {
  readonly root: BoxRenderable

  readonly #renderer: CliRenderer
  readonly #theme: Theme
  readonly #task: TextRenderable
  readonly #body: BoxRenderable
  readonly #rows: readonly TextRenderable[]
  readonly #rowKeys: string[]
  #title = ""
  #taskKey = ""
  #panelRows: number

  constructor(renderer: CliRenderer, keybindings: InteractiveKeybindings, theme: Theme) {
    this.#renderer = renderer
    this.#theme = theme
    this.#panelRows = panelRows(renderer.height)
    this.root = new BoxRenderable(renderer, {
      id: "subagent-activity",
      width: "100%",
      height: this.#panelRows,
      flexShrink: 0,
      flexDirection: "column",
      border: true,
      borderStyle: "rounded",
      borderColor: theme.border.default,
      // The dialog owns focus for as long as it is open, so the frame must not
      // shift to OpenTUI's focused color the moment it appears.
      focusedBorderColor: theme.border.default,
      titleColor: theme.text.muted,
      bottomTitle: ` ${closeHint(keybindings)} close `,
      bottomTitleAlignment: "right",
      // The dialog sits on the session's own plane; only the frame and the
      // backdrop separate it, so it never reads as a lighter block.
      backgroundColor: theme.surface.app,
      overflow: "hidden",
      paddingX: 1,
      focusable: true
    })
    this.#task = activityText(renderer, theme)
    this.#task.fg = theme.text.dim
    // The body fills downward like a terminal and clips rather than reflows, so
    // the ring buffer replaces its head instead of resizing the dialog. It
    // paints no plane of its own; the dialog owns the only one.
    this.#body = new BoxRenderable(renderer, {
      id: "subagent-activity-body",
      width: "100%",
      flexGrow: 1,
      flexDirection: "column",
      overflow: "hidden"
    })
    this.#rows = Array.from({ length: maxActivityRows }, () => activityText(renderer, theme))
    this.#rowKeys = Array.from({ length: maxActivityRows }, () => hiddenRowKey)
    this.root.add(this.#task)
    this.root.add(this.#body)
    for (const row of this.#rows) this.#body.add(row)
  }

  update(snapshot: SubagentSnapshot, sessionEvents: SubagentSessionEvents | undefined, cwd: string): void {
    const rows = panelRows(this.#renderer.height)
    if (this.#panelRows !== rows) {
      this.#panelRows = rows
      this.root.height = rows
    }
    const width = Math.max(minActivityWidth, this.#renderer.width - 4)
    this.tick(snapshot)
    this.#setTask(snapshot.task, width)

    const maxRows = Math.max(1, Math.min(maxActivityRows, rows - borderRows - (snapshot.task ? 1 : 0)))
    const activity = subagentActivityRows(snapshot, sessionEvents, { width, maxRows, cwd })
    for (const [index, row] of this.#rows.entries()) {
      const next = activity[index]
      if (!next) {
        if (this.#rowKeys[index] !== hiddenRowKey) {
          this.#rowKeys[index] = hiddenRowKey
          row.visible = false
        }
        continue
      }
      const key = `${next.kind}:${"status" in next ? next.status : ""}:${next.text}`
      if (this.#rowKeys[index] !== key) {
        this.#rowKeys[index] = key
        row.content = rowContent(next, this.#theme)
      }
      if (!row.visible) row.visible = true
    }
  }

  /** The elapsed clock only moves the title, so frames never reproject the body. */
  tick(snapshot: SubagentSnapshot): void {
    const status = activityStatus(snapshot)
    const elapsed = status.elapsed ? ` · ${status.elapsed}` : ""
    const title = ` ${truncateToCells(`${snapshot.name} · ${status.label}${elapsed}`, Math.max(4, this.#renderer.width - 6))} `
    if (this.#title === title) return
    this.#title = title
    this.root.title = title
  }

  destroy(): void {
    this.root.destroyRecursively()
  }

  #setTask(task: string | undefined, width: number): void {
    const key = `${width}:${task ?? ""}`
    if (this.#taskKey === key) return
    this.#taskKey = key
    this.#task.content = task ? truncateToCells(inlineText(task), width) : ""
    this.#task.visible = Boolean(task)
  }
}

/**
 * The dialog claims a stable share of the terminal so its rows never reflow as
 * the child streams; a short terminal yields the whole screen instead.
 */
export function panelRows(terminalRows: number): number {
  const preferred = Math.min(maxPanelRows, Math.max(minPanelRows, Math.round(terminalRows * 0.4)))
  return Math.min(terminalRows, Math.max(borderRows + 2, preferred))
}

export type ActivityRow =
  | { readonly kind: "action"; readonly status: "running" | "done" | "failed"; readonly text: string }
  | { readonly kind: "prose"; readonly text: string }
  | { readonly kind: "meta"; readonly text: string }
  | { readonly kind: "error"; readonly text: string }

export interface ActivityStatus {
  readonly label: string
  readonly elapsed: string
}

export interface ActivityProjectionOptions {
  readonly width: number
  readonly maxRows: number
  readonly cwd?: string
}

const minPanelRows = 10
const maxPanelRows = 18
const borderRows = 2
const maxActivityRows = maxPanelRows - borderRows - 1
const minActivityWidth = 8
const earlierActivity = "…"
const hiddenRowKey = "hidden"

/**
 * The child's own lifecycle words, carried by the dialog title. The body never
 * repeats them, so a child that has produced no output yet is still fully
 * readable from the frame alone.
 */
export function activityStatus(snapshot: SubagentSnapshot): ActivityStatus {
  const elapsedMs = snapshot.elapsedMs ?? snapshot.completion?.durationMs
  const elapsed = elapsedMs === undefined ? "" : formatDuration(elapsedMs)
  const completion = snapshot.completion
  if (completion) return { label: completion.status, elapsed }
  switch (snapshot.lifecycle) {
    case "starting":
      return { label: "starting", elapsed }
    case "spawn_admitting":
    case "running":
      return { label: "working", elapsed }
    case "interrupting":
      return { label: "interrupting", elapsed }
    case "closing":
      return { label: "closing", elapsed }
    case "idle":
      return { label: "idle", elapsed }
    case "exited":
      return { label: "exited", elapsed }
    default:
      return assertNever(snapshot.lifecycle)
  }
}

export function subagentActivityRows(
  snapshot: SubagentSnapshot,
  sessionEvents: SubagentSessionEvents | undefined,
  options: ActivityProjectionOptions
): readonly ActivityRow[] {
  const projection = activityBlocks(snapshot, sessionEvents, options.cwd ?? "", options.maxRows)
  return tailRows(projection.blocks, Boolean(sessionEvents?.omittedEvents) || projection.omittedEarlier, options)
}

/**
 * One block per thing that happened. Tool calls stay a single line and are
 * upgraded in place when they end, so a peek never reports the same call twice
 * and never grows a nested output rail.
 */
type ActivityBlock =
  | { readonly kind: "action"; readonly status: "running" | "done" | "failed"; readonly text: string }
  | { readonly kind: "prose"; readonly text: string }
  | { readonly kind: "meta"; readonly text: string }
  | { readonly kind: "error"; readonly text: string }

interface ActivityBlocks {
  readonly blocks: readonly ActivityBlock[]
  readonly omittedEarlier: boolean
}

function activityBlocks(
  snapshot: SubagentSnapshot,
  sessionEvents: SubagentSessionEvents | undefined,
  cwd: string,
  maxBlocks: number
): ActivityBlocks {
  const reverseBlocks: ActivityBlock[] = []
  const actionOutcomes = new Map<string, "done" | "failed">()
  const seenActions = new Set<string>()
  const completion = snapshot.completion
  let assistantProjected = false

  if (completion) {
    if (completion.error) reverseBlocks.push({ kind: "error", text: inlineText(completion.error) })
    const text = completion.text.trim()
    if (text) reverseBlocks.push({ kind: "prose", text })
    else if (!completion.error) reverseBlocks.push({ kind: "meta", text: "no result text" })
  }

  const events = sessionEvents?.events ?? []
  let index = events.length - 1
  for (; index >= 0 && reverseBlocks.length < maxBlocks; index--) {
    const event = events[index]?.event
    if (!event) continue
    switch (event.type) {
      case "tool_execution_end": {
        const id = stringField(event, "toolCallId")
        if (id) actionOutcomes.set(id, event.isError === true ? "failed" : "done")
        break
      }
      case "tool_execution_start": {
        const name = stringField(event, "toolName")
        if (!name) break
        const id = stringField(event, "toolCallId")
        if (id && seenActions.has(id)) break
        reverseBlocks.push({
          kind: "action",
          status: id ? (actionOutcomes.get(id) ?? "running") : "running",
          text: actionText(name, event.args, cwd)
        })
        if (id) seenActions.add(id)
        break
      }
      case "message_start":
        assistantProjected = false
        break
      case "message_update":
      case "message_end": {
        if (completion || assistantProjected) break
        const text = assistantProse(event.message)
        if (!text) break
        reverseBlocks.push({ kind: "prose", text })
        assistantProjected = true
        break
      }
      case "auto_retry_start":
        reverseBlocks.push({ kind: "meta", text: retryText(event) })
        break
      default:
        break
    }
  }

  if (reverseBlocks.length === 0) reverseBlocks.push({ kind: "meta", text: "no activity yet" })
  reverseBlocks.reverse()
  return { blocks: reverseBlocks, omittedEarlier: index >= 0 }
}

/**
 * Walks backwards so the wrapped work is proportional to the visible tail
 * rather than to the retained event buffer.
 */
function tailRows(
  blocks: readonly ActivityBlock[],
  omittedEarlier: boolean,
  options: ActivityProjectionOptions
): readonly ActivityRow[] {
  const maxRows = Math.max(1, options.maxRows)
  const rows: ActivityRow[] = []
  let truncated = omittedEarlier
  let index = blocks.length - 1

  for (; index >= 0 && rows.length < maxRows; index--) {
    const block = blocks[index]
    if (!block) continue
    if (block.kind !== "prose") {
      rows.push(lineRow(block, options.width))
      continue
    }
    const window = proseTail(block.text, options.width, maxRows - rows.length)
    if (window.hasMore) truncated = true
    for (let line = window.lines.length - 1; line >= 0; line--) {
      rows.push({ kind: "prose", text: window.lines[line] ?? "" })
    }
  }

  if (index >= 0) truncated = true
  rows.reverse()
  if (!truncated) return rows
  if (rows.length >= maxRows) rows.shift()
  return [{ kind: "meta", text: earlierActivity }, ...rows]
}

/**
 * Prose is soft-wrapped on word boundaries; the hard cell wrap used for tool
 * evidence would split the child's sentences mid-word. Blank lines are dropped
 * because a peek cannot spend rows on paragraph spacing, and only a bounded
 * tail is inspected so a megabyte answer costs the same as a paragraph.
 */
function proseTail(text: string, width: number, maxLines: number): { lines: readonly string[]; hasMore: boolean } {
  const budget = width * maxLines * 4
  const clipped = text.length > budget
  const lines: string[] = []

  for (const paragraph of (clipped ? text.slice(-budget) : text).split("\n")) {
    let line = ""
    for (const word of paragraph.trim().split(/\s+/)) {
      if (!word) continue
      for (const chunk of textWidth(word) > width ? wrapToCells(word, width) : [word]) {
        if (!line) line = chunk
        else if (textWidth(line) + 1 + textWidth(chunk) <= width) line += ` ${chunk}`
        else {
          lines.push(line)
          line = chunk
        }
      }
    }
    if (line) lines.push(line)
  }

  if (lines.length <= maxLines) return { lines, hasMore: clipped }
  return { lines: lines.slice(lines.length - maxLines), hasMore: true }
}

function lineRow(block: Exclude<ActivityBlock, { kind: "prose" }>, width: number): ActivityRow {
  if (block.kind !== "action") return { kind: block.kind, text: truncateToCells(block.text, width) }
  return { kind: "action", status: block.status, text: truncateToCells(block.text, Math.max(1, width - 2)) }
}

/**
 * Tool naming stays with `projectToolPresentation` so the peek, the parent
 * transcript, and future surfaces cannot drift into three vocabularies.
 */
function actionText(name: string, args: unknown, cwd: string): string {
  const header = projectToolPresentation({ status: "running", name, args }).header
  const subject = subjectText(header.subject, cwd)
  return subject ? `${header.label} ${subject}` : header.label
}

function subjectText(subject: ToolSubject | undefined, cwd: string): string {
  if (!subject) return ""
  switch (subject.type) {
    case "command":
      return inlineText(subject.text)
    case "path":
      return displayToolPath(cwd, subject.path, true)
    case "task":
      return subject.id
    case "text":
      return inlineText(subject.text)
    default:
      return assertNever(subject)
  }
}

function rowContent(row: ActivityRow, theme: Theme): StyledText | string {
  switch (row.kind) {
    case "action":
      return new StyledText([
        fg(row.status === "running" ? theme.text.accent : theme.text.dim)(
          row.status === "running" ? glyphs.toolRunning : glyphs.tool
        ),
        fg(theme.text.muted)(row.text)
      ])
    case "prose":
      return new StyledText([fg(theme.text.primary)(row.text)])
    case "meta":
      return new StyledText([fg(theme.text.dim)(row.text)])
    case "error":
      return new StyledText([fg(theme.text.error)(row.text)])
    default:
      return assertNever(row)
  }
}

function closeHint(keybindings: InteractiveKeybindings): string {
  const hint = keybindings.getHint("app.modal.close") ?? "Esc"
  return hint === "Esc" ? "esc" : hint
}

function activityText(renderer: CliRenderer, theme: Theme): TextRenderable {
  return new TextRenderable(renderer, {
    height: 1,
    wrapMode: "none",
    selectable: false,
    flexShrink: 0,
    visible: false,
    fg: theme.text.muted
  })
}

/** Only the child's own words; its tool calls already own the action rows. */
function assistantProse(message: unknown): string {
  if (!isAssistantMessage(message)) return ""
  const answers: string[] = []
  for (const part of visibleAssistantParts(message)) {
    if (part.kind === "answer") answers.push(part.content.trim())
  }
  return answers.join("\n\n").trim()
}

function retryText(event: Readonly<Record<string, unknown>>): string {
  const attempt = numberField(event, "attempt")
  const maxAttempts = numberField(event, "maxAttempts")
  if (attempt === undefined || maxAttempts === undefined) return "retrying"
  return `retrying ${attempt}/${maxAttempts}`
}

function isAssistantMessage(value: unknown): value is AssistantMessage {
  return isRecord(value) && value.role === "assistant" && Array.isArray(value.content)
}

function stringField(value: Readonly<Record<string, unknown>>, field: string): string | undefined {
  const fieldValue = value[field]
  return typeof fieldValue === "string" && fieldValue ? fieldValue : undefined
}

function numberField(value: Readonly<Record<string, unknown>>, field: string): number | undefined {
  const fieldValue = value[field]
  return typeof fieldValue === "number" && Number.isFinite(fieldValue) ? fieldValue : undefined
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}

function inlineText(text: string): string {
  return text.trim().replaceAll(/\s+/g, " ")
}

function formatDuration(ms: number): string {
  const seconds = Math.max(0, Math.floor(ms / 1000))
  if (seconds < 60) return `${seconds}s`
  const minutes = Math.floor(seconds / 60)
  if (minutes < 60) return `${minutes}m ${seconds % 60}s`
  return `${Math.floor(minutes / 60)}h ${minutes % 60}m`
}

function assertNever(value: never): never {
  throw new Error(`Unexpected subagent activity value: ${String(value)}`)
}
