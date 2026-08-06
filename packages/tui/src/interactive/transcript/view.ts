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
import { projectToolPresentation, type AgentMessage } from "@with-zi/coding-agent"
import type { ReadableAtom } from "nanostores"

import { createThinkingSyntaxStyle, type Theme } from "../../theme.js"
import type { InteractiveKeybindings, TranscriptKeyAction } from "../interactive-keybindings.js"
import type { ActiveTool } from "../interactive-store.js"
import type { TranscriptItemView } from "./item.js"
import {
  createMessageItemView,
  StreamingAssistantView,
  type AssistantToolViewOwner,
  type ToolCallPresentation
} from "./message-view.js"
import { createTranscriptStore, type TranscriptStore } from "./navigation.js"
import { ToolCallView, type ToolViewFrame } from "./tool-view.js"

interface TranscriptSession {
  readonly messages: readonly AgentMessage[]
  readonly streamingMessage: AgentMessage | undefined
  readonly sessionManager?: { readonly header: { readonly cwd: string } }
  readonly shellTasks?: readonly { readonly type: string; readonly toolCallId: string }[]
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

type ToolViewIdentity = string | symbol

interface CommittedMessageView {
  readonly messageIndex: number
  root: Renderable | undefined
  toolCallIds: ToolViewIdentity[]
  readonly item?: TranscriptItemView
  readonly assistant?: StreamingAssistantView
}

interface IndexedToolView {
  readonly view: ToolCallView
  readonly toolCallId: string
  source: ActiveTool
  placement: "embedded" | "standalone" | "committed"
  owner: StreamingAssistantView | undefined
}

type StreamingMessageView =
  | { readonly type: "assistant"; readonly messageIndex: number; readonly view: StreamingAssistantView }
  | {
      readonly type: "static"
      readonly messageIndex: number
      readonly role: Exclude<AgentMessage["role"], "assistant">
      readonly item: TranscriptItemView | undefined
    }

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
  readonly toolProjections: number
}

export interface TranscriptViewOptions {
  readonly measureSync?: boolean
}

const maxProjectedMessages = 200
const maxProjectedToolViews = 64
const maxPendingToolCalls = 64

export class TranscriptView {
  readonly root: BoxRenderable
  readonly scroll: ScrollBoxRenderable

  readonly #renderer: CliRenderer
  readonly #interactive: TranscriptSource
  readonly #keybindings: InteractiveKeybindings
  readonly #theme: Theme
  readonly #syntaxStyle: SyntaxStyle
  readonly #thinkingSyntaxStyle: SyntaxStyle
  readonly #navigation: TranscriptStore
  readonly #status: BoxRenderable
  readonly #measureSync: boolean
  readonly #requestFrame: typeof requestAnimationFrame
  readonly #cancelFrame: typeof cancelAnimationFrame
  readonly #release: Array<() => void> = []
  readonly #committed: CommittedMessageView[] = []
  readonly #pendingToolCalls = new Map<string, ToolCallPresentation>()
  readonly #projectedToolIds = new Map<ToolViewIdentity, true>()
  readonly #toolViews = new Map<ToolViewIdentity, IndexedToolView>()
  readonly #activeToolViews = new Map<string, ToolCallView>()
  readonly #assistantToolViews: AssistantToolViewOwner = {
    includes: id => this.#projectedToolIds.has(id),
    create: (owner, fallback) => {
      const tool = this.#authoritativeTool(fallback)
      const retained = this.#toolViews.get(tool.id)
      if (retained) {
        if (retained.placement === "standalone") {
          this.scroll.remove(retained.view.root)
          this.#activeToolViews.delete(tool.id)
          this.#activeToolOrder = this.#activeToolOrder.filter(candidate => candidate !== tool.id)
          retained.placement = "embedded"
        }
        retained.owner = owner
        retained.view.setEmbedded(true)
        this.#updateToolView(retained, tool)
        return retained.view
      }
      const view = new ToolCallView(
        this.#renderer,
        tool.id,
        this.#projectTool(tool),
        this.#theme,
        sessionCwd(this.#session),
        this.#keybindings.getHint("app.tools.expand")
      )
      view.setExpanded(this.#toolsExpanded)
      view.setEmbedded(true)
      this.#toolViews.set(tool.id, { view, toolCallId: tool.id, source: tool, placement: "embedded", owner })
      this.#diagnostics.activeToolCreates++
      return view
    },
    update: (view, fallback) => {
      const tool = this.#authoritativeTool(fallback)
      const retained = this.#toolViews.get(tool.id)
      return retained?.view === view ? this.#updateToolView(retained, tool) : view.update(this.#projectTool(tool))
    },
    release: (owner, id, view) => {
      const identity = this.#toolIdentity(id, view)
      const retained = identity === undefined ? undefined : this.#toolViews.get(identity)
      if (identity !== undefined && retained?.placement === "embedded" && retained.owner === owner) {
        this.#toolViews.delete(identity)
      }
      view.destroy()
    }
  }
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
    activeToolDestroys: 0,
    toolProjections: 0
  }
  #session: TranscriptSession
  #messages: readonly AgentMessage[]
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
  #toolsExpanded = false
  #runningLive = false
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
    this.#thinkingSyntaxStyle = createThinkingSyntaxStyle(theme)
    this.#measureSync = options.measureSync ?? false
    this.#requestFrame = globalThis.requestAnimationFrame.bind(globalThis)
    this.#cancelFrame = globalThis.cancelAnimationFrame.bind(globalThis)
    this.#session = interactive.getSession()
    this.#messages = this.#session.messages
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
      this.#committed.filter(view => view.root !== undefined).length +
      (this.#omittedMarker ? 1 : 0) +
      (this.#streaming && streamingRoot(this.#streaming) ? 1 : 0) +
      this.#activeToolViews.size
    )
  }

