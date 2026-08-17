import { BoxRenderable, CliRenderEvents, ScrollBoxRenderable, TextRenderable, type CliRenderer } from "@opentui/core"
import type { AgentSession, WorkPlanSnapshot, WorkPlanStepStatus } from "@with-zi/coding-agent"

import { textWidth, wrapWordsToCells } from "../components/cell-text.js"
import type { Theme } from "../theme.js"
import type { InteractiveKeybindings, TranscriptKeyAction } from "./interactive-keybindings.js"

const chromeRows = 2
const maxShelfFraction = 1 / 3
const minimumShelfRows = 3

type WorkPlanSource = Pick<AgentSession, "workPlan" | "subscribe">

export class WorkPlanView {
  readonly root: BoxRenderable

  readonly #renderer: CliRenderer
  readonly #session: WorkPlanSource
  readonly #keybindings: InteractiveKeybindings
  readonly #theme: Theme
  readonly #onUnavailable: () => void
  readonly #header: TextRenderable
  readonly #footer: TextRenderable
  readonly #scroll: ScrollBoxRenderable
  #release = () => {}
  #revision = -1
  #maximumHeight: number
  #currentOffset = 0
  #currentHeight = 1
  #revealOperation = 0
  #cancelRevealFrame = () => {}
  #expanded = false
  #presentationSuspended = false
  #presentationDirty = false
  #disposed = false

