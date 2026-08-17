import { expect, test } from "bun:test"

import {
  parseAgentPath,
  type AgentTranscriptEvent,
  type AgentTranscriptLease,
  type AgentTranscriptSnapshot
} from "@with-zi/coding-agent"

import { createAgentTranscriptSource } from "../../src/interactive/transcript/agent-source.js"

const path = parseAgentPath("/root/research")
const parentPath = parseAgentPath("/root")

class TranscriptLease implements AgentTranscriptLease {
  readonly path = path
  readonly #listeners = new Set<(event: AgentTranscriptEvent) => void>()
  released = false

  snapshot(): AgentTranscriptSnapshot {
    return {
      agent: {
        path,
        parentPath,
        sessionId: "research-session",
        taskName: "research",
        agentType: "explorer",
        generation: 1,
        residency: "resident",
        turn: "running",
        turnNumber: 2,
        status: "not_started"
      },
      messages: [{ role: "user", content: "inspect", timestamp: 1 }],
      streamingMessage: undefined,
      isStreaming: false,
      isAborting: false,
      retryStatus: { type: "idle" },
      compactionStatus: { type: "idle" },
      workPlan: { revision: 0, steps: [] },
      shellTasks: []
    }
  }

  subscribe(listener: (event: AgentTranscriptEvent) => void): () => void {
    this.#listeners.add(listener)
    return () => {
      this.released = true
      this.#listeners.delete(listener)
    }
  }

  dispose(): void {}

  emit(event: AgentTranscriptEvent): void {
    for (const listener of this.#listeners) listener(event)
  }
}

test("agent transcript source keeps session identity across live handoffs and fences stale tool events", () => {
  const lease = new TranscriptLease()
  const source = createAgentTranscriptSource(lease, "/work")
  const session = source.getSession()

  lease.emit({
    type: "session",
    sourceGeneration: 1,
    event: { type: "tool_execution_start", toolCallId: "first", toolName: "read", args: { path: "first.ts" } }
  })
  expect(source.$activeTools.get().get("first")).toMatchObject({ status: "running", name: "read" })
  const liveRevision = source.$transcriptRevision.get()

  lease.emit({ type: "agent_changed", sourceGeneration: 2 })
  expect(source.getSession()).toBe(session)
  expect(source.$activeTools.get()).toHaveLength(0)
  expect(source.$transcriptRevision.get()).toBeGreaterThan(liveRevision)

  lease.emit({
    type: "session",
    sourceGeneration: 1,
    event: { type: "tool_execution_start", toolCallId: "stale", toolName: "read", args: { path: "stale.ts" } }
  })
  expect(source.$activeTools.get()).toHaveLength(0)

  lease.emit({
    type: "session",
    sourceGeneration: 3,
    event: { type: "tool_execution_start", toolCallId: "next", toolName: "read", args: { path: "next.ts" } }
  })
  expect(source.$activeTools.get().get("next")).toMatchObject({ status: "running", name: "read" })

  source.dispose()
  expect(lease.released).toBeTrue()
  expect(() => source.getSession()).toThrow("Agent transcript source is disposed")
})
