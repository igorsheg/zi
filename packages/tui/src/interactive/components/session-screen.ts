import { BoxRenderable, type CliRenderer, type SyntaxStyle } from "@opentui/core"

import type { Theme } from "../../theme.js"
import type { BrowserOpener } from "../browser-opener.js"
import type { ExitGestureController } from "../exit-gesture.js"
import type { InteractiveCommands } from "../interactive-commands.js"
import type { InteractiveKeybindings } from "../interactive-keybindings.js"
import type { InteractiveStore } from "../stores/interactive.js"
import { PromptView } from "./prompt.js"
import { TranscriptView } from "./transcript.js"

export class SessionScreen {
  readonly root: BoxRenderable
  readonly transcript: TranscriptView
  readonly prompt: PromptView

  constructor(
    renderer: CliRenderer,
    mode: InteractiveStore,
    commands: InteractiveCommands,
    keybindings: InteractiveKeybindings,
    exitGestures: ExitGestureController,
    browserOpener: BrowserOpener,
    theme: Theme,
    syntaxStyle: SyntaxStyle
  ) {
    this.root = new BoxRenderable(renderer, { flexDirection: "column", flexGrow: 1, minHeight: 0 })
    this.transcript = new TranscriptView(renderer, mode, keybindings, theme, syntaxStyle)
    this.prompt = new PromptView(renderer, mode, commands, keybindings, exitGestures, browserOpener, theme)
    this.root.add(this.transcript.root)
    this.root.add(this.prompt.root)
  }

  destroy(): void {
    this.transcript.destroy()
    this.prompt.destroy()
    this.root.destroyRecursively()
  }
}
