import {
  BoxRenderable,
  CliRenderEvents,
  decodePasteBytes,
  type CliRenderer,
  type KeyEvent,
  type PasteEvent,
  stripAnsiSequences,
  TextAttributes
} from "@opentui/core"

import { composerGeometry, createComposer, type Composer, type ComposerSlots } from "../../components/composer.js"
import { ShimmerTextView } from "../../components/shimmer-text.js"
import type { Theme } from "../../theme.js"
import type { BrowserOpener } from "../browser-opener.js"
import { maxPastedTextBytes, type ClipboardReader } from "../clipboard.js"
import type { ExitGestureController } from "../exit-gesture.js"
import type { InteractiveKeybindings, PromptKeyAction } from "../interactive-keybindings.js"
import type { InteractiveStore } from "../interactive-store.js"
import type { SlashController } from "../slash-controller.js"
import { PromptFeedbackView } from "./feedback-view.js"
import { PickerStackView } from "./picker-view.js"
import { QueuedInputsView } from "./queue-view.js"
import { promptInputIsSecret, type PromptWorkflow } from "./state.js"
import { createPromptStore, type PromptSessionActions, type PromptStore } from "./store.js"

export class PromptView {
  readonly root: BoxRenderable

  readonly #renderer: CliRenderer
  readonly #interactive: InteractiveStore
  readonly #keybindings: InteractiveKeybindings
  readonly #exitGestures: ExitGestureController
  readonly #store: PromptStore
  readonly #working: ShimmerTextView
  readonly #feedback: PromptFeedbackView
  readonly #queue: QueuedInputsView
  readonly #composer: Composer
  readonly #input: Composer["input"]
  readonly #pickerStack: PickerStackView
  readonly #release: Array<() => void> = []
  #appliedInputRevision = 0
  #syncedImages: ReturnType<Composer["activeImages"]> = []

