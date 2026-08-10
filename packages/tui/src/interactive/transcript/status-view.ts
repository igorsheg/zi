import { BoxRenderable, TextRenderable, type CliRenderer } from "@opentui/core"
import type { WorkPlanSnapshot, WorkPlanStepStatus } from "@with-zi/coding-agent"

import { textWidth } from "../../components/cell-text.js"
import { ShimmerTextView } from "../../components/shimmer-text.js"
import type { Theme } from "../../theme.js"
import type { InteractiveKeybindings } from "../interactive-keybindings.js"
import { WorkPlanDetailsView } from "./work-plan-details-view.js"

export const transcriptStatusRows = 1

export type TranscriptActivityStatus =
  | { readonly type: "idle" }
  | { readonly type: "working" }
  | { readonly type: "working_with_lifecycle"; readonly text: string }

export type TranscriptBackgroundStatus =
  | { readonly type: "idle" }
  | { readonly type: "running"; readonly shellCommands: number; readonly subagents: number }

export type TranscriptWorkPlanStatus =
  | { readonly type: "absent" }
  | {
      readonly type: "present"
      readonly plan: WorkPlanSnapshot
      readonly completed: number
      readonly total: number
      readonly currentIndex: number
      readonly currentStatus: Extract<WorkPlanStepStatus, "pending" | "in_progress">
    }

export interface TranscriptStatusPresentation {
  readonly activity: TranscriptActivityStatus
  readonly background: TranscriptBackgroundStatus
  readonly workPlan: TranscriptWorkPlanStatus
  readonly unseenOutput: boolean
}

type WorkPlanDisclosure = { readonly type: "collapsed" } | { readonly type: "expanded" }

export class TranscriptStatusView {
  readonly root: BoxRenderable

  readonly #working: ShimmerTextView
  readonly #details: WorkPlanDetailsView
  readonly #line: BoxRenderable
  readonly #workingLifecycleSeparator: TextRenderable
  readonly #lifecycle: TextRenderable
  readonly #unseenSeparator: TextRenderable
  readonly #unseenLabel: TextRenderable
  readonly #unseenHint: TextRenderable
  readonly #backgroundSeparator: TextRenderable
  readonly #background: TextRenderable
  readonly #planSeparator: TextRenderable
  readonly #planLabel: TextRenderable
  readonly #planProgress: TextRenderable
  readonly #planCurrent: TextRenderable
  readonly #planHint: TextRenderable
  readonly #toggleHint: string | undefined
  #presentation: TranscriptStatusPresentation = emptyPresentation
  #disclosure: WorkPlanDisclosure = { type: "collapsed" }
  #width = 0
  #detailRows = 0
  #available = true
  #renderedPlan = false

