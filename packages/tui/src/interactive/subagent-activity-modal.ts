import {
  BoxRenderable,
  RGBA,
  type CliRenderer,
  type OptimizedBuffer,
  ScrollBoxRenderable,
  TextRenderable
} from "@opentui/core"
import type { SubagentSessionEvents, SubagentSnapshot } from "@with-zi/coding-agent"

import type { Theme } from "../theme.js"
import { visibleAssistantParts, type AssistantMessage } from "./transcript/assistant-projection.js"

export class SubagentActivityModalView {
  readonly root: BoxRenderable
  readonly scroll: ScrollBoxRenderable

  readonly #body: TextRenderable
  readonly #railColor: RGBA
  readonly #railBackground: RGBA
  #content = ""
  #controls = ""

  constructor(renderer: CliRenderer, theme: Theme) {
    this.#railColor = RGBA.fromHex(theme.text.muted)
    this.#railBackground = RGBA.fromHex(theme.surface.panel)
    this.root = new BoxRenderable(renderer, {
      id: "subagent-activity-modal",
      width: "100%",
      height: "36%",
      minWidth: 40,
      minHeight: 12,
      maxWidth: "100%",
      maxHeight: 22,
      flexDirection: "column",
      border: true,
      borderStyle: "rounded",
      borderColor: theme.border.muted,
      titleColor: theme.text.muted,
      backgroundColor: theme.surface.panel,
      paddingX: 1,
      paddingTop: 1,
      paddingBottom: 0,
      gap: 0,
      focusable: true,
      renderAfter: buffer => this.#drawRail(buffer)
    })
    this.scroll = new ScrollBoxRenderable(renderer, {
      id: "subagent-activity-scroll",
      flexGrow: 1,
      minHeight: 1,
      focusable: false,
      scrollY: true,
      viewportCulling: true,
      scrollbarOptions: { visible: true },
      backgroundColor: theme.surface.panel,
      wrapperOptions: { backgroundColor: theme.surface.panel },
      viewportOptions: { backgroundColor: theme.surface.panel },
      contentOptions: { backgroundColor: theme.surface.panel }
    })
    this.#body = new TextRenderable(renderer, {
      id: "subagent-activity-content",
      width: "100%",
      flexShrink: 0,
      wrapMode: "word",
      fg: theme.text.primary,
      bg: theme.surface.panel,
      content: ""
    })
    this.scroll.add(this.#body)
    this.root.add(this.scroll)
  }

  setControls(controls: string): void {
    this.#controls = controls
  }

  #drawRail(buffer: OptimizedBuffer): void {
    if (!this.#controls || this.root.width < 8 || this.root.height < 3) return
    buffer.drawText(
      this.#controls.slice(0, Math.max(0, this.root.width - 4)),
      this.root.screenX + 2,
      this.root.screenY + this.root.height - 1,
      this.#railColor,
      this.#railBackground
    )
  }

  update(
    snapshot: SubagentSnapshot,
    sessionEvents: SubagentSessionEvents | undefined,
    options: { readonly preserveScroll?: boolean } = {}
  ): void {
    const scrollTop = this.scroll.scrollTop
    const title = ` ${snapshot.name} · ${statusLine(snapshot)} `
    if (this.root.title !== title) this.root.title = title

    const content = renderSnapshot(snapshot, sessionEvents)
    if (this.#content !== content) {
      this.#content = content
      this.#body.content = content
    }
    this.scroll.scrollTo(options.preserveScroll ? scrollTop : 0)
  }

  scrollLines(delta: number): void {
    this.scroll.scrollBy(delta, "absolute")
  }

  scrollPages(delta: number): void {
    this.scroll.scrollBy(delta, "viewport")
  }

  jump(position: "top" | "bottom"): void {
    this.scroll.scrollTo(position === "top" ? 0 : this.scroll.scrollHeight)
  }

  destroy(): void {
    this.root.destroyRecursively()
  }
}

function renderSnapshot(snapshot: SubagentSnapshot, sessionEvents: SubagentSessionEvents | undefined): string {
  const rows = [
    snapshot.task ? `task     ${snapshot.task}` : undefined,
    snapshot.sessionId ? `session  ${snapshot.sessionId}` : undefined,
    snapshot.elapsedMs === undefined ? undefined : `elapsed  ${formatDuration(snapshot.elapsedMs)}`
  ].filter((row): row is string => row !== undefined)

  if (rows.length > 0) rows.push("")
  rows.push(...eventRows(sessionEvents))

  const completion = snapshot.completion
  if (!completion) return boundedRows(rows).join("\n")

  rows.push("", `result   ${completion.status} · ${formatDuration(completion.durationMs)}`)
  if (completion.reason) rows.push(`reason   ${completion.reason}`)
  if (completion.error) rows.push(`error    ${completion.error}`)
  if (completion.truncated) rows.push(`         retained preview · ${formatBytes(completion.omittedBytes)} omitted`)
  rows.push("", completion.text.trim() || "[empty completion]")
  return boundedRows(rows).join("\n")
}

