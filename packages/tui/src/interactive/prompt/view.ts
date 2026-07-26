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
import type { ExternalEditor } from "../external-editor.js"
import type { InteractiveKeybindings, PromptKeyAction } from "../interactive-keybindings.js"
import type { InteractiveStore } from "../interactive-store.js"
import type { SlashController } from "../slash-controller.js"
import { PromptFeedbackView } from "./feedback-view.js"
import { captureFileCompletionInput } from "./file-completion.js"
import { SessionGreeterView } from "./greeter-view.js"
import { PickerStackView } from "./picker-view.js"
import { QueuedInputsView } from "./queue-view.js"
import { promptInputIsSecret, type PromptInputEdit, type PromptWorkflow } from "./state.js"
import { createPromptStore, type PromptSessionActions, type PromptStore } from "./store.js"

type ExternalEditorState =
  | { readonly type: "idle" }
  | { readonly type: "editing"; readonly operationId: number }
  | { readonly type: "disposed" }

export class PromptView {
  readonly root: BoxRenderable

  readonly #renderer: CliRenderer
  readonly #interactive: InteractiveStore
  readonly #keybindings: InteractiveKeybindings
  readonly #exitGestures: ExitGestureController
  readonly #externalEditor: ExternalEditor
  readonly #store: PromptStore
  readonly #working: ShimmerTextView
  readonly #feedback: PromptFeedbackView
  readonly #queue: QueuedInputsView
  readonly #greeter: SessionGreeterView
  readonly #composer: Composer
  readonly #input: Composer["input"]
  readonly #pickerStack: PickerStackView
  readonly #release: Array<() => void> = []
  #appliedInputRevision = 0
  #syncedImages: ReturnType<Composer["activeImages"]> = []
  #externalEditorState: ExternalEditorState = { type: "idle" }
  #nextExternalEditorOperationId = 0

