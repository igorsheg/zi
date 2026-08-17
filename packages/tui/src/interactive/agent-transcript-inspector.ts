import {
  BoxRenderable,
  CliRenderEvents,
  type CliRenderer,
  fg,
  type KeyEvent,
  StyledText,
  TextRenderable,
  type SyntaxStyle
} from "@opentui/core"
import type { AgentPath, AgentSnapshot, AgentTranscriptLease } from "@with-zi/coding-agent"

import { textWidth, truncateMiddleToCells, truncateToCells } from "../components/cell-text.js"
import type { Theme } from "../theme.js"
import type { InteractiveKeybindings } from "./interactive-keybindings.js"
import { createAgentTranscriptSource, type AgentTranscriptSource } from "./transcript/agent-source.js"
import { TranscriptView } from "./transcript/view.js"

export interface AgentTranscriptInspectorSession {
  readonly sessionManager: { readonly header: { readonly cwd: string } }
  agentSnapshots(): readonly AgentSnapshot[]
  openAgentTranscript(path: AgentPath, signal: AbortSignal): Promise<AgentTranscriptLease>
}

export interface AgentTranscriptInspectorWorkspace {
  suspendPresentation(): void
  resumePresentation(): void
}

interface InspectorHeader {
  readonly root: BoxRenderable
  readonly label: TextRenderable
  readonly path: AgentPath
  snapshot: AgentSnapshot | undefined
  readonly phase: "loading" | "unavailable" | undefined
}

interface InspectorFooter {
  readonly root: BoxRenderable
  readonly label: TextRenderable
  readonly action: "cancel" | "return to root"
  readonly detail: string | undefined
}

export type AgentTranscriptInspectorState =
  | { readonly type: "root" }
  | {
      readonly type: "loading"
      readonly operationId: number
      readonly path: AgentPath
      readonly controller: AbortController
    }
  | {
      readonly type: "viewing"
      readonly operationId: number
      readonly path: AgentPath
      readonly lease: AgentTranscriptLease
      readonly source: AgentTranscriptSource
      readonly view: TranscriptView
      readonly releaseHeader: () => void
    }
  | { readonly type: "failed"; readonly operationId: number; readonly path: AgentPath; readonly message: string }
  | { readonly type: "disposed" }

export class AgentTranscriptInspector {
  readonly root: BoxRenderable

  readonly #renderer: CliRenderer
  readonly #getSession: () => AgentTranscriptInspectorSession
  readonly #workspace: AgentTranscriptInspectorWorkspace
  readonly #keybindings: InteractiveKeybindings
  readonly #theme: Theme
  readonly #syntaxStyle: SyntaxStyle
  #state: AgentTranscriptInspectorState = { type: "root" }
  #header: InspectorHeader | undefined
  #footer: InspectorFooter | undefined
  #cancelLoadAdmission = () => {}
  #nextOperationId = 0

