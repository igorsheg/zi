import {
  BoxRenderable,
  CliRenderEvents,
  type CliRenderer,
  type KeyEvent,
  type Renderable,
  ScrollBoxRenderable,
  type SyntaxStyle,
  TextRenderable
} from "@opentui/core"
import type { AgentMessage } from "@openzi/coding-agent"
import type { ReadableAtom } from "nanostores"

import type { Theme } from "../../theme.js"
import type { InteractiveKeybindings, TranscriptKeyAction } from "../interactive-keybindings.js"
import type { ActiveTool } from "../interactive-store.js"
import { createMessageView, StreamingAssistantView, type ToolCallPresentation } from "./message-view.js"
import { createTranscriptStore, type TranscriptStore } from "./navigation.js"
import { createActiveToolView, type ActiveToolView } from "./tool-view.js"

interface TranscriptSession {
  readonly messages: readonly AgentMessage[]
  readonly streamingMessage: AgentMessage | undefined
}

interface TranscriptSource {
  readonly $transcriptRevision: ReadableAtom<number>
  readonly $activeTools: ReadableAtom<ReadonlyMap<string, ActiveTool>>
  getSession(): TranscriptSession
}

interface PendingNativeRead {
  readonly target: ScrollBoxRenderable
  manualGeneration?: number
  resize: boolean
}

interface CommittedMessageView {
  readonly messageIndex: number
  readonly root: Renderable
}

type StreamingMessageView =
  | { readonly type: "assistant"; readonly view: StreamingAssistantView }
  | { readonly type: "static"; readonly role: AgentMessage["role"]; readonly root: Renderable | undefined }

type Mutable<T> = { -readonly [Key in keyof T]: T[Key] }

export interface TranscriptDiagnostics {
  readonly syncRequests: number
  readonly syncPasses: number
  readonly coalescedRequests: number
  readonly lastSyncMs: number
  readonly maxSyncMs: number
  readonly projectedMessages: number
  readonly omittedMessages: number
  readonly streamingCreates: number
  readonly streamingUpdates: number
  readonly activeToolCreates: number
  readonly activeToolUpdates: number
  readonly activeToolDestroys: number
}

export interface TranscriptViewOptions {
  readonly measureSync?: boolean
}

const maxProjectedMessages = 200
const maxPendingToolCalls = 64

export class TranscriptView {
  readonly root: BoxRenderable
  readonly scroll: ScrollBoxRenderable

