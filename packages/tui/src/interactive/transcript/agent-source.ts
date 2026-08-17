import type { AgentTranscriptLease } from "@with-zi/coding-agent"
import { atom, computed } from "nanostores"

import { transitionTranscriptProjection, type TranscriptProjectionState } from "../interactive-store.js"
import type { TranscriptSession, TranscriptSource } from "./source.js"

export interface AgentTranscriptSource extends TranscriptSource {
  dispose(): void
}

export function createAgentTranscriptSource(lease: AgentTranscriptLease, cwd: string): AgentTranscriptSource {
  const initial: TranscriptProjectionState = { promptRevision: 0, transcriptRevision: 0, tools: new Map() }
  const $state = atom(initial)
  const $promptRevision = computed($state, state => state.promptRevision)
  const $transcriptRevision = computed($state, state => state.transcriptRevision)
  const $activeTools = computed($state, state => state.tools)
  let sourceGeneration = 0
  let disposed = false

  const session: TranscriptSession = {
    get messages() {
      return lease.snapshot().messages
    },
    get streamingMessage() {
      return lease.snapshot().streamingMessage
    },
    get isStreaming() {
      return lease.snapshot().isStreaming
    },
    get isAborting() {
      return lease.snapshot().isAborting
    },
    get retryStatus() {
      return lease.snapshot().retryStatus
    },
    get compactionStatus() {
      return lease.snapshot().compactionStatus
    },
    get workPlan() {
      return lease.snapshot().workPlan
    },
    get shellTasks() {
      return lease.snapshot().shellTasks
    },
    sessionManager: { header: { cwd } }
  }

  const release = lease.subscribe(event => {
    if (disposed || event.sourceGeneration < sourceGeneration) return
    const current = $state.get()
    const changedSource = event.sourceGeneration > sourceGeneration
    sourceGeneration = event.sourceGeneration
    const baseline = changedSource ? { ...current, tools: new Map() } : current
    const next =
      event.type === "session"
        ? transitionTranscriptProjection(baseline, event.event)
        : {
            ...baseline,
            promptRevision: baseline.promptRevision + 1,
            transcriptRevision: baseline.transcriptRevision + 1
          }
    if (next !== current) $state.set(next)
  })

  return {
    $promptRevision,
    $transcriptRevision,
    $activeTools,
    getSession() {
      if (disposed) throw new Error("Agent transcript source is disposed")
      return session
    },
    dispose() {
      if (disposed) return
      disposed = true
      release()
    }
  }
}