  get retainedToolCount(): number {
    return this.#toolViews.size
  }

  destroy(): void {
    if (this.#destroyed) return
    this.#destroyed = true
    this.#operationGeneration++
    this.#pendingNativeRead = undefined
    this.#dirty = false
    this.#setRunningLive(false)
    this.#cancelAnchorFrame()
    for (const release of this.#release.splice(0)) release()
    this.#clearContent()
    this.root.destroyRecursively()
    this.#thinkingSyntaxStyle.destroy()
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
    if (this.#destroyed) return
    if (this.#dirty) {
      this.#dirty = false
      this.#syncContent()
    }
    this.#refreshRunningTools()
  }

  #syncContent(): void {
    const started = this.#measureSync ? performance.now() : 0
    this.#diagnostics.syncPasses++
    try {
      const session = this.#interactive.getSession()
      const activeTools = this.#interactive.$activeTools.get()
      if (
        !this.#hasProjection ||
        session !== this.#session ||
        session.messages !== this.#messages ||
        session.messages.length < this.#nextMessageIndex
      ) {
        this.#session = session
        this.#messages = session.messages
        this.#resetProjection(session)
        this.#hasProjection = true
      } else {
        this.#appendCommittedMessages(session)
      }

      for (const [id, tool] of activeTools) {
        if (
          this.#toolViews.has(id) ||
          tool.status === "preparing" ||
          tool.status === "ready" ||
          tool.status === "running"
        ) {
          this.#admitProjectedTool(id, false)
        }
      }
      this.#syncStreaming(session.streamingMessage)
      this.#syncActiveTools(activeTools)
      this.#syncToolActions(session)
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
    this.#jumpToTail()
  }

  #appendCommittedMessages(session: TranscriptSession): void {
    for (let index = this.#nextMessageIndex; index < session.messages.length; index++) {
      const message = session.messages[index]
      if (!message) continue
      this.#admitMessageTools(message)
      this.#recordToolCalls(message)
      if (message.role === "assistant") {
        this.#commitAssistantMessage(message, index)
      } else if (message.role === "toolResult") {
        this.#commitToolResult(message, index)
      } else {
        const promoted =
          this.#streaming?.type === "static" &&
          this.#streaming.messageIndex === index &&
          this.#streaming.role === message.role
            ? this.#streaming
            : undefined
        const item = promoted?.item ?? this.#createMessageItem(message)
        if (promoted) this.#streaming = undefined
        if (item) {
          if (!promoted) this.#insertBeforeTransient(item.root)
          this.#committed.push({ messageIndex: index, root: item.root, toolCallIds: [], item })
        }
      }
      this.#nextMessageIndex = index + 1
    }
    this.#enforceProjectionLimit()
  }

  #commitAssistantMessage(message: Extract<AgentMessage, { role: "assistant" }>, messageIndex: number): void {
    let view: StreamingAssistantView
    if (this.#streaming?.type === "assistant" && this.#streaming.messageIndex === messageIndex) {
      view = this.#streaming.view
      view.update(message)
      this.#streaming = undefined
    } else {
      view = new StreamingAssistantView(
        this.#renderer,
        message,
        this.#theme,
        this.#syntaxStyle,
        this.#thinkingSyntaxStyle,
        this.#assistantToolViews,
        sessionCwd(this.#session)
      )
      this.#insertBeforeTransient(view.root)
      this.#diagnostics.streamingCreates++
    }
    view.root.id = `assistant-message:${messageIndex}`
    const toolCallIds =
      message.stopReason === "error"
        ? view.toolCallIds.map(id => this.#scopeFailedTool(view, id, messageIndex))
        : [...view.toolCallIds]
    this.#committed.push({ messageIndex, root: view.root, toolCallIds, assistant: view })
  }

  #scopeFailedTool(owner: StreamingAssistantView, toolCallId: string, messageIndex: number): ToolViewIdentity {
    const retained = this.#toolViews.get(toolCallId)
    if (!retained || retained.owner !== owner) return toolCallId
    const identity = Symbol(`failed-tool:${messageIndex}:${toolCallId}`)
    retained.view.root.id = `active-tool:failed:${messageIndex}:${toolCallId}`
    this.#toolViews.delete(toolCallId)
    this.#toolViews.set(identity, retained)
    if (this.#projectedToolIds.delete(toolCallId)) this.#projectedToolIds.set(identity, true)
    return identity
  }

  #commitToolResult(message: Extract<AgentMessage, { role: "toolResult" }>, messageIndex: number): void {
    const call = this.#pendingToolCalls.get(message.toolCallId)
    const name = call?.name ?? message.toolName
    const args = call?.args
    const result = { content: message.content, details: message.details }
    const tool: ActiveTool = { id: message.toolCallId, name, args, result, status: message.isError ? "failed" : "done" }
    const retained = this.#toolViews.get(message.toolCallId)

    if (retained) {
      if (this.#updateToolView(retained, tool)) this.#diagnostics.activeToolUpdates++
      if (retained.placement === "standalone") {
        this.scroll.remove(retained.view.root)
        this.#activeToolViews.delete(message.toolCallId)
        this.#activeToolOrder = this.#activeToolOrder.filter(id => id !== message.toolCallId)
        retained.placement = "committed"
        this.#insertBeforeTransient(retained.view.root)
        this.#committed.push({ messageIndex, root: retained.view.root, toolCallIds: [message.toolCallId] })
      } else if (retained.placement === "embedded") {
        this.#committed.push({ messageIndex, root: undefined, toolCallIds: [message.toolCallId] })
      }
    } else if (this.#projectedToolIds.has(message.toolCallId)) {
      const view = new ToolCallView(
        this.#renderer,
        tool.id,
        this.#projectTool(tool),
        this.#theme,
        sessionCwd(this.#session),
        this.#keybindings.getHint("app.tools.expand")
      )
      view.setExpanded(this.#toolsExpanded)
      this.#toolViews.set(message.toolCallId, {
        view,
        toolCallId: message.toolCallId,
        source: tool,
        placement: "committed",
        owner: undefined
      })
      this.#insertBeforeTransient(view.root)
      this.#committed.push({ messageIndex, root: view.root, toolCallIds: [message.toolCallId] })
      this.#diagnostics.activeToolCreates++
    } else {
      const marker = this.#createToolOmissionMarker()
      this.#insertBeforeTransient(marker)
      this.#committed.push({ messageIndex, root: marker, toolCallIds: [] })
    }
    this.#pendingToolCalls.delete(message.toolCallId)
  }

  #admitMessageTools(message: AgentMessage): void {
    if (message.role === "assistant") {
      for (const part of message.content) {
        if (part.type === "toolCall" && part.id) this.#admitProjectedTool(part.id, false)
      }
    } else if (message.role === "toolResult") {
      this.#admitProjectedTool(message.toolCallId, true)
    }
  }

  #admitProjectedTool(id: string, refresh: boolean): void {
    if (this.#projectedToolIds.has(id)) {
      if (refresh) {
        this.#projectedToolIds.delete(id)
        this.#projectedToolIds.set(id, true)
      }
      return
    }
    if (this.#projectedToolIds.size === maxProjectedToolViews) {
      const oldest = this.#projectedToolIds.keys().next().value
      if (oldest !== undefined) {
        this.#projectedToolIds.delete(oldest)
        this.#omitProjectedTool(oldest)
      }
    }
    this.#projectedToolIds.set(id, true)
  }

  #omitProjectedTool(id: ToolViewIdentity): void {
    const indexed = this.#toolViews.get(id)
    if (!indexed) return

    this.#toolViews.delete(id)
    if (this.#activeToolViews.get(indexed.toolCallId) === indexed.view) {
      this.#activeToolViews.delete(indexed.toolCallId)
      this.#activeToolOrder = this.#activeToolOrder.filter(candidate => candidate !== indexed.toolCallId)
    }

    const result = this.#committed.find(view => view.toolCallIds.includes(id) && view.assistant === undefined)
    if (indexed.placement === "embedded" && indexed.owner) {
      if (result) {
        indexed.owner.detachTool(indexed.toolCallId, indexed.view)
        indexed.view.destroy()
      } else {
        indexed.owner.omitTool(indexed.toolCallId, indexed.view)
      }
    } else {
      if (indexed.view.root.parent) indexed.view.root.parent.remove(indexed.view.root)
      indexed.view.destroy()
    }

    for (const committed of this.#committed) {
      if (!committed.toolCallIds.includes(id)) continue
      committed.toolCallIds = committed.toolCallIds.filter(candidate => candidate !== id)
    }
    if (result) {
      const marker = this.#createToolOmissionMarker()
      result.root = marker
      this.#insertCommittedRoot(result)
    }
    this.#diagnostics.activeToolDestroys++
  }

