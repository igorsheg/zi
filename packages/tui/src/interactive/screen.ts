import { BoxRenderable, CliRenderEvents, type CliRenderer, type KeyEvent, type SyntaxStyle } from "@opentui/core"

import type { Theme } from "../theme.js"
import type { BrowserOpener } from "./browser-opener.js"
import type { BuiltInNoticeActions } from "./built-in-notifications.js"
import type { ClipboardCopyController } from "./clipboard-copy.js"
import type { ClipboardReader } from "./clipboard.js"
import type { ExitGestureController } from "./exit-gesture.js"
import type { ExternalEditor } from "./external-editor.js"
import type { InteractiveKeybindings } from "./interactive-keybindings.js"
import type { InteractiveStore } from "./interactive-store.js"
import type { PromptAgentActions, PromptSessionActions } from "./prompt/store.js"
import { PromptView } from "./prompt/view.js"
import type { SlashController } from "./slash-controller.js"
import { TranscriptView } from "./transcript/view.js"
import { WorkPlanView } from "./work-plan-view.js"

export class SessionScreen {
  readonly root: BoxRenderable
  readonly transcript: TranscriptView
  readonly prompt: PromptView

  readonly #renderer: CliRenderer
  readonly #keybindings: InteractiveKeybindings
  readonly #plan: WorkPlanView
  readonly #release: Array<() => void> = []
  #presentationSuspended = false
  #disposed = false

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
    syntaxStyle: SyntaxStyle,
    measureTranscriptSync: boolean,
    notices: BuiltInNoticeActions,
    sessionActions?: PromptSessionActions,
    agentActions?: PromptAgentActions
  ) {
    this.#renderer = renderer
    this.#keybindings = keybindings
    this.root = new BoxRenderable(renderer, { flexDirection: "column", flexGrow: 1, minHeight: 0 })
    this.#plan = new WorkPlanView(renderer, interactive.getSession(), keybindings, theme, () => this.#closePlan())
    let prompt: PromptView | undefined
    this.transcript = new TranscriptView(renderer, interactive, keybindings, theme, syntaxStyle, {
      measureSync: measureTranscriptSync,
      availableHeight: () => renderer.height - (prompt?.root.height ?? 0) - this.#plan.root.height
    })
    this.prompt = prompt = new PromptView(
      renderer,
      interactive,
      slash,
      keybindings,
      exitGestures,
      browserOpener,
      clipboard,
      clipboardCopy,
      externalEditor,
      theme,
      notices,
      sessionActions,
      agentActions
    )
    this.root.add(this.transcript.root)
    this.root.add(this.#plan.root)
    this.root.add(this.prompt.root)
    this.#release.push(() => renderer.off(CliRenderEvents.RESIZE, this.#onResize))
    renderer.on(CliRenderEvents.RESIZE, this.#onResize)
    renderer.keyInput.on("keypress", this.#onKeyPress)
  }

  preserveFocus(): void {
    if (!this.#presentationSuspended && !this.#plan.expanded) this.prompt.focus()
  }

  suspendPresentation(): void {
    if (this.#presentationSuspended) return
    this.#presentationSuspended = true
    this.#plan.suspendPresentation()
    this.transcript.suspendPresentation()
    this.prompt.suspendPresentation()
    this.root.visible = false
  }

  resumePresentation(): void {
    if (!this.#presentationSuspended) return
    this.root.visible = true
    this.#presentationSuspended = false
    this.#plan.resumePresentation()
    this.transcript.resumePresentation()
    this.prompt.resumePresentation()
    this.#syncFocus()
  }

  destroy(): void {
    if (this.#disposed) return
    this.#disposed = true
    this.#renderer.keyInput.off("keypress", this.#onKeyPress)
    for (const release of this.#release.splice(0)) release()
    this.#plan.destroy()
    this.transcript.destroy()
    this.prompt.destroy()
    this.root.destroyRecursively()
  }

  #togglePlan(): void {
    if (!this.#plan.expanded) this.#plan.resize(this.#planMaximumHeight())
    if (!this.#plan.toggle()) return
    this.#syncFocus()
  }

  #closePlan(): void {
    this.#plan.close()
    this.#syncFocus()
  }

  #syncFocus(): void {
    const planExpanded = this.#plan.expanded
    this.transcript.setWorkPlanStatusAvailable(!planExpanded)
    this.prompt.setInputActive(!planExpanded)
    if (!planExpanded) this.prompt.focus()
    this.#renderer.requestRender()
  }

  #planMaximumHeight(): number {
    return Math.max(0, this.#renderer.height - this.prompt.root.height)
  }

  #onResize = (): void => {
    if (this.#disposed) return
    this.#plan.resize(this.#planMaximumHeight())
    this.#renderer.requestRender()
  }

  #onKeyPress = (key: KeyEvent): void => {
    if (this.#disposed || this.#presentationSuspended || key.defaultPrevented || key.propagationStopped) return
    if (this.#plan.expanded && this.#keybindings.closesWorkPlan(key)) {
      consume(key)
      this.#closePlan()
      return
    }
    if (this.#keybindings.togglesWorkPlan(key)) {
      consume(key)
      this.#togglePlan()
      return
    }

    const transcriptAction = this.#keybindings.transcriptAction(key)
    if (this.#plan.expanded) {
      if (transcriptAction && this.#plan.handleAction(transcriptAction)) consume(key)
      return
    }
    if (transcriptAction && this.transcript.handleAction(transcriptAction)) {
      consume(key)
      return
    }
    this.prompt.handleKeyPress(key)
  }
}

function consume(key: KeyEvent): void {
  key.preventDefault()
  key.stopPropagation()
}
