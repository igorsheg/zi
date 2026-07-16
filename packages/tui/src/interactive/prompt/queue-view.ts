import { BoxRenderable, type CliRenderer, TextRenderable } from "@opentui/core"
import type { QueuedInputs } from "@openzi/coding-agent"

import { truncateToCells } from "../../components/cell-text.js"
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
    if ((queue.steering.length === 0 && queue.followUp.length === 0) || maxRows === 0) {
      this.hide()
      return
    }

    this.root.visible = true
    const width = Math.max(0, this.#renderer.width - 2)
    const rows = [
      ...queue.steering.map(entry => ({ id: entry.id, text: `Steering: ${firstLine(entry.text)}` })),
      ...queue.followUp.map(entry => ({ id: entry.id, text: `Follow-up: ${firstLine(entry.text)}` }))
    ]
    const overflow = rows.length + 1 - maxRows
    const visibleRows = overflow > 0 ? rows.slice(0, Math.max(0, maxRows - 2)) : rows
    const dequeueHint = this.#keybindings.getHint("app.message.dequeue")
    const footerRows =
      maxRows === 1
        ? [`${rows.length} queued${dequeueHint ? ` · ${dequeueHint} to edit all` : ""}`]
        : [
            ...(overflow > 0 ? [`… ${rows.length - visibleRows.length} more queued`] : []),
            ...(dequeueHint ? [`↳ ${dequeueHint} to edit all queued messages`] : [])
          ]

    for (const row of visibleRows) this.root.add(this.#row(row.id, row.text, width))
    for (const text of footerRows) this.root.add(this.#row(text, text, width))
  }

  destroy(): void {
    this.root.destroyRecursively()
  }

  #row(id: string | number, text: string, width: number): BoxRenderable {
    const row = new BoxRenderable(this.#renderer, {
      id: `queued-${id}`,
      height: 1,
      paddingLeft: 1,
      paddingRight: 1,
      flexShrink: 0
    })
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

function firstLine(text: string): string {
  return text.split(/\r?\n/, 1)[0] ?? ""
}

function clear(root: BoxRenderable): void {
  for (const child of root.getChildren()) {
    root.remove(child)
    child.destroyRecursively()
  }
}
