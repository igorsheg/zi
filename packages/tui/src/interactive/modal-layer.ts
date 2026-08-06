import { BoxRenderable, type CliRenderer, type KeyEvent, type Renderable } from "@opentui/core"
import type { AgentSessionEvent, SubagentSnapshot } from "@with-zi/coding-agent"

import type { Theme } from "../theme.js"
import type { InteractiveKeybindings } from "./interactive-keybindings.js"
import type { InteractiveStore } from "./interactive-store.js"
import { SubagentActivityModalView } from "./subagent-activity-modal.js"

export type ModalCloseReason = "escape" | "session_replaced" | "disposed"

type CursorRestore = { readonly target: CursorRenderable; readonly showCursor: boolean }

type ModalState =
  | { readonly type: "closed" }
  | {
      readonly type: "subagent_activity"
      readonly name: string
      readonly previousFocus: Renderable | undefined
      readonly cursorRestore: CursorRestore | undefined
    }

interface CursorRenderable extends Renderable {
  showCursor: boolean
}

export class ModalLayer {
  readonly root: BoxRenderable

  readonly #renderer: CliRenderer
  readonly #interactive: InteractiveStore
  readonly #keybindings: InteractiveKeybindings
  readonly #view: SubagentActivityModalView
  #state: ModalState = { type: "closed" }
  #releaseSubagentUpdates: (() => void) | undefined
  #live = false
  #disposed = false

