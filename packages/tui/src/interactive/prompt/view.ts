import { BoxRenderable, CliRenderEvents, type CliRenderer, type KeyEvent, TextAttributes } from "@opentui/core"

import { composerGeometry, createComposer, type Composer } from "../../components/composer.js"
import { ShimmerTextView } from "../../components/shimmer-text.js"
import type { Theme } from "../../theme.js"
import type { BrowserOpener } from "../browser-opener.js"
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
  readonly input: Composer["input"]

  readonly #renderer: CliRenderer
  readonly #interactive: InteractiveStore
  readonly #keybindings: InteractiveKeybindings
  readonly #exitGestures: ExitGestureController
  readonly #store: PromptStore
  readonly #working: ShimmerTextView
  readonly #feedback: PromptFeedbackView
  readonly #queue: QueuedInputsView
  readonly #composer: Composer
  readonly #pickerStack: PickerStackView
  readonly #release: Array<() => void> = []
  #appliedInputRevision = 0

  constructor(
    renderer: CliRenderer,
    interactive: InteractiveStore,
    slash: SlashController,
    keybindings: InteractiveKeybindings,
    exitGestures: ExitGestureController,
    browserOpener: BrowserOpener,
    theme: Theme,
    sessionActions?: PromptSessionActions
  ) {
    this.#renderer = renderer
    this.#interactive = interactive
    this.#keybindings = keybindings
    this.#exitGestures = exitGestures
    this.#store = createPromptStore(interactive, slash, sessionActions)
    this.root = new BoxRenderable(renderer, { flexDirection: "column", flexShrink: 0 })

    this.#working = new ShimmerTextView(renderer, "Working…", theme.text.muted, theme.text.primary)
    this.#feedback = new PromptFeedbackView(renderer, browserOpener, theme)
    this.#queue = new QueuedInputsView(renderer, keybindings, theme)

    const session = interactive.getSession()
    const geometry = composerGeometry(renderer.width, renderer.height)
    this.#composer = createComposer(renderer, {
      geometry,
      title: session.sessionManager.header.cwd,
      bottomTitle: modelTitle(session),
      theme,
      onSubmit: () => this.#submit("steer"),
      onContentChange: () => this.#store.draftChanged(this.input.plainText, this.input.cursorOffset)
    })
    this.input = this.#composer.input
    this.#pickerStack = new PickerStackView(renderer, this.#store.picker, theme, () => this.input.plainText)

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
    this.input.focus()
  }

  focus(): void {
    this.input.focus()
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
    this.input.attributes = secretInput ? TextAttributes.HIDDEN : 0
    this.input.selectable = !secretInput
    if (secretInput) this.#renderer.clearSelection()
    const feedbackVisible = this.#feedback.update(prompt.feedback, this.#renderer.width)
    const fixedRows = geometry.protectedRows + (session.isStreaming ? 1 : 0) + (feedbackVisible ? 1 : 0)
    const pickerVisible = this.#pickerStack.update(Math.max(0, this.#renderer.height - fixedRows))

    this.#working.setActive(session.isStreaming)
    if (pickerVisible) this.#queue.hide()
    else this.#queue.update(session.queuedInputs, Math.max(0, this.#renderer.height - fixedRows))
    this.#composer.update(geometry, session.sessionManager.header.cwd, modelTitle(session))
  }

  #submit(delivery: "steer" | "followUp"): void {
    this.#store.submit(this.input.plainText, delivery)
  }

  #replaceInput(text: string, cursorOffset = text.length): void {
    this.input.setText(text)
    this.input.cursorOffset = cursorOffset
    this.input.focus()
  }

  #restore(abort: boolean): void {
    const text = abort
      ? this.#store.abortAndRestoreQueuedInputs(this.input.plainText)
      : this.#store.restoreQueuedInputs(this.input.plainText)
    if (text !== this.input.plainText) this.#replaceInput(text)
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
    const action = this.#keybindings.promptAction(key, {
      pickerOpen: Boolean(this.#store.picker.presentation(this.input.plainText)),
      editorEmpty: this.input.plainText.length === 0,
      streaming: session.isStreaming || authenticationActive(this.#store.$state.get().workflow),
      foregroundShellTask: session.shellTasks.some(task => task.type === "foreground")
    })
    if (!action) return
    this.#handleKeyAction(key, action)
  }

  #handleKeyAction(key: KeyEvent, action: PromptKeyAction): void {
    switch (action) {
      case "picker_confirm":
        consume(key)
        this.#store.activatePicker(this.input.plainText, this.input.cursorOffset)
        return
      case "picker_complete":
        consume(key)
        this.#store.completePicker(this.input.plainText, this.input.cursorOffset)
        return
      case "picker_cancel":
        consume(key)
        this.#store.backPicker()
        if (this.#keybindings.matches(key, "app.clear")) this.#exitGestures.consume()
        return
      case "picker_up":
        consume(key)
        this.#store.movePicker(this.input.plainText, -1)
        return
      case "picker_down":
        consume(key)
        this.#store.movePicker(this.input.plainText, 1)
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
      case "new_line":
        consume(key)
        this.input.newLine()
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

function modelTitle(session: ReturnType<InteractiveStore["getSession"]>): string {
  const state = session.modelState
  if (state.type === "unselected") return "No model selected"
  return session.thinkingLevel === "off" ? state.model.id : `${state.model.id} (${session.thinkingLevel})`
}
