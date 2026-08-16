import { expect, test } from "bun:test"
import { mkdtemp, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { parseAgentPath } from "../src/agent-team/path.js"
import { ZiPaths } from "../src/paths.js"
import { agentTaskCustomType, createSessionFork, projectSessionFork } from "../src/session-fork.js"
import { SessionManager } from "../src/session-manager.js"

const research = parseAgentPath("/root/research")

function assistant(text: string, timestamp: number, stopReason: "stop" | "toolUse" = "stop") {
  return {
    role: "assistant" as const,
    content:
      stopReason === "toolUse"
        ? [{ type: "toolCall" as const, id: "tool-1", name: "read", arguments: { path: "file.ts" } }]
        : [{ type: "text" as const, text }],
    api: "test",
    provider: "test",
    model: "model",
    usage: emptyUsage(),
    stopReason,
    timestamp
  }
}

function emptyUsage() {
  return {
    input: 0,
    output: 0,
    cacheRead: 0,
    cacheWrite: 0,
    totalTokens: 0,
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 }
  }
}

test("session forks select all, none, and recent complete turns", () => {
  const parent = SessionManager.inMemory("/work", "root-session")
  parent.appendMessage({ role: "user", content: "first", timestamp: 1 })
  parent.appendMessage(assistant("first answer", 2))
  parent.appendCustomMessage({
    customType: "zi.agent-message.v1",
    content: "queue-only context",
    display: false,
    details: { mailId: "mail-1" }
  })
  parent.appendMessage({ role: "user", content: "second", timestamp: 3 })
  parent.appendMessage(assistant("using tool", 4, "toolUse"))
  parent.appendMessage({
    role: "toolResult",
    toolCallId: "tool-1",
    toolName: "read",
    content: [{ type: "text", text: "result" }],
    isError: false,
    timestamp: 5
  })
  parent.appendMessage(assistant("second answer", 6))
  parent.appendCustomMessage({
    customType: agentTaskCustomType,
    content: "third task",
    display: false,
    details: { mailId: "parent-task" }
  })
  parent.appendMessage(assistant("third answer", 7))

  expect(projectSessionFork(parent.captureForkCheckpoint(), "all").messages.map(message => message.role)).toEqual([
    "user",
    "assistant",
    "user",
    "assistant",
    "toolResult",
    "assistant",
    "custom",
    "assistant"
  ])
  expect(
    projectSessionFork(parent.captureForkCheckpoint(), "all").messages.find(message => message.role === "custom")
  ).toEqual({
    role: "custom",
    customType: agentTaskCustomType,
    content: "third task",
    display: false,
    timestamp: expect.any(Number)
  })
  expect(projectSessionFork(parent.captureForkCheckpoint(), "none").messages).toEqual([])
  expect(projectSessionFork(parent.captureForkCheckpoint(), 1).messages.map(message => message.role)).toEqual([
    "custom",
    "assistant"
  ])
  expect(projectSessionFork(parent.captureForkCheckpoint(), 2).messages.map(message => message.role)).toEqual([
    "user",
    "assistant",
    "toolResult",
    "assistant",
    "custom",
    "assistant"
  ])
})

test("session forks remove an in-flight tool call and count only settled recent turns", () => {
  const parent = SessionManager.inMemory("/work", "root-session")
  parent.appendMessage({ role: "user", content: "settled", timestamp: 1 })
  parent.appendMessage(assistant("settled answer", 2))
  parent.appendMessage({ role: "user", content: "current request", timestamp: 3 })
  parent.appendMessage({
    ...assistant("", 4, "toolUse"),
    content: [{ type: "toolCall", id: "spawn", name: "spawn_agent", arguments: { task_name: "research" } }]
  })

  expect(projectSessionFork(parent.captureForkCheckpoint(), "all").messages.map(message => message.role)).toEqual([
    "user",
    "assistant",
    "user"
  ])
  expect(projectSessionFork(parent.captureForkCheckpoint(), 1).messages).toEqual([
    { role: "user", content: "settled", timestamp: 1 },
    assistant("settled answer", 2)
  ])
})

test("session forks preserve the active compaction checkpoint without resurrecting compacted turns", () => {
  const parent = SessionManager.inMemory("/work", "root-session")
  parent.appendMessage({ role: "user", content: "old", timestamp: 1 })
  parent.appendMessage(assistant("old answer", 2))
  const recent = parent.appendMessage({ role: "user", content: "recent", timestamp: 3 })
  parent.appendMessage(assistant("recent answer", 4))
  parent.appendCompaction({
    reason: "manual",
    summary: "old turn summary",
    firstKeptEntryId: recent.id,
    tokensBefore: 100,
    estimatedTokensAfter: 20,
    details: { readFiles: [], modifiedFiles: [], omittedReadFiles: 0, omittedModifiedFiles: 0 }
  })

  const all = projectSessionFork(parent.captureForkCheckpoint(), "all")
  expect(all.messages.map(message => message.role)).toEqual(["compactionSummary", "user", "assistant"])
  expect(all.messages[0]).toMatchObject({ summary: "old turn summary" })
  expect(projectSessionFork(parent.captureForkCheckpoint(), 1).messages.map(message => message.role)).toEqual([
    "user",
    "assistant"
  ])
})

test("persistent session forks write nested lineage and reopen the same child journal", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-session-fork-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "agent"))
  try {
    const parent = SessionManager.create(paths, { sessionId: "root-session" })
    parent.appendMessage({ role: "user", content: "inspect persistence", timestamp: 1 })
    parent.appendMessage(assistant("parent answer", 2))
    parent.appendModelChange("test", "selected-model")
    parent.appendThinkingLevelChange("high")

    const child = await createSessionFork(parent, paths, {
      path: research,
      rootSessionId: parent.sessionId,
      sessionId: "child-session",
      forkTurns: "all"
    })

    expect(child.file).toBe(join(paths.sessionDir, "agents", parent.sessionId, "child-session.jsonl"))
    expect(child.header.agent).toEqual({
      rootSessionId: parent.sessionId,
      parentSessionId: parent.sessionId,
      parentEntryId: parent.entries().at(-1)!.id,
      path: research,
      generation: 1
    })
    expect(child.buildSessionContext()).toMatchObject({
      model: { provider: "test", modelId: "selected-model" },
      thinkingLevel: "high",
      messages: [
        { role: "user", content: "inspect persistence" },
        { role: "assistant", content: [{ type: "text", text: "parent answer" }] }
      ]
    })

    const restored = SessionManager.openAgent(paths, child.sessionId, child.header.agent!)
    expect(restored.sessionId).toBe(child.sessionId)
    expect(restored.header.agent).toEqual(child.header.agent)
    expect(restored.buildSessionContext()).toEqual(child.buildSessionContext())
    expect(() =>
      SessionManager.openAgent(paths, child.sessionId, { ...child.header.agent!, path: parseAgentPath("/root/other") })
    ).toThrow("Agent session lineage does not match")
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test("an in-memory root keeps its complete fork tree in memory", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-memory-session-fork-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "agent"))
  try {
    const parent = SessionManager.inMemory(paths.cwd, "root-session")
    parent.appendMessage({ role: "user", content: "ephemeral", timestamp: 1 })

    const child = await createSessionFork(parent, paths, {
      path: research,
      rootSessionId: parent.sessionId,
      sessionId: "child-session",
      forkTurns: "none"
    })

    expect(child.file).toBeUndefined()
    expect(child.header.agent?.rootSessionId).toBe(parent.sessionId)
    expect(child.activeMessages()).toEqual([])
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})
