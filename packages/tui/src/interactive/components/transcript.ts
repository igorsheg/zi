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
import type { AgentMessage, AgentSession } from "@openzi/coding-agent"

import type { Theme } from "../../theme.js"
import type { InteractiveKeybindings, TranscriptKeyAction } from "../interactive-keybindings.js"
import type { InteractiveStore } from "../stores/interactive.js"
import { createTranscriptStore, type TranscriptStore } from "../stores/transcript.js"
import { createMessageView, type ToolCallPresentation } from "./message.js"
import { createActiveToolView } from "./tool-block.js"

interface PendingNativeRead {
  readonly target: ScrollBoxRenderable
  manualGeneration?: number
  resize: boolean
}

export class TranscriptView {
  readonly root: BoxRenderable
  readonly scroll: ScrollBoxRenderable

  readonly #renderer: CliRenderer
  readonly #mode: InteractiveStore
  readonly #keybindings: InteractiveKeybindings
  readonly #theme: Theme
  readonly #syntaxStyle: SyntaxStyle
  readonly #navigation: TranscriptStore
  readonly #status: BoxRenderable
  readonly #release: Array<() => void> = []
  readonly #activeToolViews = new Map<string, Renderable>()
  #session: AgentSession
  #messageCount = 0
  #streamingView: Renderable | undefined
  #operationGeneration = 0
  #pendingNativeRead: PendingNativeRead | undefined
  #transcriptRevision: number

  constructor(
    renderer: CliRenderer,
    mode: InteractiveStore,
    keybindings: InteractiveKeybindings,
    theme: Theme,
    syntaxStyle: SyntaxStyle
  ) {
    this.#renderer = renderer
    this.#mode = mode
    this.#keybindings = keybindings
    this.#theme = theme
    this.#syntaxStyle = syntaxStyle
    this.#session = mode.getSession()
    this.#transcriptRevision = mode.$transcriptRevision.get()
    this.#navigation = createTranscriptStore()

    this.root = new BoxRenderable(renderer, {
      id: "transcript-region",
      position: "relative",
      flexGrow: 1,
      minHeight: 1
    })
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

    const syncContent = () => this.#syncContent()
    this.#release.push(mode.$transcriptRevision.subscribe(syncContent), mode.$activeTools.subscribe(syncContent))
    this.#release.push(this.#navigation.$navigation.subscribe(this.#syncNavigation))
    renderer.keyInput.on("keypress", this.#onKeyPress)
    renderer.on(CliRenderEvents.SELECTION, this.#onSelection)
    this.#release.push(() => renderer.keyInput.off("keypress", this.#onKeyPress))
    this.#release.push(() => renderer.off(CliRenderEvents.SELECTION, this.#onSelection))
  }

  destroy(): void {
    this.#operationGeneration++
    this.#pendingNativeRead = undefined
    for (const release of this.#release.splice(0)) release()
    this.root.destroyRecursively()
  }

  #syncContent = (): void => {
    const session = this.#mode.getSession()
    if (session !== this.#session || session.messages.length < this.#messageCount) {
      this.#session = session
      this.#clearContent()
    }

    const toolCalls = collectToolCalls(session.messages, session.streamingMessage)
    for (let index = this.#messageCount; index < session.messages.length; index++) {
      const message = session.messages[index]
      if (!message) continue
      const toolCall = message.role === "toolResult" ? toolCalls.get(message.toolCallId) : undefined
      const view = createMessageView(this.#renderer, message, {
        theme: this.#theme,
        syntaxStyle: this.#syntaxStyle,
        ...(toolCall === undefined ? {} : { toolCall })
      })
      if (view) this.#insertBeforeTransient(view)
    }
    this.#messageCount = session.messages.length

    if (this.#streamingView) {
      this.scroll.remove(this.#streamingView)
      this.#streamingView.destroyRecursively()
      this.#streamingView = undefined
    }
    if (session.streamingMessage) {
      const view = createMessageView(this.#renderer, session.streamingMessage, {
        theme: this.#theme,
        syntaxStyle: this.#syntaxStyle
      })
      if (view) {
        this.#insertBeforeActiveTools(view)
        this.#streamingView = view
      }
    }

    for (const view of this.#activeToolViews.values()) {
      this.scroll.remove(view)
      view.destroyRecursively()
    }
    this.#activeToolViews.clear()
    for (const tool of this.#mode.$activeTools.get().values()) {
      const view = createActiveToolView(this.#renderer, tool, this.#theme)
      this.scroll.add(view)
      this.#activeToolViews.set(tool.id, view)
    }

    const revision = this.#mode.$transcriptRevision.get()
    if (revision !== this.#transcriptRevision) {
      this.#transcriptRevision = revision
      if (this.#navigation.$navigation.get().type === "detached") {
        this.#navigation.dispatch({ type: "OUTPUT_COMMITTED" })
      }
    }
  }

  #clearContent(): void {
    for (const child of this.scroll.getChildren()) {
      this.scroll.remove(child)
      child.destroyRecursively()
    }
    this.#messageCount = 0
    this.#streamingView = undefined
    this.#activeToolViews.clear()
  }

  #insertBeforeTransient(view: Renderable): void {
    const anchor = this.#streamingView ?? this.#activeToolViews.values().next().value
    if (anchor) this.scroll.insertBefore(view, anchor)
    else this.scroll.add(view)
  }

  #insertBeforeActiveTools(view: Renderable): void {
    const anchor = this.#activeToolViews.values().next().value
    if (anchor) this.scroll.insertBefore(view, anchor)
    else this.scroll.add(view)
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

function collectToolCalls(
  messages: readonly AgentMessage[],
  streamingMessage: AgentMessage | undefined
): ReadonlyMap<string, ToolCallPresentation> {
  const calls = new Map<string, ToolCallPresentation>()
  for (const message of messages) collectAssistantToolCalls(calls, message)
  if (streamingMessage) collectAssistantToolCalls(calls, streamingMessage)
  return calls
}

function collectAssistantToolCalls(calls: Map<string, ToolCallPresentation>, message: AgentMessage): void {
  if (message.role !== "assistant") return
  for (const part of message.content) {
    if (part.type === "toolCall") calls.set(part.id, { name: part.name, args: part.arguments })
  }
}
