import type { EventEmitter } from "node:events"

import {
  BoxRenderable,
  CliRenderEvents,
  type CliRenderer,
  Renderable,
  TextRenderable,
  TimeToFirstDrawRenderable
} from "@opentui/core"
import type { AgentSession, AgentSessionMemoryDiagnostics } from "@zi/coding-agent"

import type { Theme } from "../theme.js"
import type { TranscriptView } from "./transcript/view.js"

export interface TuiDiagnosticFlags {
  readonly showTimeToFirstDraw: boolean
  readonly showStats: boolean
  readonly showMemory: boolean
}

export interface TuiMemorySnapshot {
  readonly process: {
    readonly rssBytes: number
    readonly heapUsedBytes: number
    readonly heapTotalBytes: number
    readonly externalBytes: number
    readonly arrayBufferBytes: number
  }
  readonly session: AgentSessionMemoryDiagnostics
  readonly renderer: {
    readonly reachableRenderables: number
    readonly registeredRenderables: number
    readonly transcriptRoots: number
    readonly bufferBytes: number
    readonly lifecyclePasses: number
    readonly liveRequests: number
  }
  readonly listeners: { readonly renderer: number; readonly keyInput: number }
}

export function captureTuiMemorySnapshot(
  renderer: CliRenderer,
  session: AgentSession,
  transcriptRoots: number
): TuiMemorySnapshot {
  const memory = process.memoryUsage()
  return {
    process: {
      rssBytes: memory.rss,
      heapUsedBytes: memory.heapUsed,
      heapTotalBytes: memory.heapTotal,
      externalBytes: memory.external,
      arrayBufferBytes: memory.arrayBuffers
    },
    session: session.memoryDiagnostics,
    renderer: {
      reachableRenderables: countRenderables(renderer.root),
      registeredRenderables: Renderable.renderablesByNumber.size,
      transcriptRoots,
      bufferBytes: renderBufferBytes(renderer),
      lifecyclePasses: renderer.getLifecyclePasses().size,
      liveRequests: renderer.liveRequestCount
    },
    listeners: { renderer: countListeners(renderer), keyInput: countListeners(renderer.keyInput) }
  }
}

export class TuiDiagnosticsOverlay {
  readonly root: BoxRenderable

  readonly #renderer: CliRenderer
  readonly #transcript: () => TranscriptView
  readonly #captureMemory: (() => TuiMemorySnapshot) | undefined
  readonly #stats: TextRenderable | undefined
  readonly #memory: TextRenderable | undefined
  #lastStatsUpdate = -Infinity
  #lastMemoryUpdate = -Infinity