  constructor(
    renderer: CliRenderer,
    getSession: () => AgentTranscriptInspectorSession,
    workspace: AgentTranscriptInspectorWorkspace,
    keybindings: InteractiveKeybindings,
    theme: Theme,
    syntaxStyle: SyntaxStyle
  ) {
    this.#renderer = renderer
    this.#getSession = getSession
    this.#workspace = workspace
    this.#keybindings = keybindings
    this.#theme = theme
    this.#syntaxStyle = syntaxStyle
    this.root = new BoxRenderable(renderer, {
      id: "agent-transcript-inspector",
      width: "100%",
      height: "100%",
      flexDirection: "column",
      minWidth: 0,
      minHeight: 0,
      backgroundColor: theme.surface.app,
      focusable: true,
      visible: false
    })
    this.root.onSizeChange = this.#syncChromeLayout
    renderer.keyInput.on("keypress", this.#onKeyPress)
  }

  get state(): AgentTranscriptInspectorState {
    return this.#state
  }

  open(path: AgentPath): void {
    if (this.#state.type !== "root") return
    const operationId = ++this.#nextOperationId
    const controller = new AbortController()
    this.#state = { type: "loading", operationId, path, controller }
    this.#renderer.clearSelection()
    this.#workspace.suspendPresentation()
    this.root.visible = true
    this.#renderLoading(path)
    this.root.focus()
    let cancelled = false
    const firstDraw = () => {
      queueMicrotask(() => {
        if (!cancelled) void this.#startLoad(operationId, path, controller)
      })
    }
    this.#renderer.once(CliRenderEvents.FRAME, firstDraw)
    this.#cancelLoadAdmission = () => {
      cancelled = true
      this.#renderer.off(CliRenderEvents.FRAME, firstDraw)
    }
    this.#renderer.requestRender()
  }

  close(): void {
    if (this.#state.type === "root" || this.#state.type === "disposed") return
    this.#releaseActive()
    this.#state = { type: "root" }
    this.root.visible = false
    this.#workspace.resumePresentation()
  }

  dispose(): void {
    if (this.#state.type === "disposed") return
    this.#releaseActive()
    this.#state = { type: "disposed" }
    this.#renderer.keyInput.off("keypress", this.#onKeyPress)
    this.root.destroyRecursively()
  }

  async #startLoad(operationId: number, path: AgentPath, controller: AbortController): Promise<void> {
    let lease: AgentTranscriptLease
    try {
      lease = await this.#getSession().openAgentTranscript(path, controller.signal)
    } catch (cause) {
      const state = this.#state
      if (
        state.type !== "loading" ||
        state.operationId !== operationId ||
        state.controller !== controller ||
        controller.signal.aborted
      ) {
        return
      }
      const message = boundedError(cause)
      this.#state = { type: "failed", operationId, path, message }
      this.#renderFailure(path, message)
      this.root.focus()
      this.#renderer.requestRender()
      return
    }

    const state = this.#state
    if (
      state.type !== "loading" ||
      state.operationId !== operationId ||
      state.controller !== controller ||
      controller.signal.aborted
    ) {
      lease.dispose()
      return
    }
    this.#showTranscript(operationId, path, lease)
  }

  #showTranscript(operationId: number, path: AgentPath, lease: AgentTranscriptLease): void {
    let source: AgentTranscriptSource | undefined
    let view: TranscriptView | undefined
    let releaseHeader: (() => void) | undefined
    try {
      source = createAgentTranscriptSource(lease, this.#getSession().sessionManager.header.cwd)
      view = new TranscriptView(this.#renderer, source, this.#keybindings, this.#theme, this.#syntaxStyle, {
        idPrefix: "agent-inspector",
        availableHeight: () => Math.max(0, this.#renderer.height - this.#chromeHeight())
      })
      this.#clearSurface()
      this.root.add(this.#createHeader(path, lease.snapshot().agent))
      this.root.add(view.root)
      this.root.add(this.#createFooter("return to root", "Read-only agent transcript"))
      this.#syncChromeLayout()
      releaseHeader = source.$promptRevision.subscribe(() => this.#syncHeader(lease))
      this.#state = { type: "viewing", operationId, path, lease, source, view, releaseHeader }
      this.root.focus()
      this.#renderer.requestRender()
    } catch (cause) {
      releaseHeader?.()
      view?.destroy()
      source?.dispose()
      lease.dispose()
      const message = boundedError(cause)
      this.#state = { type: "failed", operationId, path, message }
      this.#renderFailure(path, message)
      this.root.focus()
      this.#renderer.requestRender()
    }
  }

  #renderLoading(path: AgentPath): void {
    this.#clearSurface()
    this.root.add(this.#createHeader(path, this.#snapshot(path), "loading"))
    this.root.add(this.#messageBody("Loading agent transcript…", this.#theme.text.muted))
    this.root.add(this.#createFooter("cancel", "Read-only agent transcript"))
    this.#syncChromeLayout()
  }

  #renderFailure(path: AgentPath, message: string): void {
    this.#clearSurface()
    this.root.add(this.#createHeader(path, this.#snapshot(path), "unavailable"))
    this.root.add(this.#failureBody(message))
    this.root.add(this.#createFooter("return to root"))
    this.#syncChromeLayout()
  }

  #createHeader(
    path: AgentPath,
    snapshot: AgentSnapshot | undefined,
    phase?: "loading" | "unavailable"
  ): BoxRenderable {
    const root = new BoxRenderable(this.#renderer, {
      id: "agent-inspector-header",
      height: 2,
      flexShrink: 0,
      minWidth: 0,
      paddingLeft: 1,
      paddingRight: 1,
      border: ["bottom"],
      borderColor: this.#theme.border.default
    })
    const label = new TextRenderable(this.#renderer, {
      id: "agent-inspector-header-line",
      flexGrow: 1,
      minWidth: 0,
      height: 1,
      wrapMode: "none",
      selectable: true
    })
    root.add(label)
    this.#header = { root, label, path, snapshot, phase }
    this.#layoutHeader()
    return root
  }

  #createFooter(action: "cancel" | "return to root", detail?: string): BoxRenderable {
    const root = new BoxRenderable(this.#renderer, {
      id: "agent-inspector-footer",
      height: 2,
      flexShrink: 0,
      minWidth: 0,
      paddingLeft: 1,
      paddingRight: 1,
      border: ["top"],
      borderColor: this.#theme.border.default
    })
    const label = new TextRenderable(this.#renderer, {
      fg: this.#theme.text.muted,
      flexGrow: 1,
      height: 1,
      minWidth: 0,
      wrapMode: "none",
      selectable: true
    })
    root.add(label)
    this.#footer = { root, label, action, detail }
    this.#layoutFooter()
    return root
  }

  #messageBody(content: string, color: Theme["text"][keyof Theme["text"]]): BoxRenderable {
    const root = new BoxRenderable(this.#renderer, {
      id: "agent-inspector-message",
      flexGrow: 1,
      minHeight: 1,
      minWidth: 0,
      paddingLeft: 1,
      paddingRight: 1,
      justifyContent: "center"
    })
    root.add(
      new TextRenderable(this.#renderer, { content, fg: color, minWidth: 0, wrapMode: "word", selectable: true })
    )
    return root
  }

  #failureBody(message: string): BoxRenderable {
    const root = new BoxRenderable(this.#renderer, {
      id: "agent-inspector-message",
      flexGrow: 1,
      minHeight: 1,
      minWidth: 0,
      flexDirection: "column",
      paddingLeft: 1,
      paddingRight: 1,
      justifyContent: "center"
    })
    root.add(
      new TextRenderable(this.#renderer, {
        content: new StyledText([
          fg(this.#theme.text.error)("Agent transcript unavailable.\n"),
          fg(this.#theme.text.muted)(message)
        ]),
        minWidth: 0,
        wrapMode: "word",
        selectable: true
      })
    )
    return root
  }

  #syncChromeLayout = (): void => {
    const header = this.#header
    if (header) {
      const visible = this.#renderer.height >= 5
      const expanded = this.#renderer.height >= 6
      header.root.visible = visible
      header.root.height = visible ? (expanded ? 2 : 1) : 0
      header.root.border = expanded ? ["bottom"] : false
      this.#layoutHeader()
    }
    const footer = this.#footer
    if (footer) {
      const expanded = this.#renderer.height >= 6
      footer.root.height = expanded ? 2 : 1
      footer.root.border = expanded ? ["top"] : false
      this.#layoutFooter()
    }
  }