  constructor(
    renderer: CliRenderer,
    session: WorkPlanSource,
    keybindings: InteractiveKeybindings,
    theme: Theme,
    onUnavailable: () => void
  ) {
    this.#renderer = renderer
    this.#session = session
    this.#keybindings = keybindings
    this.#theme = theme
    this.#onUnavailable = onUnavailable
    this.#maximumHeight = renderer.height
    this.root = new BoxRenderable(renderer, {
      id: "work-plan-shelf",
      flexDirection: "column",
      flexShrink: 0,
      minWidth: 0,
      minHeight: 0,
      overflow: "hidden",
      visible: false
    })
    this.#header = new TextRenderable(renderer, {
      height: 1,
      wrapMode: "none",
      selectable: false,
      flexShrink: 0,
      minWidth: 0,
      truncate: true,
      fg: theme.text.accent,
      content: ""
    })
    this.#scroll = new ScrollBoxRenderable(renderer, {
      id: "work-plan-scroll",
      flexGrow: 1,
      minWidth: 0,
      minHeight: 0,
      stickyScroll: false,
      overflow: "hidden"
    })
    this.#footer = new TextRenderable(renderer, {
      height: 1,
      wrapMode: "none",
      selectable: false,
      flexShrink: 0,
      minWidth: 0,
      truncate: true,
      fg: theme.text.muted,
      content: ""
    })
    this.root.add(this.#header)
    this.root.add(this.#scroll)
    this.root.add(this.#footer)
  }

  get expanded(): boolean {
    return this.#expanded
  }

  open(): boolean {
    if (this.#disposed || this.#expanded || !workPlanIsActive(this.#session.workPlan)) return false
    this.#expanded = true
    this.root.visible = true
    this.#release = this.#session.subscribe(event => {
      if (event.type === "work_plan_changed") this.#requestSync()
    })
    this.#sync(true)
    return true
  }

  close(): void {
    if (!this.#expanded) return
    this.#expanded = false
    this.#cancelReveal()
    this.#release()
    this.#release = () => {}
    this.root.visible = false
    this.#renderer.requestRender()
  }

  toggle(): boolean {
    if (this.#expanded) {
      this.close()
      return true
    }
    return this.open()
  }

  resize(maximumHeight = this.#renderer.height): void {
    this.#maximumHeight = Math.max(0, Math.floor(maximumHeight))
    if (!this.#expanded) return
    this.#renderPlan(this.#session.workPlan)
    this.#renderer.requestRender()
  }

  handleAction(action: TranscriptKeyAction): boolean {
    if (!this.#expanded) return false
    switch (action) {
      case "page_up":
        this.#scroll.scrollBy(-0.5, "viewport")
        return true
      case "page_down":
        this.#scroll.scrollBy(0.5, "viewport")
        return true
      case "line_up":
        this.#scroll.scrollBy(-1, "absolute")
        return true
      case "line_down":
        this.#scroll.scrollBy(1, "absolute")
        return true
      case "tail":
        this.#scroll.scrollTo(this.#scroll.scrollHeight)
        return true
      case "toggle_tools":
        return false
      default:
        return assertNever(action)
    }
  }

  suspendPresentation(): void {
    this.#presentationSuspended = true
  }

  resumePresentation(): void {
    if (!this.#presentationSuspended) return
    this.#presentationSuspended = false
    if (!this.#presentationDirty) return
    this.#presentationDirty = false
    this.#sync()
  }

  destroy(): void {
    if (this.#disposed) return
    this.#disposed = true
    this.#cancelReveal()
    this.#release()
    this.root.destroyRecursively()
  }

  #requestSync(): void {
    if (this.#presentationSuspended) {
      this.#presentationDirty = true
      return
    }
    this.#sync()
  }

  #sync(force = false): void {
    if (this.#disposed) return
    const plan = this.#session.workPlan
    if (!workPlanIsActive(plan)) {
      const wasExpanded = this.#expanded
      this.close()
      if (wasExpanded) this.#onUnavailable()
      return
    }
    if (!force && plan.revision === this.#revision) return
    this.#revision = plan.revision
    this.#renderPlan(plan)
    this.#renderer.requestRender()
  }

  #renderPlan(plan: WorkPlanSnapshot): void {
    clear(this.#scroll)
    const contentWidth = Math.max(1, this.#renderer.width)
    const currentIndex = findCurrentStep(plan)
    const completed = plan.steps.filter(step => step.status === "completed").length
    const current = currentIndex >= 0 ? plan.steps[currentIndex] : undefined
    this.#header.content = `Plan ${completed}/${plan.steps.length}${current ? ` — ${singleLine(current.text)}` : ""}`
    this.#footer.content = footerText(this.#renderer.width, this.#keybindings)

    let contentRows = 0
    this.#currentOffset = 0
    this.#currentHeight = 1
    for (const [index, step] of plan.steps.entries()) {
      const prefix = `${statusGlyph(step.status)} `
      const lines = wrapWordsToCells(singleLine(step.text), Math.max(1, contentWidth - textWidth(prefix)))
      const height = lines.length
      if (index === currentIndex) {
        this.#currentOffset = contentRows
        this.#currentHeight = height
      }
      const content = lines.map((line, lineIndex) => `${lineIndex === 0 ? prefix : "  "}${line}`).join("\n")
      this.#scroll.add(
        new TextRenderable(this.#renderer, {
          height,
          wrapMode: "none",
          selectable: false,
          flexShrink: 0,
          minWidth: 0,
          fg: statusColor(step.status, this.#theme),
          content
        })
      )
      contentRows += height
    }

    const preferredRows = Math.max(minimumShelfRows, Math.floor(this.#renderer.height * maxShelfFraction))
    const maxRows = Math.min(this.#maximumHeight, preferredRows)
    this.root.height = Math.min(maxRows, Math.max(minimumShelfRows, contentRows + chromeRows))
    const viewportRows = Math.max(1, this.root.height - chromeRows)
    const revealOffset =
      this.#currentHeight >= viewportRows
        ? this.#currentOffset
        : this.#currentOffset - Math.floor((viewportRows - this.#currentHeight) / 2)
    this.#queueCurrentReveal(Math.max(0, revealOffset))
  }

  #queueCurrentReveal(offset: number): void {
    this.#cancelReveal()
    const operation = ++this.#revealOperation
    const reveal = () => {
      this.#cancelRevealFrame = () => {}
      queueMicrotask(() => {
        if (this.#disposed || !this.#expanded || operation !== this.#revealOperation) return
        this.#scroll.scrollTo(offset)
        this.#renderer.requestRender()
      })
    }
    this.#renderer.once(CliRenderEvents.FRAME, reveal)
    this.#cancelRevealFrame = () => this.#renderer.off(CliRenderEvents.FRAME, reveal)
  }

  #cancelReveal(): void {
    this.#revealOperation++
    this.#cancelRevealFrame()
    this.#cancelRevealFrame = () => {}
  }
}

export function workPlanIsActive(plan: WorkPlanSnapshot): boolean {
  return plan.steps.some(step => step.status === "pending" || step.status === "in_progress")
}

function findCurrentStep(plan: WorkPlanSnapshot): number {
  const inProgress = plan.steps.findIndex(step => step.status === "in_progress")
  return inProgress >= 0 ? inProgress : plan.steps.findIndex(step => step.status === "pending")
}

function statusGlyph(status: WorkPlanStepStatus): string {
  switch (status) {
    case "completed":
      return "✓"
    case "in_progress":
      return "◉"
    case "pending":
      return "○"
    case "cancelled":
      return "–"
    default:
      return assertNever(status)
  }
}

function statusColor(status: WorkPlanStepStatus, theme: Theme): Theme["text"]["primary"] {
  switch (status) {
    case "in_progress":
      return theme.text.accent
    case "pending":
      return theme.text.primary
    case "completed":
    case "cancelled":
      return theme.text.muted
    default:
      return assertNever(status)
  }
}

function footerText(width: number, keybindings: InteractiveKeybindings): string {
  const close = keybindings.getHint("app.plan.close") ?? keybindings.getHint("app.plan.toggle")
  const pageUp = keybindings.getHint("app.transcript.pageUp")
  const pageDown = keybindings.getHint("app.transcript.pageDown")
  const tail = keybindings.getHint("app.transcript.tail")
  const hints = [
    close ? `${close} return` : "",
    pageUp && pageDown ? `${pageUp}/${pageDown} scroll` : pageUp || pageDown ? `${pageUp ?? pageDown} scroll` : "",
    tail ? `${tail} tail` : ""
  ].filter(Boolean)
  const full = hints.join(" · ")
  if (textWidth(full) <= width) return full
  return hints.slice(0, 2).join(" · ")
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
  throw new Error(`Unexpected work-plan value: ${String(value)}`)
}