  constructor(renderer: CliRenderer, interactive: InteractiveStore, keybindings: InteractiveKeybindings, theme: Theme) {
    this.#renderer = renderer
    this.#interactive = interactive
    this.#keybindings = keybindings
    this.root = new BoxRenderable(renderer, {
      id: "modal-layer",
      position: "absolute",
      top: 0,
      right: 0,
      bottom: 0,
      left: 0,
      width: "100%",
      height: "100%",
      zIndex: 1000,
      visible: false,
      alignItems: "stretch",
      justifyContent: "flex-end",
      paddingX: 0,
      paddingBottom: 0,
      shouldFill: false,
      backgroundColor: theme.surface.app
    })
    this.#view = new SubagentActivityModalView(renderer, theme)
    this.#view.setControls(modalControls(keybindings))
    this.root.add(this.#view.root)
    this.root.onLifecyclePass = this.#tick
    renderer.keyInput.on("keypress", this.#onKeyPress)
  }

  isOpen(): boolean {
    return this.#state.type !== "closed"
  }

  openSubagentActivity(name: string): boolean {
    if (this.#disposed) return false
    const session = this.#interactive.getSession()
    const snapshot = session.subagentSnapshot(name)
    if (!snapshot) return false

    const previousFocus =
      this.#state.type === "closed" ? (this.#renderer.currentFocusedRenderable ?? undefined) : this.#state.previousFocus
    const cursorRestore = this.#state.type === "closed" ? cursorRestoreFor(previousFocus) : this.#state.cursorRestore
    this.#releaseSubagentUpdates?.()
    this.#releaseSubagentUpdates = session.subscribe(event => this.#onSessionEvent(event))
    this.#state = { type: "subagent_activity", name, previousFocus, cursorRestore }
    this.#view.update(snapshot, session.subagentSessionEvents(name))
    this.#setLive(needsElapsedTick(snapshot))
    this.root.visible = true
    if (cursorRestore) cursorRestore.target.showCursor = false
    previousFocus?.blur()
    this.#view.root.focus()
    this.#renderer.requestRender()
    return true
  }

  close(_reason: ModalCloseReason = "escape"): void {
    const state = this.#state
    if (state.type === "closed") return
    this.#state = { type: "closed" }
    this.#setLive(false)
    this.#releaseSubagentUpdates?.()
    this.#releaseSubagentUpdates = undefined
    this.root.visible = false
    if (state.cursorRestore && !state.cursorRestore.target.isDestroyed) {
      state.cursorRestore.target.showCursor = state.cursorRestore.showCursor
    }
    if (state.previousFocus && !state.previousFocus.isDestroyed) state.previousFocus.focus()
    this.#renderer.requestRender()
  }

  dispose(): void {
    if (this.#disposed) return
    this.close("disposed")
    this.#disposed = true
    this.root.onLifecyclePass = null
    this.#renderer.keyInput.off("keypress", this.#onKeyPress)
    this.#view.destroy()
    this.root.destroyRecursively()
  }

  #onSessionEvent(event: AgentSessionEvent): void {
    const state = this.#state
    if (state.type !== "subagent_activity" || event.type !== "subagent_changed" || event.name !== state.name) return
    const session = this.#interactive.getSession()
    const snapshot = session.subagentSnapshot(state.name)
    if (!snapshot) return
    this.#view.update(snapshot, session.subagentSessionEvents(state.name), { preserveScroll: true })
    this.#setLive(needsElapsedTick(snapshot))
    this.#renderer.requestRender()
  }

  #tick = (): void => {
    const state = this.#state
    if (state.type !== "subagent_activity") return
    const session = this.#interactive.getSession()
    const snapshot = session.subagentSnapshot(state.name)
    if (!snapshot) return
    this.#view.update(snapshot, session.subagentSessionEvents(state.name), { preserveScroll: true })
    this.#setLive(needsElapsedTick(snapshot))
  }

  #setLive(live: boolean): void {
    if (this.#live === live) return
    this.#live = live
    if (live) this.#renderer.requestLive()
    else this.#renderer.dropLive()
  }

  #onKeyPress = (key: KeyEvent): void => {
    if (this.#state.type === "closed") return
    this.#consume(key)
    const action = this.#keybindings.modalAction(key)
    switch (action) {
      case "close":
        this.close("escape")
        return
      case "line_up":
        this.#view.scrollLines(-1)
        return
      case "line_down":
        this.#view.scrollLines(1)
        return
      case "page_up":
        this.#view.scrollPages(-1)
        return
      case "page_down":
        this.#view.scrollPages(1)
        return
      case "top":
        this.#view.jump("top")
        return
      case "bottom":
        this.#view.jump("bottom")
        return
      case undefined:
        return
      default:
        return assertNever(action)
    }
  }

  #consume(key: KeyEvent): void {
    key.preventDefault()
    key.stopPropagation()
  }
}

function modalControls(keybindings: InteractiveKeybindings): string {
  const close = keybindings.getHint("app.modal.close") ?? "Esc"
  const up = keybindings.getHint("app.modal.lineUp") ?? "↑"
  const down = keybindings.getHint("app.modal.lineDown") ?? "↓"
  const pageUp = keybindings.getHint("app.modal.pageUp") ?? "PgUp"
  const pageDown = keybindings.getHint("app.modal.pageDown") ?? "PgDn"
  const top = keybindings.getHint("app.modal.top") ?? "Home"
  const bottom = keybindings.getHint("app.modal.bottom") ?? "End"
  return ` ${close} close · ${up}/${down} scroll · ${pageUp}/${pageDown} page · ${top}/${bottom} jump `
}

function cursorRestoreFor(renderable: Renderable | undefined): CursorRestore | undefined {
  if (!hasCursorVisibility(renderable)) return undefined
  return { target: renderable, showCursor: renderable.showCursor }
}

function hasCursorVisibility(value: unknown): value is CursorRenderable {
  return typeof value === "object" && value !== null && "showCursor" in value && typeof value.showCursor === "boolean"
}

function needsElapsedTick(snapshot: SubagentSnapshot): boolean {
  if (snapshot.completion || snapshot.elapsedMs === undefined) return false
  switch (snapshot.lifecycle) {
    case "starting":
    case "spawn_admitting":
    case "running":
    case "interrupting":
    case "closing":
      return true
    case "idle":
    case "exited":
      return false
    default:
      return assertNever(snapshot.lifecycle)
  }
}

function assertNever(value: never): never {
  throw new Error(`Unexpected subagent lifecycle: ${String(value)}`)
}
