import type { AgentSession, SubagentTranscriptSnapshot } from "@with-zi/coding-agent"
import { atom, type WritableAtom } from "nanostores"

import type { ActiveTool } from "./interactive-store.js"
import type { TranscriptSession, TranscriptSource } from "./transcript/source.js"

export class SubagentTranscriptSource implements TranscriptSource {
  readonly $promptRevision: WritableAtom<number> = atom(0)
  readonly $transcriptRevision: WritableAtom<number> = atom(0)
  readonly $activeTools: WritableAtom<ReadonlyMap<string, ActiveTool>> = atom(new Map())

  readonly #parent: AgentSession
  readonly #name: string
  readonly #onUnavailable: () => void
  readonly #viewSession: TranscriptSession
  readonly #release: () => void
  #snapshot: SubagentTranscriptSnapshot
  #disposed = false

  constructor(parent: AgentSession, name: string, onUnavailable: () => void) {
    const snapshot = parent.subagentTranscript(name)
    if (!snapshot) throw new Error(`Subagent ${name} transcript is unavailable`)
    this.#parent = parent
    this.#name = name
    this.#onUnavailable = onUnavailable
    this.#snapshot = snapshot
    const currentSnapshot = () => this.#snapshot
    const currentLifecycle = () => this.#parent.subagentSnapshot(this.#name)?.lifecycle
    const currentCwd = () => this.#parent.sessionManager.header.cwd
    this.#viewSession = {
      get messages() {
        return currentSnapshot().messages
      },
      get streamingMessage() {
        return currentSnapshot().streamingMessage
      },
      get isStreaming() {
        return currentSnapshot().streamingMessage !== undefined
      },
      get isAborting() {
        return currentLifecycle() === "interrupting"
      },
      get retryStatus() {
        return { type: "idle" } as const
      },
      get compactionStatus() {
        return { type: "idle" } as const
      },
      get workPlan() {
        return { revision: 0, steps: [] }
      },
      get sessionManager() {
        return { header: { cwd: currentCwd() } }
      },
      get shellTasks() {
        return []
      },
      subagentSnapshots() {
        return []
      }
    }
    this.#syncTools(snapshot)
    this.#release = parent.subscribe(event => {
      if (event.type !== "subagent_changed" || event.name !== name || this.#disposed) return
      this.#refresh()
    })
  }

  getSession(): TranscriptSession {
    return this.#viewSession
  }

  dispose(): void {
    if (this.#disposed) return
    this.#disposed = true
    this.#release()
  }

  #refresh(): void {
    const snapshot = this.#parent.subagentTranscript(this.#name)
    if (!snapshot) {
      this.#onUnavailable()
      return
    }
    this.#snapshot = snapshot
    this.#syncTools(snapshot)
    this.$promptRevision.set(this.$promptRevision.get() + 1)
    this.$transcriptRevision.set(this.$transcriptRevision.get() + 1)
  }

  #syncTools(snapshot: SubagentTranscriptSnapshot): void {
    const tools = new Map<string, ActiveTool>()
    for (const tool of snapshot.activeTools) {
      switch (tool.status) {
        case "running":
          tools.set(tool.id, {
            id: tool.id,
            name: tool.name,
            args: tool.args,
            status: "running",
            ...(tool.result === undefined ? {} : { result: tool.result })
          })
          break
        case "done":
        case "failed":
          tools.set(tool.id, {
            id: tool.id,
            name: tool.name,
            args: tool.args,
            status: tool.status,
            result: tool.result
          })
          break
        default:
          assertNever(tool.status)
      }
    }
    this.$activeTools.set(tools)
  }
}

function assertNever(value: never): never {
  throw new Error(`Unexpected subagent transcript tool status: ${String(value)}`)
}
