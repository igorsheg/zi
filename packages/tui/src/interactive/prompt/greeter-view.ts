import { BoxRenderable, fg, StyledText, TextRenderable, type CliRenderer } from "@opentui/core"

import type { Theme } from "../../theme.js"

const occupiedRows = 4
const minimumTerminalRows = 11
const minimumCompactColumns = 14
const minimumFullColumns = 30

type GreeterPresentation = "hidden" | "compact" | "full"

export class SessionGreeterView {
  readonly root: BoxRenderable

  readonly #text: TextRenderable
  readonly #fullContent: StyledText
  readonly #compactContent: StyledText
  #presentation: GreeterPresentation = "hidden"

  constructor(renderer: CliRenderer, theme: Theme) {
    this.root = new BoxRenderable(renderer, {
      id: "session-greeter",
      flexDirection: "column",
      flexShrink: 0,
      paddingLeft: 1,
      paddingBottom: 1,
      visible: false
    })
    this.#fullContent = new StyledText([
      fg(theme.text.accent)("░▀▀█░▀█▀"),
      fg(theme.text.primary)("  zi coding agent\n"),
      fg(theme.text.accent)("░▄▀░░░█░"),
      fg(theme.text.muted)("  you can build with\n"),
      fg(theme.text.accent)("░▀▀▀░▀▀▀")
    ])
    this.#compactContent = new StyledText([
      fg(theme.text.accent)("░▀▀█░▀█▀"),
      fg(theme.text.primary)("  zi\n"),
      fg(theme.text.accent)("░▄▀░░░█░\n░▀▀▀░▀▀▀")
    ])
    this.#text = new TextRenderable(renderer, {
      height: 3,
      wrapMode: "none",
      selectable: false,
      content: this.#fullContent
    })
    this.root.add(this.#text)
  }

  update(sessionEmpty: boolean, columns: number, rows: number, pickerOpen: boolean): number {
    const presentation = greeterPresentation(sessionEmpty, columns, rows, pickerOpen)
    if (presentation === this.#presentation) return presentation === "hidden" ? 0 : occupiedRows

    this.#presentation = presentation
    switch (presentation) {
      case "hidden":
        this.root.visible = false
        return 0
      case "compact":
        this.#text.content = this.#compactContent
        this.root.visible = true
        return occupiedRows
      case "full":
        this.#text.content = this.#fullContent
        this.root.visible = true
        return occupiedRows
      default:
        return assertNever(presentation)
    }
  }

  destroy(): void {
    this.root.destroyRecursively()
  }
}

function greeterPresentation(
  sessionEmpty: boolean,
  columns: number,
  rows: number,
  pickerOpen: boolean
): GreeterPresentation {
  if (!sessionEmpty || pickerOpen || rows < minimumTerminalRows || columns < minimumCompactColumns) return "hidden"
  return columns >= minimumFullColumns ? "full" : "compact"
}

function assertNever(value: never): never {
  throw new Error(`Unhandled greeter presentation: ${String(value)}`)
}
