import { expect, test } from "bun:test"

import type { AgentSession, AgentSessionEvent } from "@openzi/coding-agent"
import { createModels, createTestAgentRuntime as createAgentRuntime, fauxProvider } from "@openzi/coding-agent/testing"

import {
  createInteractiveStore,
  initialInteractiveState,
  transitionInteractiveState
} from "../../src/interactive/interactive-store.js"

test("interactive store owns bounded transient tools", async () => {
  const session = await createSession("tools")
  try {
    let state = initialInteractiveState(session)

    for (let index = 0; index < 65; index++) {
      state = transitionInteractiveState(state, toolStarted(`tool-${index}`))
    }

    expect(state.tools).toHaveLength(64)
    expect(state.tools.has("tool-0")).toBe(false)
    expect(state.tools.get("tool-64")).toMatchObject({ status: "running", name: "bash" })
    expect(state.transcriptRevision).toBe(65)
    expect(state.promptRevision).toBe(0)

    state = transitionInteractiveState(state, {
      type: "tool_execution_update",
      toolCallId: "tool-64",
      toolName: "bash",
      args: { command: "pwd" },
      partialResult: { content: [{ type: "text", text: "running" }] }
    })
    expect(state.tools.get("tool-64")).toMatchObject({ status: "running", result: { content: [{ text: "running" }] } })
    expect(state.transcriptRevision).toBe(66)

    state = transitionInteractiveState(state, {
      type: "tool_execution_end",
      toolCallId: "tool-64",
      toolName: "bash",
      result: { content: [{ type: "text", text: "failed" }] },
      isError: true
    })
    expect(state.tools.get("tool-64")).toMatchObject({ status: "failed" })
    expect(state.transcriptRevision).toBe(67)

    state = transitionInteractiveState(state, { type: "queue_update", steering: [], followUp: [] })
    expect(state.promptRevision).toBe(1)
  } finally {
    session.dispose()
  }
})

test("session replacement clears presentation and rejects stale session events", async () => {
  const first = await createSession("first")
  const second = await createSession("second")
  const store = createInteractiveStore(first)

  try {
    first.steer("old session")
    expect(store.$state.get().promptRevision).toBe(1)

    store.replaceSession(second)
    expect(store.$state.get()).toMatchObject({ session: second, generation: 1, promptRevision: 0 })
    expect(store.$state.get().tools).toHaveLength(0)

    first.steer("stale")
    expect(store.$state.get().promptRevision).toBe(0)
    second.steer("current")
    expect(store.$state.get().promptRevision).toBe(1)
  } finally {
    store.dispose()
    first.dispose()
    second.dispose()
  }
})

async function createSession(provider: string): Promise<AgentSession> {
  const models = createModels()
  const faux = fauxProvider({ provider, models: [{ id: "model" }] })
  models.setProvider(faux.provider)
  return (await createAgentRuntime({ cwd: "/work", models, persist: false })).session
}

function toolStarted(toolCallId: string): AgentSessionEvent {
  return { type: "tool_execution_start", toolCallId, toolName: "bash", args: { command: "pwd" } }
}