  #chromeHeight(): number {
    if (this.#renderer.height >= 6) return 4
    if (this.#renderer.height === 5) return 2
    return 1
  }

  #layoutHeader(): void {
    const header = this.#header
    if (!header) return
    const width = Math.max(0, this.#renderer.width - 2)
    const projected = projectHeader(header.path, header.snapshot, header.phase, width)
    const statusColor = header.phase === "unavailable" ? this.#theme.text.error : this.#theme.text.muted
    header.label.content = new StyledText([
      ...(projected.breadcrumb ? [fg(this.#theme.text.primary)(projected.breadcrumb)] : []),
      ...(projected.breadcrumb && projected.status ? [fg(this.#theme.text.muted)("  ")] : []),
      ...(projected.status ? [fg(statusColor)(projected.status)] : [])
    ])
  }

  #layoutFooter(): void {
    const footer = this.#footer
    if (!footer) return
    const width = Math.max(0, this.#renderer.width - 2)
    const action = `Esc ${footer.action}`
    const full = footer.detail ? `${action} · ${footer.detail}` : action
    footer.label.content = truncateToCells(textWidth(full) <= width ? full : action, width)
  }

  #syncHeader(lease: AgentTranscriptLease): void {
    if (this.#state.type !== "viewing" || this.#state.lease !== lease || !this.#header) return
    this.#header.snapshot = lease.snapshot().agent
    this.#layoutHeader()
    this.#renderer.requestRender()
  }

  #snapshot(path: AgentPath): AgentSnapshot | undefined {
    return this.#getSession()
      .agentSnapshots()
      .find(snapshot => snapshot.path === path)
  }

  #releaseActive(): void {
    this.#cancelLoadAdmission()
    this.#cancelLoadAdmission = () => {}
    this.#renderer.clearSelection()
    const state = this.#state
    if (state.type === "loading") state.controller.abort()
    if (state.type === "viewing") {
      state.releaseHeader()
      state.view.destroy()
      state.source.dispose()
      state.lease.dispose()
    }
    this.#clearSurface()
  }

  #clearSurface(): void {
    this.#header = undefined
    this.#footer = undefined
    for (const child of this.root.getChildren()) {
      this.root.remove(child)
      if (!child.isDestroyed) child.destroyRecursively()
    }
  }

  #onKeyPress = (key: KeyEvent): void => {
    const state = this.#state
    if (state.type === "root" || state.type === "disposed" || key.defaultPrevented || key.propagationStopped) return
    if (this.#keybindings.matches(key, "app.agentTranscript.return")) {
      consume(key)
      this.close()
      return
    }
    if (state.type !== "viewing") return
    const action = this.#keybindings.transcriptAction(key)
    if (!action || !state.view.handleAction(action)) return
    consume(key)
  }
}

function breadcrumb(path: AgentPath): string {
  return path.split("/").filter(Boolean).join(" › ")
}

function projectHeader(
  path: AgentPath,
  snapshot: AgentSnapshot | undefined,
  phase: "loading" | "unavailable" | undefined,
  width: number
): { readonly breadcrumb: string; readonly status: string } {
  const pathLabel = breadcrumb(path)
  const statuses = headerStatuses(snapshot, phase)
  const minimumBreadcrumb = Math.min(8, Math.floor(width / 2))
  for (const status of statuses) {
    const breadcrumbWidth = width - textWidth(status) - 2
    if (breadcrumbWidth < minimumBreadcrumb) continue
    return { breadcrumb: truncateMiddleToCells(pathLabel, breadcrumbWidth), status }
  }
  return { breadcrumb: "", status: truncateToCells(statuses.at(-1) ?? "unavailable", width) }
}

function headerStatuses(
  snapshot: AgentSnapshot | undefined,
  phase: "loading" | "unavailable" | undefined
): readonly string[] {
  if (!snapshot) return [phase ?? "unavailable"]
  if (phase) return [`${snapshot.agentType} · ${phase}`, phase]
  const lifecycle =
    snapshot.turn === "running"
      ? "working"
      : snapshot.turn === "idle"
        ? snapshot.status === "not_started"
          ? "idle"
          : snapshot.status
        : snapshot.turn
  if (snapshot.turnNumber === 0) return [`${snapshot.agentType} · ${lifecycle}`, lifecycle]
  return [
    `${snapshot.agentType} · ${lifecycle} · turn ${snapshot.turnNumber}`,
    `${lifecycle} · #${snapshot.turnNumber}`,
    `${lifecycle} #${snapshot.turnNumber}`,
    lifecycle
  ]
}

function boundedError(cause: unknown): string {
  const message = cause instanceof Error ? cause.message : String(cause)
  return Buffer.from(message).subarray(0, 2_000).toString("utf8")
}

function consume(key: KeyEvent): void {
  key.preventDefault()
  key.stopPropagation()
}