  constructor(
    renderer: CliRenderer,
    flags: TuiDiagnosticFlags,
    transcript: () => TranscriptView,
    captureMemory: (() => TuiMemorySnapshot) | undefined,
    theme: Theme
  ) {
    this.#renderer = renderer
    this.#transcript = transcript
    this.#captureMemory = captureMemory
    const height = (flags.showTimeToFirstDraw ? 1 : 0) + (flags.showStats ? 3 : 0) + (flags.showMemory ? 3 : 0)
    this.root = new BoxRenderable(renderer, {
      id: "tui-diagnostics",
      position: "absolute",
      top: 0,
      right: 0,
      zIndex: 10,
      width: 58,
      maxWidth: "100%",
      height,
      flexDirection: "column",
      backgroundColor: theme.surface.panel
    })
    if (flags.showTimeToFirstDraw) {
      this.root.add(
        new TimeToFirstDrawRenderable(renderer, {
          id: "tui-time-to-first-draw",
          label: "First draw",
          precision: 1,
          fg: theme.text.muted
        })
      )
    }
    if (flags.showStats) {
      this.#stats = new TextRenderable(renderer, {
        id: "tui-performance-stats",
        selectable: false,
        fg: theme.text.muted,
        bg: theme.surface.panel,
        wrapMode: "none",
        content: "Collecting renderer statistics…"
      })
      this.root.add(this.#stats)
    }
    if (flags.showMemory) {
      this.#memory = new TextRenderable(renderer, {
        id: "tui-memory-stats",
        selectable: false,
        fg: theme.text.muted,
        bg: theme.surface.panel,
        wrapMode: "none",
        content: "Collecting memory statistics…"
      })
      this.root.add(this.#memory)
    }
    if (this.#stats || this.#memory) renderer.on(CliRenderEvents.FRAME, this.#onFrame)
  }

  destroy(): void {
    this.#renderer.off(CliRenderEvents.FRAME, this.#onFrame)
    this.root.destroyRecursively()
  }

  #onFrame = (): void => {
    if (this.root.isDestroyed) return
    const now = performance.now()
    if (this.#stats && now - this.#lastStatsUpdate >= 250) {
      this.#lastStatsUpdate = now
      this.#updateStats()
    }
    if (this.#memory && this.#captureMemory && now - this.#lastMemoryUpdate >= 3_000) {
      this.#lastMemoryUpdate = now
      this.#updateMemory(this.#captureMemory())
    }
  }

  #updateStats(): void {
    if (!this.#stats) return
    const native = this.#renderer.getStats()
    const view = this.#transcript()
    const transcript = view.diagnostics
    const nativeRender =
      native.nativeRenderTime === undefined ? "n/a" : `${(native.nativeRenderTime / 1000).toFixed(2)}ms`
    this.#stats.content = [
      `Overall avg ${native.averageFrameTime.toFixed(1)} max ${native.maxFrameTime.toFixed(1)} · render ${nativeRender}`,
      `Sync ${transcript.lastSyncMs.toFixed(1)} max ${transcript.maxSyncMs.toFixed(1)}ms · ${transcript.syncPasses}/${transcript.syncRequests}/${transcript.coalescedRequests}`,
      `Nodes ${view.retainedRootCount} · messages ${transcript.projectedMessages} · omitted ${transcript.omittedMessages}`
    ].join("\n")
  }

  #updateMemory(snapshot: TuiMemorySnapshot): void {
    if (!this.#memory) return
    this.#memory.content = [
      `RSS ${formatBytes(snapshot.process.rssBytes)} · heapUsed ${formatBytes(snapshot.process.heapUsedBytes)} · heapTotal ${formatBytes(snapshot.process.heapTotalBytes)}`,
      `Messages ${snapshot.session.committedMessages} · payload ${formatBytes(snapshot.session.committedMessageBytes)} · stream ${formatBytes(snapshot.session.streamingMessageBytes)}`,
      `Renderables ${snapshot.renderer.reachableRenderables}/${snapshot.renderer.registeredRenderables} · transcript ${snapshot.renderer.transcriptRoots} · listeners ${snapshot.listeners.renderer + snapshot.listeners.keyInput}`
    ].join("\n")
  }
}

function countRenderables(root: Renderable): number {
  let count = 0
  const pending = [root]
  while (pending.length > 0) {
    const renderable = pending.pop()
    if (!renderable) continue
    count++
    pending.push(...renderable.getChildren())
  }
  return count
}

function renderBufferBytes(renderer: CliRenderer): number {
  return bufferBytes(renderer.currentRenderBuffer) + bufferBytes(renderer.nextRenderBuffer)
}

function bufferBytes(buffer: CliRenderer["currentRenderBuffer"]): number {
  const buffers = buffer.buffers
  return buffers.char.byteLength + buffers.fg.byteLength + buffers.bg.byteLength + buffers.attributes.byteLength
}

function countListeners(emitter: EventEmitter): number {
  let count = 0
  for (const event of emitter.eventNames()) count += emitter.listenerCount(event)
  return count
}

function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes}B`
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)}K`
  return `${(bytes / (1024 * 1024)).toFixed(1)}M`
}
