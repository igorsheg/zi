import { BoxRenderable, CliRenderEvents, type CliRenderer, type SyntaxStyle } from "@opentui/core"
import type { AgentSession } from "@openzi/coding-agent"

import { createSyntaxStyle, defaultTheme, type Theme } from "../theme.js"
import { SessionScreen } from "./components/session-screen.js"
import { createInteractiveCommands, type InteractiveCommands } from "./interactive-commands.js"
import { InteractiveKeybindings, type InteractiveKeybindingOverrides } from "./interactive-keybindings.js"
import { createInteractiveStore, type InteractiveStore } from "./stores/interactive.js"

const exitGestureWindowMs = 500

type ExitGestureState = { readonly type: "ready" } | { readonly type: "armed"; readonly pressedAt: number }

export interface InteractiveModeOptions {
  readonly renderer: CliRenderer
  readonly session: AgentSession
  readonly onExit: () => void
  readonly keybindingOverrides?: InteractiveKeybindingOverrides
  readonly theme?: Theme
}

export class InteractiveMode {
  readonly root: BoxRenderable
  readonly store: InteractiveStore

  readonly #renderer: CliRenderer
  readonly #onExit: () => void
  readonly #theme: Theme
  readonly #syntaxStyle: SyntaxStyle
  readonly #commands: InteractiveCommands
  readonly #keybindings: InteractiveKeybindings
  #screen: SessionScreen
  #releaseGeneration: () => void
  #exitGesture: ExitGestureState = { type: "ready" }
  #disposed = false

  constructor({ renderer, session, onExit, keybindingOverrides, theme = defaultTheme }: InteractiveModeOptions) {
    this.#renderer = renderer
    this.store = createInteractiveStore(session)
    this.#onExit = onExit
    this.#theme = theme
    this.#syntaxStyle = createSyntaxStyle(theme)
    this.#commands = createInteractiveCommands()
    this.#keybindings = new InteractiveKeybindings(keybindingOverrides)
    this.root = new BoxRenderable(renderer, {
      id: "interactive-mode",
      width: "100%",
      height: "100%",
      flexDirection: "column",
      backgroundColor: theme.surface.app
    })
    this.#screen = this.#createScreen()
    this.root.add(this.#screen.root)
    renderer.root.add(this.root)
    this.#screen.prompt.focus()
    renderer.on(CliRenderEvents.SELECTION, this.#preservePromptFocus)

    this.#releaseGeneration = this.store.$generation.listen(() => this.#replaceScreen())
  }

  replaceSession(session: AgentSession): void {
    this.store.replaceSession(session)
  }

  dispose(): void {
    if (this.#disposed) return
    this.#disposed = true
    this.#releaseGeneration()
    this.#renderer.off(CliRenderEvents.SELECTION, this.#preservePromptFocus)
    this.#screen.destroy()
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

  #handleClear = (): "armed" | "exit" => {
    const now = Date.now()
    if (this.#exitGesture.type === "armed" && now - this.#exitGesture.pressedAt < exitGestureWindowMs) {
      this.#exitGesture = { type: "ready" }
      this.#onExit()
      return "exit"
    }
    this.#exitGesture = { type: "armed", pressedAt: now }
    return "armed"
  }

  #resetExitGesture = (): void => {
    this.#exitGesture = { type: "ready" }
  }

  #createScreen(): SessionScreen {
    return new SessionScreen(
      this.#renderer,
      this.store,
      this.#commands,
      this.#keybindings,
      this.#handleClear,
      this.#resetExitGesture,
      this.#onExit,
      this.#theme,
      this.#syntaxStyle
    )
  }
}