type ActivityBlock =
  | {
      readonly type: "assistant"
      readonly sequence: number
      readonly workCycle?: number
      readonly phase: "started" | "streaming" | "ended"
      readonly message: AssistantMessage
    }
  | { readonly type: "line"; readonly sequence: number; readonly workCycle?: number; readonly text: string }

const maxActivityAssistantPartBytes = 24 * 1024
const maxActivityRows = 180
const maxActivityTextBytes = 96 * 1024

function eventRows(sessionEvents: SubagentSessionEvents | undefined): string[] {
  if (!sessionEvents || (sessionEvents.events.length === 0 && sessionEvents.omittedEvents === 0)) {
    return ["activity no child events retained yet"]
  }

  const blocks: ActivityBlock[] = []
  if (sessionEvents.omittedEvents > 0) {
    blocks.push({
      type: "line",
      sequence: 0,
      text: `… ${sessionEvents.omittedEvents} older/oversized events omitted (${formatBytes(sessionEvents.omittedBytes)})`
    })
  }

  for (const entry of sessionEvents.events) {
    const assistant = assistantEvent(entry.event)
    if (assistant) {
      const block = {
        type: "assistant" as const,
        sequence: entry.sequence,
        ...(entry.workCycle === undefined ? {} : { workCycle: entry.workCycle }),
        phase: assistant.phase,
        message: assistant.message
      }
      const previous = blocks.at(-1)
      if (
        previous?.type === "assistant" &&
        previous.workCycle === block.workCycle &&
        block.phase !== "started" &&
        previous.phase !== "ended"
      ) {
        blocks[blocks.length - 1] = block
      } else {
        blocks.push(block)
      }
      continue
    }

    const text = eventSummary(entry.event)
    if (!text) continue
    blocks.push({
      type: "line",
      sequence: entry.sequence,
      ...(entry.workCycle === undefined ? {} : { workCycle: entry.workCycle }),
      text
    })
  }

  if (blocks.length === 0) return ["activity no displayable child events retained yet"]

  const rows = ["activity"]
  for (const block of blocks) rows.push(...activityBlockRows(block))
  return rows
}

function activityBlockRows(block: ActivityBlock): string[] {
  const cycle = block.workCycle === undefined ? "" : ` c${block.workCycle}`
  if (block.type === "line") return [`  ${block.sequence || "…"}.${cycle}  ${block.text}`]

  const rows = [`  ${block.sequence}.${cycle}  assistant ${block.phase}`]
  const partRows = assistantPartRows(block.message)
  rows.push(...(partRows.length > 0 ? partRows : ["       no visible prose yet"]))
  return rows
}

function assistantEvent(
  event: unknown
): { readonly phase: "started" | "streaming" | "ended"; readonly message: AssistantMessage } | undefined {
  const record: unknown = event
  if (!isRecord(record)) return undefined
  const type = record.type
  if (type !== "message_start" && type !== "message_update" && type !== "message_end") return undefined
  const message = record.message
  if (!isAssistantMessage(message)) return undefined
  return { phase: type === "message_start" ? "started" : type === "message_end" ? "ended" : "streaming", message }
}

function assistantPartRows(message: AssistantMessage): string[] {
  const rows: string[] = []
  let pendingTool: { name: string; status: string; count: number } | undefined

  const flushTool = (): void => {
    if (!pendingTool) return
    const count = pendingTool.count > 1 ? ` ×${pendingTool.count}` : ""
    rows.push(`       ↳ ${pendingTool.name} · ${pendingTool.status}${count}`)
    pendingTool = undefined
  }

  for (const part of visibleAssistantParts(message)) {
    if (part.kind === "tool") {
      if (pendingTool?.name === part.tool.name && pendingTool.status === part.tool.status) {
        pendingTool.count++
      } else {
        flushTool()
        pendingTool = { name: part.tool.name, status: part.tool.status, count: 1 }
      }
      continue
    }

    flushTool()
    if (part.kind === "thinking") {
      rows.push("       thinking")
      rows.push(...indentedContentRows(part.content, "         "))
    } else if (part.kind === "answer") {
      rows.push(...indentedContentRows(part.content, "       "))
    } else {
      rows.push(`       … ${part.count} tool invocation${part.count === 1 ? "" : "s"} not rendered`)
    }
  }
  flushTool()
  if (message.errorMessage) rows.push(`       error: ${message.errorMessage}`)
  return rows
}

