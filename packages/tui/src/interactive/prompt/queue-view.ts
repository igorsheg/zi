import { BoxRenderable, type CliRenderer, TextRenderable } from "@opentui/core"
import type { QueuedInput, QueuedInputs } from "@with-zi/coding-agent"

import { truncateToCells, wrapHeadToCells } from "../../components/cell-text.js"
import {
  createPendingUserMessageSurface,
  formatUserMessageContent,
  userMessageChromeRows
} from "../../components/user-message.js"
import type { Theme } from "../../theme.js"
import type { InteractiveKeybindings } from "../interactive-keybindings.js"

export class QueuedInputsView {
  readonly root: BoxRenderable

  readonly #renderer: CliRenderer
  readonly #keybindings: InteractiveKeybindings
  readonly #theme: Theme

  constructor(renderer: CliRenderer, keybindings: InteractiveKeybindings, theme: Theme) {
    this.#renderer = renderer
    this.#keybindings = keybindings
    this.#theme = theme
    this.root = new BoxRenderable(renderer, { flexDirection: "column", flexShrink: 0 })
  }

  hide(): void {
    this.root.visible = false
  }

  update(queue: QueuedInputs, maxRows: number): void {
    clear(this.root)
    const entries = queuedEntries(queue)
    if (entries.length === 0 || maxRows <= 0) {
      this.hide()
      return
    }

    const dequeueHint = this.#keybindings.getHint("app.message.dequeue")
    if (maxRows < minimumPendingBlockRows) {
      this.#renderSummary(entries.length, dequeueHint)
      return
    }

    this.root.visible = true
    const width = Math.max(0, this.#renderer.width - 2)
    const layout = layoutBlocks(entries, Math.max(1, width - 2), maxRows)

    let usedRows = layout.usedRows
    for (const block of layout.blocks) this.root.add(this.#block(block))
    if (layout.omitted > 0 && usedRows < maxRows) {
      this.root.add(this.#metaRow(`… ${layout.omitted} more queued`, width))
      usedRows++
    }
    if (dequeueHint && usedRows < maxRows) {
      this.root.add(this.#metaRow(`${dequeueHint} to edit all queued messages`, width))
    }
  }

  destroy(): void {
    this.root.destroyRecursively()
  }

  #renderSummary(count: number, dequeueHint: string | undefined): void {
    this.root.visible = true
    const width = Math.max(0, this.#renderer.width - 2)
    const suffix = dequeueHint ? ` · ${dequeueHint} to edit all` : ""
    this.root.add(this.#metaRow(`${count} queued${suffix}`, width))
  }

  #block(block: PendingBlock): BoxRenderable {
    const root = new BoxRenderable(this.#renderer, { id: `queued-${block.id}`, width: "100%", flexShrink: 0 })
    const surface = createPendingUserMessageSurface(this.#renderer)
    surface.add(
      new TextRenderable(this.#renderer, {
        height: 1,
        wrapMode: "none",
        selectable: false,
        flexShrink: 0,
        fg: this.#theme.text.dim,
        content: block.label
      })
    )
    for (const line of block.lines) {
      surface.add(
        new TextRenderable(this.#renderer, {
          height: 1,
          wrapMode: "none",
          selectable: false,
          flexShrink: 0,
          fg: this.#theme.text.primary,
          content: line.length === 0 ? " " : line
        })
      )
    }
    if (block.truncated) {
      surface.add(
        new TextRenderable(this.#renderer, {
          height: 1,
          wrapMode: "none",
          selectable: false,
          flexShrink: 0,
          fg: this.#theme.text.dim,
          content: "…"
        })
      )
    }
    root.add(surface)
    return root
  }

  #metaRow(text: string, width: number): BoxRenderable {
    const row = new BoxRenderable(this.#renderer, { height: 1, paddingLeft: 1, paddingRight: 1, flexShrink: 0 })
    row.add(
      new TextRenderable(this.#renderer, {
        fg: this.#theme.text.dim,
        wrapMode: "none",
        content: truncateToCells(text, width)
      })
    )
    return row
  }
}

const maxPendingContentRows = 24
const pendingLabelRows = 1
const minimumPendingBlockRows = userMessageChromeRows + pendingLabelRows + 2

interface PendingEntry {
  readonly id: number
  readonly label: string
  readonly text: string
}

interface PendingBlock {
  readonly id: number
  readonly label: string
  readonly lines: readonly string[]
  readonly truncated: boolean
}

interface PendingLayout {
  readonly blocks: readonly PendingBlock[]
  readonly omitted: number
  readonly usedRows: number
}

function queuedEntries(queue: QueuedInputs): PendingEntry[] {
  return [
    ...queue.steering.map(entry => ({ id: entry.id, label: "Steering", text: pendingText(entry) })),
    ...queue.followUp.map(entry => ({ id: entry.id, label: "Follow-up", text: pendingText(entry) }))
  ]
}

function pendingText(entry: QueuedInput): string {
  return formatUserMessageContent([{ text: entry.text }, ...entry.images])
}

function layoutBlocks(entries: readonly PendingEntry[], bodyWidth: number, blockBudget: number): PendingLayout {
  const blocks: PendingBlock[] = []
  let usedRows = 0
  for (const entry of entries) {
    const remainingRows = blockBudget - usedRows
    const contentRows = Math.min(maxPendingContentRows, remainingRows - userMessageChromeRows - pendingLabelRows)
    if (contentRows < 1) break

    const body = wrappedBody(entry.text, bodyWidth, contentRows)
    const rows = blockRowCount(body.lines.length, body.truncated)
    if (rows > remainingRows) break

    blocks.push({ id: entry.id, label: entry.label, lines: body.lines, truncated: body.truncated })
    usedRows += rows
  }
  return { blocks, omitted: entries.length - blocks.length, usedRows }
}

function blockRowCount(bodyLines: number, truncated: boolean): number {
  return userMessageChromeRows + pendingLabelRows + bodyLines + (truncated ? 1 : 0)
}

function wrappedBody(text: string, width: number, contentRows: number): { lines: string[]; truncated: boolean } {
  const body = wrappedBodyLines(text, width, contentRows)
  if (!body.truncated) return body
  const visible = wrappedBodyLines(text, width, Math.max(1, contentRows - 1))
  return { lines: visible.lines, truncated: true }
}

function wrappedBodyLines(text: string, width: number, maxLines: number): { lines: string[]; truncated: boolean } {
  const lines: string[] = []
  const chunks = logicalLines(text)
  while (true) {
    const next = chunks.next()
    if (next.done) return { lines, truncated: false }
    if (lines.length >= maxLines) return { lines, truncated: true }
    const window = wrapHeadToCells(next.value, width, maxLines - lines.length)
    lines.push(...window.lines)
    if (window.hasMore) return { lines, truncated: true }
  }
}

function* logicalLines(text: string): Generator<string> {
  let start = 0
  while (true) {
    const newline = text.indexOf("\n", start)
    if (newline < 0) {
      yield withoutTrailingCarriageReturn(text.slice(start))
      return
    }
    yield withoutTrailingCarriageReturn(text.slice(start, newline))
    start = newline + 1
  }
}

function withoutTrailingCarriageReturn(line: string): string {
  return line.endsWith("\r") ? line.slice(0, -1) : line
}

function clear(root: BoxRenderable): void {
  for (const child of root.getChildren()) {
    root.remove(child)
    child.destroyRecursively()
  }
}
