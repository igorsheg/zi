import type { CliRenderer, KeyEvent } from "@opentui/core"

import type { ClipboardWriter, ClipboardWriteResult } from "./clipboard.js"
import type { InteractiveKeybindings } from "./interactive-keybindings.js"

type NativeSelection = Exclude<ReturnType<CliRenderer["getSelection"]>, null>

type SelectionCopyState =
  | { readonly type: "idle" }
  | {
      readonly type: "writing"
      readonly selection: NativeSelection
      readonly text: string
      readonly controller: AbortController
    }
  | { readonly type: "disposed" }

export class SelectionCopyController {
  readonly #renderer: CliRenderer
  readonly #keybindings: InteractiveKeybindings
  readonly #writer: ClipboardWriter
  readonly #onConsumed: () => void
  readonly #onCopied: () => void
  readonly #onWarning: (message: string) => void
  #state: SelectionCopyState = { type: "idle" }

  constructor(
    renderer: CliRenderer,
    keybindings: InteractiveKeybindings,
    writer: ClipboardWriter,
    onConsumed: () => void,
    onCopied: () => void,
    onWarning: (message: string) => void
  ) {
    this.#renderer = renderer
    this.#keybindings = keybindings
    this.#writer = writer
    this.#onConsumed = onConsumed
    this.#onCopied = onCopied
    this.#onWarning = onWarning
    renderer.keyInput.on("keypress", this.#onKeyPress)
  }

  dispose(): void {
    const state = this.#state
    if (state.type === "disposed") return
    this.#state = { type: "disposed" }
    if (state.type === "writing") state.controller.abort()
    this.#renderer.keyInput.off("keypress", this.#onKeyPress)
  }

  #onKeyPress = (key: KeyEvent): void => {
    if (!this.#keybindings.matches(key, "app.selection.copy")) return
    const selection = this.#renderer.getSelection()
    const text = selection?.getSelectedText()
    if (!selection || !text) return

    key.preventDefault()
    key.stopPropagation()
    this.#onConsumed()
    this.#copy(selection, text)
  }

  #copy(selection: NativeSelection, text: string): void {
    const previous = this.#state
    if (previous.type === "disposed") return
    if (previous.type === "writing") previous.controller.abort()

    const writing = { type: "writing" as const, selection, text, controller: new AbortController() }
    this.#state = writing
    let operation: Promise<ClipboardWriteResult>
    try {
      operation = this.#writer.write(text, writing.controller.signal)
    } catch {
      this.#fail(writing)
      return
    }
    void operation.then(
      result => this.#finish(writing, result),
      () => this.#fail(writing)
    )
  }

  #finish(writing: Extract<SelectionCopyState, { type: "writing" }>, result: ClipboardWriteResult): void {
    if (this.#state !== writing) return
    this.#state = { type: "idle" }

    switch (result.type) {
      case "copied": {
        this.#onCopied()
        const current = this.#renderer.getSelection()
        if (current === writing.selection && current.getSelectedText() === writing.text) {
          this.#renderer.clearSelection()
        }
        return
      }
      case "unavailable":
        this.#onWarning("Copy failed; the selection was preserved")
        return
      case "too_large":
        this.#onWarning(`Selected text exceeds the ${formatBytes(result.maxBytes)} copy limit`)
        return
      default:
        return assertNever(result)
    }
  }

  #fail(writing: Extract<SelectionCopyState, { type: "writing" }>): void {
    if (this.#state !== writing) return
    this.#state = { type: "idle" }
    this.#onWarning("Copy failed; the selection was preserved")
  }
}

function formatBytes(bytes: number): string {
  return bytes % (1024 * 1024) === 0 ? `${bytes / (1024 * 1024)} MiB` : `${bytes} bytes`
}

function assertNever(value: never): never {
  throw new Error(`Unhandled clipboard write result: ${String(value)}`)
}
