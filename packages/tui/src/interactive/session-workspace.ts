import { BoxRenderable, CliRenderEvents, type CliRenderer, type KeyEvent, type SyntaxStyle } from "@opentui/core"
import type { AgentSession } from "@with-zi/coding-agent"

import type { Theme } from "../theme.js"
import type { InteractiveKeybindings, TranscriptKeyAction, WorkspaceKeyAction } from "./interactive-keybindings.js"
import type { InteractiveStore } from "./interactive-store.js"
import type { SessionScreen } from "./screen.js"
import { WorkPlanPane, workPlanIsActive } from "./work-plan-pane.js"
import { WorkspaceLayoutView } from "./workspace/layout-view.js"
import {
  activateWorkspacePane,
  closeWorkspacePane,
  createWorkspaceLayout,
  focusWorkspacePane,
  splitWorkspacePane,
  workspaceMinimumSize,
  workspacePaneIds,
  type WorkspaceFocusDirection,
  type WorkspaceLayoutState,
  type WorkspaceMinimumSize,
  type WorkspacePaneId,
  type WorkspacePaneRect
} from "./workspace/layout.js"

const primaryPaneId = "primary"
const workPlanPaneId = "work-plan"
const primarySecondarySplitId = "primary-secondary"
const secondaryStackSplitId = "secondary-stack"
const goldenPrimaryRatio = 0.618
const primaryMinimum: WorkspaceMinimumSize = { width: 52, height: 12 }
const secondaryMinimum: WorkspaceMinimumSize = { width: 32, height: 8 }

type PrimaryPane = { readonly type: "primary"; readonly frame: BoxRenderable; readonly minimum: WorkspaceMinimumSize }

type PlanPane = {
  readonly type: "work_plan"
  readonly frame: BoxRenderable
  readonly minimum: WorkspaceMinimumSize
  readonly view: WorkPlanPane
}

type WorkspacePane = PrimaryPane | PlanPane
type SecondaryPane = Exclude<WorkspacePane, PrimaryPane>
type WorkspaceCommandState = { readonly type: "idle" } | { readonly type: "awaiting_command" }

export class SessionWorkspace {
  readonly root: BoxRenderable

  readonly #renderer: CliRenderer
  readonly #interactive: InteractiveStore
  readonly #keybindings: InteractiveKeybindings
  readonly #screen: SessionScreen
  readonly #primaryFrame: BoxRenderable
  readonly #theme: Theme
  readonly #layoutView: WorkspaceLayoutView
  readonly #panes = new Map<WorkspacePaneId, WorkspacePane>()
  #layout: WorkspaceLayoutState = createWorkspaceLayout(primaryPaneId)
  #commandState: WorkspaceCommandState = { type: "idle" }
  #compact = false
  #presentationSuspended = false
  #disposed = false

