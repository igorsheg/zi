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
import type { BuiltInNoticeActions } from "../built-in-notifications.js"
import type { ClipboardCopyController } from "../clipboard-copy.js"
import { maxPastedTextBytes, type ClipboardReader } from "../clipboard.js"
import type { ExitGestureController } from "../exit-gesture.js"
import type { ExternalEditor } from "../external-editor.js"
import type { InteractiveKeybindings, PromptKeyAction } from "../interactive-keybindings.js"
import type { InteractiveStore } from "../interactive-store.js"
import type { SlashController } from "../slash-controller.js"
import { AuthCeremonyView } from "./auth-ceremony-view.js"
import { captureFileCompletionInput } from "./file-completion.js"
import { layoutPromptFooter, type PromptFooterPresentation, PromptFooterView } from "./footer-view.js"
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
  readonly #notices: BuiltInNoticeActions
  readonly #store: PromptStore
  readonly #working: ShimmerTextView
  readonly #authCeremony: AuthCeremonyView
  readonly #queue: QueuedInputsView
  readonly #greeter: SessionGreeterView
  readonly #composer: Composer
  readonly #footer: PromptFooterView
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
    clipboardCopy: ClipboardCopyController,
    externalEditor: ExternalEditor,
    theme: Theme,
    notices: BuiltInNoticeActions,
    sessionActions?: PromptSessionActions
  ) {
    this.#renderer = renderer
    this.#interactive = interactive
    this.#keybindings = keybindings
    this.#exitGestures = exitGestures
    this.#externalEditor = externalEditor
    this.#notices = notices
    this.#store = createPromptStore(interactive, slash, sessionActions, clipboard, notices, clipboardCopy)
    this.root = new BoxRenderable(renderer, { flexDirection: "column", flexShrink: 0 })
    this.root.onLifecyclePass = this.#refreshWorkingStatus

    this.#working = new ShimmerTextView(renderer, "Working…", theme.text.muted, theme.text.primary)
    this.#authCeremony = new AuthCeremonyView(renderer, browserOpener, theme)
    this.#queue = new QueuedInputsView(renderer, keybindings, theme)
    this.#greeter = new SessionGreeterView(renderer, theme)

    const session = interactive.getSession()
    const geometry = composerGeometry(renderer.width, renderer.height)
    this.#composer = createComposer(renderer, {
      geometry,
      slots: composerSlots(),
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
    this.#footer = new PromptFooterView(renderer, theme)
    this.#pickerStack = new PickerStackView(renderer, this.#store.picker, theme, () => this.#input.plainText)

    // Transient workflows stay above the composer; stable session metadata yields the below-input surface to pickers.
    this.root.add(this.#working.root)
    this.root.add(this.#authCeremony.root)
    this.root.add(this.#queue.root)
    this.root.add(this.#greeter.root)
    this.root.add(this.#composer.root)
    this.root.add(this.#footer.root)
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

  requestProjectTrust(cwd: string): void {
    this.#store.requestProjectTrust(cwd)
  }

  destroy(): void {
    this.#externalEditorState = { type: "disposed" }
    for (const release of this.#release.splice(0)) release()
    this.root.onLifecyclePass = null
    this.#working.destroy()
    this.#authCeremony.destroy()
    this.#queue.destroy()
    this.#greeter.destroy()
    this.#footer.destroy()
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
    const authCeremonyRows = this.#authCeremony.update(prompt.authCeremony, this.#renderer.width)
    const working = session.isStreaming || session.compactionStatus.type === "running"
    const pickerOpen = Boolean(this.#store.picker.presentation(this.#input.plainText))
    const greeterRows = this.#greeter.update(
      session.messages.length === 0,
      this.#renderer.width,
      this.#renderer.height,
      pickerOpen
    )
    const queuedInputs = session.queuedInputs
    const queueActive = queuedInputs.steering.length > 0 || queuedInputs.followUp.length > 0
    const fixedRowsWithoutFooter = geometry.protectedRows + greeterRows + (working ? 1 : 0) + authCeremonyRows
    // The transcript owns one row; an active queue needs one summary row before ambient metadata is admitted.
    const reservedContentRows = 1 + (queueActive ? 1 : 0)
    const footerFits =
      fixedRowsWithoutFooter + PromptFooterView.occupiedRows + reservedContentRows <= this.#renderer.height
    const footerRows = this.#footer.update(
      layoutPromptFooter(
        pickerOpen || !geometry.bordered || !footerFits ? { type: "hidden" } : footerPresentation(session),
        this.#renderer.width
      )
    )
    const fixedRows = fixedRowsWithoutFooter + footerRows
    const pickerVisible = this.#pickerStack.update(Math.max(0, this.#renderer.height - fixedRows))

    this.#working.setText(workingStatusText(session, this.#keybindings.getHint("app.interrupt"), Date.now()))
    this.#working.setActive(working)
    if (pickerVisible) this.#queue.hide()
    else this.#queue.update(queuedInputs, Math.max(0, this.#renderer.height - fixedRows))
    if (prompt.images !== this.#syncedImages) {
      this.#syncedImages = prompt.images
      this.#composer.syncImageMarkers(prompt.images)
    }
    this.#composer.update(geometry, composerSlots(prompt.images.length))
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
      this.#notices.promptWarning("Unsupported binary clipboard content")
      return
    }
    if (event.bytes.byteLength > maxPastedTextBytes) {
      this.#notices.promptError("Pasted text exceeds the 1 MiB limit")
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
          this.#notices.promptWarning("File completion could not replace this marked range")
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
        this.#handleHistoryKey(key, this.#composer.historyPrevious())
        return
      case "history_next":
        this.#handleHistoryKey(key, this.#composer.historyNext())
        return
      case "follow_up":
        consume(key)
        this.#submit("followUp")
        return
      case "background_task": {
        consume(key)
        const result = this.#interactive.backgroundForegroundShellTask()
        if (result.type === "capacity_exceeded") this.#notices.backgroundTaskCapacityExceeded()
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
    else this.#notices.promptWarning(result.message)
  }

  #handleHistoryKey(key: KeyEvent, result: ReturnType<Composer["historyPrevious"]>): void {
    switch (result) {
      case "native_fallthrough":
        return
      case "cursor_boundary":
      case "history_boundary":
        consume(key)
        return
      case "history_changed": {
        consume(key)
        const images = this.#composer.activeImages()
        this.#syncedImages = images
        this.#store.imageMarkersChanged(images)
        this.#syncedImages = this.#store.$state.get().images
        return
      }
      default:
        return assertNever(result)
    }
  }
}

function consume(key: KeyEvent): void {
  key.preventDefault()
  key.stopPropagation()
}

function assertNever(value: never): never {
  throw new Error(`Unhandled prompt value: ${String(value)}`)
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

function composerSlots(imageCount = 0): ComposerSlots {
  return { topLeft: "", topRight: imageCount === 0 ? [] : [`${imageCount} image${imageCount === 1 ? "" : "s"}`] }
}

function footerPresentation(session: ReturnType<InteractiveStore["getSession"]>): PromptFooterPresentation {
  const model = session.modelState
  return {
    type: "session",
    cwd: session.sessionManager.header.cwd,
    homeDir: session.homeDir,
    model:
      model.type === "unselected"
        ? { type: "unselected" }
        : { type: "selected", id: model.model.id, thinking: session.thinkingLevel },
    context: session.contextUsage
  }
}

function normalizePastedText(text: string): string {
  return stripAnsiSequences(text).replace(/\r\n/g, "\n").replace(/\r/g, "\n")
}
