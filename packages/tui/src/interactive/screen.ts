import { BoxRenderable, type CliRenderer, type SyntaxStyle } from "@opentui/core"

import type { Theme } from "../theme.js"
import type { BrowserOpener } from "./browser-opener.js"
import type { ClipboardReader } from "./clipboard.js"
import type { ExitGestureController } from "./exit-gesture.js"
import type { ExternalEditor } from "./external-editor.js"
import type { InteractiveKeybindings } from "./interactive-keybindings.js"
import type { InteractiveStore } from "./interactive-store.js"
import type { PromptSessionActions } from "./prompt/store.js"
import { PromptView } from "./prompt/view.js"
import type { SlashController } from "./slash-controller.js"
import type { SystemNoticeActions } from "./system-notifications.js"
import { TranscriptView } from "./transcript/view.js"

export class SessionScreen {
  readonly root: BoxRenderable
  readonly transcript: TranscriptView
  readonly prompt: PromptView

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
    syntaxStyle: SyntaxStyle,
    measureTranscriptSync: boolean,
    systemNotices: SystemNoticeActions,
    sessionActions?: PromptSessionActions
  ) {
    this.root = new BoxRenderable(renderer, { flexDirection: "column", flexGrow: 1, minHeight: 0 })
    this.transcript = new TranscriptView(renderer, interactive, keybindings, theme, syntaxStyle, {
      measureSync: measureTranscriptSync
    })
    this.prompt = new PromptView(
      renderer,
      interactive,
      slash,
      keybindings,
      exitGestures,
      browserOpener,
      clipboard,
      externalEditor,
      theme,
      systemNotices,
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
