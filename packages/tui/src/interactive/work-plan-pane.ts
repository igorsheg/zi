import { ScrollBoxRenderable, TextRenderable, type CliRenderer } from "@opentui/core"
import type { AgentSession, WorkPlanSnapshot, WorkPlanStep } from "@with-zi/coding-agent"

import type { Theme } from "../theme.js"
import type { TranscriptKeyAction } from "./interactive-keybindings.js"

type WorkPlanSource = Pick<AgentSession, "workPlan" | "subscribe">

export class WorkPlanPane {
  readonly root: ScrollBoxRenderable

  readonly #renderer: CliRenderer
  readonly #session: WorkPlanSource
  readonly #theme: Theme
  readonly #onUnavailable: () => void
  #release = () => {}
  #revision = -1
  #disposed = false

  constructor(renderer: CliRenderer, session: WorkPlanSource, theme: Theme, onUnavailable: () => void) {
    this.#renderer = renderer
    this.#session = session
    this.#theme = theme
    this.#onUnavailable = onUnavailable
    this.root = new ScrollBoxRenderable(renderer, {
      id: "work-plan-scroll",
      flexGrow: 1,
      minWidth: 0,
      minHeight: 0,
      stickyScroll: false,
      overflow: "hidden"
    })
    try {
      this.#release = session.subscribe(event => {
        if (event.type === "work_plan_changed") this.#sync()
      })
      this.#sync()
    } catch (cause) {
      this.#release()
      this.root.destroyRecursively()
      throw cause
    }
  }

  handleAction(action: TranscriptKeyAction): boolean {
    switch (action) {
      case "page_up":
        this.root.scrollBy(-0.5, "viewport")
        return true
      case "page_down":
        this.root.scrollBy(0.5, "viewport")
        return true
      case "line_up":
        this.root.scrollBy(-1, "absolute")
        return true
      case "line_down":
        this.root.scrollBy(1, "absolute")
        return true
      case "tail":
        this.root.scrollTo(this.root.scrollHeight)
        return true
      case "toggle_tools":
        return false
      default:
        return assertNever(action)
    }
  }

  destroy(): void {
    if (this.#disposed) return
    this.#disposed = true
    this.#release()
    this.root.destroyRecursively()
  }

  #sync(): void {
    if (this.#disposed) return
    const plan = this.#session.workPlan
    if (!workPlanIsActive(plan)) {
      this.#onUnavailable()
      return
    }
    if (plan.revision === this.#revision) return
    this.#revision = plan.revision
    clear(this.root)
    for (const step of plan.steps) this.root.add(this.#stepRow(step))
    this.#renderer.requestRender()
  }

  #stepRow(step: WorkPlanStep): TextRenderable {
    const glyph =
      step.status === "completed" ? "✓" : step.status === "in_progress" ? "◉" : step.status === "pending" ? "○" : "–"
    const color =
      step.status === "in_progress"
        ? this.#theme.text.accent
        : step.status === "pending"
          ? this.#theme.text.primary
          : this.#theme.text.dim
    return new TextRenderable(this.#renderer, {
      height: 1,
      wrapMode: "none",
      truncate: true,
      selectable: false,
      flexShrink: 0,
      minWidth: 0,
      fg: color,
      content: `${glyph} ${singleLine(step.text)}`
    })
  }
}

export function workPlanIsActive(plan: WorkPlanSnapshot): boolean {
  return plan.steps.some(step => step.status === "pending" || step.status === "in_progress")
}

function singleLine(content: string): string {
  return content.replace(/[\r\n]+/g, " ")
}

function clear(root: ScrollBoxRenderable): void {
  for (const child of root.getChildren()) {
    root.remove(child)
    child.destroyRecursively()
  }
}

function assertNever(value: never): never {
  throw new Error(`Unexpected work-plan action: ${String(value)}`)
}