  constructor(renderer: CliRenderer, keybindings: InteractiveKeybindings, theme: Theme) {
    this.root = new BoxRenderable(renderer, { id: "transcript-status", flexDirection: "column", flexShrink: 0 })
    this.#details = new WorkPlanDetailsView(renderer, theme)
    this.#line = new BoxRenderable(renderer, { height: 1, flexDirection: "row", flexShrink: 0 })
    this.#working = new ShimmerTextView(renderer, "Working…", theme.text.muted, theme.text.primary)
    this.#workingLifecycleSeparator = statusText(renderer, theme.text.muted, " • ")
    this.#lifecycle = shrinkingStatusText(renderer, theme.text.primary)
    this.#unseenSeparator = statusText(renderer, theme.text.muted, " • ")
    const tailHint = keybindings.getHint("app.transcript.tail")
    this.#unseenLabel = statusText(renderer, theme.text.accent, "New output")
    this.#unseenHint = shrinkingStatusText(renderer, theme.text.accent, tailHint ? ` (${tailHint} to jump)` : "")
    this.#backgroundSeparator = statusText(renderer, theme.text.muted, " • ")
    this.#background = statusText(renderer, theme.text.muted, "")
    this.#planSeparator = statusText(renderer, theme.text.muted, " • ")
    this.#planLabel = statusText(renderer, theme.text.accent, "")
    this.#planProgress = statusText(renderer, theme.text.muted, "")
    this.#planCurrent = new TextRenderable(renderer, {
      height: 1,
      wrapMode: "none",
      selectable: false,
      flexShrink: 1,
      minWidth: 0,
      truncate: true,
      visible: false,
      fg: theme.text.primary,
      content: ""
    })
    this.#toggleHint = keybindings.getHint("app.plan.toggle")
    this.#planHint = new TextRenderable(renderer, {
      height: 1,
      wrapMode: "none",
      selectable: false,
      flexShrink: 0,
      visible: false,
      fg: theme.text.muted,
      content: ""
    })
    this.root.add(this.#details.root)
    this.root.add(this.#line)
    this.#line.add(this.#working.root)
    this.#line.add(this.#workingLifecycleSeparator)
    this.#line.add(this.#lifecycle)
    this.#line.add(this.#unseenSeparator)
    this.#line.add(this.#unseenLabel)
    this.#line.add(this.#unseenHint)
    this.#line.add(this.#backgroundSeparator)
    this.#line.add(this.#background)
    this.#line.add(this.#planSeparator)
    this.#line.add(this.#planLabel)
    this.#line.add(this.#planProgress)
    this.#line.add(this.#planCurrent)
    this.#line.add(this.#planHint)
    this.#render()
  }

  get canTogglePlan(): boolean {
    return this.#available && this.#detailRows > 0 && this.#renderedPlan
  }

  update(presentation: TranscriptStatusPresentation, width: number, detailRows: number): void {
    if (presentation.workPlan.type === "absent") this.#disclosure = { type: "collapsed" }
    if (
      samePresentation(this.#presentation, presentation) &&
      this.#width === width &&
      this.#detailRows === detailRows
    ) {
      return
    }
    this.#presentation = presentation
    this.#width = width
    this.#detailRows = detailRows
    this.#render()
  }

  togglePlan(): boolean {
    if (!this.canTogglePlan) return false
    this.#disclosure = this.#disclosure.type === "collapsed" ? { type: "expanded" } : { type: "collapsed" }
    this.#render()
    return true
  }

  setAvailable(available: boolean): void {
    if (available === this.#available) return
    this.#available = available
    this.root.visible = available
    this.#render()
  }

  destroy(): void {
    this.#working.destroy()
    this.#details.destroy()
    this.root.destroyRecursively()
  }

  #render(): void {
    const presentation = this.#presentation
    const plan = presentation.workPlan.type === "present" ? presentation.workPlan : undefined
    const showWorking = this.#available && presentation.activity.type !== "idle"
    const showLifecycle = this.#available && presentation.activity.type === "working_with_lifecycle"
    const showUnseen = this.#available && presentation.unseenOutput
    const showBackground = this.#available && presentation.background.type === "running"
    const disclosureExpanded = this.#disclosure.type === "expanded" && this.#detailRows > 0
    const planLabel = plan ? `${disclosureExpanded ? "▾" : plan.currentStatus === "in_progress" ? "◉" : "○"} Plan` : ""
    const planProgress = plan ? ` · ${plan.completed}/${plan.total}` : ""
    const planCurrent =
      plan && !disclosureExpanded
        ? ` · ${plan.currentStatus === "pending" ? "Next: " : ""}${plan.plan.steps[plan.currentIndex]!.text}`
        : ""
    const planHint = this.#toggleHint
      ? ` (${this.#toggleHint} to ${this.#disclosure.type === "expanded" ? "collapse" : "expand"})`
      : ""
    const fullBackgroundText =
      presentation.background.type === "running" ? runningBackgroundText(presentation.background) : ""
    const activityWidth = showWorking
      ? textWidth("Working…") +
        (presentation.activity.type === "working_with_lifecycle" ? textWidth(presentation.activity.text) + 3 : 0)
      : 0
    const unseenWidth = showUnseen ? textWidth("New output") + (showWorking ? 3 : 0) : 0
    const backgroundSeparatorWidth = showBackground && (showWorking || showUnseen) ? 3 : 0
    const backgroundWidth = showBackground ? textWidth(fullBackgroundText) + backgroundSeparatorWidth : 0
    const priorityWidth = activityWidth + unseenWidth + backgroundWidth
    const fixedPlanWidth =
      priorityWidth + textWidth(planLabel) + textWidth(planProgress) + (priorityWidth > 0 && plan !== undefined ? 3 : 0)
    const showPlan = this.#available && plan !== undefined && (fixedPlanWidth <= this.#width || priorityWidth === 0)
    const planWidth = showPlan ? textWidth(planLabel) + textWidth(planProgress) + (priorityWidth > 0 ? 3 : 0) : 0
    const backgroundText =
      presentation.background.type === "running"
        ? runningBackgroundText(
            presentation.background,
            Math.max(1, this.#width - activityWidth - unseenWidth - backgroundSeparatorWidth - planWidth)
          )
        : ""
    const expanded = showPlan && disclosureExpanded
    this.#renderedPlan = showPlan

    this.#working.setActive(showWorking)
    this.#workingLifecycleSeparator.visible = showLifecycle
    this.#lifecycle.visible = showLifecycle
    if (presentation.activity.type === "working_with_lifecycle") this.#lifecycle.content = presentation.activity.text
    this.#unseenSeparator.visible = showWorking && showUnseen
    this.#unseenLabel.visible = showUnseen
    this.#unseenHint.visible = showUnseen && !showBackground && !showPlan
    this.#backgroundSeparator.visible = showBackground && (showWorking || showUnseen)
    this.#background.visible = showBackground
    this.#background.content = backgroundText
    this.#planSeparator.visible = showPlan && (showWorking || showUnseen || showBackground)
    this.#planLabel.visible = showPlan
    this.#planProgress.visible = showPlan
    this.#planCurrent.visible = showPlan && !expanded
    this.#planHint.visible =
      showPlan &&
      this.#detailRows > 0 &&
      Boolean(planHint) &&
      fixedPlanWidth + textWidth(planCurrent) + textWidth(planHint) <= this.#width

    if (!plan) {
      this.#details.update(emptyPlan, 0, 0, 0)
      return
    }

    this.#planLabel.content = planLabel
    this.#planProgress.content = planProgress
    this.#planCurrent.content = planCurrent
    this.#planHint.content = planHint
    if (expanded) this.#details.update(plan.plan, this.#width, this.#detailRows, plan.currentIndex)
    else this.#details.hide()
  }
}

const emptyPlan: WorkPlanSnapshot = Object.freeze({ revision: 0, steps: Object.freeze([]) })
const emptyPresentation: TranscriptStatusPresentation = Object.freeze({
  activity: Object.freeze({ type: "idle" }),
  background: Object.freeze({ type: "idle" }),
  workPlan: Object.freeze({ type: "absent" }),
  unseenOutput: false
})

function statusText(renderer: CliRenderer, color: Theme["text"]["muted"], content: string): TextRenderable {
  return new TextRenderable(renderer, {
    height: 1,
    wrapMode: "none",
    selectable: false,
    flexShrink: 0,
    visible: false,
    fg: color,
    content
  })
}

function shrinkingStatusText(
  renderer: CliRenderer,
  color: Theme["text"]["muted"],
  content = "",
  minWidth = 0
): TextRenderable {
  return new TextRenderable(renderer, {
    height: 1,
    wrapMode: "none",
    selectable: false,
    flexShrink: 1,
    minWidth,
    truncate: true,
    visible: false,
    fg: color,
    content
  })
}

function runningBackgroundText(
  background: Extract<TranscriptBackgroundStatus, { type: "running" }>,
  availableWidth = Number.POSITIVE_INFINITY
): string {
  const commands = background.shellCommands
    ? `${background.shellCommands} command${background.shellCommands === 1 ? "" : "s"}`
    : ""
  const subagents = background.subagents
    ? `${background.subagents} subagent${background.subagents === 1 ? "" : "s"}`
    : ""
  const total = background.shellCommands + background.subagents
  const candidates = [
    `◎ ${[commands, subagents].filter(Boolean).join(" · ")} still running`,
    `◎ ${total} still running`,
    `◎ ${total}`,
    "◎"
  ]
  return candidates.find(candidate => textWidth(candidate) <= availableWidth) ?? "◎"
}

function samePresentation(left: TranscriptStatusPresentation, right: TranscriptStatusPresentation): boolean {
  if (left.activity.type !== right.activity.type) return false
  if (left.activity.type === "working_with_lifecycle" && right.activity.type === "working_with_lifecycle") {
    if (left.activity.text !== right.activity.text) return false
  }
  if (left.background.type !== right.background.type) return false
  if (left.background.type === "running" && right.background.type === "running") {
    if (
      left.background.shellCommands !== right.background.shellCommands ||
      left.background.subagents !== right.background.subagents
    ) {
      return false
    }
  }
  if (left.unseenOutput !== right.unseenOutput || left.workPlan.type !== right.workPlan.type) return false
  if (left.workPlan.type === "present" && right.workPlan.type === "present") {
    return (
      left.workPlan.plan.revision === right.workPlan.plan.revision &&
      left.workPlan.completed === right.workPlan.completed &&
      left.workPlan.total === right.workPlan.total &&
      left.workPlan.currentIndex === right.workPlan.currentIndex &&
      left.workPlan.currentStatus === right.workPlan.currentStatus
    )
  }
  return true
}
