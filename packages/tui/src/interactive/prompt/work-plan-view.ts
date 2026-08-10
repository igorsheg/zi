import { BoxRenderable, type CliRenderer, TextRenderable } from "@opentui/core"
import type { WorkPlanSnapshot } from "@with-zi/coding-agent"

import { truncateToCells } from "../../components/cell-text.js"
import type { Theme } from "../../theme.js"

const maxWorkPlanRows = 8

type WorkPlanLayout =
  | { readonly type: "invalid" }
  | {
      readonly type: "current"
      readonly revision: number
      readonly width: number
      readonly rowBudget: number
      readonly occupiedRows: number
    }

export class WorkPlanView {
  readonly root: BoxRenderable

  readonly #renderer: CliRenderer
  readonly #theme: Theme
  #layout: WorkPlanLayout = { type: "invalid" }

  constructor(renderer: CliRenderer, theme: Theme) {
    this.#renderer = renderer
    this.#theme = theme
    this.root = new BoxRenderable(renderer, {
      id: "prompt-work-plan",
      flexDirection: "column",
      flexShrink: 0,
      visible: false
    })
  }

  update(plan: WorkPlanSnapshot, width: number, maxRows: number): number {
    const effectiveWidth = Math.max(0, width)
    const rowBudget = Math.min(maxWorkPlanRows, Math.max(0, maxRows))
    const layout = this.#layout
    if (
      layout.type === "current" &&
      layout.revision === plan.revision &&
      layout.width === effectiveWidth &&
      layout.rowBudget === rowBudget
    ) {
      this.root.visible = layout.occupiedRows > 0
      return layout.occupiedRows
    }

    clear(this.root)
    const steps = plan.steps.filter(step => step.status === "pending" || step.status === "in_progress")
    if (steps.length === 0 || effectiveWidth === 0 || rowBudget === 0) {
      this.hide()
      this.#layout = { type: "current", revision: plan.revision, width: effectiveWidth, rowBudget, occupiedRows: 0 }
      return 0
    }

    this.root.visible = true
    const stepRows = steps.length > rowBudget ? rowBudget - 1 : steps.length
    for (const step of steps.slice(0, stepRows)) {
      const glyph = step.status === "in_progress" ? "◉" : "○"
      this.root.add(this.#row(`${glyph} ${singleLine(step.text)}`, effectiveWidth, step.status === "in_progress"))
    }
    const occupiedRows = stepRows < steps.length ? stepRows + 1 : stepRows
    if (stepRows < steps.length) {
      this.root.add(this.#row(`… ${steps.length - stepRows} more`, effectiveWidth, false))
    }
    this.#layout = { type: "current", revision: plan.revision, width: effectiveWidth, rowBudget, occupiedRows }
    return occupiedRows
  }

  hide(): void {
    this.root.visible = false
  }

  destroy(): void {
    this.root.destroyRecursively()
  }

  #row(content: string, width: number, inProgress: boolean): TextRenderable {
    return new TextRenderable(this.#renderer, {
      height: 1,
      wrapMode: "none",
      selectable: false,
      flexShrink: 0,
      fg: inProgress ? this.#theme.text.accent : this.#theme.text.dim,
      content: truncateToCells(content, width)
    })
  }
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
