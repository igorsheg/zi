import { basename, isAbsolute, relative, resolve, sep } from "node:path"

import { BoxRenderable, TextRenderable, type CliRenderer } from "@opentui/core"
import type { ContextUsage, ThinkingLevel } from "@with-zi/coding-agent"

import { textWidth } from "../../components/cell-text.js"
import type { Theme } from "../../theme.js"

export type PromptFooterModel =
  | { readonly type: "unselected" }
  | { readonly type: "selected"; readonly id: string; readonly thinking: ThinkingLevel }

export type PromptFooterPresentation =
  | { readonly type: "hidden" }
  | {
      readonly type: "session"
      readonly cwd: string
      readonly homeDir: string
      readonly model: PromptFooterModel
      readonly context: ContextUsage
    }

export type PromptFooterLayout =
  | { readonly type: "hidden" }
  | { readonly type: "line"; readonly left: string; readonly right: string }

const horizontalPadding = 2
const sideGap = 2
const itemSeparator = " • "
// OpenTUI's native middle truncation needs this width to preserve a useful prefix and basename.
const minimumTruncatedPathWidth = 8

export class PromptFooterView {
  static readonly occupiedRows = 1

  readonly root: BoxRenderable

  readonly #left: TextRenderable
  readonly #right: TextRenderable
  #layout: PromptFooterLayout = { type: "hidden" }

  constructor(renderer: CliRenderer, theme: Theme) {
    this.root = new BoxRenderable(renderer, {
      id: "prompt-footer",
      height: PromptFooterView.occupiedRows,
      flexDirection: "row",
      flexShrink: 0,
      paddingLeft: 1,
      paddingRight: 1,
      visible: false
    })
    this.#left = new TextRenderable(renderer, {
      id: "prompt-footer-left",
      height: 1,
      wrapMode: "none",
      selectable: false,
      flexGrow: 1,
      flexShrink: 1,
      minWidth: 0,
      // OpenTUI 0.4.5 retains both ends with a three-cell middle ellipsis.
      truncate: true,
      fg: theme.text.muted
    })
    this.#right = new TextRenderable(renderer, {
      id: "prompt-footer-right",
      height: 1,
      wrapMode: "none",
      selectable: false,
      flexShrink: 0,
      fg: theme.text.muted
    })
    this.root.add(this.#left)
    this.root.add(this.#right)
  }

  update(layout: PromptFooterLayout): number {
    const previous = this.#layout
    if (sameLayout(previous, layout)) return layout.type === "hidden" ? 0 : PromptFooterView.occupiedRows
    this.#layout = layout

    if (layout.type === "hidden") {
      this.root.visible = false
      return 0
    }

    if (previous.type === "hidden" || previous.left !== layout.left) this.#left.content = layout.left
    if (previous.type === "hidden" || previous.right !== layout.right) this.#right.content = layout.right
    if (previous.type === "hidden" || hasGap(previous) !== hasGap(layout)) {
      this.root.columnGap = hasGap(layout) ? sideGap : 0
    }
    this.root.visible = true
    return PromptFooterView.occupiedRows
  }

  destroy(): void {
    this.root.destroyRecursively()
  }
}

export function layoutPromptFooter(presentation: PromptFooterPresentation, width: number): PromptFooterLayout {
  if (presentation.type === "hidden") return presentation

  const available = width - horizontalPadding
  if (available <= 0) return { type: "hidden" }

  for (const candidate of footerCandidates(presentation)) {
    if (lineWidth(candidate) <= available) {
      return { type: "line", left: candidate.left, right: candidate.right }
    }
  }
  return { type: "hidden" }
}

interface FooterLine {
  readonly left: string
  readonly right: string
  readonly leftWidth: number
}

function footerCandidates(presentation: Extract<PromptFooterPresentation, { type: "session" }>): FooterLine[] {
  const displayCwd = formatCwd(presentation.cwd, presentation.homeDir)
  const compactCwd = basename(displayCwd) || displayCwd
  const model = presentation.model

  if (model.type === "unselected") {
    return [
      pathLine(displayCwd, "No model selected"),
      line(compactCwd, "No model selected"),
      pathLine(displayCwd, "No model"),
      line(compactCwd, "No model"),
      line("", "No model")
    ]
  }

  const fullModel = model.thinking === "off" ? model.id : `${model.id} (${model.thinking})`
  const context = presentation.context
  if (context.type === "unavailable") {
    return [
      pathLine(displayCwd, fullModel),
      line(compactCwd, fullModel),
      pathLine(displayCwd, model.id),
      line(compactCwd, model.id),
      pathLine(displayCwd, ""),
      line(compactCwd, "")
    ]
  }

  const fullContext = contextTitle(context.type, context.percent, context.contextWindow)
  const compactContext = contextPercent(context.type, context.percent)
  const fullRight = joinItems(fullContext, fullModel)
  const compactRight = joinItems(compactContext, model.id)
  return [
    pathLine(displayCwd, fullRight),
    line(compactCwd, fullRight),
    pathLine(displayCwd, compactRight),
    line(compactCwd, compactRight),
    pathLine(displayCwd, compactContext),
    line(compactCwd, compactContext),
    line("", compactContext)
  ]
}

// Pi provenance: pi-coding-agent footer.ts at 73414d08 contracts only cwd values inside the configured home.
function formatCwd(cwd: string, homeDir: string): string {
  const resolvedCwd = resolve(cwd)
  const resolvedHome = resolve(homeDir)
  const relativeToHome = relative(resolvedHome, resolvedCwd)
  const insideHome =
    relativeToHome === "" ||
    (relativeToHome !== ".." && !relativeToHome.startsWith(`..${sep}`) && !isAbsolute(relativeToHome))
  if (!insideHome) return cwd
  return relativeToHome === "" ? "~" : `~${sep}${relativeToHome}`
}

function pathLine(left: string, right: string): FooterLine {
  return { left, right, leftWidth: Math.min(textWidth(left), minimumTruncatedPathWidth) }
}

function line(left: string, right: string): FooterLine {
  return { left, right, leftWidth: textWidth(left) }
}

function lineWidth(candidate: FooterLine): number {
  const right = textWidth(candidate.right)
  return candidate.leftWidth + right + (candidate.leftWidth > 0 && right > 0 ? sideGap : 0)
}

function joinItems(...items: readonly string[]): string {
  return items.filter(Boolean).join(itemSeparator)
}

function contextTitle(type: "measured" | "estimated", percent: number, contextWindow: number): string {
  return `${contextPercent(type, percent)}/${formatTokenCount(contextWindow)}`
}

function contextPercent(type: "measured" | "estimated", percent: number): string {
  return `ctx ${type === "estimated" ? "~" : ""}${Math.round(percent)}%`
}

function formatTokenCount(tokens: number): string {
  if (tokens < 1_000) return String(tokens)
  if (tokens < 1_000_000) return `${Math.round(tokens / 1_000)}k`
  return `${(tokens / 1_000_000).toFixed(1).replace(/\.0$/, "")}m`
}

function hasGap(layout: PromptFooterLayout): boolean {
  return layout.type === "line" && Boolean(layout.left) && Boolean(layout.right)
}

function sameLayout(left: PromptFooterLayout, right: PromptFooterLayout): boolean {
  if (left.type !== right.type) return false
  if (left.type === "hidden" || right.type === "hidden") return true
  return left.left === right.left && left.right === right.right
}
