import type { CliRenderer, KeyEvent } from "@opentui/core"
import type { AgentSession } from "@with-zi/coding-agent"

import type { ClipboardWriter, ClipboardWriteResult } from "./clipboard.js"
import type { InteractiveKeybindings } from "./interactive-keybindings.js"

type NativeSelection = Exclude<ReturnType<CliRenderer["getSelection"]>, null>

type ClipboardCopyRequest =
  | { readonly type: "selection"; readonly selection: NativeSelection; readonly text: string }
  | { readonly type: "last_assistant"; readonly text: string }

type ClipboardCopyState =
  | { readonly type: "idle" }
  | { readonly type: "writing"; readonly request: ClipboardCopyRequest; readonly controller: AbortController }
  | { readonly type: "disposed" }

export class ClipboardCopyController {
  readonly #renderer: CliRenderer
  readonly #keybindings: InteractiveKeybindings
  readonly #writer: ClipboardWriter
  readonly #onConsumed: () => void
  readonly #onSelectionCopied: () => void
  readonly #onMessageCopied: () => void
  readonly #onWarning: (message: string) => void
  #state: ClipboardCopyState = { type: "idle" }

  constructor(
    renderer: CliRenderer,
    keybindings: InteractiveKeybindings,
    writer: ClipboardWriter,
    onConsumed: () => void,
    onSelectionCopied: () => void,
    onMessageCopied: () => void,
    onWarning: (message: string) => void
  ) {
    this.#renderer = renderer
    this.#keybindings = keybindings
    this.#writer = writer
    this.#onConsumed = onConsumed
    this.#onSelectionCopied = onSelectionCopied
    this.#onMessageCopied = onMessageCopied
    this.#onWarning = onWarning
    renderer.keyInput.on("keypress", this.#onKeyPress)
  }

  copyLastAssistant(session: Pick<AgentSession, "getLastAssistantText">): void {
    if (this.#state.type === "disposed") return
    const text = session.getLastAssistantText()
    if (!text) {
      this.#onWarning("No assistant messages to copy yet")
      return
    }
    this.#copy({ type: "last_assistant", text })
  }

  cancel(): void {
    const state = this.#state
    if (state.type !== "writing") return
    this.#state = { type: "idle" }
    state.controller.abort()
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
    this.#copy({ type: "selection", selection, text })
  }

  #copy(request: ClipboardCopyRequest): void {
    const previous = this.#state
    if (previous.type === "disposed") return
    if (previous.type === "writing") previous.controller.abort()

    const writing = { type: "writing" as const, request, controller: new AbortController() }
    this.#state = writing
    let operation: Promise<ClipboardWriteResult>
    try {
      operation = this.#writer.write(request.text, writing.controller.signal)
    } catch {
      this.#fail(writing)
      return
    }
    void operation.then(
      result => this.#finish(writing, result),
      () => this.#fail(writing)
    )
  }

  #finish(writing: Extract<ClipboardCopyState, { type: "writing" }>, result: ClipboardWriteResult): void {
    if (this.#state !== writing) return
    this.#state = { type: "idle" }

    switch (result.type) {
      case "copied":
        this.#succeed(writing.request)
        return
      case "unavailable":
        this.#onWarning(failureMessage(writing.request))
        return
      case "too_large":
        this.#onWarning(tooLargeMessage(writing.request, result.maxBytes))
        return
      default:
        return assertNever(result)
    }
  }

  #succeed(request: ClipboardCopyRequest): void {
    switch (request.type) {
      case "last_assistant":
        this.#onMessageCopied()
        return
      case "selection": {
        this.#onSelectionCopied()
        const current = this.#renderer.getSelection()
        if (current === request.selection && current.getSelectedText() === request.text) {
          this.#renderer.clearSelection()
        }
        return
      }
      default:
        return assertNever(request)
    }
  }

  #fail(writing: Extract<ClipboardCopyState, { type: "writing" }>): void {
    if (this.#state !== writing) return
    this.#state = { type: "idle" }
    this.#onWarning(failureMessage(writing.request))
  }
}

function failureMessage(request: ClipboardCopyRequest): string {
  return request.type === "selection"
    ? "Copy failed; the selection was preserved"
    : "Copy failed; clipboard unavailable"
}

function tooLargeMessage(request: ClipboardCopyRequest, maxBytes: number): string {
  const source = request.type === "selection" ? "Selected text" : "Assistant message"
  return `${source} exceeds the ${formatBytes(maxBytes)} copy limit`
}

function formatBytes(bytes: number): string {
  return bytes % (1024 * 1024) === 0 ? `${bytes / (1024 * 1024)} MiB` : `${bytes} bytes`
}

function assertNever(value: never): never {
  throw new Error(`Unhandled clipboard copy value: ${String(value)}`)
}
