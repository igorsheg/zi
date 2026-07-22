import { BoxRenderable, CliRenderEvents, type CliRenderer, type SyntaxStyle } from "@opentui/core"
import type { AgentSession, AgentSessionRuntime, SessionBootstrapDiagnostic } from "@with-zi/coding-agent"

import { createSyntaxStyle, defaultTheme, type Theme } from "../theme.js"
import { type BrowserOpener, SystemBrowserOpener } from "./browser-opener.js"
import { type ClipboardReader, SystemClipboardReader } from "./clipboard.js"
import {
  captureTuiMemorySnapshot,
  TuiDiagnosticsOverlay,
  type TuiDiagnosticFlags,
  type TuiMemorySnapshot
} from "./diagnostics.js"
import { ExitGestureController } from "./exit-gesture.js"
import { InteractiveKeybindings, type InteractiveKeybindingOverrides } from "./interactive-keybindings.js"
import { createInteractiveStore, type InteractiveStore } from "./interactive-store.js"
import type { PromptSessionActions } from "./prompt/store.js"
import { SessionScreen } from "./screen.js"
import { SlashController } from "./slash-controller.js"
import type { TranscriptDiagnostics } from "./transcript/view.js"

export interface InteractiveModeOptions {
  readonly renderer: CliRenderer
  readonly session: AgentSession
  readonly sessionRuntime?: AgentSessionRuntime
  readonly onExit: () => void
  readonly keybindingOverrides?: InteractiveKeybindingOverrides
  readonly theme?: Theme
  readonly browserOpener?: BrowserOpener
  readonly clipboard?: ClipboardReader
  readonly diagnostics?: TuiDiagnosticFlags
  readonly bootstrapDiagnostic?: SessionBootstrapDiagnostic
}

export class InteractiveMode {
  readonly root: BoxRenderable
  readonly store: InteractiveStore

  readonly #renderer: CliRenderer
  readonly #sessionRuntime: AgentSessionRuntime | undefined
  readonly #sessionActions: PromptSessionActions | undefined
  readonly #browserOpener: BrowserOpener
  readonly #clipboard: ClipboardReader
  readonly #exitGestures: ExitGestureController
  readonly #theme: Theme
  readonly #syntaxStyle: SyntaxStyle
  readonly #slash: SlashController
  readonly #keybindings: InteractiveKeybindings
  readonly #diagnosticFlags: TuiDiagnosticFlags
  readonly #diagnostics: TuiDiagnosticsOverlay | undefined
  #screen: SessionScreen
  #releaseGeneration: () => void
  #disposed = false

  constructor({
    renderer,
    session,
    sessionRuntime,
    onExit,
    keybindingOverrides,
    theme = defaultTheme,
    browserOpener = new SystemBrowserOpener(),
    clipboard = new SystemClipboardReader(),
    diagnostics = { showTimeToFirstDraw: false, showStats: false, showMemory: false },
    bootstrapDiagnostic
  }: InteractiveModeOptions) {
    if (sessionRuntime && sessionRuntime.session !== session) {
      throw new Error("InteractiveMode session must be the session runtime current session")
    }
    this.#renderer = renderer
    this.#sessionRuntime = sessionRuntime
    this.#sessionActions = sessionRuntime
      ? {
          listSessions: () => sessionRuntime.listSessions(),
          startNewSession: async () => {
            const next = await sessionRuntime.newSession()
            if (!this.#disposed) this.replaceSession(next.session, next.bootstrapDiagnostic)
          },
          resumeSession: async path => {
            const next = await sessionRuntime.switchSession(path)
            if (!this.#disposed) this.replaceSession(next.session, next.bootstrapDiagnostic)
          },
          cancelReplacement: () => sessionRuntime.cancelReplacement()
        }
      : undefined
    this.#browserOpener = browserOpener
    this.#clipboard = clipboard
    this.#exitGestures = new ExitGestureController(onExit)
    this.store = createInteractiveStore(session)
    this.#theme = theme
    this.#syntaxStyle = createSyntaxStyle(theme)
    this.#slash = new SlashController(
      () => this.store.getSession(),
      () => this.store.$generation.get()
    )
    this.#keybindings = new InteractiveKeybindings(keybindingOverrides)
    this.#diagnosticFlags = diagnostics
    this.root = new BoxRenderable(renderer, {
      id: "interactive-mode",
      width: "100%",
      height: "100%",
      flexDirection: "column",
      backgroundColor: theme.surface.app
    })
    this.#screen = this.#createScreen()
    this.root.add(this.#screen.root)
    this.#diagnostics =
      diagnostics.showTimeToFirstDraw || diagnostics.showStats || diagnostics.showMemory
        ? new TuiDiagnosticsOverlay(
            renderer,
            diagnostics,
            () => this.#screen.transcript,
            diagnostics.showMemory ? () => this.captureMemoryDiagnostics() : undefined,
            theme
          )
        : undefined
    if (this.#diagnostics) this.root.add(this.#diagnostics.root)
    renderer.root.add(this.root)
    this.#screen.prompt.focus()
    renderer.on(CliRenderEvents.SELECTION, this.#preservePromptFocus)

    this.#releaseGeneration = this.store.$generation.listen(() => this.#replaceScreen())
    this.#showBootstrapWarning(bootstrapDiagnostic)
  }

  replaceSession(session: AgentSession, diagnostic?: SessionBootstrapDiagnostic): void {
    if (this.#sessionRuntime && this.#sessionRuntime.session !== session) {
      throw new Error("InteractiveMode can only bind the current session runtime session")
    }
    this.store.replaceSession(session)
    this.#showBootstrapWarning(diagnostic)
  }

  get transcriptDiagnostics(): TranscriptDiagnostics {
    return this.#screen.transcript.diagnostics
  }

  captureMemoryDiagnostics(): TuiMemorySnapshot {
    return captureTuiMemorySnapshot(this.#renderer, this.store.getSession(), this.#screen.transcript.retainedRootCount)
  }

  dispose(): void {
    if (this.#disposed) return
    this.#disposed = true
    this.#releaseGeneration()
    this.#renderer.off(CliRenderEvents.SELECTION, this.#preservePromptFocus)
    this.#diagnostics?.destroy()
    this.#screen.destroy()
    this.#browserOpener.dispose()
    this.root.destroyRecursively()
    this.#syntaxStyle.destroy()
    this.store.dispose()
  }

  #preservePromptFocus = (): void => {
    this.#screen.prompt.focus()
  }

  #showBootstrapWarning(diagnostic: SessionBootstrapDiagnostic | undefined): void {
    if (diagnostic) this.#screen.prompt.showWarning(diagnostic.message)
  }

  #replaceScreen(): void {
    this.#screen.destroy()
    this.#screen = this.#createScreen()
    this.root.add(this.#screen.root)
    this.#screen.prompt.focus()
  }

  #createScreen(): SessionScreen {
    return new SessionScreen(
      this.#renderer,
      this.store,
      this.#slash,
      this.#keybindings,
      this.#exitGestures,
      this.#browserOpener,
      this.#clipboard,
      this.#theme,
      this.#syntaxStyle,
      this.#diagnosticFlags.showTimeToFirstDraw || this.#diagnosticFlags.showStats || this.#diagnosticFlags.showMemory,
      this.#sessionActions
    )
  }
}