  constructor(
    renderer: CliRenderer,
    interactive: InteractiveStore,
    keybindings: InteractiveKeybindings,
    screen: SessionScreen,
    theme: Theme,
    _syntaxStyle: SyntaxStyle
  ) {
    this.#renderer = renderer
    this.#interactive = interactive
    this.#keybindings = keybindings
    this.#screen = screen
    this.#primaryFrame = new BoxRenderable(renderer, {
      id: "main-agent-pane",
      flexDirection: "column",
      flexGrow: 1,
      minWidth: 0,
      minHeight: 0,
      overflow: "hidden",
      border: false,
      borderStyle: "rounded",
      borderColor: theme.border.default,
      titleColor: theme.text.muted
    })
    this.#primaryFrame.border = false
    this.#primaryFrame.add(screen.root)
    this.#panes.set(primaryPaneId, { type: "primary", frame: this.#primaryFrame, minimum: primaryMinimum })
    this.#theme = theme
    this.#layoutView = new WorkspaceLayoutView(renderer, paneId => this.#pane(paneId).frame)
    this.root = this.#layoutView.root
    this.#layoutView.render(this.#layout.root)
    renderer.keyInput.on("keypress", this.#onKeyPress)
    renderer.on(CliRenderEvents.RESIZE, this.#onResize)
  }

  get primaryActive(): boolean {
    return this.#layout.activePaneId === primaryPaneId
  }

  preserveFocus(): void {
    if (!this.#presentationSuspended && this.#layout.activePaneId === primaryPaneId) this.#screen.prompt.focus()
  }

  suspendPresentation(): void {
    if (this.#presentationSuspended) return
    this.#presentationSuspended = true
    this.#commandState = { type: "idle" }
    this.#screen.suspendPresentation()
    for (const pane of this.#panes.values()) {
      if (pane.type === "work_plan") pane.view.suspendPresentation()
    }
    this.root.visible = false
  }

  resumePresentation(): void {
    if (!this.#presentationSuspended) return
    this.root.visible = true
    this.#presentationSuspended = false
    this.#screen.resumePresentation()
    for (const pane of this.#panes.values()) {
      if (pane.type === "work_plan") pane.view.resumePresentation()
    }
    this.#syncPresentation(true)
  }

  destroy(): void {
    if (this.#disposed) return
    this.#disposed = true
    this.#renderer.keyInput.off("keypress", this.#onKeyPress)
    this.#renderer.off(CliRenderEvents.RESIZE, this.#onResize)
    for (const paneId of this.#panes.keys()) {
      if (paneId === primaryPaneId) continue
      const pane = this.#panes.get(paneId)
      if (pane && pane.type !== "primary") this.#releasePane(paneId, pane)
    }
    this.#layoutView.destroy()
    if (this.#screen.root.parent === this.#primaryFrame) this.#primaryFrame.remove(this.#screen.root)
    this.#primaryFrame.destroyRecursively()
    this.#panes.clear()
  }

  #toggleWorkPlan(): boolean {
    const current = this.#panes.get(workPlanPaneId)
    if (current?.type === "work_plan") {
      this.#closePane(workPlanPaneId)
      return true
    }

    const session = this.#interactive.getSession()
    if (!workPlanIsActive(session.workPlan)) return false
    const pane = this.#createWorkPlanPane(session)
    if (!pane) return false
    this.#panes.set(workPlanPaneId, pane)
    if (!this.#insertSecondary(workPlanPaneId)) {
      this.#releasePane(workPlanPaneId, pane)
      return false
    }
    this.#syncPresentation(true)
    return true
  }

  #createWorkPlanPane(session: AgentSession): PlanPane | undefined {
    let view: WorkPlanPane | undefined
    let frame: BoxRenderable | undefined
    try {
      view = new WorkPlanPane(this.#renderer, session, this.#theme, () => {
        const pane = this.#panes.get(workPlanPaneId)
        if (view && pane?.type === "work_plan" && pane.view === view) this.#closePane(workPlanPaneId)
      })
      frame = this.#secondaryFrame("work-plan-pane", " Work plan ")
      frame.add(view.root)
      return { type: "work_plan", frame, minimum: secondaryMinimum, view }
    } catch {
      view?.destroy()
      if (frame && !frame.isDestroyed) frame.destroyRecursively()
      return undefined
    }
  }

  #secondaryFrame(id: string, title: string): BoxRenderable {
    return new BoxRenderable(this.#renderer, {
      id,
      flexDirection: "column",
      flexGrow: 1,
      minWidth: 0,
      minHeight: 0,
      overflow: "hidden",
      border: true,
      borderStyle: "rounded",
      borderColor: this.#theme.border.default,
      focusedBorderColor: this.#theme.text.accent,
      title,
      titleColor: this.#theme.text.muted,
      focusable: true
    })
  }

  #insertSecondary(paneId: typeof workPlanPaneId): boolean {
    const existing = [...this.#panes.keys()].filter(candidate => candidate !== primaryPaneId && candidate !== paneId)
    if (existing.length === 0) {
      const split = splitWorkspacePane(this.#layout, {
        targetPaneId: primaryPaneId,
        paneId,
        splitId: primarySecondarySplitId,
        axis: "horizontal",
        side: "second",
        ratio: goldenPrimaryRatio
      })
      if (!split) return false
      this.#layout = split
      return true
    }
    if (existing.length !== 1) return false

    const targetPaneId = existing[0]!
    const split = splitWorkspacePane(this.#layout, {
      targetPaneId,
      paneId,
      splitId: secondaryStackSplitId,
      axis: "vertical",
      side: "second",
      ratio: goldenPrimaryRatio
    })
    if (!split) return false
    this.#layout = split
    return true
  }

  #closePane(paneId: WorkspacePaneId): void {
    const pane = this.#panes.get(paneId)
    if (!pane || pane.type === "primary") return
    const closed = closeWorkspacePane(this.#layout, paneId)
    if (!closed) return
    this.#layout = closed
    this.#releasePane(paneId, pane)
    this.#syncPresentation(true)
  }

  #releasePane(paneId: WorkspacePaneId, pane: SecondaryPane): void {
    this.#renderer.clearSelection()
    if (pane.frame.parent) pane.frame.parent.remove(pane.frame)
    pane.view.destroy()
    if (!pane.frame.isDestroyed) pane.frame.destroyRecursively()
    this.#panes.delete(paneId)
    this.#commandState = { type: "idle" }
  }

  #pane(paneId: WorkspacePaneId): WorkspacePane {
    const pane = this.#panes.get(paneId)
    if (!pane) throw new Error(`Workspace pane ${paneId} is unavailable`)
    return pane
  }

  #activate(paneId: WorkspacePaneId): void {
    const next = activateWorkspacePane(this.#layout, paneId)
    if (!next) return
    this.#layout = next
    this.#syncPresentation(true)
  }

  #focus(direction: WorkspaceFocusDirection): void {
    if (this.#compact) {
      const panes = workspacePaneIds(this.#layout.root)
      const current = panes.indexOf(this.#layout.activePaneId)
      const delta = direction === "left" || direction === "up" ? -1 : 1
      const paneId = panes[current + delta]
      if (paneId) this.#activate(paneId)
      return
    }
    const rects = new Map<WorkspacePaneId, WorkspacePaneRect>()
    for (const [paneId, pane] of this.#panes) rects.set(paneId, renderableRect(pane.frame))
    const next = focusWorkspacePane(this.#layout, direction, rects)
    if (!next) return
    this.#layout = next
    this.#syncPresentation(true)
  }

  #syncPresentation(force = false): void {
    if (this.#presentationSuspended) return
    const minimums = new Map<WorkspacePaneId, WorkspaceMinimumSize>()
    for (const [paneId, pane] of this.#panes) minimums.set(paneId, pane.minimum)
    const minimum = workspaceMinimumSize(this.#layout.root, minimums)
    const width = this.#renderer.width
    const height = this.#renderer.height
    const compact = this.#panes.size > 1 && (width < minimum.width || height < minimum.height)
    if (!force && compact === this.#compact) return
    if (compact !== this.#compact) this.#renderer.clearSelection()
    this.#compact = compact
    this.#layoutView.render(this.#layout.root, compact ? this.#layout.activePaneId : undefined)

    const activePaneId = this.#layout.activePaneId
    const primaryActive = activePaneId === primaryPaneId
    const framed = this.#panes.size > 1
    this.#primaryFrame.border = framed
    this.#primaryFrame.title = framed ? " Main agent " : undefined
    for (const [paneId, pane] of this.#panes) {
      if (framed)
        pane.frame.borderColor = paneId === activePaneId ? this.#theme.border.active : this.#theme.border.default
    }

    this.#screen.prompt.setInputActive(primaryActive)
    if (primaryActive) this.#screen.prompt.focus()
    else this.#pane(activePaneId).frame.focus()
  }

  #onResize = (): void => {
    this.#syncPresentation()
  }

  #onKeyPress = (key: KeyEvent): void => {
    if (this.#disposed || this.#presentationSuspended || key.defaultPrevented || key.propagationStopped) return
    const secondaryActive = this.#layout.activePaneId !== primaryPaneId

    if (this.#keybindings.togglesWorkPlan(key) && this.#toggleWorkPlan()) {
      consume(key)
      return
    }

    if (
      this.#panes.size > 1 &&
      this.#commandState.type === "idle" &&
      this.#keybindings.matches(key, "app.workspace.prefix")
    ) {
      this.#commandState = { type: "awaiting_command" }
      consume(key)
      return
    }

    if (this.#commandState.type === "awaiting_command") {
      this.#commandState = { type: "idle" }
      const action = this.#keybindings.workspaceChordAction(key)
      if (action) this.#handleWorkspaceAction(action)
      consume(key)
      return
    }

    const workspaceAction = this.#keybindings.workspaceContextAction(key, secondaryActive)
    if (workspaceAction) {
      this.#handleWorkspaceAction(workspaceAction)
      consume(key)
      return
    }

    const transcriptAction = this.#keybindings.transcriptAction(key)
    if (transcriptAction && this.#handlePaneAction(transcriptAction)) {
      consume(key)
      return
    }
    if (!secondaryActive) this.#screen.prompt.handleKeyPress(key)
  }

  #handlePaneAction(action: TranscriptKeyAction): boolean {
    const pane = this.#pane(this.#layout.activePaneId)
    switch (pane.type) {
      case "primary":
        return this.#screen.transcript.handleAction(action)
      case "work_plan":
        return pane.view.handleAction(action)
      default:
        return assertNever(pane)
    }
  }

  #handleWorkspaceAction(action: WorkspaceKeyAction): void {
    switch (action) {
      case "primary":
        this.#activate(primaryPaneId)
        return
      case "close":
        this.#closePane(this.#layout.activePaneId)
        return
      case "focus_left":
        this.#focus("left")
        return
      case "focus_down":
        this.#focus("down")
        return
      case "focus_up":
        this.#focus("up")
        return
      case "focus_right":
        this.#focus("right")
        return
      default:
        return assertNever(action)
    }
  }
}

function renderableRect(renderable: BoxRenderable): WorkspacePaneRect {
  return { x: renderable.screenX, y: renderable.screenY, width: renderable.width, height: renderable.height }
}

function consume(key: KeyEvent): void {
  key.preventDefault()
  key.stopPropagation()
}

function assertNever(value: never): never {
  throw new Error(`Unexpected workspace value: ${String(value)}`)
}
