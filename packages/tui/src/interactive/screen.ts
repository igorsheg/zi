import { BoxRenderable, type CliRenderer, type SyntaxStyle } from "@opentui/core"

import type { Theme } from "../theme.js"
import type { BrowserOpener } from "./browser-opener.js"
import type { ExitGestureController } from "./exit-gesture.js"
import type { InteractiveCommands } from "./interactive-commands.js"
import type { InteractiveKeybindings } from "./interactive-keybindings.js"
import type { InteractiveStore } from "./interactive-store.js"
import type { PromptSessionActions } from "./prompt/store.js"
import { PromptView } from "./prompt/view.js"
import { TranscriptView } from "./transcript/view.js"

export class SessionScreen {
  readonly root: BoxRenderable
  readonly transcript: TranscriptView
  readonly prompt: PromptView

  constructor(
    renderer: CliRenderer,
    interactive: InteractiveStore,
    commands: InteractiveCommands,
    keybindings: InteractiveKeybindings,
    exitGestures: ExitGestureController,
    browserOpener: BrowserOpener,
    theme: Theme,
    syntaxStyle: SyntaxStyle,
    measureTranscriptSync: boolean,
    sessionActions?: PromptSessionActions
  ) {
    this.root = new BoxRenderable(renderer, { flexDirection: "column", flexGrow: 1, minHeight: 0 })
    this.transcript = new TranscriptView(renderer, interactive, keybindings, theme, syntaxStyle, {
      measureSync: measureTranscriptSync
    })
    this.prompt = new PromptView(
      renderer,
      interactive,
      commands,
      keybindings,
      exitGestures,
      browserOpener,
      theme,
      sessionActions
    )
    this.root.add(this.transcript.root)
    this.root.add(this.prompt.root)
  }

  destroy(): void {
    this.transcript.destroy()
    this.prompt.destroy()
    this.root.destroyRecursively()
  }
}