  readonly #renderer: CliRenderer
  readonly #interactive: TranscriptSource
  readonly #keybindings: InteractiveKeybindings
  readonly #theme: Theme
  readonly #syntaxStyle: SyntaxStyle
  readonly #navigation: TranscriptStore
  readonly #status: BoxRenderable
  readonly #measureSync: boolean
  readonly #requestFrame: typeof requestAnimationFrame
  readonly #cancelFrame: typeof cancelAnimationFrame
  readonly #release: Array<() => void> = []
  readonly #committed: CommittedMessageView[] = []
  readonly #pendingToolCalls = new Map<string, ToolCallPresentation>()
  readonly #activeToolViews = new Map<string, ActiveToolView>()
  readonly #diagnostics: Mutable<TranscriptDiagnostics> = {
    syncRequests: 0,
    syncPasses: 0,
    coalescedRequests: 0,
    lastSyncMs: 0,
    maxSyncMs: 0,
    projectedMessages: 0,
    omittedMessages: 0,
    streamingCreates: 0,
    streamingUpdates: 0,
    activeToolCreates: 0,
    activeToolUpdates: 0,
    activeToolDestroys: 0
  }
  #session: TranscriptSession
  #hasProjection = false
  #nextMessageIndex = 0
  #omittedMessageCount = 0
  #omittedMarker: TextRenderable | undefined
  #streaming: StreamingMessageView | undefined
  #activeToolOrder: string[] = []
  #dirty = false
  #scheduledAnchorFrame: number | undefined
  #operationGeneration = 0
  #pendingNativeRead: PendingNativeRead | undefined
  #transcriptRevision: number
  #destroyed = false

  constructor(
    renderer: CliRenderer,
    interactive: TranscriptSource,
    keybindings: InteractiveKeybindings,
    theme: Theme,
    syntaxStyle: SyntaxStyle,
    options: TranscriptViewOptions = {}
  ) {
    this.#renderer = renderer
    this.#interactive = interactive
    this.#keybindings = keybindings
    this.#theme = theme
    this.#syntaxStyle = syntaxStyle
    this.#measureSync = options.measureSync ?? false
    this.#requestFrame = globalThis.requestAnimationFrame.bind(globalThis)
    this.#cancelFrame = globalThis.cancelAnimationFrame.bind(globalThis)
    this.#session = interactive.getSession()
    this.#transcriptRevision = interactive.$transcriptRevision.get()
    this.#navigation = createTranscriptStore()

    this.root = new BoxRenderable(renderer, {
      id: "transcript-region",
      position: "relative",
      flexGrow: 1,
      minHeight: 1
    })
    this.root.onLifecyclePass = this.#syncFrame
    this.scroll = new ScrollBoxRenderable(renderer, {
      id: "transcript-scroll",
      flexGrow: 1,
      minHeight: 1,
      focusable: false,
      stickyScroll: true,
      stickyStart: "bottom",
      viewportCulling: true,
      scrollbarOptions: { visible: false }
    })
    this.scroll.verticalScrollBar.visible = false
    this.scroll.horizontalScrollBar.visible = false
    this.#status = new BoxRenderable(renderer, {
      id: "transcript-status",
      position: "absolute",
      left: 0,
      right: 0,
      bottom: 0,
      zIndex: 1,
      height: 1,
      visible: false,
      paddingLeft: 1,
      backgroundColor: theme.surface.app
    })
    this.#status.add(
      new TextRenderable(renderer, {
        selectable: false,
        fg: theme.text.accent,
        bg: theme.surface.app,
        wrapMode: "none",
        content: transcriptHint(keybindings)
      })
    )
    this.root.add(this.scroll)
    this.root.add(this.#status)

    this.scroll.onMouseScroll = () => this.#queueNativeRead("manual")
    this.scroll.onMouseDown = () => {
      if (renderer.getSelection()?.isDragging) this.#detachForSelection()
    }
    this.scroll.onMouseDrag = () => this.#detachForSelection()
    this.scroll.onSizeChange = () => {
      if (this.#navigation.$navigation.get().type === "detached") this.#queueNativeRead("resize")
    }
    this.root.onSizeChange = this.#syncStatus
    this.#status.onMouseScroll = event => {
      if (!this.scroll.isDestroyed) this.scroll.processMouseEvent(event)
    }

    this.#release.push(interactive.$transcriptRevision.subscribe(this.#requestSync))
    this.#release.push(this.#navigation.$navigation.subscribe(this.#syncNavigation))
    renderer.keyInput.on("keypress", this.#onKeyPress)
    renderer.on(CliRenderEvents.SELECTION, this.#onSelection)
    this.#release.push(() => renderer.keyInput.off("keypress", this.#onKeyPress))
    this.#release.push(() => renderer.off(CliRenderEvents.SELECTION, this.#onSelection))
  }

  get diagnostics(): TranscriptDiagnostics {
    return { ...this.#diagnostics }
  }

  get retainedRootCount(): number {
    return (
      this.#committed.length +
      (this.#omittedMarker ? 1 : 0) +
      (this.#streaming && streamingRoot(this.#streaming) ? 1 : 0) +
      this.#activeToolViews.size
    )
  }

  destroy(): void {
    if (this.#destroyed) return
    this.#destroyed = true
    this.#operationGeneration++
    this.#pendingNativeRead = undefined
    this.#dirty = false
    this.#cancelAnchorFrame()
    for (const release of this.#release.splice(0)) release()
    this.#clearContent()
    this.root.destroyRecursively()
  }

  #requestSync = (): void => {
    if (this.#destroyed) return
    this.#diagnostics.syncRequests++
    if (this.#dirty) {
      this.#diagnostics.coalescedRequests++
      return
    }
    this.#dirty = true
    this.#renderer.requestRender()
  }

  #syncFrame = (): void => {
    if (this.#destroyed || !this.#dirty) return
    this.#dirty = false
    this.#syncContent()
  }

  #syncContent(): void {
    const started = this.#measureSync ? performance.now() : 0
    this.#diagnostics.syncPasses++
    try {
      const session = this.#interactive.getSession()
      if (!this.#hasProjection || session !== this.#session || session.messages.length < this.#nextMessageIndex) {
        this.#session = session
        this.#resetProjection(session)
        this.#hasProjection = true
      } else {
        this.#appendCommittedMessages(session)
      }

      this.#syncStreaming(session.streamingMessage)
      this.#syncActiveTools(this.#interactive.$activeTools.get())
      this.#diagnostics.projectedMessages = this.#committed.length
      this.#diagnostics.omittedMessages = this.#omittedMessageCount

      const revision = this.#interactive.$transcriptRevision.get()
      if (revision !== this.#transcriptRevision) {
        this.#transcriptRevision = revision
        if (this.#navigation.$navigation.get().type === "detached") {
          this.#navigation.dispatch({ type: "OUTPUT_COMMITTED" })
        }
      }
    } finally {
      if (this.#measureSync) {
        const duration = performance.now() - started
        this.#diagnostics.lastSyncMs = duration
        this.#diagnostics.maxSyncMs = Math.max(this.#diagnostics.maxSyncMs, duration)
      }
    }
  }

  #resetProjection(session: TranscriptSession): void {
    this.#operationGeneration++
    this.#cancelAnchorFrame()
    this.#clearContent()
    const start = Math.max(0, session.messages.length - maxProjectedMessages)
    this.#nextMessageIndex = start
    this.#setOmittedMessageCount(start)
    this.#appendCommittedMessages(session)
  }

  #appendCommittedMessages(session: TranscriptSession): void {
    for (let index = this.#nextMessageIndex; index < session.messages.length; index++) {
      const message = session.messages[index]
      if (!message) continue
      this.#recordToolCalls(message)
      const toolCall = message.role === "toolResult" ? this.#pendingToolCalls.get(message.toolCallId) : undefined
      const root = createMessageView(this.#renderer, message, {
        theme: this.#theme,
        syntaxStyle: this.#syntaxStyle,
        ...(toolCall === undefined ? {} : { toolCall })
      })
      if (root) {
        this.#insertBeforeTransient(root)
        this.#committed.push({ messageIndex: index, root })
      }
      if (message.role === "toolResult") this.#pendingToolCalls.delete(message.toolCallId)
      this.#nextMessageIndex = index + 1
    }
    this.#enforceProjectionLimit()
  }

  #recordToolCalls(message: AgentMessage): void {
    if (message.role !== "assistant") return
    for (const part of message.content) {
      if (part.type !== "toolCall") continue
      if (this.#pendingToolCalls.has(part.id)) this.#pendingToolCalls.delete(part.id)
      this.#pendingToolCalls.set(part.id, { name: part.name, args: part.arguments })
      if (this.#pendingToolCalls.size <= maxPendingToolCalls) continue
      const oldest = this.#pendingToolCalls.keys().next().value
      if (oldest !== undefined) this.#pendingToolCalls.delete(oldest)
    }
  }

  #enforceProjectionLimit(): void {
    const omitted = Math.max(0, this.#nextMessageIndex - maxProjectedMessages)
    if (omitted <= this.#omittedMessageCount) return

    const firstRetained = this.#committed.find(view => view.messageIndex >= omitted)
    const detached = this.#navigation.$navigation.get().type === "detached"
    const anchorY = detached && firstRetained ? firstRetained.root.y : undefined
    const evicted = this.#committed.filter(view => view.messageIndex < omitted)
    if (evicted.length > 0 && this.#renderer.hasSelection) this.#renderer.clearSelection()

    for (const view of evicted) {
      this.scroll.remove(view.root)
      view.root.destroyRecursively()
    }
    if (evicted.length > 0) this.#committed.splice(0, evicted.length)
    this.#setOmittedMessageCount(omitted)

    if (anchorY !== undefined && firstRetained) this.#scheduleAnchorCorrection(firstRetained.root, anchorY)
  }

  #setOmittedMessageCount(count: number): void {
    this.#omittedMessageCount = count
    if (count === 0) {
      if (this.#omittedMarker) {
        this.scroll.remove(this.#omittedMarker)
        this.#omittedMarker.destroyRecursively()
        this.#omittedMarker = undefined
      }
      return
    }

    const content = `… ${count} earlier messages are not rendered`
    if (this.#omittedMarker) {
      this.#omittedMarker.content = content
      return
    }
    this.#omittedMarker = new TextRenderable(this.#renderer, {
      id: "transcript-omitted-history",
      selectable: false,
      fg: this.#theme.text.muted,
      paddingLeft: 1,
      marginBottom: 1,
      flexShrink: 0,
      content
    })
    const first = this.scroll.getChildren()[0]
    if (first) this.scroll.insertBefore(this.#omittedMarker, first)
    else this.scroll.add(this.#omittedMarker)
  }

  #scheduleAnchorCorrection(anchor: Renderable, beforeY: number): void {
    this.#cancelAnchorFrame()
    const target = this.scroll
    const generation = ++this.#operationGeneration
    this.#scheduledAnchorFrame = -1
    let ranSynchronously = false
    const frame = this.#requestFrame(() => {
      ranSynchronously = true
      this.#scheduledAnchorFrame = undefined
      if (
        this.#destroyed ||
        this.#operationGeneration !== generation ||
        this.scroll !== target ||
        target.isDestroyed ||
        anchor.isDestroyed ||
        this.#navigation.$navigation.get().type !== "detached"
      ) {
        return
      }
      const delta = anchor.y - beforeY
      if (delta !== 0) target.scrollBy(delta)
    })
    if (!ranSynchronously) this.#scheduledAnchorFrame = frame
  }

  #syncStreaming(message: AgentMessage | undefined): void {
    if (!message) {
      this.#destroyStreaming()
      return
    }

    if (message.role === "assistant") {
      if (this.#streaming?.type === "assistant") {
        if (this.#streaming.view.update(message)) this.#diagnostics.streamingUpdates++
        return
      }
      this.#destroyStreaming()
      const view = new StreamingAssistantView(this.#renderer, message, this.#theme, this.#syntaxStyle)
      this.#streaming = { type: "assistant", view }
      this.#insertBeforeActiveTools(view.root)
      this.#diagnostics.streamingCreates++
      return
    }

    if (this.#streaming?.type === "static" && this.#streaming.role === message.role) return
    this.#destroyStreaming()
    const root = createMessageView(this.#renderer, message, { theme: this.#theme, syntaxStyle: this.#syntaxStyle })
    this.#streaming = { type: "static", role: message.role, root }
    if (root) this.#insertBeforeActiveTools(root)
    this.#diagnostics.streamingCreates++
  }

  #destroyStreaming(): void {
    if (!this.#streaming) return
    const root = streamingRoot(this.#streaming)
    if (root) this.scroll.remove(root)
    if (this.#streaming.type === "assistant") this.#streaming.view.destroy()
    else this.#streaming.root?.destroyRecursively()
    this.#streaming = undefined
  }

  #syncActiveTools(tools: ReadonlyMap<string, ActiveTool>): void {
    for (const [id, view] of this.#activeToolViews) {
      if (tools.has(id)) continue
      this.scroll.remove(view.root)
      view.destroy()
      this.#activeToolViews.delete(id)
      this.#diagnostics.activeToolDestroys++
    }

    for (const [id, tool] of tools) {
      const retained = this.#activeToolViews.get(id)
      if (retained) {
        if (retained.update(tool)) this.#diagnostics.activeToolUpdates++
        continue
      }
      const view = createActiveToolView(this.#renderer, tool, this.#theme)
      this.scroll.add(view.root)
      this.#activeToolViews.set(id, view)
      this.#diagnostics.activeToolCreates++
    }

    const order = [...tools.keys()]
    if (!sameOrder(order, this.#activeToolOrder)) {
      for (const id of order) {
        const root = this.#activeToolViews.get(id)?.root
        if (root) this.scroll.remove(root)
      }
      for (const id of order) {
        const root = this.#activeToolViews.get(id)?.root
        if (root) this.scroll.add(root)
      }
      this.#activeToolOrder = order
    }
  }

  #clearContent(): void {
    for (const child of this.scroll.getChildren()) {
      this.scroll.remove(child)
      child.destroyRecursively()
    }
    this.#committed.length = 0
    this.#pendingToolCalls.clear()
    this.#activeToolViews.clear()
    this.#activeToolOrder = []
    this.#nextMessageIndex = 0
    this.#omittedMessageCount = 0
    this.#omittedMarker = undefined
    this.#streaming = undefined
    this.#diagnostics.projectedMessages = 0
    this.#diagnostics.omittedMessages = 0
  }

  #insertBeforeTransient(root: Renderable): void {
    const anchor = this.#streaming ? streamingRoot(this.#streaming) : undefined
    const activeTool = this.#activeToolOrder.length
      ? this.#activeToolViews.get(this.#activeToolOrder[0]!)?.root
      : undefined
    if (anchor ?? activeTool) this.scroll.insertBefore(root, anchor ?? activeTool)
    else this.scroll.add(root)
  }

  #insertBeforeActiveTools(root: Renderable): void {
    const anchor = this.#activeToolOrder.length ? this.#activeToolViews.get(this.#activeToolOrder[0]!)?.root : undefined
    if (anchor) this.scroll.insertBefore(root, anchor)
    else this.scroll.add(root)
  }

  #cancelAnchorFrame(): void {
    if (this.#scheduledAnchorFrame === undefined) return
    this.#cancelFrame(this.#scheduledAnchorFrame)
    // OpenTUI 0.4.3 removes a cancelled callback without balancing requestLive().
    this.#renderer.dropLive()
    this.#scheduledAnchorFrame = undefined
  }

  #syncNavigation = (): void => {
    const navigation = this.#navigation.$navigation.get()
    this.scroll.stickyScroll = navigation.type === "following"
    this.#syncStatus()
  }

  #syncStatus = (): void => {
    const navigation = this.#navigation.$navigation.get()
    this.#status.visible = navigation.type === "detached" && navigation.unseenOutput && this.root.height > 1
  }

  #queueNativeRead(kind: "manual" | "resize"): void {
    const target = this.scroll
    if (target.isDestroyed) return

    let pending = this.#pendingNativeRead
    if (!pending || pending.target !== target) {
      const queued: PendingNativeRead = { target, resize: false }
      pending = queued
      this.#pendingNativeRead = queued
      queueMicrotask(() => {
        if (this.#pendingNativeRead === queued) this.#pendingNativeRead = undefined
        if (this.scroll !== queued.target || queued.target.isDestroyed) return

        if (queued.manualGeneration !== undefined && queued.manualGeneration === this.#operationGeneration) {
          this.#navigation.dispatch({ type: "MANUAL_POSITION_CHANGED", atTail: isAtTail(queued.target) })
        }
        if (queued.resize) {
          this.#navigation.dispatch({
            type: "RESIZE_SETTLED",
            contentFits: queued.target.scrollHeight <= queued.target.viewport.height
          })
        }
      })
    }

    if (kind === "manual") pending.manualGeneration = ++this.#operationGeneration
    else pending.resize = true
  }

  #manualScroll(delta: number, unit: "absolute" | "viewport"): void {
    const target = this.scroll
    if (target.isDestroyed) return

    this.#operationGeneration++
    target.scrollBy(delta, unit)
    if (target.isDestroyed) return
    this.#navigation.dispatch({ type: "MANUAL_POSITION_CHANGED", atTail: isAtTail(target) })
  }

  #jumpToTail(): void {
    const target = this.scroll
    if (target.isDestroyed) return

    const generation = ++this.#operationGeneration
    this.#navigation.dispatch({ type: "JUMP_TO_TAIL" })
    queueMicrotask(() => {
      if (this.#operationGeneration !== generation || target.isDestroyed) return
      target.scrollTo(target.scrollHeight)
    })
  }

  #detachForSelection(): void {
    this.#operationGeneration++
    this.#navigation.dispatch({ type: "SELECTION_DRAG_STARTED" })
  }

  #onSelection = (): void => {
    this.#queueNativeRead("manual")
  }

  #onKeyPress = (key: KeyEvent): void => {
    const action = this.#keybindings.transcriptAction(key)
    if (!action) return
    key.preventDefault()
    key.stopPropagation()
    this.#handleKeyAction(action)
  }

  #handleKeyAction(action: TranscriptKeyAction): void {
    switch (action) {
      case "page_up":
        this.#manualScroll(-0.5, "viewport")
        return
      case "page_down":
        this.#manualScroll(0.5, "viewport")
        return
      case "line_up":
        this.#manualScroll(-1, "absolute")
        return
      case "line_down":
        this.#manualScroll(1, "absolute")
        return
      case "tail":
        this.#jumpToTail()
        return
      default:
        return assertNever(action)
    }
  }
}

function streamingRoot(streaming: StreamingMessageView): Renderable | undefined {
  return streaming.type === "assistant" ? streaming.view.root : streaming.root
}

function sameOrder(left: readonly string[], right: readonly string[]): boolean {
  return left.length === right.length && left.every((value, index) => value === right[index])
}

function transcriptHint(keybindings: InteractiveKeybindings): string {
  const tailHint = keybindings.getHint("app.transcript.tail")
  return `New output${tailHint ? ` · ${tailHint} to jump` : ""}`
}

function assertNever(value: never): never {
  throw new Error(`Unhandled transcript key action: ${String(value)}`)
}

function isAtTail(scroll: ScrollBoxRenderable): boolean {
  const maximum = Math.max(0, scroll.scrollHeight - scroll.viewport.height)
  return maximum <= 1 || scroll.scrollTop >= maximum
}
