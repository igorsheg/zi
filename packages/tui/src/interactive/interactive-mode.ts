import { BoxRenderable, CliRenderEvents, type CliRenderer, type SyntaxStyle } from "@opentui/core"
import type { AgentSession } from "@openzi/coding-agent"

import { createSyntaxStyle, defaultTheme, type Theme } from "../theme.js"
import { type BrowserOpener, SystemBrowserOpener } from "./browser-opener.js"
import {
  captureTuiMemorySnapshot,
  TuiDiagnosticsOverlay,
  type TuiDiagnosticFlags,
  type TuiMemorySnapshot
} from "./diagnostics.js"
import { ExitGestureController } from "./exit-gesture.js"
import { createInteractiveCommands, type InteractiveCommands } from "./interactive-commands.js"
import { InteractiveKeybindings, type InteractiveKeybindingOverrides } from "./interactive-keybindings.js"
import { createInteractiveStore, type InteractiveStore } from "./interactive-store.js"
import { SessionScreen } from "./screen.js"
import type { TranscriptDiagnostics } from "./transcript/view.js"

export interface InteractiveModeOptions {
  readonly renderer: CliRenderer
  readonly session: AgentSession
  readonly onExit: () => void
  readonly keybindingOverrides?: InteractiveKeybindingOverrides
  readonly theme?: Theme
  readonly browserOpener?: BrowserOpener
  readonly diagnostics?: TuiDiagnosticFlags
}

export class InteractiveMode {
  readonly root: BoxRenderable
  readonly store: InteractiveStore

  readonly #renderer: CliRenderer
  readonly #browserOpener: BrowserOpener
  readonly #exitGestures: ExitGestureController
  readonly #theme: Theme
  readonly #syntaxStyle: SyntaxStyle
  readonly #commands: InteractiveCommands
  readonly #keybindings: InteractiveKeybindings
  readonly #diagnosticFlags: TuiDiagnosticFlags
  readonly #diagnostics: TuiDiagnosticsOverlay | undefined
  #screen: SessionScreen
  #releaseGeneration: () => void
  #disposed = false

  constructor({
    renderer,
    session,
    onExit,
    keybindingOverrides,
    theme = defaultTheme,
    browserOpener = new SystemBrowserOpener(),
    diagnostics = { showTimeToFirstDraw: false, showStats: false, showMemory: false }
  }: InteractiveModeOptions) {
    this.#renderer = renderer
    this.#browserOpener = browserOpener
    this.#exitGestures = new ExitGestureController(onExit)
    this.store = createInteractiveStore(session)
    this.#theme = theme
    this.#syntaxStyle = createSyntaxStyle(theme)
    this.#commands = createInteractiveCommands(() => this.store.getSession())
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
  }

  replaceSession(session: AgentSession): void {
    this.store.replaceSession(session)
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
      this.#commands,
      this.#keybindings,
      this.#exitGestures,
      this.#browserOpener,
      this.#theme,
      this.#syntaxStyle,
      this.#diagnosticFlags.showTimeToFirstDraw || this.#diagnosticFlags.showStats || this.#diagnosticFlags.showMemory
    )
  }
}
