import { BoxRenderable, type CliRenderer, TextRenderable } from "@opentui/core"
import type { WorkPlanSnapshot, WorkPlanStep } from "@with-zi/coding-agent"

import { truncateToCells } from "../../components/cell-text.js"
import type { Theme } from "../../theme.js"

export const maxWorkPlanDetailRows = 7

type WorkPlanLayout =
  | { readonly type: "invalid" }
  | {
      readonly type: "current"
      readonly revision: number
      readonly width: number
      readonly rowBudget: number
      readonly currentIndex: number
      readonly occupiedRows: number
    }

interface DetailLayout {
  readonly steps: readonly WorkPlanStep[]
  readonly omission?: { readonly text: string; readonly before: boolean }
}

export class WorkPlanDetailsView {
  readonly root: BoxRenderable

  readonly #renderer: CliRenderer
  readonly #theme: Theme
  #layout: WorkPlanLayout = { type: "invalid" }

  constructor(renderer: CliRenderer, theme: Theme) {
    this.#renderer = renderer
    this.#theme = theme
    this.root = new BoxRenderable(renderer, {
      id: "work-plan-details",
      flexDirection: "column",
      flexShrink: 0,
      visible: false
    })
  }

  update(plan: WorkPlanSnapshot, width: number, maxRows: number, currentIndex: number): number {
    const effectiveWidth = Math.max(0, width)
    const rowBudget = Math.min(maxWorkPlanDetailRows, Math.max(0, maxRows))
    const layout = this.#layout
    if (
      layout.type === "current" &&
      layout.revision === plan.revision &&
      layout.width === effectiveWidth &&
      layout.rowBudget === rowBudget &&
      layout.currentIndex === currentIndex
    ) {
      this.root.visible = layout.occupiedRows > 0
      return layout.occupiedRows
    }

    clear(this.root)
    if (plan.steps.length === 0 || effectiveWidth === 0 || rowBudget === 0) {
      this.root.visible = false
      this.#layout = {
        type: "current",
        revision: plan.revision,
        width: effectiveWidth,
        rowBudget,
        currentIndex,
        occupiedRows: 0
      }
      return 0
    }

    const detail = detailLayout(plan.steps, currentIndex, rowBudget)
    this.root.visible = true
    if (detail.omission?.before) this.root.add(this.#row(`… ${detail.omission.text}`, effectiveWidth, "omitted"))
    for (const step of detail.steps) this.root.add(this.#stepRow(step, effectiveWidth))
    if (detail.omission && !detail.omission.before) {
      this.root.add(this.#row(`… ${detail.omission.text}`, effectiveWidth, "omitted"))
    }
    const occupiedRows = detail.steps.length + (detail.omission ? 1 : 0)
    this.#layout = {
      type: "current",
      revision: plan.revision,
      width: effectiveWidth,
      rowBudget,
      currentIndex,
      occupiedRows
    }
    return occupiedRows
  }

  hide(): void {
    this.root.visible = false
  }

  destroy(): void {
    this.root.destroyRecursively()
  }

  #stepRow(step: WorkPlanStep, width: number): TextRenderable {
    const glyph =
      step.status === "completed" ? "✓" : step.status === "in_progress" ? "◉" : step.status === "pending" ? "○" : "–"
    const tone = step.status === "in_progress" ? "active" : "settled"
    return this.#row(`  ${glyph} ${singleLine(step.text)}`, width, tone)
  }

  #row(content: string, width: number, tone: "active" | "settled" | "omitted"): TextRenderable {
    return new TextRenderable(this.#renderer, {
      height: 1,
      wrapMode: "none",
      selectable: false,
      flexShrink: 0,
      fg:
        tone === "active"
          ? this.#theme.text.accent
          : tone === "omitted"
            ? this.#theme.text.muted
            : this.#theme.text.dim,
      content: truncateToCells(content, width)
    })
  }
}

function detailLayout(steps: readonly WorkPlanStep[], currentIndex: number, rowBudget: number): DetailLayout {
  if (steps.length <= rowBudget) return { steps }
  if (rowBudget === 1) return { steps: steps.slice(currentIndex, currentIndex + 1) }

  const visibleRows = rowBudget - 1
  const start = Math.min(Math.max(0, currentIndex - Math.floor(visibleRows / 2)), steps.length - visibleRows)
  const end = start + visibleRows
  const earlier = start
  const later = steps.length - end
  const text =
    earlier === 0 ? `${later} later` : later === 0 ? `${earlier} earlier` : `${earlier} earlier · ${later} later`
  return { steps: steps.slice(start, end), omission: { text, before: later === 0 } }
}

function singleLine(content: string): string {
  return content.replace(/[\r\n]+/g, " ")
}

function clear(root: BoxRenderable): void {
  for (const child of root.getChildren()) {
    root.remove(child)
    child.destroyRecursively()
  }
}