  #promoteRetainedToolResults(evicted: readonly CommittedMessageView[], omitted: number): void {
    for (const assistant of evicted) {
      if (!assistant.assistant) continue
      for (const id of assistant.toolCallIds) {
        const result = this.#committed.find(
          view => view.messageIndex >= omitted && view.root === undefined && view.toolCallIds.includes(id)
        )
        const indexed = this.#toolViews.get(id)
        if (!result || !indexed || indexed.placement !== "embedded" || indexed.owner !== assistant.assistant) continue
        if (!assistant.assistant.detachTool(indexed.toolCallId, indexed.view)) continue

        assistant.toolCallIds = assistant.toolCallIds.filter(candidate => candidate !== id)
        indexed.placement = "committed"
        indexed.owner = undefined
        indexed.view.setEmbedded(false)
        result.root = indexed.view.root
        this.#insertCommittedRoot(result)
      }
    }
  }

  #insertCommittedRoot(record: CommittedMessageView): void {
    if (!record.root) return
    const anchor = this.#committed.find(
      candidate => candidate.messageIndex > record.messageIndex && candidate.root !== undefined
    )?.root
    if (anchor) this.scroll.insertBefore(record.root, anchor)
    else this.#insertBeforeTransient(record.root)
  }

  #committedRoot(record: CommittedMessageView): Renderable | undefined {
    if (record.root) return record.root
    for (const id of record.toolCallIds) {
      const indexed = this.#toolViews.get(id)
      if (indexed) return indexed.view.root
    }
    return undefined
  }

  #createToolOmissionMarker(): TextRenderable {
    return new TextRenderable(this.#renderer, {
      selectable: false,
      fg: this.#theme.text.muted,
      paddingLeft: 1,
      marginTop: 0,
      marginBottom: 1,
      flexShrink: 0,
      content: "… tool invocation not rendered"
    })
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

    const firstRetained = this.#committed.find(view => view.messageIndex >= omitted && this.#committedRoot(view))
    const anchor = firstRetained ? this.#committedRoot(firstRetained) : undefined
    const detached = this.#navigation.$navigation.get().type === "detached"
    const anchorY = detached && anchor ? anchor.y : undefined
    const evicted = this.#committed.filter(view => view.messageIndex < omitted)
    if (evicted.length > 0 && this.#renderer.hasSelection) this.#renderer.clearSelection()

    this.#promoteRetainedToolResults(evicted, omitted)
    for (const view of evicted) {
      for (const id of view.toolCallIds) {
        this.#toolViews.delete(id)
        this.#projectedToolIds.delete(id)
      }
      if (view.root) {
        this.scroll.remove(view.root)
        if (view.assistant) view.assistant.destroy()
        else if (view.item) view.item.destroy()
        else view.root.destroyRecursively()
      }
    }
    if (evicted.length > 0) this.#committed.splice(0, evicted.length)
    this.#setOmittedMessageCount(omitted)

    if (anchorY !== undefined && anchor && !anchor.isDestroyed) this.#scheduleAnchorCorrection(anchor, anchorY)
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
      marginTop: 0,
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
      const view = new StreamingAssistantView(
        this.#renderer,
        message,
        this.#theme,
        this.#syntaxStyle,
        this.#thinkingSyntaxStyle,
        this.#assistantToolViews,
        sessionCwd(this.#session)
      )
      this.#streaming = { type: "assistant", messageIndex: this.#nextMessageIndex, view }
      this.#insertBeforeActiveTools(view.root)
      this.#diagnostics.streamingCreates++
      return
    }

    if (this.#streaming?.type === "static" && this.#streaming.role === message.role) return
    this.#destroyStreaming()
    const item = this.#createMessageItem(message)
    this.#streaming = { type: "static", messageIndex: this.#nextMessageIndex, role: message.role, item }
    if (item) this.#insertBeforeActiveTools(item.root)
    this.#diagnostics.streamingCreates++
  }

  #createMessageItem(message: Exclude<AgentMessage, { role: "assistant" }>): TranscriptItemView | undefined {
    const expandHint = this.#keybindings.getHint("app.tools.expand")
    const item = createMessageItemView(this.#renderer, message, {
      theme: this.#theme,
      syntaxStyle: this.#syntaxStyle,
      cwd: sessionCwd(this.#session),
      ...(expandHint === undefined ? {} : { expandHint })
    })
    item?.setExpanded?.(this.#toolsExpanded)
    return item
  }

  #destroyStreaming(): void {
    if (!this.#streaming) return
    const root = streamingRoot(this.#streaming)
    if (root) this.scroll.remove(root)
    if (this.#streaming.type === "assistant") this.#streaming.view.destroy()
    else this.#streaming.item?.destroy()
    this.#streaming = undefined
  }

  #syncActiveTools(tools: ReadonlyMap<string, ActiveTool>): void {
    for (const [id, view] of this.#activeToolViews) {
      if (tools.has(id)) continue
      this.scroll.remove(view.root)
      view.destroy()
      this.#activeToolViews.delete(id)
      const indexed = this.#toolViews.get(id)
      if (indexed?.view === view && indexed.placement === "standalone") this.#toolViews.delete(id)
      this.#diagnostics.activeToolDestroys++
    }

    for (const [id, tool] of tools) {
      if (!this.#projectedToolIds.has(id)) continue
      const indexed = this.#toolViews.get(id)
      if (indexed) {
        if (this.#updateToolView(indexed, tool)) this.#diagnostics.activeToolUpdates++
        continue
      }
      const view = new ToolCallView(
        this.#renderer,
        tool.id,
        this.#projectTool(tool),
        this.#theme,
        sessionCwd(this.#session),
        this.#keybindings.getHint("app.tools.expand")
      )
      view.setExpanded(this.#toolsExpanded)
      this.scroll.add(view.root)
      this.#toolViews.set(id, { view, toolCallId: id, source: tool, placement: "standalone", owner: undefined })
      this.#activeToolViews.set(id, view)
      this.#diagnostics.activeToolCreates++
    }

    const order = [...tools.keys()].filter(id => this.#activeToolViews.has(id))
    if (!sameOrder(order, this.#activeToolOrder)) {
      for (const id of order) this.scroll.remove(this.#activeToolViews.get(id)!.root)
      for (const id of order) this.scroll.add(this.#activeToolViews.get(id)!.root)
      this.#activeToolOrder = order
    }
  }

  #toolIdentity(toolCallId: string, view: ToolCallView): ToolViewIdentity | undefined {
    if (this.#toolViews.get(toolCallId)?.view === view) return toolCallId
    for (const [identity, retained] of this.#toolViews) {
      if (retained.view === view) return identity
    }
    return undefined
  }

  #authoritativeTool(fallback: ActiveTool): ActiveTool {
    if (fallback.status === "failed" || fallback.status === "aborted") return fallback
    return this.#interactive.$activeTools.get().get(fallback.id) ?? fallback
  }

  #projectTool(source: ActiveTool): ToolViewFrame {
    this.#diagnostics.toolProjections++
    return { status: source.status, presentation: projectToolPresentation(source) }
  }

  #updateToolView(indexed: IndexedToolView, source: ActiveTool): boolean {
    if (indexed.source === source) return false
    indexed.source = source
    return indexed.view.update(this.#projectTool(source))
  }

  #syncToolActions(session: TranscriptSession): void {
    const foreground = session.shellTasks?.find(task => task.type === "foreground")
    const action = foreground
      ? `${this.#keybindings.getHint("app.task.background")} background · ${this.#keybindings.getHint("app.interrupt")} interrupt`
      : undefined
    for (const [identity, { view }] of this.#toolViews) {
      view.setActionHint(typeof identity === "string" && identity === foreground?.toolCallId ? action : undefined)
    }
  }

  #refreshRunningTools(): void {
    let hasVisibleRunningTool = false
    const now = performance.now()
    for (const { view } of this.#toolViews.values()) {
      if (!view.isRunning || !this.#isVisible(view.root)) continue
      hasVisibleRunningTool = true
      view.refreshRunning(now)
    }
    this.#setRunningLive(hasVisibleRunningTool)
  }

  #isVisible(root: Renderable): boolean {
    if (root.height === 0 || this.scroll.viewport.height === 0) return true
    const top = this.scroll.viewport.screenY
    const bottom = top + this.scroll.viewport.height
    return root.screenY < bottom && root.screenY + root.height > top
  }

  #setRunningLive(live: boolean): void {
    if (live === this.#runningLive) return
    this.#runningLive = live
    if (live) this.#renderer.requestLive()
    else this.#renderer.dropLive()
  }

  #clearContent(): void {
    this.#setRunningLive(false)
    if (this.#renderer.hasSelection) this.#renderer.clearSelection()
    const children = this.scroll.getChildren()
    for (const child of children) this.scroll.remove(child)

    const assistants = new Set(this.#committed.flatMap(record => (record.assistant ? [record.assistant] : [])))
    if (this.#streaming?.type === "assistant") assistants.add(this.#streaming.view)
    for (const assistant of assistants) assistant.destroy()

    const items = new Set(this.#committed.flatMap(record => (record.item ? [record.item] : [])))
    if (this.#streaming?.type === "static" && this.#streaming.item) items.add(this.#streaming.item)
    for (const item of items) item.destroy()

    for (const { view } of this.#toolViews.values()) {
      if (!view.root.isDestroyed) view.destroy()
    }
    for (const child of children) {
      if (!child.isDestroyed) child.destroyRecursively()
    }

    this.#committed.length = 0
    this.#pendingToolCalls.clear()
    this.#projectedToolIds.clear()
    this.#toolViews.clear()
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
    // OpenTUI 0.4.5 removes a cancelled callback without balancing requestLive().
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
    if (key.defaultPrevented || key.propagationStopped) return
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
      case "toggle_tools":
        this.#toolsExpanded = !this.#toolsExpanded
        for (const { view } of this.#toolViews.values()) view.setExpanded(this.#toolsExpanded)
        for (const committed of this.#committed) committed.item?.setExpanded?.(this.#toolsExpanded)
        if (this.#streaming?.type === "static") this.#streaming.item?.setExpanded?.(this.#toolsExpanded)
        this.#renderer.requestRender()
        return
      default:
        return assertNever(action)
    }
  }
}

function sessionCwd(session: TranscriptSession): string {
  return session.sessionManager?.header.cwd ?? ""
}

function streamingRoot(streaming: StreamingMessageView): Renderable | undefined {
  return streaming.type === "assistant" ? streaming.view.root : streaming.item?.root
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