  constructor(
    renderer: CliRenderer,
    interactive: InteractiveStore,
    slash: SlashController,
    keybindings: InteractiveKeybindings,
    exitGestures: ExitGestureController,
    browserOpener: BrowserOpener,
    clipboard: ClipboardReader,
    externalEditor: ExternalEditor,
    theme: Theme,
    sessionActions?: PromptSessionActions
  ) {
    this.#renderer = renderer
    this.#interactive = interactive
    this.#keybindings = keybindings
    this.#exitGestures = exitGestures
    this.#externalEditor = externalEditor
    this.#store = createPromptStore(interactive, slash, sessionActions, clipboard)
    this.root = new BoxRenderable(renderer, { flexDirection: "column", flexShrink: 0 })
    this.root.onLifecyclePass = this.#refreshWorkingStatus

    this.#working = new ShimmerTextView(renderer, "Working…", theme.text.muted, theme.text.primary)
    this.#feedback = new PromptFeedbackView(renderer, browserOpener, theme)
    this.#queue = new QueuedInputsView(renderer, keybindings, theme)
    this.#greeter = new SessionGreeterView(renderer, theme)

    const session = interactive.getSession()
    const geometry = composerGeometry(renderer.width, renderer.height)
    this.#composer = createComposer(renderer, {
      geometry,
      slots: composerSlots(session),
      theme,
      historySource: {
        latest: () => session.latestPromptHistoryEntry(),
        older: entryId => session.olderPromptHistoryEntry(entryId)
      },
      onSubmit: () => this.#submit("steer"),
      onContentChange: () => this.#store.draftChanged(this.#input.plainText, captureFileCompletionInput(this.#input)),
      onCursorChange: () => this.#store.cursorChanged(this.#input.plainText, captureFileCompletionInput(this.#input)),
      onImageMarkersChange: images => this.#store.imageMarkersChanged(images),
      onPaste: this.#onPaste
    })
    this.#input = this.#composer.input
    this.#pickerStack = new PickerStackView(renderer, this.#store.picker, theme, () => this.#input.plainText)

    // Transient status stays above stable session metadata; PickerStack is the only below-input choice surface.
    this.root.add(this.#working.root)
    this.root.add(this.#feedback.root)
    this.root.add(this.#queue.root)
    this.root.add(this.#greeter.root)
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

  showCopyWarning(message: string): void {
    const state = this.#store.$state.get()
    if (state.workflow.type === "idle" && (state.feedback.type === "none" || state.feedback.type === "copy_warning")) {
      this.#store.reportFeedback({ type: "copy_warning", message })
    }
  }

  clearCopyWarning(): void {
    if (this.#store.$state.get().feedback.type === "copy_warning") {
      this.#store.reportFeedback({ type: "none" })
    }
  }

  destroy(): void {
    this.#externalEditorState = { type: "disposed" }
    for (const release of this.#release.splice(0)) release()
    this.root.onLifecyclePass = null
    this.#working.destroy()
    this.#feedback.destroy()
    this.#queue.destroy()
    this.#greeter.destroy()
    this.#store.dispose()
    this.#pickerStack.destroy()
    this.root.destroyRecursively()
  }

  #update = (): void => {
    const session = this.#interactive.getSession()
    const prompt = this.#store.$state.get()
    const geometry = composerGeometry(this.#renderer.width, this.#renderer.height)
    if (prompt.inputEdit.revision > this.#appliedInputRevision) {
      this.#appliedInputRevision = prompt.inputEdit.revision
      this.#applyInputEdit(prompt.inputEdit)
    }
    const secretInput = promptInputIsSecret(prompt.workflow)
    this.#input.attributes = secretInput ? TextAttributes.HIDDEN : 0
    this.#input.selectable = !secretInput
    if (secretInput) this.#renderer.clearSelection()
    const feedbackVisible = this.#feedback.update(prompt.feedback, this.#renderer.width)
    const working = session.isStreaming || session.compactionStatus.type === "running"
    const pickerOpen = Boolean(this.#store.picker.presentation(this.#input.plainText))
    const greeterRows = this.#greeter.update(
      session.messages.length === 0,
      this.#renderer.width,
      this.#renderer.height,
      pickerOpen
    )
    const fixedRows = geometry.protectedRows + greeterRows + (working ? 1 : 0) + (feedbackVisible ? 1 : 0)
    const pickerVisible = this.#pickerStack.update(Math.max(0, this.#renderer.height - fixedRows))

    this.#working.setText(workingStatusText(session, this.#keybindings.getHint("app.interrupt"), Date.now()))
    this.#working.setActive(working)
    if (pickerVisible) this.#queue.hide()
    else this.#queue.update(session.queuedInputs, Math.max(0, this.#renderer.height - fixedRows))
    if (prompt.images !== this.#syncedImages) {
      this.#syncedImages = prompt.images
      this.#composer.syncImageMarkers(prompt.images)
    }
    this.#composer.update(geometry, composerSlots(session, prompt.images.length))
  }

  #refreshWorkingStatus = (): void => {
    const session = this.#interactive.getSession()
    if (session.retryStatus.type !== "waiting") return
    this.#working.setText(workingStatusText(session, this.#keybindings.getHint("app.interrupt"), Date.now()))
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

  #applyInputEdit(edit: PromptInputEdit): void {
    switch (edit.type) {
      case "replace":
        this.#replaceInput(edit.text, edit.cursorOffset)
        return
      case "range":
        if (this.#composer.replaceRange(edit) === "unavailable") {
          this.#store.reportFeedback({
            type: "warning",
            message: "File completion could not replace this marked range"
          })
        }
        this.#syncedImages = this.#composer.activeImages()
        this.#input.focus()
        return
      default:
        return assertNever(edit)
    }
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
    const session = this.#interactive.getSession()
    const prompt = this.#store.$state.get()
    const pickerOpen = Boolean(this.#store.picker.presentation(this.#input.plainText))
    const action = this.#keybindings.promptAction(key, {
      pickerOpen,
      editorEmpty: this.#input.plainText.length === 0,
      hasImages: prompt.images.length > 0,
      streaming:
        session.isStreaming || session.compactionStatus.type === "running" || authenticationActive(prompt.workflow),
      foregroundShellTask: session.shellTasks.some(task => task.type === "foreground"),
      externalEditorEnabled: prompt.workflow.type === "idle",
      historyEnabled: prompt.workflow.type === "idle" && !pickerOpen
    })
    if (!action) return
    this.#handleKeyAction(key, action)
  }

  #handleKeyAction(key: KeyEvent, action: PromptKeyAction): void {
    switch (action) {
      case "picker_confirm":
        consume(key)
        this.#store.activatePicker(this.#input.plainText, captureFileCompletionInput(this.#input))
        return
      case "picker_complete":
        consume(key)
        this.#store.completePicker(this.#input.plainText, captureFileCompletionInput(this.#input))
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
      case "history_previous":
        consume(key)
        this.#applyHistoryResult(this.#composer.historyPrevious())
        return
      case "history_next":
        consume(key)
        this.#applyHistoryResult(this.#composer.historyNext())
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
      case "external_editor":
        consume(key)
        void this.#openExternalEditor()
        return
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

  async #openExternalEditor(): Promise<void> {
    if (this.#externalEditorState.type !== "idle") return
    const operationId = ++this.#nextExternalEditorOperationId
    this.#externalEditorState = { type: "editing", operationId }
    const session = this.#interactive.getSession()

    let result: Awaited<ReturnType<ExternalEditor["edit"]>>
    try {
      result = await this.#externalEditor.edit({
        command: session.settingsManager.getExternalEditorCommand(),
        content: this.#composer.expandedText(),
        cwd: session.sessionManager.header.cwd
      })
    } catch (cause) {
      result = { type: "failed", message: cause instanceof Error ? cause.message : String(cause) }
    }

    const state = this.#externalEditorState
    if (state.type !== "editing" || state.operationId !== operationId) return
    this.#externalEditorState = { type: "idle" }
    if (result.type === "complete") this.#replaceInput(result.content)
    else this.#store.reportFeedback({ type: "warning", message: result.message })
  }

  #applyHistoryResult(result: ReturnType<Composer["historyPrevious"]>): void {
    if (result !== "history_changed") return
    const images = this.#composer.activeImages()
    this.#syncedImages = images
    this.#store.imageMarkersChanged(images)
    this.#syncedImages = this.#store.$state.get().images
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