  constructor(
    renderer: CliRenderer,
    interactive: InteractiveStore,
    slash: SlashController,
    keybindings: InteractiveKeybindings,
    exitGestures: ExitGestureController,
    browserOpener: BrowserOpener,
    clipboard: ClipboardReader,
    theme: Theme,
    sessionActions?: PromptSessionActions
  ) {
    this.#renderer = renderer
    this.#interactive = interactive
    this.#keybindings = keybindings
    this.#exitGestures = exitGestures
    this.#store = createPromptStore(interactive, slash, sessionActions, clipboard)
    this.root = new BoxRenderable(renderer, { flexDirection: "column", flexShrink: 0 })

    this.#working = new ShimmerTextView(renderer, "Working…", theme.text.muted, theme.text.primary)
    this.#feedback = new PromptFeedbackView(renderer, browserOpener, theme)
    this.#queue = new QueuedInputsView(renderer, keybindings, theme)

    const session = interactive.getSession()
    const geometry = composerGeometry(renderer.width, renderer.height)
    this.#composer = createComposer(renderer, {
      geometry,
      slots: composerSlots(session),
      theme,
      onSubmit: () => this.#submit("steer"),
      onContentChange: () => this.#store.draftChanged(this.#input.plainText, this.#input.cursorOffset),
      onImageMarkersChange: images => this.#store.imageMarkersChanged(images),
      onPaste: this.#onPaste
    })
    this.#input = this.#composer.input
    this.#pickerStack = new PickerStackView(renderer, this.#store.picker, theme, () => this.#input.plainText)

    // Transient status stays above stable session metadata; PickerStack is the only below-input choice surface.
    this.root.add(this.#working.root)
    this.root.add(this.#feedback.root)
    this.root.add(this.#queue.root)
    this.root.add(this.#composer.root)
    this.root.add(this.#pickerStack.root)

    const update = () => this.#update()
    this.#release.push(
      this.#store.$state.subscribe(update),
      this.#store.picker.$state.subscribe(update),
      interactive.$promptRevision.subscribe(update)
    )
    renderer.keyInput.on("keypress", this.#onKeyPress)
    renderer.on(CliRenderEvents.RESIZE, update)
    this.#release.push(() => renderer.keyInput.off("keypress", this.#onKeyPress))
    this.#release.push(() => renderer.off(CliRenderEvents.RESIZE, update))
    this.#input.focus()
  }

  focus(): void {
    this.#input.focus()
  }

  showWarning(message: string): void {
    this.#store.reportFeedback({ type: "warning", message })
  }

  destroy(): void {
    for (const release of this.#release.splice(0)) release()
    this.#working.destroy()
    this.#pickerStack.destroy()
    this.#feedback.destroy()
    this.#queue.destroy()
    this.#store.dispose()
    this.root.destroyRecursively()
  }

  #update = (): void => {
    const session = this.#interactive.getSession()
    const prompt = this.#store.$state.get()
    const geometry = composerGeometry(this.#renderer.width, this.#renderer.height)
    if (prompt.inputEdit.revision > this.#appliedInputRevision) {
      this.#appliedInputRevision = prompt.inputEdit.revision
      this.#replaceInput(prompt.inputEdit.text, prompt.inputEdit.cursorOffset)
    }
    const secretInput = promptInputIsSecret(prompt.workflow)
    this.#input.attributes = secretInput ? TextAttributes.HIDDEN : 0
    this.#input.selectable = !secretInput
    if (secretInput) this.#renderer.clearSelection()
    const feedbackVisible = this.#feedback.update(prompt.feedback, this.#renderer.width)
    const working = session.isStreaming || session.compactionStatus.type === "running"
    const fixedRows = geometry.protectedRows + (working ? 1 : 0) + (feedbackVisible ? 1 : 0)
    const pickerVisible = this.#pickerStack.update(Math.max(0, this.#renderer.height - fixedRows))

    this.#working.setText(
      session.isAborting ? "Cancelling…" : session.compactionStatus.type === "running" ? "Compacting…" : "Working…"
    )
    this.#working.setActive(working)
    if (pickerVisible) this.#queue.hide()
    else this.#queue.update(session.queuedInputs, Math.max(0, this.#renderer.height - fixedRows))
    if (prompt.images !== this.#syncedImages) {
      this.#syncedImages = prompt.images
      this.#composer.syncImageMarkers(prompt.images)
    }
    this.#composer.update(geometry, composerSlots(session, prompt.images.length))
  }

  #submit(delivery: "steer" | "followUp"): void {
    this.#store.imageMarkersChanged(this.#composer.activeImages())
    this.#store.submit(this.#composer.expandedText(), delivery)
  }

  #onPaste = (event: PasteEvent): void => {
    event.preventDefault()
    if (event.metadata?.mimeType?.startsWith("image/")) {
      this.#store.attachImage({ type: "image", bytes: event.bytes, mimeType: event.metadata.mimeType })
      return
    }
    if (event.metadata?.kind === "binary") {
      this.#store.reportFeedback({ type: "warning", message: "Unsupported binary clipboard content" })
      return
    }
    if (event.bytes.byteLength > maxPastedTextBytes) {
      this.#store.reportFeedback({ type: "error", message: "Pasted text exceeds the 1 MiB limit" })
      return
    }

    const text = normalizePastedText(decodePasteBytes(event.bytes))
    if (!text) {
      this.#pasteClipboard()
      return
    }
    this.#composer.insertPastedText(text)
  }

  #pasteClipboard(): void {
    void this.#store
      .pasteClipboard()
      .then(text => {
        if (text === undefined || this.#input.isDestroyed) return false
        const normalized = normalizePastedText(text)
        if (!normalized) return false
        this.#composer.insertPastedText(normalized)
        return true
      })
      .catch(() => false)
  }

  #replaceInput(text: string, cursorOffset?: number): void {
    this.#composer.replaceText(text, cursorOffset)
    const images = this.#store.$state.get().images
    this.#syncedImages = images
    this.#composer.syncImageMarkers(images)
    this.#input.focus()
  }

  #restore(abort: boolean): void {
    this.#store.imageMarkersChanged(this.#composer.activeImages())
    const currentText = this.#composer.expandedText()
    const text = abort
      ? this.#store.abortAndRestoreQueuedInputs(currentText)
      : this.#store.restoreQueuedInputs(currentText)
    if (text !== currentText) this.#replaceInput(text)
  }

  #onKeyPress = (key: KeyEvent): void => {
    if (this.#keybindings.matches(key, "tui.input.copy")) {
      const selectedText = this.#renderer.getSelection()?.getSelectedText()
      if (selectedText) {
        consume(key)
        this.#exitGestures.consume()
        let copied = false
        try {
          copied = this.#renderer.copyToClipboardOSC52(selectedText)
        } catch {
          return
        }
        if (copied) this.#renderer.clearSelection()
        return
      }
    }

    const session = this.#interactive.getSession()
    const prompt = this.#store.$state.get()
    const action = this.#keybindings.promptAction(key, {
      pickerOpen: Boolean(this.#store.picker.presentation(this.#input.plainText)),
      editorEmpty: this.#input.plainText.length === 0,
      hasImages: prompt.images.length > 0,
      streaming:
        session.isStreaming || session.compactionStatus.type === "running" || authenticationActive(prompt.workflow),
      foregroundShellTask: session.shellTasks.some(task => task.type === "foreground")
    })
    if (!action) return
    this.#handleKeyAction(key, action)
  }

  #handleKeyAction(key: KeyEvent, action: PromptKeyAction): void {
    switch (action) {
      case "picker_confirm":
        consume(key)
        this.#store.activatePicker(this.#input.plainText, this.#input.cursorOffset)
        return
      case "picker_complete":
        consume(key)
        this.#store.completePicker(this.#input.plainText, this.#input.cursorOffset)
        return
      case "picker_cancel":
        consume(key)
        this.#store.backPicker()
        if (this.#keybindings.matches(key, "app.clear")) this.#exitGestures.consume()
        return
      case "picker_up":
        consume(key)
        this.#store.movePicker(this.#input.plainText, -1)
        return
      case "picker_down":
        consume(key)
        this.#store.movePicker(this.#input.plainText, 1)
        return
      case "submit":
        consume(key)
        this.#submit("steer")
        return
      case "follow_up":
        consume(key)
        this.#submit("followUp")
        return
      case "background_task": {
        consume(key)
        const result = this.#interactive.backgroundForegroundShellTask()
        if (result.type === "capacity_exceeded") {
          this.#store.reportFeedback({ type: "error", message: "Background task capacity exceeded" })
        }
        return
      }
      case "paste_clipboard":
        consume(key)
        this.#pasteClipboard()
        return
      case "new_line":
        consume(key)
        this.#input.newLine()
        return
      case "restore_queue":
        consume(key)
        this.#restore(false)
        return
      case "interrupt":
        consume(key)
        this.#restore(true)
        return
      case "clear":
        consume(key)
        if (this.#exitGestures.clear() === "armed") this.#store.clear()
        return
      case "exit":
        consume(key)
        this.#exitGestures.exit()
        return
      case "consume":
        consume(key)
        return
      default:
        return assertNever(action)
    }
  }
}

