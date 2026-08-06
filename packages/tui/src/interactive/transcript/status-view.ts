import { BoxRenderable, TextRenderable, type CliRenderer } from "@opentui/core"

import { ShimmerTextView } from "../../components/shimmer-text.js"
import type { Theme } from "../../theme.js"
import type { InteractiveKeybindings } from "../interactive-keybindings.js"

export const transcriptStatusRows = 1

export type TranscriptStatusPresentation =
  | { readonly type: "empty" }
  | { readonly type: "working"; readonly text: string }
  | { readonly type: "unseen_output" }
  | { readonly type: "working_with_unseen_output"; readonly text: string }

export class TranscriptStatusView {
  readonly root: BoxRenderable

  readonly #working: ShimmerTextView
  readonly #separator: TextRenderable
  readonly #unseenLabel: TextRenderable
  readonly #unseenHint: TextRenderable
  #presentation: TranscriptStatusPresentation = { type: "empty" }
  #available = true

  constructor(renderer: CliRenderer, keybindings: InteractiveKeybindings, theme: Theme) {
    this.root = new BoxRenderable(renderer, {
      id: "transcript-status",
      height: transcriptStatusRows,
      flexDirection: "row",
      flexShrink: 0
    })
    this.#working = new ShimmerTextView(renderer, "Working…", theme.text.muted, theme.text.primary)
    this.#separator = new TextRenderable(renderer, {
      height: 1,
      wrapMode: "none",
      selectable: false,
      flexShrink: 0,
      visible: false,
      fg: theme.text.muted,
      content: " • "
    })
    const tailHint = keybindings.getHint("app.transcript.tail")
    this.#unseenLabel = new TextRenderable(renderer, {
      height: 1,
      wrapMode: "none",
      selectable: false,
      flexShrink: 0,
      visible: false,
      fg: theme.text.accent,
      content: "New output"
    })
    this.#unseenHint = new TextRenderable(renderer, {
      height: 1,
      wrapMode: "none",
      selectable: false,
      flexShrink: 1,
      minWidth: 0,
      truncate: true,
      visible: false,
      fg: theme.text.accent,
      content: tailHint ? ` (${tailHint} to jump)` : ""
    })
    this.root.add(this.#working.root)
    this.root.add(this.#separator)
    this.root.add(this.#unseenLabel)
    this.root.add(this.#unseenHint)
  }

  update(presentation: TranscriptStatusPresentation): void {
    if (samePresentation(this.#presentation, presentation)) return
    this.#presentation = presentation
    this.#render()
  }

  setAvailable(available: boolean): void {
    if (available === this.#available) return
    this.#available = available
    this.root.visible = available
    this.#render()
  }

  destroy(): void {
    this.#working.destroy()
    this.root.destroyRecursively()
  }

  #render(): void {
    const presentation = this.#presentation
    const working =
      this.#available && (presentation.type === "working" || presentation.type === "working_with_unseen_output")
    const unseenOutput =
      this.#available && (presentation.type === "unseen_output" || presentation.type === "working_with_unseen_output")
    if (working) this.#working.setText(presentation.text)
    this.#working.setActive(working)
    this.#separator.visible = this.#available && presentation.type === "working_with_unseen_output"
    this.#unseenLabel.visible = unseenOutput
    this.#unseenHint.visible = unseenOutput
  }
}

function samePresentation(left: TranscriptStatusPresentation, right: TranscriptStatusPresentation): boolean {
  if (left.type !== right.type) return false
  if (left.type === "working" && right.type === "working") return left.text === right.text
  if (left.type === "working_with_unseen_output" && right.type === "working_with_unseen_output") {
    return left.text === right.text
  }
  return true
}
