import {
  BoxRenderable,
  CliRenderEvents,
  type CliRenderer,
  type KeyEvent,
  TextareaRenderable,
  TextRenderable
} from "@opentui/core"
import type { ModelChoice } from "@openzi/coding-agent"

import { createPickerList, type PickerList, type PickerRow } from "../../components/picker-list.js"
import { glyphs } from "../../glyphs.js"
import type { Theme } from "../../theme.js"
import { filterModelChoices, sameModel } from "../model-selector.js"
import type { PromptStore, PromptSurface } from "../stores/prompt.js"

export class ModelSelectorView {
  readonly root: BoxRenderable
  readonly input: TextareaRenderable

  readonly #renderer: CliRenderer
  readonly #store: PromptStore
  readonly #theme: Theme
  readonly #currentModel: ModelChoice["model"]
  readonly #picker: PickerList
  readonly #detail: TextRenderable
  readonly #release: Array<() => void> = []

  constructor(
    renderer: CliRenderer,
    store: PromptStore,
    theme: Theme,
    currentModel: ModelChoice["model"],
    initialSearch: string
  ) {
    this.#renderer = renderer
    this.#store = store
    this.#theme = theme
    this.#currentModel = currentModel
    this.root = new BoxRenderable(renderer, {
      id: "model-selector",
      flexDirection: "column",
      flexShrink: 0,
      backgroundColor: theme.surface.composer
    })
    this.root.add(
      new TextRenderable(renderer, {
        height: 1,
        wrapMode: "none",
        fg: theme.text.warning,
        content: "Only showing models from configured providers. Use /login to add providers."
      })
    )
    this.input = new TextareaRenderable(renderer, {
      id: "model-search-input",
      height: 1,
      minHeight: 1,
      maxHeight: 1,
      wrapMode: "none",
      placeholder: "Search models",
      textColor: theme.text.primary,
      focusedTextColor: theme.text.primary,
      cursorColor: theme.text.primary,
      backgroundColor: theme.surface.composer,
      focusedBackgroundColor: theme.surface.composer,
      onContentChange: () => {
        this.#store.modelQueryChanged(this.input.plainText)
        this.#update()
      }
    })
    this.root.add(this.input)
    this.#picker = createPickerList(renderer, {
      rows: [],
      height: pickerHeight(renderer),
      emptyText: "Loading models…",
      theme
    })
    this.root.add(this.#picker.root)
    this.#detail = new TextRenderable(renderer, { height: 1, wrapMode: "none", fg: theme.text.muted })
    this.root.add(this.#detail)

    this.#release.push(store.$state.subscribe(this.#update))
    renderer.keyInput.on("keypress", this.#onKeyPress)
    renderer.on(CliRenderEvents.RESIZE, this.#update)
    this.#release.push(() => renderer.keyInput.off("keypress", this.#onKeyPress))
    this.#release.push(() => renderer.off(CliRenderEvents.RESIZE, this.#update))
    if (initialSearch) this.input.setText(initialSearch)
    this.input.focus()
  }

  focus(): void {
    this.input.focus()
  }

  destroy(): void {
    for (const release of this.#release.splice(0)) release()
    this.root.destroyRecursively()
  }

  #update = (): void => {
    const surface = this.#store.$state.get().surface
    if (surface.type === "composer") return
    const choices = selectorChoices(surface, this.input.plainText)
    const selectedIndex = surface.type === "loading_models" ? 0 : surface.selectedIndex
    const selected = choices[Math.min(selectedIndex, Math.max(0, choices.length - 1))]
    this.#picker.update({
      rows: choices.map(choice => modelRow(choice, this.#currentModel)),
      ...(selected ? { selectedId: modelId(selected) } : {}),
      height: pickerHeight(this.#renderer),
      emptyText: emptyText(surface),
      theme: this.#theme
    })
    this.#detail.content = selected ? `  Model Name: ${selected.model.name ?? selected.model.id}` : ""
  }

  #onKeyPress = (key: KeyEvent): void => {
    const surface = this.#store.$state.get().surface
    if (surface.type === "composer") return

    const bare = !key.shift && !key.ctrl && !key.meta && !key.super && !key.hyper
    if (bare && key.name === "up") {
      key.preventDefault()
      key.stopPropagation()
      this.#store.moveModelSelection(this.input.plainText, -1)
      return
    }
    if (bare && key.name === "down") {
      key.preventDefault()
      key.stopPropagation()
      this.#store.moveModelSelection(this.input.plainText, 1)
      return
    }
    if (bare && key.name === "return") {
      key.preventDefault()
      key.stopPropagation()
      this.#store.selectModel(this.input.plainText)
      return
    }
    if ((bare && key.name === "escape") || (key.ctrl && key.name === "c")) {
      key.preventDefault()
      key.stopPropagation()
      this.#store.cancelModelSelector()
    }
  }
}

function emptyText(surface: Exclude<PromptSurface, { type: "composer" }>): string {
  if (surface.type === "loading_models") return "Loading models…"
  if (surface.type === "model_selector" && surface.error) return surface.error
  return "No matching models"
}

function selectorChoices(surface: Exclude<PromptSurface, { type: "composer" }>, query: string): readonly ModelChoice[] {
  return surface.type === "loading_models" ? [] : filterModelChoices(surface.choices, query)
}

function modelRow(choice: ModelChoice, currentModel: ModelChoice["model"]): PickerRow {
  return {
    id: modelId(choice),
    label: choice.model.id,
    detail: `[${choice.model.provider}]`,
    ...(sameModel(choice.model, currentModel) ? { metadata: glyphs.check } : {})
  }
}

function modelId(choice: ModelChoice): string {
  return `${choice.model.provider}/${choice.model.id}`
}

function pickerHeight(renderer: CliRenderer): number {
  return Math.max(1, Math.min(10, renderer.height - 3))
}
