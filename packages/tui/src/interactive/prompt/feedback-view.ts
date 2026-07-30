import {
  BoxRenderable,
  type CliRenderer,
  fg,
  link,
  StyledText,
  t,
  TextRenderable,
  type Color as OtuiColor
} from "@opentui/core"

import { truncateToCells } from "../../components/cell-text.js"
import type { Theme } from "../../theme.js"
import type { BrowserOpener } from "../browser-opener.js"
import type { AuthCeremony, PromptFeedback } from "./state.js"

export const maxAuthCeremonyRows = 8

type CeremonyLineKind = "title" | "code" | "link" | "instructions" | "status" | "prompt" | "placeholder"

type CeremonyLine = {
  readonly kind: CeremonyLineKind
  readonly content: TextRenderable["content"]
  readonly openUrl?: string
  readonly requestId?: number
}

export class PromptFeedbackView {
  readonly root: BoxRenderable

  readonly #renderer: CliRenderer
  readonly #browserOpener: BrowserOpener
  readonly #theme: Theme
  #openedRequestId = 0

  constructor(renderer: CliRenderer, browserOpener: BrowserOpener, theme: Theme) {
    this.#renderer = renderer
    this.#browserOpener = browserOpener
    this.#theme = theme
    this.root = new BoxRenderable(renderer, { flexDirection: "column", flexShrink: 0 })
  }

  /** Occupied rows; 0 when hidden. */
  update(feedback: PromptFeedback, ceremony: AuthCeremony | undefined, width: number): number {
    clear(this.root)
    const innerWidth = Math.max(0, width - 2)
    const lines = ceremony
      ? ceremonyLines(ceremony, innerWidth, this.#theme)
      : feedbackLines(feedback, innerWidth, this.#theme)
    if (lines.length === 0) {
      this.root.visible = false
      return 0
    }

    this.root.visible = true
    for (const [index, line] of lines.entries()) {
      this.root.add(this.#row(`feedback-${index}`, line))
      if (line.openUrl && line.requestId !== undefined && line.requestId > this.#openedRequestId) {
        this.#openedRequestId = line.requestId
        // The OSC 8 link remains usable when the bounded platform opener fails.
        void this.#browserOpener.open(line.openUrl).catch(() => {})
      }
    }
    return lines.length
  }

  destroy(): void {
    this.root.destroyRecursively()
  }

  #row(id: string, line: CeremonyLine): BoxRenderable {
    const row = new BoxRenderable(this.#renderer, { id, height: 1, paddingLeft: 1, paddingRight: 1, flexShrink: 0 })
    row.add(new TextRenderable(this.#renderer, { wrapMode: "none", content: line.content }))
    return row
  }
}

function feedbackLines(feedback: PromptFeedback, width: number, theme: Theme): CeremonyLine[] {
  if (feedback.type === "none") return []
  const color =
    feedback.type === "error"
      ? theme.text.error
      : feedback.type === "warning" || feedback.type === "copy_warning"
        ? theme.text.warning
        : theme.text.muted
  return [{ kind: "status", content: textLine(color, feedback.message, width) }]
}

function ceremonyLines(ceremony: AuthCeremony, width: number, theme: Theme): CeremonyLine[] {
  const lines: CeremonyLine[] = [{ kind: "title", content: textLine(theme.text.accent, ceremony.methodName, width) }]

  if (ceremony.device) {
    lines.push({
      kind: "code",
      content: textLine(theme.text.warning, `Enter code: ${ceremony.device.userCode}`, width)
    })
    lines.push(linkLine(ceremony.device.verificationUri, width, ceremony.device.requestId))
  }

  if (ceremony.url) {
    lines.push(linkLine(ceremony.url.href, width, ceremony.url.requestId))
    if (ceremony.url.instructions) {
      lines.push({ kind: "instructions", content: textLine(theme.text.warning, ceremony.url.instructions, width) })
    }
  }

  if (ceremony.info) {
    lines.push({ kind: "status", content: textLine(theme.text.primary, ceremony.info.message, width) })
    for (const item of ceremony.info.links ?? []) {
      const label = item.label ? `${item.label}: ${item.url}` : item.url
      lines.push({
        kind: "link",
        content: t`${link(item.url)(truncateToCells(label, width))}`,
        openUrl: item.url,
        requestId: 0
      })
    }
  }

  if (ceremony.status) {
    lines.push({ kind: "status", content: textLine(theme.text.muted, ceremony.status, width) })
  }

  if (ceremony.prompt) {
    lines.push({ kind: "prompt", content: textLine(theme.text.primary, ceremony.prompt.message, width) })
    if (ceremony.prompt.placeholder) {
      lines.push({
        kind: "placeholder",
        content: textLine(theme.text.dim, `e.g. ${ceremony.prompt.placeholder}`, width)
      })
    }
  }

  return boundCeremonyLines(lines, maxAuthCeremonyRows)
}

function textLine(color: OtuiColor, text: string, width: number): StyledText {
  return new StyledText([fg(color)(truncateToCells(text, width))])
}

function linkLine(url: string, width: number, requestId: number): CeremonyLine {
  return { kind: "link", content: t`${link(url)(truncateToCells(url, width))}`, openUrl: url, requestId }
}

/**
 * Prefer title, codes, URLs, and the active prompt. Drop status/instructions/placeholders first.
 */
function boundCeremonyLines(lines: CeremonyLine[], maxRows: number): CeremonyLine[] {
  if (lines.length <= maxRows) return lines
  const dropOrder: readonly CeremonyLineKind[] = ["placeholder", "status", "instructions", "prompt", "title"]
  const kept = [...lines]
  for (const kind of dropOrder) {
    while (kept.length > maxRows) {
      const index = kept.findLastIndex(line => line.kind === kind)
      if (index < 0) break
      kept.splice(index, 1)
    }
    if (kept.length <= maxRows) return kept
  }
  return kept.slice(0, maxRows)
}

function clear(root: BoxRenderable): void {
  for (const child of root.getChildren()) {
    root.remove(child)
    child.destroyRecursively()
  }
}
