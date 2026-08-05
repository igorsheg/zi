import { BoxRenderable, type CliRenderer, TextRenderable } from "@opentui/core"

import { textWidth, truncateToCells } from "../../components/cell-text.js"
import { createPickerList, maxPickerListRows, type PickerList } from "../../components/picker-list.js"
import type { Theme } from "../../theme.js"
import type { InteractiveKeybindings } from "../interactive-keybindings.js"
import type { PickerFrame, PickerStack } from "./picker.js"

export class PickerStackView {
  readonly root: BoxRenderable

  readonly #renderer: CliRenderer
  readonly #stack: PickerStack
  readonly #theme: Theme
  readonly #keybindings: InteractiveKeybindings
  readonly #filter: () => string
  readonly #title: TextRenderable
  readonly #hint: TextRenderable
  readonly #list: PickerList
  readonly #footer: TextRenderable
  readonly #keys: TextRenderable

  constructor(
    renderer: CliRenderer,
    stack: PickerStack,
    theme: Theme,
    keybindings: InteractiveKeybindings,
    filter: () => string
  ) {
    this.#renderer = renderer
    this.#stack = stack
    this.#theme = theme
    this.#keybindings = keybindings
    this.#filter = filter
    this.root = new BoxRenderable(renderer, {
      id: "picker-stack",
      flexDirection: "column",
      flexShrink: 0,
      backgroundColor: theme.surface.composer
    })
    this.#title = new TextRenderable(renderer, { height: 1, wrapMode: "none", fg: theme.text.accent })
    this.#hint = new TextRenderable(renderer, { height: 1, wrapMode: "none" })
    this.#list = createPickerList(renderer, { scope: "", rows: [], height: 0, theme })
    this.#footer = new TextRenderable(renderer, { height: 1, wrapMode: "none", fg: theme.text.muted })
    this.#keys = new TextRenderable(renderer, { height: 1, wrapMode: "none", fg: theme.text.muted })
    this.root.add(this.#title)
    this.root.add(this.#hint)
    this.root.add(this.#list.root)
    this.root.add(this.#footer)
    this.root.add(this.#keys)
  }

  update(maxHeight: number): boolean {
    const presentation = this.#stack.presentation(this.#filter())
    if (!presentation || maxHeight <= 0) {
      this.root.visible = false
      this.#list.update({ scope: "", rows: [], height: 0, theme: this.#theme })
      return false
    }

    this.root.visible = true
    let available = maxHeight
    const titleVisible = presentation.frame.title.length > 0 && available > 1
    this.#title.visible = titleVisible
    this.#title.content = presentation.frame.title
    if (titleVisible) available--

    const hintVisible = Boolean(presentation.frame.hint) && available > 1
    this.#hint.visible = hintVisible
    this.#hint.content = presentation.frame.hint ?? ""
    this.#hint.fg = presentation.frame.hintTone === "warning" ? this.#theme.text.warning : this.#theme.text.muted
    if (hintVisible) available--

    const footerVisible = Boolean(presentation.frame.footer) && available > 1
    this.#footer.visible = footerVisible
    this.#footer.content = presentation.frame.footer ?? ""
    if (footerVisible) available--

    // Deliberate (titled) pickers carry the key affordance; transient
    // completion popups stay chromeless.
    const keysVisible = titleVisible && available > 1
    this.#keys.visible = keysVisible
    this.#keys.content = keysText(
      presentation.frame,
      presentation.depth,
      Math.max(1, this.#renderer.width - 2),
      this.#keybindings
    )
    if (keysVisible) available--

    const chromeRows = maxHeight - available
    const listHeight =
      presentation.frame.height === undefined
        ? Math.max(1, Math.min(maxPickerListRows, presentation.rows.length))
        : Math.max(1, presentation.frame.height - chromeRows)
    this.#list.update({
      scope: presentation.frame.id,
      rows: presentation.rows,
      ...(presentation.selectedId ? { selectedId: presentation.selectedId } : {}),
      ...(presentation.frame.disabled ? { disabled: true } : {}),
      height: Math.min(available, listHeight),
      ...(presentation.frame.emptyText ? { emptyText: presentation.frame.emptyText } : {}),
      theme: this.#theme
    })
    return true
  }

  destroy(): void {
    this.#list.destroy()
    this.root.destroyRecursively()
  }
}

function keysText(frame: PickerFrame, depth: number, width: number, keybindings: InteractiveKeybindings): string {
  const up = pickerKeyHint(keybindings.getHint("tui.select.up"))
  const down = pickerKeyHint(keybindings.getHint("tui.select.down"))
  const confirm = pickerKeyHint(keybindings.getHint("tui.select.confirm"))
  const cancel = pickerKeyHint(keybindings.getHint("tui.select.cancel"))
  const keys = [
    up || down ? `${[up, down].filter(Boolean).join("/")} select` : "",
    confirm ? `${confirm} confirm` : "",
    cancel ? `${cancel} ${depth > 1 ? "back" : "close"}` : ""
  ]
    .filter(Boolean)
    .join(" · ")
  if (frame.filter !== "fuzzy") return truncateToCells(keys, width)
  const full = `type to filter · ${keys}`
  return truncateToCells(textWidth(full) <= width ? full : keys, width)
}

function pickerKeyHint(hint: string | undefined): string {
  if (hint === "Up") return "↑"
  if (hint === "Down") return "↓"
  if (hint === "Enter") return "enter"
  if (hint === "Esc") return "esc"
  return hint ?? ""
}
