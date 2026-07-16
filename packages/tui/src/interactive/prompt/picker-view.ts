import { BoxRenderable, type CliRenderer, TextRenderable } from "@opentui/core"

import { createPickerList, type PickerList } from "../../components/picker-list.js"
import type { Theme } from "../../theme.js"
import type { PickerStack } from "./picker.js"

export class PickerStackView {
  readonly root: BoxRenderable

  readonly #stack: PickerStack
  readonly #theme: Theme
  readonly #filter: () => string
  readonly #title: TextRenderable
  readonly #hint: TextRenderable
  readonly #list: PickerList
  readonly #footer: TextRenderable
  readonly #release: () => void

  constructor(renderer: CliRenderer, stack: PickerStack, theme: Theme, filter: () => string) {
    this.#stack = stack
    this.#theme = theme
    this.#filter = filter
    this.root = new BoxRenderable(renderer, {
      id: "picker-stack",
      flexDirection: "column",
      flexShrink: 0,
      backgroundColor: theme.surface.composer
    })
    this.#title = new TextRenderable(renderer, { height: 1, wrapMode: "none", fg: theme.text.accent })
    this.#hint = new TextRenderable(renderer, { height: 1, wrapMode: "none", fg: theme.text.warning })
    this.#list = createPickerList(renderer, { rows: [], height: 0, theme })
    this.#footer = new TextRenderable(renderer, { height: 1, wrapMode: "none", fg: theme.text.muted })
    this.root.add(this.#title)
    this.root.add(this.#hint)
    this.root.add(this.#list.root)
    this.root.add(this.#footer)
    this.#release = stack.$state.subscribe(() => this.update())
  }

  update(maxHeight = 10): void {
    const presentation = this.#stack.presentation(this.#filter())
    if (!presentation) {
      this.root.visible = false
      this.#list.update({ rows: [], height: 0, theme: this.#theme })
      return
    }

    this.root.visible = true
    let available = Math.max(1, maxHeight)
    const titleVisible = presentation.frame.title.length > 0 && available > 1
    this.#title.visible = titleVisible
    this.#title.content =
      presentation.depth === 1 ? presentation.frame.title : `${presentation.frame.title} · ${presentation.depth}`
    if (titleVisible) available--

    const hintVisible = Boolean(presentation.frame.hint) && available > 1
    this.#hint.visible = hintVisible
    this.#hint.content = presentation.frame.hint ?? ""
    if (hintVisible) available--

    const footerVisible = Boolean(presentation.frame.footer) && available > 1
    this.#footer.visible = footerVisible
    this.#footer.content = presentation.frame.footer ?? ""
    if (footerVisible) available--

    this.#list.update({
      rows: presentation.rows,
      ...(presentation.selectedId ? { selectedId: presentation.selectedId } : {}),
      height: Math.min(available, Math.max(1, Math.min(10, presentation.rows.length))),
      ...(presentation.frame.emptyText ? { emptyText: presentation.frame.emptyText } : {}),
      theme: this.#theme
    })
  }

  destroy(): void {
    this.#release()
    this.root.destroyRecursively()
  }
}