function consume(key: KeyEvent): void {
  key.preventDefault()
  key.stopPropagation()
}

function assertNever(value: never): never {
  throw new Error(`Unhandled prompt key action: ${String(value)}`)
}

function authenticationActive(workflow: PromptWorkflow): boolean {
  return (
    workflow.type === "authenticating" || workflow.type === "auth_prompt" || workflow.type === "choosing_auth_option"
  )
}

function composerSlots(session: ReturnType<InteractiveStore["getSession"]>, imageCount = 0): ComposerSlots {
  const context = session.contextUsage
  return {
    topLeft: session.sessionManager.header.cwd,
    topRight: [
      ...(imageCount === 0 ? [] : [`${imageCount} image${imageCount === 1 ? "" : "s"}`]),
      modelTitle(session),
      ...(context.type === "unavailable" ? [] : [contextTitle(context.type, context.percent)])
    ]
  }
}

function modelTitle(session: ReturnType<InteractiveStore["getSession"]>): string {
  const state = session.modelState
  if (state.type === "unselected") return "No model selected"
  return session.thinkingLevel === "off" ? state.model.id : `${state.model.id} (${session.thinkingLevel})`
}

function contextTitle(type: "measured" | "estimated", percent: number): string {
  return `${type === "estimated" ? "~" : ""}${Math.round(percent)}% ctx`
}

function normalizePastedText(text: string): string {
  return stripAnsiSequences(text).replace(/\r\n/g, "\n").replace(/\r/g, "\n")
}
