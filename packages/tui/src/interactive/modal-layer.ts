import { BoxRenderable, CliRenderEvents, RGBA, type CliRenderer, type KeyEvent, type Renderable } from "@opentui/core"
import type { AgentSessionEvent, SubagentSnapshot } from "@with-zi/coding-agent"

import type { Theme } from "../theme.js"
import type { InteractiveKeybindings } from "./interactive-keybindings.js"
import type { InteractiveStore } from "./interactive-store.js"
import { SubagentActivityModalView } from "./subagent-activity-modal.js"

export type ModalCloseReason = "escape" | "session_replaced" | "subagent_unavailable" | "disposed"

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
    // The layer is the backdrop: a translucent fill dims the session behind the
    // dialog without touching it, because a background alpha blends only the
    // fill this box draws while opaque children paint over it.
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
      shouldFill: true,
      backgroundColor: scrimColor(theme.surface.app)
    })
    this.#view = new SubagentActivityModalView(renderer, keybindings, theme)
    this.root.add(this.#view.root)
    this.root.onLifecyclePass = this.#tick
    renderer.keyInput.on("keypress", this.#onKeyPress)
    renderer.on(CliRenderEvents.RESIZE, this.#onResize)
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
    this.#view.update(snapshot, session.subagentSessionEvents(name), session.sessionManager.header.cwd)
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
    this.#renderer.off(CliRenderEvents.RESIZE, this.#onResize)
    this.#view.destroy()
    this.root.destroyRecursively()
  }

  #onSessionEvent(event: AgentSessionEvent): void {
    const state = this.#state
    if (state.type !== "subagent_activity" || event.type !== "subagent_changed") return
    if (event.name === state.name) {
      if (this.#refresh()) this.#renderer.requestRender()
      return
    }
    if (!this.#interactive.getSession().subagentSnapshot(state.name)) this.close("subagent_unavailable")
  }

  #refresh(): boolean {
    const state = this.#state
    if (state.type !== "subagent_activity") return false
    const session = this.#interactive.getSession()
    const snapshot = session.subagentSnapshot(state.name)
    if (!snapshot) {
      this.close("subagent_unavailable")
      return false
    }
    this.#view.update(snapshot, session.subagentSessionEvents(state.name), session.sessionManager.header.cwd)
    this.#setLive(needsElapsedTick(snapshot))
    return true
  }

  /** Live frames advance the elapsed clock only; activity arrives as events. */
  #tick = (): void => {
    const state = this.#state
    if (state.type !== "subagent_activity") return
    const snapshot = this.#interactive.getSession().subagentSnapshot(state.name)
    if (!snapshot) return
    this.#view.tick(snapshot)
    this.#setLive(needsElapsedTick(snapshot))
  }

  /** A resized terminal changes the dialog's row budget, so the body reprojects. */
  #onResize = (): void => {
    this.#refresh()
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
    if (this.#keybindings.closesModal(key)) this.close("escape")
  }

  #consume(key: KeyEvent): void {
    key.preventDefault()
    key.stopPropagation()
  }
}

/** Dim enough that the session behind reads as suspended, not as content. */
export function scrimColor(surface: string): RGBA {
  const base = RGBA.fromHex(surface)
  return RGBA.fromValues(base.r, base.g, base.b, 0.6)
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