function indentedContentRows(content: string, indent: string): string[] {
  const clipped = clipUtf8(content.trim(), maxActivityAssistantPartBytes)
  const rows = clipped.text.split("\n").map(line => `${indent}${line}`)
  if (clipped.omittedBytes > 0) rows.push(`${indent}… ${formatBytes(clipped.omittedBytes)} omitted`)
  return rows
}

function eventSummary(event: unknown): string | undefined {
  const record: unknown = event
  if (!isRecord(record)) return undefined
  const type = typeof record.type === "string" ? record.type : ""
  switch (type) {
    case "message_start":
    case "message_update":
    case "message_end":
    case "turn_start":
    case "turn_end":
      return undefined
    case "tool_start":
    case "tool_execution_start":
      return `tool ${toolName(record)} started`
    case "tool_update":
    case "tool_execution_update":
      return undefined
    case "tool_end":
    case "tool_execution_end":
      return `tool ${toolName(record)} ${booleanField(record, "isError") ? "failed" : "done"}`
    case "agent_start":
      return "agent started"
    case "agent_end":
      return `agent ended · ${booleanField(record, "willRetry") ? "will retry" : "settled"}`
    case "agent_settled":
      return "agent settled"
    case "entry_appended":
      return entryType(record) === "message" ? undefined : `entry appended · ${entryType(record)}`
    case "model_changed":
      return `model changed · ${modelLabel(record)}`
    case "thinking_level_changed":
      return `thinking changed · ${stringField(record, "level") ?? "unknown"}`
    case "queue_update":
      return undefined
    case "subagent_changed":
      return `subagent changed · ${stringField(record, "name") ?? "unknown"}`
    default:
      return type ? `event ${type}` : "event unknown"
  }
}

function isAssistantMessage(value: unknown): value is AssistantMessage {
  return isRecord(value) && value.role === "assistant" && Array.isArray(value.content)
}

function toolName(record: Record<string, unknown>): string {
  const value = record.toolName ?? record.name
  return typeof value === "string" ? value : "tool"
}

function entryType(record: Record<string, unknown>): string {
  const entry = isRecord(record.entry) ? record.entry : undefined
  return entry && typeof entry.type === "string" ? entry.type : "unknown"
}

function modelLabel(record: Record<string, unknown>): string {
  const model = isRecord(record.model) ? record.model : undefined
  const provider = model && typeof model.provider === "string" ? model.provider : "unknown"
  const id = model && typeof model.id === "string" ? model.id : "unknown"
  return `${provider}/${id}`
}

function stringField(value: unknown, field: string): string | undefined {
  if (!isRecord(value)) return undefined
  const fieldValue = value[field]
  return typeof fieldValue === "string" ? fieldValue : undefined
}

function booleanField(value: unknown, field: string): boolean {
  return isRecord(value) && value[field] === true
}

function clipUtf8(text: string, maxBytes: number): { readonly text: string; readonly omittedBytes: number } {
  const bytes = Buffer.from(text)
  if (bytes.byteLength <= maxBytes) return { text, omittedBytes: 0 }
  let end = maxBytes
  while (end > 0 && (bytes[end]! & 0xc0) === 0x80) end--
  return { text: bytes.subarray(0, end).toString("utf8"), omittedBytes: bytes.byteLength - end }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}

function boundedRows(rows: readonly string[]): readonly string[] {
  const retained: string[] = []
  let bytes = 0
  let omitted = 0

  for (let index = rows.length - 1; index >= 0; index--) {
    const row = rows[index]
    if (row === undefined) continue
    const rowBytes = Buffer.byteLength(row) + 1
    if (retained.length >= maxActivityRows || bytes + rowBytes > maxActivityTextBytes) {
      omitted = index + 1
      break
    }
    retained.push(row)
    bytes += rowBytes
  }

  retained.reverse()
  if (omitted === 0) return retained
  return [`… ${omitted} projected rows omitted`, ...retained]
}

function statusLine(snapshot: SubagentSnapshot): string {
  const cycle = snapshot.workCycle ?? snapshot.capturedWorkCycle
  const parts: string[] = [snapshot.lifecycle]
  if (cycle !== undefined) parts.push(`cycle ${cycle}`)
  if (snapshot.completionDelivery) parts.push(`delivery ${snapshot.completionDelivery}`)
  return parts.join(" · ")
}

function formatDuration(ms: number): string {
  const seconds = Math.max(0, Math.floor(ms / 1000))
  if (seconds < 60) return `${seconds}s`
  const minutes = Math.floor(seconds / 60)
  const remainder = seconds % 60
  if (minutes < 60) return `${minutes}m ${remainder}s`
  const hours = Math.floor(minutes / 60)
  return `${hours}h ${minutes % 60}m`
}

function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`
  const kib = bytes / 1024
  if (kib < 1024) return `${kib.toFixed(1)} KiB`
  return `${(kib / 1024).toFixed(1)} MiB`
}
