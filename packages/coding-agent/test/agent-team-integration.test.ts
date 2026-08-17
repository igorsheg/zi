import { expect, test } from "bun:test"
import { mkdir, mkdtemp, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type { AgentSession } from "../src/agent-session.js"
import type { AgentSnapshot } from "../src/agent-team/agent-team.js"
import { agentCompletionCustomType } from "../src/agent-team/mail.js"
import { parseAgentPath } from "../src/agent-team/path.js"
import {
  createModels,
  createTestAgentRuntime,
  fauxAssistantMessage,
  fauxProvider,
  fauxToolCall
} from "../src/testing.js"

const childPath = "/root/research"

test("production AgentTeam restores one child lazily and continues its journal after restart", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-agent-team-production-"))
  const cwd = join(root, "project")
  const agentDir = join(root, "agent")
  await mkdir(cwd, { recursive: true })
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  let rootTools: readonly string[] = []
  faux.setResponses([
    context => {
      rootTools = (context.tools ?? []).map(tool => tool.name)
      return fauxAssistantMessage(
        fauxToolCall(
          "spawn_agent",
          { task_name: "research", message: "first task", fork_turns: "all" },
          { id: "spawn-research" }
        ),
        { stopReason: "toolUse" }
      )
    },
    fauxAssistantMessage("first child answer"),
    fauxAssistantMessage("root after spawn"),
    fauxAssistantMessage("root received first completion"),
    fauxAssistantMessage(
      fauxToolCall("followup_task", { target: "research", message: "second task" }, { id: "followup-research" }),
      { stopReason: "toolUse" }
    ),
    fauxAssistantMessage("second child answer"),
    fauxAssistantMessage("root after follow-up"),
    fauxAssistantMessage("root received second completion")
  ])

  try {
    const first = await createTestAgentRuntime({ cwd, agentDir, models, session: { type: "new", persist: true } })
    await first.session.prompt("delegate")
    const firstSnapshot = await waitForAgentIdle(first.session, childPath)
    const collaborationTools = new Set([
      "spawn_agent",
      "send_message",
      "followup_task",
      "wait_agent",
      "list_agents",
      "interrupt_agent"
    ])
    expect(rootTools.filter(name => collaborationTools.has(name))).toEqual([
      "spawn_agent",
      "send_message",
      "followup_task",
      "wait_agent",
      "list_agents",
      "interrupt_agent"
    ])
    const childSessionId = firstSnapshot.sessionId
    const rootFile = first.session.sessionManager.file
    expect(rootFile).toBeString()
    expect(completionEntries(first.session)).toHaveLength(1)
    first.session.dispose()
    await first.session.waitForIdle()

    const second = await createTestAgentRuntime({ cwd, agentDir, models, session: { type: "resume", file: rootFile! } })
    expect(second.session.agentSnapshots()).toEqual([
      expect.objectContaining({
        path: childPath,
        sessionId: childSessionId,
        residency: "unloaded",
        status: "completed"
      })
    ])
    expect(completionEntries(second.session)).toHaveLength(1)

    const transcript = await second.session.openAgentTranscript(parseAgentPath(childPath), new AbortController().signal)
    expect(transcript.snapshot()).toMatchObject({
      agent: { path: childPath, residency: "unloaded", status: "completed" },
      isStreaming: false
    })
    expect(transcript.snapshot().messages).toContainEqual(
      expect.objectContaining({ role: "assistant", content: [{ type: "text", text: "first child answer" }] })
    )
    transcript.dispose()

    await second.session.prompt("continue the child")
    const secondSnapshot = await waitForAgentIdle(second.session, childPath)
    expect(secondSnapshot).toMatchObject({ sessionId: childSessionId, residency: "unloaded", status: "completed" })
    expect(completionEntries(second.session)).toHaveLength(2)
    const deliveries = completionEntries(second.session).map(entry => entry.details)
    expect(new Set(deliveries.map(details => JSON.stringify(details))).size).toBe(2)
    second.session.dispose()
    await second.session.waitForIdle()
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test("production AgentTeam restores recursive real sessions with direct-parent completion", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-agent-team-recursive-production-"))
  const cwd = join(root, "project")
  const agentDir = join(root, "agent")
  await mkdir(cwd, { recursive: true })
  const models = createModels()
  const rootProvider = fauxProvider()
  const parentProvider = fauxProvider({ provider: "recursive-parent", models: [{ id: "model", reasoning: true }] })
  const leafProvider = fauxProvider({ provider: "recursive-leaf", models: [{ id: "model", reasoning: true }] })
  models.setProvider(rootProvider.provider)
  models.setProvider(parentProvider.provider)
  models.setProvider(leafProvider.provider)
  let parentObservedNestedCompletion = false
  rootProvider.setResponses([
    fauxAssistantMessage(
      fauxToolCall(
        "spawn_agent",
        { task_name: "research", message: "delegate recursively", model: "recursive-parent/model" },
        { id: "spawn-parent" }
      ),
      { stopReason: "toolUse" }
    ),
    fauxAssistantMessage("root after recursive spawn"),
    fauxAssistantMessage("root received recursive completion")
  ])
  parentProvider.setResponses([
    fauxAssistantMessage(
      fauxToolCall(
        "spawn_agent",
        { task_name: "fact", message: "find the nested fact", model: "recursive-leaf/model" },
        { id: "spawn-fact" }
      ),
      { stopReason: "toolUse" }
    ),
    fauxAssistantMessage(fauxToolCall("wait_agent", { timeout_ms: 1_000 }, { id: "wait-fact" }), {
      stopReason: "toolUse"
    }),
    context => {
      parentObservedNestedCompletion = JSON.stringify(context).includes("Agent completion from /root/research/fact:")
      return fauxAssistantMessage("parent integrated nested evidence")
    }
  ])
  leafProvider.setResponses([fauxAssistantMessage("nested evidence")])

  try {
    const first = await createTestAgentRuntime({ cwd, agentDir, models, session: { type: "new", persist: true } })
    await first.session.prompt("delegate recursively")
    await waitForAgentIdle(first.session, "/root/research")
    await waitForAgentIdle(first.session, "/root/research/fact")
    expect(parentObservedNestedCompletion).toBeTrue()
    expect(completionEntries(first.session)).toHaveLength(1)
    const firstSnapshots = first.session.agentSnapshots()
    expect(firstSnapshots.map(snapshot => String(snapshot.path))).toEqual(["/root/research", "/root/research/fact"])
    const sessionIds = new Map<string, string>(
      firstSnapshots.map(snapshot => [snapshot.path, snapshot.sessionId] as const)
    )
    const rootFile = first.session.sessionManager.file
    expect(rootFile).toBeString()
    first.session.dispose()
    await first.session.waitForIdle()

    const second = await createTestAgentRuntime({ cwd, agentDir, models, session: { type: "resume", file: rootFile! } })
    expect(second.session.agentSnapshots()).toEqual([
      expect.objectContaining({
        path: "/root/research",
        sessionId: sessionIds.get("/root/research"),
        residency: "unloaded",
        status: "completed"
      }),
      expect.objectContaining({
        path: "/root/research/fact",
        sessionId: sessionIds.get("/root/research/fact"),
        parentPath: "/root/research",
        residency: "unloaded",
        status: "completed"
      })
    ])
    expect(completionEntries(second.session)).toHaveLength(1)
    second.session.dispose()
    await second.session.waitForIdle()
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

function completionEntries(session: AgentSession) {
  return session.sessionManager.customMessageEntries().filter(entry => entry.customType === agentCompletionCustomType)
}

async function waitForAgentIdle(session: AgentSession, path: string): Promise<AgentSnapshot> {
  const current = session.agentSnapshots().find(snapshot => snapshot.path === path)
  if (current?.turn === "idle") return current
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      unsubscribe()
      reject(new Error(`Agent did not become idle: ${path}; ${JSON.stringify(session.agentSnapshots())}`))
    }, 2_000)
    const unsubscribe = session.subscribe(event => {
      if (event.type !== "agent_changed" || event.path !== path) return
      const snapshot = session.agentSnapshots().find(candidate => candidate.path === path)
      if (!snapshot || snapshot.turn !== "idle") return
      clearTimeout(timeout)
      unsubscribe()
      resolve(snapshot)
    })
  })
}
