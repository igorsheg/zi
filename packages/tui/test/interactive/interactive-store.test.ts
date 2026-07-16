import { expect, test } from "bun:test"

import type { AgentSession, AgentSessionEvent } from "@openzi/coding-agent"
import {
  createModels,
  createTestAgentRuntime as createAgentRuntime,
  fauxAssistantMessage,
  fauxProvider,
  fauxToolCall
} from "@openzi/coding-agent/testing"

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

test("tool arguments stream through preparing, ready, and running states", async () => {
  const session = await createSession("argument-stream")
  try {
    let state = initialInteractiveState(session)
    const firstPartial = fauxAssistantMessage(
      fauxToolCall("write", { path: "notes.txt", content: "hel" }, { id: "write-1" })
    )
    state = transitionInteractiveState(state, {
      type: "message_update",
      message: firstPartial,
      assistantMessageEvent: { type: "toolcall_delta", contentIndex: 0, delta: "hel", partial: firstPartial }
    })
    expect(state.tools.get("write-1")).toEqual({
      id: "write-1",
      name: "write",
      args: { path: "notes.txt", content: "hel" },
      status: "preparing"
    })

    const complete = fauxAssistantMessage(
      [
        fauxToolCall("write", { path: "notes.txt", content: "hello" }, { id: "write-1" }),
        fauxToolCall("read", { path: "notes.txt" }, { id: "read-1" })
      ],
      { stopReason: "toolUse" }
    )
    state = transitionInteractiveState(state, { type: "message_end", message: complete })
    expect(state.tools.get("write-1")?.status).toBe("ready")
    expect(state.tools.get("write-1")?.args).toEqual({ path: "notes.txt", content: "hello" })
    expect(state.tools.get("read-1")?.status).toBe("ready")

    state = transitionInteractiveState(state, {
      type: "tool_execution_start",
      toolCallId: "write-1",
      toolName: "write",
      args: { path: "notes.txt", content: "hello" }
    })
    expect(state.tools.get("write-1")?.status).toBe("running")
    expect(state.tools.get("read-1")?.status).toBe("ready")
  } finally {
    session.dispose()
  }
})

test("an aborted assistant message settles prepared tool rows", async () => {
  const session = await createSession("argument-abort")
  try {
    const message = fauxAssistantMessage(fauxToolCall("bash", { command: "sleep 10" }, { id: "bash-1" }), {
      stopReason: "aborted",
      errorMessage: "cancelled"
    })
    let state = transitionInteractiveState(initialInteractiveState(session), { type: "message_end", message })
    expect(state.tools.get("bash-1")).toMatchObject({
      status: "aborted",
      result: { content: [{ text: "Operation aborted" }] }
    })

    state = transitionInteractiveState(state, { type: "agent_end", messages: [message] })
    expect(state.tools.get("bash-1")?.status).toBe("aborted")
  } finally {
    session.dispose()
  }
})

test("agent end aborts sequential calls that never started", async () => {
  const session = await createSession("sequential-abort")
  try {
    const assistant = fauxAssistantMessage(
      [
        fauxToolCall("bash", { command: "sleep 10" }, { id: "running" }),
        fauxToolCall("read", { path: "later.txt" }, { id: "waiting" })
      ],
      { stopReason: "toolUse" }
    )
    let state = transitionInteractiveState(initialInteractiveState(session), {
      type: "message_end",
      message: assistant
    })
    state = transitionInteractiveState(state, {
      type: "tool_execution_start",
      toolCallId: "running",
      toolName: "bash",
      args: { command: "sleep 10" }
    })
    state = transitionInteractiveState(state, {
      type: "tool_execution_end",
      toolCallId: "running",
      toolName: "bash",
      result: { content: [{ type: "text", text: "Operation aborted" }] },
      isError: true
    })
    state = transitionInteractiveState(state, {
      type: "message_end",
      message: {
        role: "toolResult",
        toolCallId: "running",
        toolName: "bash",
        content: [{ type: "text", text: "Operation aborted" }],
        isError: true,
        timestamp: 2
      }
    })
    state = transitionInteractiveState(state, { type: "agent_end", messages: [assistant] })

    expect(state.tools).toHaveLength(1)
    expect(state.tools.get("waiting")).toMatchObject({
      status: "aborted",
      result: { content: [{ text: "Operation aborted" }] }
    })
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