function workingStatusText(
  session: ReturnType<InteractiveStore["getSession"]>,
  interruptHint: string | undefined,
  now: number
): string {
  if (session.isAborting) return "Cancelling…"
  const retry = session.retryStatus
  if (retry.type === "waiting") {
    const seconds = Math.max(0, Math.ceil((retry.retryAt - now) / 1_000))
    const cancel = interruptHint ? `${interruptHint} to cancel` : "interrupt to cancel"
    return `Retrying (${retry.attempt}/${retry.maxAttempts}) in ${seconds}s… (${cancel})`
  }
  return session.compactionStatus.type === "running" ? "Compacting…" : "Working…"
}

function composerSlots(session: ReturnType<InteractiveStore["getSession"]>, imageCount = 0): ComposerSlots {
  const context = session.contextUsage
  return {
    topLeft: session.sessionManager.header.cwd,
    topRight: [
      ...(imageCount === 0 ? [] : [`${imageCount} image${imageCount === 1 ? "" : "s"}`]),
      ...(context.type === "unavailable" ? [] : [contextTitle(context.type, context.percent, context.contextWindow)]),
      modelTitle(session)
    ]
  }
}

function modelTitle(session: ReturnType<InteractiveStore["getSession"]>): string {
  const state = session.modelState
  if (state.type === "unselected") return "No model selected"
  return session.thinkingLevel === "off" ? state.model.id : `${state.model.id} (${session.thinkingLevel})`
}

function contextTitle(type: "measured" | "estimated", percent: number, contextWindow: number): string {
  const window =
    contextWindow < 1_000
      ? String(contextWindow)
      : contextWindow < 1_000_000
        ? `${Math.round(contextWindow / 1_000)}k`
        : `${(contextWindow / 1_000_000).toFixed(1).replace(/\.0$/, "")}m`
  return `ctx ${type === "estimated" ? "~" : ""}${Math.round(percent)}%/${window}`
}

function normalizePastedText(text: string): string {
  return stripAnsiSequences(text).replace(/\r\n/g, "\n").replace(/\r/g, "\n")
}
