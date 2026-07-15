import { BoxRenderable, type CliRenderer, link, t, TextRenderable } from "@opentui/core"

import type { Theme } from "../../theme.js"
import type { BrowserOpener } from "../browser-opener.js"
import type { PromptFeedback } from "../stores/prompt.js"
import { truncateToCells } from "./cell-text.js"

export class PromptFeedbackView {
  readonly root: BoxRenderable

  readonly #browserOpener: BrowserOpener
  readonly #theme: Theme
  readonly #text: TextRenderable
  #openedRequestId = 0

  constructor(renderer: CliRenderer, browserOpener: BrowserOpener, theme: Theme) {
    this.#browserOpener = browserOpener
    this.#theme = theme
    this.root = new BoxRenderable(renderer, { height: 1, paddingLeft: 1, paddingRight: 1, flexShrink: 0 })
    this.#text = new TextRenderable(renderer, { wrapMode: "none" })
    this.root.add(this.#text)
  }

  update(feedback: PromptFeedback, width: number): boolean {
    const visible = feedback.type !== "none"
    this.root.visible = visible
    if (!visible) {
      this.#text.content = ""
      return false
    }

    if (feedback.type === "auth_link") {
      this.#text.content = t`${feedback.message}: ${link(feedback.url)(feedback.url)}`
      if (feedback.requestId > this.#openedRequestId) {
        this.#openedRequestId = feedback.requestId
        // The OSC 8 link remains usable when the bounded platform opener fails.
        void this.#browserOpener.open(feedback.url).catch(() => {})
      }
    } else {
      this.#text.content = truncateToCells(feedback.message, Math.max(0, width - 2))
    }
    this.#text.fg = feedback.type === "error" ? this.#theme.text.error : this.#theme.text.muted
    return true
  }

  destroy(): void {
    this.root.destroyRecursively()
  }
}
