import { expect, test } from "bun:test"
import { existsSync } from "node:fs"
import {
  appendFile,
  mkdir,
  mkdtemp,
  readFile,
  readdir,
  rename,
  rm,
  truncate,
  utimes,
  writeFile
} from "node:fs/promises"
import { tmpdir } from "node:os"
import { join, relative, resolve } from "node:path"

import { ZiPaths } from "../src/paths.js"
import {
  maxCustomJsonBytes,
  maxCustomJsonDepth,
  maxCustomMessageBytes,
  maxCustomStateEntries,
  maxSessionFileBytes,
  maxSessionFirstMessageLength,
  maxSessionPromptHistoryEntries,
  maxSessionPromptHistoryEntryBytes,
  maxSessionStorageBytes,
  CustomStateCapacityError,
  SessionCapacityError,
  SessionManager,
  type SessionJson
} from "../src/session-manager.js"

test("session entries form one append-only branch", () => {
  const session = SessionManager.inMemory("/work")

  const model = session.appendModelChange("anthropic", "claude")
  const thinking = session.appendThinkingLevelChange("medium")
  const message = session.appendMessage({ role: "user", content: "hello", timestamp: 1 })
  const entries = session.entries()

  expect(entries.map(entry => entry.id)).toEqual([model.id, thinking.id, message.id])
  expect(entries.map(entry => entry.parentId)).toEqual([null, model.id, thinking.id])
  expect(session.messages()).toEqual([{ role: "user", content: "hello", timestamp: 1 }])
})

test("native subagent journal evidence restores and rejects malformed variants", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-subagent-journal-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "agent"))
  const session = SessionManager.create(paths)
  session.appendSubagent({ event: "starting", agentId: "agent-1", definitionName: "general" })
  session.appendSubagent({ event: "work_cycle_started", agentId: "agent-1", workCycle: 1 })
  session.appendSubagent({
    event: "work_cycle_finished",
    agentId: "agent-1",
    workCycle: 1,
    status: "completed",
    preview: "done",
    originalBytes: 4,
    omittedBytes: 0,
    truncated: false,
    durationMs: 10
  })
  expect(SessionManager.open(session.file!).subagentEntries()).toMatchObject([
    { event: "starting", agentId: "agent-1" },
    { event: "work_cycle_started", workCycle: 1 },
    { event: "work_cycle_finished", status: "completed", preview: "done" }
  ])

  const malformed: unknown = JSON.parse((await readFile(session.file!, "utf8")).trim().split("\n").at(-1)!)
  if (typeof malformed !== "object" || malformed === null || Array.isArray(malformed)) {
    throw new Error("Expected a journal entry object")
  }
  Reflect.set(malformed, "status", "unknown")
  await appendFile(
    session.file!,
    `${JSON.stringify({ ...malformed, id: crypto.randomUUID(), parentId: Reflect.get(malformed, "id") })}\n`
  )
  expect(() => SessionManager.open(session.file!)).toThrow("Invalid session entry")
  await rm(root, { recursive: true, force: true })
})

test("session prompt history traverses trimmed text chronologically with consecutive deduplication", () => {
  const session = SessionManager.inMemory("/work")
  expect(session.latestPromptHistoryEntry()).toBeUndefined()

  const first = session.appendMessage({ role: "user", content: "  first\nline  ", timestamp: 1 })
  session.appendMessage({ role: "user", content: "first\nline", timestamp: 2 })
  session.appendMessage({ role: "user", content: "   ", timestamp: 3 })
  session.appendMessage({
    role: "user",
    content: [
      { type: "text", text: "mixed" },
      { type: "image", mimeType: "image/png", data: "AAAA" },
      { type: "text", text: " prompt" }
    ],
    timestamp: 4
  })
  session.appendMessage({
    role: "user",
    content: [{ type: "image", mimeType: "image/png", data: "BBBB" }],
    timestamp: 5
  })
  const repeated = session.appendMessage({ role: "user", content: "first\nline", timestamp: 6 })

  expect(session.latestPromptHistoryEntry()).toEqual({ entryId: repeated.id, text: "first\nline" })
  const mixed = session.olderPromptHistoryEntry(repeated.id)
  expect(mixed?.text).toBe("mixed prompt")
  expect(session.olderPromptHistoryEntry(mixed!.entryId)).toEqual({ entryId: first.id, text: "first\nline" })
  expect(session.olderPromptHistoryEntry(first.id)).toBeUndefined()
  expect(session.olderPromptHistoryEntry("missing")).toBeUndefined()
})

test("session prompt history is bounded by values and rejects oversized text", () => {
  const session = SessionManager.inMemory("/work")
  session.appendMessage({
    role: "user",
    content: [
      { type: "text", text: "x".repeat(maxSessionPromptHistoryEntryBytes) },
      { type: "text", text: "x" }
    ],
    timestamp: 0
  })
  expect(session.latestPromptHistoryEntry()).toBeUndefined()

  const entries = Array.from({ length: maxSessionPromptHistoryEntries + 2 }, (_, index) =>
    session.appendMessage({ role: "user", content: `prompt-${index}`, timestamp: index + 1 })
  )
  const history = promptHistory(session)

  expect(history).toHaveLength(maxSessionPromptHistoryEntries)
  expect(history[0]).toEqual({ entryId: entries.at(-1)!.id, text: `prompt-${entries.length - 1}` })
  expect(history.at(-1)).toEqual({ entryId: entries[2]!.id, text: "prompt-2" })
  expect(session.olderPromptHistoryEntry(entries[1]!.id)).toBeUndefined()
})

test("session prompt history evicts oldest values at its aggregate byte bound", () => {
  const session = SessionManager.inMemory("/work")
  const entries = Array.from({ length: 9 }, (_, index) =>
    session.appendMessage({
      role: "user",
      content: String(index).repeat(maxSessionPromptHistoryEntryBytes),
      timestamp: index
    })
  )

  const history = promptHistory(session)
  expect(history).toHaveLength(8)
  expect(history[0]?.entryId).toBe(entries[8]!.id)
  expect(history.at(-1)?.entryId).toBe(entries[1]!.id)
})

test("session prompt history survives compaction, append, and journal restore by stable entry ID", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-session-prompt-history-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "global"))
  const session = SessionManager.create(paths)
  const old = session.appendMessage({ role: "user", content: " old ", timestamp: 1 })
  session.appendMessage(assistantMessage(2))
  const kept = session.appendMessage({ role: "user", content: "kept", timestamp: 3 })
  session.appendCompaction({
    reason: "manual",
    summary: "summary",
    firstKeptEntryId: kept.id,
    tokensBefore: 100,
    estimatedTokensAfter: 10,
    details: emptyCompactionDetails()
  })
  const latest = session.latestPromptHistoryEntry()!
  const appended = session.appendMessage({ role: "user", content: "new", timestamp: 4 })

  expect(session.olderPromptHistoryEntry(latest.entryId)).toEqual({ entryId: old.id, text: "old" })
  expect(session.olderPromptHistoryEntry(appended.id)).toEqual(latest)
  expect(session.activeMessages().some(message => message.role === "user" && message.content === "old")).toBe(false)

  const restored = SessionManager.open(session.file!)
  expect(promptHistory(restored)).toEqual(promptHistory(session))
})

test("session context derives resumable model and thinking state from the journal", () => {
  const session = SessionManager.inMemory("/work")
  expect(session.buildSessionContext()).toEqual({ messages: [] })

  session.appendMessage({ role: "user", content: "hello", timestamp: 1 })
  session.appendMessage({ ...assistantMessage(2), provider: "derived", model: "answer-model" })
  session.appendThinkingLevelChange("high")

  expect(session.buildSessionContext()).toEqual({
    messages: [
      { role: "user", content: "hello", timestamp: 1 },
      { ...assistantMessage(2), provider: "derived", model: "answer-model" }
    ],
    model: { provider: "derived", modelId: "answer-model" },
    thinkingLevel: "high"
  })
})

test("new persisted sessions wait for the first assistant response before creating a journal", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-session-lazy-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "global"))
  const session = SessionManager.create(paths)
  const file = session.file!

  session.appendModelChange("anthropic", "claude")
  session.appendThinkingLevelChange("medium")
  expect(existsSync(file)).toBe(false)

  session.appendMessage({ role: "user", content: "hello", timestamp: 1 })
  expect(existsSync(file)).toBe(false)

  session.appendMessage({
    role: "assistant",
    content: [],
    api: "test",
    provider: "test",
    model: "test",
    usage: emptyUsage(),
    stopReason: "stop",
    timestamp: 2
  })

  expect(existsSync(file)).toBe(true)
  expect(SessionManager.open(file).entries()).toEqual(session.entries())
})

test("custom state and messages keep durability, context, and presentation independent", () => {
  const session = SessionManager.inMemory("/work")
  const stateData = { count: 1 }
  const messageDetails = { source: "test" }
  const state = session.appendCustomEntry("example.counter", stateData)
  const hidden = session.appendCustomMessage({
    customType: "example.policy",
    content: "hidden model context",
    display: false,
    details: messageDetails
  })
  const displayed = session.appendCustomMessage({
    customType: "example.notice",
    content: [{ type: "text", text: "visible model context" }],
    display: true
  })
  stateData.count = 2
  messageDetails.source = "mutated"

  expect(session.entries().map(entry => entry.type)).toEqual(["custom", "custom_message", "custom_message"])
  expect(session.customEntries("example.counter")).toEqual([state])
  expect(session.activeMessages()).toEqual([
    {
      role: "custom",
      customType: "example.policy",
      content: "hidden model context",
      display: false,
      details: { source: "test" },
      timestamp: new Date(hidden.timestamp).getTime()
    },
    {
      role: "custom",
      customType: "example.notice",
      content: [{ type: "text", text: "visible model context" }],
      display: true,
      timestamp: new Date(displayed.timestamp).getTime()
    }
  ])
  expect(session.presentationMessages()).toEqual([session.activeMessages()[1]!])
  expect(() =>
    session.appendMessage({ role: "custom", customType: "legacy", content: "new write", display: true, timestamp: 1 })
  ).toThrow("appendCustomMessage")
})

test("journal-owned custom values cannot be mutated through entries or projections", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-session-custom-immutable-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "global"))
  const session = SessionManager.create(paths)
  const state = session.appendCustomEntry("example.state", { nested: { count: 1 } })
  const message = session.appendCustomMessage({
    customType: "example.message",
    content: [{ type: "text", text: "original" }],
    display: true,
    details: { nested: { enabled: true } }
  })
  const projected = session.activeMessages().find(candidate => candidate.role === "custom")
  if (!projected || projected.role !== "custom") throw new Error("Expected custom projection")

  expect(Reflect.set(jsonObject(jsonObject(state.data).nested), "count", 2)).toBe(false)
  const current = session.customEntries("example.state")[0]!
  expect(Reflect.set(jsonObject(jsonObject(current.data).nested), "count", 3)).toBe(false)
  expect(Reflect.set(jsonObject(jsonObject(message.details).nested), "enabled", false)).toBe(false)
  const content = projected.content
  if (!Array.isArray(content) || content[0]?.type !== "text") throw new Error("Expected text content")
  expect(Reflect.set(content[0], "text", "mutated")).toBe(false)

  const restored = SessionManager.open(session.file!)
  expect(session.customEntries("example.state")).toEqual(restored.customEntries("example.state"))
  expect(session.activeMessages()).toEqual(restored.activeMessages())
})

test("the first custom append flushes pending persistence and restores folded state", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-session-custom-persistence-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "global"))
  const session = SessionManager.create(paths)
  const state = session.appendCustomEntry("example.counter", { count: 1 })
  expect(existsSync(session.file!)).toBe(true)

  session.appendMessage({ role: "user", content: "old", timestamp: 1 })
  const kept = session.appendMessage({ role: "user", content: "kept", timestamp: 2 })
  session.appendCompaction({
    reason: "manual",
    summary: "summary",
    firstKeptEntryId: kept.id,
    tokensBefore: 100,
    estimatedTokensAfter: 10,
    details: emptyCompactionDetails()
  })

  expect(session.retainedEntries().some(entry => entry.id === state.id)).toBe(false)
  expect(session.customEntries("example.counter")).toEqual([state])
  const restored = SessionManager.open(session.file!)
  expect(restored.customEntries("example.counter")).toEqual([state])
  expect(restored.retainedEntries().some(entry => entry.id === state.id)).toBe(false)
})

test("custom message images share format-2 session blob ownership", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-session-custom-image-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "global"))
  const session = SessionManager.create(paths)
  const image = Buffer.from("custom image payload")
  const data = image.toString("base64")
  session.appendCustomMessage({
    customType: "example.image",
    content: [{ type: "image", mimeType: "image/png", data }],
    display: true
  })

  const file = session.file!
  const persisted = await readFile(file, "utf8")
  const blobDir = file.replace(/\.jsonl$/u, ".blobs")
  const blobs = await readdir(blobDir)
  expect(persisted).not.toContain(data)
  expect(persisted).toContain('"type":"custom_message"')
  expect(blobs).toHaveLength(1)
  expect((await readFile(join(blobDir, blobs[0]!))).equals(image)).toBe(true)
  expect(SessionManager.open(file).activeMessages()).toEqual(session.activeMessages())
})

test("custom values and aggregate state reject before journal mutation", () => {
  const session = SessionManager.inMemory("/work")
  const entries = session.entries()
  expect(() => session.appendCustomEntry("Invalid Type", null)).toThrow("Custom type")
  expect(() => session.appendCustomEntry("example.large", "x".repeat(maxCustomJsonBytes))).toThrow(
    "Invalid session entry"
  )
  expect(() =>
    session.appendCustomMessage({
      customType: "example.large",
      content: "x".repeat(maxCustomMessageBytes + 1),
      display: true
    })
  ).toThrow("Invalid custom message")

  let nested: SessionJson = null
  for (let depth = 0; depth < maxCustomJsonDepth; depth++) nested = [nested]
  expect(() => session.appendCustomEntry("example.deep", nested)).toThrow("Invalid session entry")
  expect(session.entries()).toBe(entries)

  for (let index = 0; index < maxCustomStateEntries; index++) {
    session.appendCustomEntry("example.count", null)
  }
  expect(() => session.appendCustomEntry("example.count", null)).toThrow(CustomStateCapacityError)
  expect(session.customEntries("example.count")).toHaveLength(maxCustomStateEntries)
})

test("restore preserves legacy custom messages but rejects unknown fields on new custom kinds", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-session-custom-restore-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "global"))
  const legacy = SessionManager.create(paths, { sessionId: "legacy-custom" })
  const parent = legacy.appendCustomEntry("example.state", null)
  await appendFile(
    legacy.file!,
    `${JSON.stringify({
      type: "message",
      id: "legacy-message",
      parentId: parent.id,
      timestamp: new Date().toISOString(),
      message: {
        role: "custom",
        customType: "legacy.notice",
        content: "legacy hidden context",
        display: false,
        timestamp: 1
      }
    })}\n`
  )
  const restored = SessionManager.open(legacy.file!)
  expect(restored.activeMessages()).toContainEqual({
    role: "custom",
    customType: "legacy.notice",
    content: "legacy hidden context",
    display: false,
    timestamp: 1
  })
  expect(restored.presentationMessages()).toEqual([])

  const strict = SessionManager.create(paths, { sessionId: "strict-custom" })
  strict.appendCustomEntry("example.state", null)
  const records = (await readFile(strict.file!, "utf8")).trimEnd().split("\n")
  const entry = JSON.parse(records[1]!)
  entry.unknown = true
  records[1] = JSON.stringify(entry)
  await writeFile(strict.file!, `${records.join("\n")}\n`)
  expect(() => SessionManager.open(strict.file!)).toThrow("Invalid session entry")
})

test("restore rejects invalid custom entry timestamps", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-session-custom-timestamp-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "global"))

  for (const kind of ["custom", "custom_message"] as const) {
    const session = SessionManager.create(paths, { sessionId: `invalid-${kind}` })
    if (kind === "custom") session.appendCustomEntry("example.state", null)
    else session.appendCustomMessage({ customType: "example.message", content: "message", display: true })
    // Each mutation must finish before the same path is reopened.
    // oxlint-disable-next-line no-await-in-loop
    const records = (await readFile(session.file!, "utf8")).trimEnd().split("\n")
    const entry = JSON.parse(records[1]!)
    entry.timestamp = "not-a-date"
    records[1] = JSON.stringify(entry)
    // oxlint-disable-next-line no-await-in-loop
    await writeFile(session.file!, `${records.join("\n")}\n`)
    expect(() => SessionManager.open(session.file!)).toThrow("Invalid session entry")
  }
})

test("a failed first journal write leaves pending entries retryable", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-session-lazy-failure-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "global"))
  const session = SessionManager.create(paths)
  const file = session.file!
  session.appendModelChange("anthropic", "claude")
  session.appendMessage({ role: "user", content: "hello", timestamp: 1 })
  const before = [...session.entries()]
  await mkdir(file, { recursive: true })

  expect(() => session.appendMessage(assistantMessage(2))).toThrow()
  expect(session.entries()).toEqual(before)

  await rm(file, { recursive: true })
  session.appendMessage(assistantMessage(2))
  expect(SessionManager.open(file).entries()).toEqual(session.entries())
})

test("compaction markers project one latest summary and an exact retained tail", () => {
  const session = SessionManager.inMemory("/work")
  const oldUser = session.appendMessage({ role: "user", content: "old", timestamp: 1 })
  session.appendMessage({
    role: "assistant",
    content: [],
    api: "test",
    provider: "test",
    model: "test",
    usage: emptyUsage(),
    stopReason: "stop",
    timestamp: 2
  })
  const keptUser = session.appendMessage({ role: "user", content: "kept", timestamp: 3 })
  const keptAssistant = session.appendMessage({
    role: "assistant",
    content: [],
    api: "test",
    provider: "test",
    model: "test",
    usage: emptyUsage(),
    stopReason: "stop",
    timestamp: 4
  })
  session.appendCompaction({
    reason: "manual",
    summary: "first summary",
    firstKeptEntryId: keptUser.id,
    tokensBefore: 100,
    estimatedTokensAfter: 20,
    details: emptyCompactionDetails()
  })
  session.appendMessage({ role: "user", content: "new", timestamp: 5 })
  session.appendCompaction({
    reason: "threshold",
    summary: "latest summary",
    firstKeptEntryId: keptAssistant.id,
    tokensBefore: 120,
    estimatedTokensAfter: 18,
    details: emptyCompactionDetails()
  })

  expect(session.entries()[0]?.id).toBe(oldUser.id)
  expect(session.activeMessages().map(message => message.role)).toEqual(["compactionSummary", "assistant", "user"])
  expect(session.activeMessages()[0]).toMatchObject({ summary: "latest summary", estimatedTokensAfter: 18 })
  expect(session.presentationMessages().map(message => message.role)).toEqual([
    "assistant",
    "user",
    "compactionSummary"
  ])
  expect(session.presentationMessages().at(-1)).toMatchObject({ summary: "latest summary", estimatedTokensAfter: 18 })
})

test("a compaction marker cannot become a later exact-tail boundary", () => {
  const session = SessionManager.inMemory("/work")
  session.appendMessage({ role: "user", content: "old", timestamp: 1 })
  const kept = session.appendMessage({ role: "user", content: "kept", timestamp: 2 })
  const marker = session.appendCompaction({
    reason: "manual",
    summary: "first",
    firstKeptEntryId: kept.id,
    tokensBefore: 100,
    estimatedTokensAfter: 10,
    details: emptyCompactionDetails()
  })

  expect(() =>
    session.appendCompaction({
      reason: "threshold",
      summary: "second",
      firstKeptEntryId: marker.id,
      tokensBefore: 100,
      estimatedTokensAfter: 9,
      details: emptyCompactionDetails()
    })
  ).toThrow("Invalid compaction boundary")
})

test("persisted compaction markers restore the same active projection", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-session-compaction-restore-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "global"))
  const session = SessionManager.create(paths)
  session.appendMessage({ role: "user", content: "old", timestamp: 1 })
  session.appendMessage(assistantMessage(2))
  const kept = session.appendMessage({ role: "user", content: "kept", timestamp: 3 })
  session.appendCompaction({
    reason: "manual",
    summary: "restored summary",
    firstKeptEntryId: kept.id,
    tokensBefore: 100,
    estimatedTokensAfter: 10,
    details: emptyCompactionDetails()
  })

  const restored = SessionManager.open(session.file!)
  expect(restored.activeMessages()).toEqual(session.activeMessages())
  expect(restored.entries()).toHaveLength(4)
})

test("overflow failures remain durable but are omitted from active context", () => {
  const session = SessionManager.inMemory("/work")
  const prompt = session.appendMessage({ role: "user", content: "retry me", timestamp: 1 })
  const failure = session.appendMessage({
    role: "assistant",
    content: [{ type: "text", text: "too long" }],
    api: "test",
    provider: "test",
    model: "test",
    usage: emptyUsage(),
    stopReason: "error",
    errorMessage: "context length exceeded",
    timestamp: 2
  })
  session.appendCompaction({
    reason: "overflow",
    summary: "retry summary",
    firstKeptEntryId: prompt.id,
    tokensBefore: 200,
    estimatedTokensAfter: 10,
    details: emptyCompactionDetails(),
    excludedFailureEntryId: failure.id
  })

  expect(session.messages()).toHaveLength(2)
  expect(session.activeMessages().map(message => message.role)).toEqual(["compactionSummary", "user"])
})

test("presentation retains messages excluded only from provider context", () => {
  const session = SessionManager.inMemory("/work")
  const bash = {
    role: "bashExecution" as const,
    command: "printf evidence",
    output: "evidence",
    truncated: false,
    exitCode: 0,
    cancelled: false,
    excludeFromContext: true,
    timestamp: 1
  }
  session.appendMessage(bash)

  expect(session.activeMessages()).toEqual([])
  expect(session.presentationMessages()).toEqual([bash])
})

test("retry markers durably exclude failed attempts from active context", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-session-retry-restore-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "global"))
  const session = SessionManager.create(paths)
  const presentation = session.presentationMessages()
  session.appendMessage({ role: "user", content: "retry me", timestamp: 1 })
  const failure = session.appendMessage({
    role: "assistant",
    content: [{ type: "text", text: "partial" }],
    api: "test",
    provider: "test",
    model: "test",
    usage: emptyUsage(),
    stopReason: "error",
    errorMessage: "network error",
    timestamp: 2
  })
  session.appendRetry(failure.id, 1)
  session.appendMessage(assistantMessage(3))

  expect(session.messages()).toHaveLength(3)
  expect(session.activeMessages().map(message => message.role)).toEqual(["user", "assistant"])
  expect(session.presentationMessages()).toBe(presentation)
  expect(session.presentationMessages().map(message => message.role)).toEqual(["user", "assistant", "assistant"])

  const restored = SessionManager.open(session.file!)
  expect(restored.activeMessages()).toEqual(session.activeMessages())
  expect(restored.presentationMessages()).toEqual(session.presentationMessages())
  expect(restored.entries().map(entry => entry.type)).toEqual(["message", "message", "retry", "message"])
})

test("compaction boundaries cannot begin with a tool result after retry exclusions", () => {
  const session = SessionManager.inMemory("/work")
  session.appendMessage({ role: "user", content: "retry", timestamp: 1 })
  const failure = session.appendMessage({
    role: "assistant",
    content: [{ type: "toolCall", id: "failed-call", name: "read", arguments: { path: "file" } }],
    api: "test",
    provider: "test",
    model: "test",
    usage: emptyUsage(),
    stopReason: "error",
    errorMessage: "network error",
    timestamp: 2
  })
  session.appendRetry(failure.id, 1)
  session.appendMessage({
    role: "toolResult",
    toolCallId: "failed-call",
    toolName: "read",
    content: [{ type: "text", text: "result" }],
    isError: false,
    timestamp: 3
  })

  expect(() =>
    session.appendCompaction({
      reason: "manual",
      summary: "summary",
      firstKeptEntryId: failure.id,
      tokensBefore: 100,
      estimatedTokensAfter: 10,
      details: emptyCompactionDetails()
    })
  ).toThrow("Invalid compaction boundary")
})

test("opening rejects completed compaction markers with invalid semantic references", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-session-invalid-compaction-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "global"))
  const session = SessionManager.create(paths)
  session.appendMessage({ role: "user", content: "kept", timestamp: 1 })
  const assistant = session.appendMessage(assistantMessage(2))
  const invalid = {
    type: "compaction",
    id: "invalid-marker",
    parentId: assistant.id,
    timestamp: new Date().toISOString(),
    reason: "manual",
    summary: "summary",
    firstKeptEntryId: "missing",
    tokensBefore: 10,
    estimatedTokensAfter: 5,
    details: emptyCompactionDetails()
  }
  await appendFile(session.file!, `${JSON.stringify(invalid)}\n`)

  expect(() => SessionManager.open(session.file!)).toThrow("Invalid compaction boundary")
})

test("compaction append failure leaves the in-memory leaf unchanged", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-session-append-failure-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "global"))
  const session = SessionManager.create(paths)
  session.appendMessage({ role: "user", content: "old", timestamp: 1 })
  const kept = session.appendMessage({ role: "user", content: "kept", timestamp: 2 })
  session.appendMessage(assistantMessage(3))
  const before = [...session.entries()]
  const file = session.file!
  await rename(file, `${file}.saved`)
  await mkdir(file)

  expect(() =>
    session.appendCompaction({
      reason: "manual",
      summary: "summary",
      firstKeptEntryId: kept.id,
      tokensBefore: 10,
      estimatedTokensAfter: 5,
      details: emptyCompactionDetails()
    })
  ).toThrow()
  expect(session.entries()).toEqual(before)
})

test("persisted and explicitly opened session paths are canonical", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-session-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "global"), "sessions")
  const created = SessionManager.create(paths)
  const file = created.file
  if (!file) throw new Error("Session file was not created")
  created.appendMessage({ role: "user", content: "persist", timestamp: 1 })
  created.appendMessage(assistantMessage(2))

  const opened = SessionManager.open(relative(process.cwd(), file))

  expect(file).toBe(join(resolve(paths.cwd), "sessions", `${created.sessionId}.jsonl`))
  expect(opened.file).toBe(file)
  expect(opened.header.cwd).toBe(resolve(paths.cwd))
})

test("format 1 journals remain readable and keep inline images on append", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-session-v1-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "global"))
  const created = SessionManager.create(paths)
  created.appendMessage({ role: "user", content: "legacy", timestamp: 1 })
  created.appendMessage(assistantMessage(2))
  const file = created.file!
  const content = await readFile(file, "utf8")
  await writeFile(file, content.replace('"version":2', '"version":1'))

  const restored = SessionManager.open(file)
  const data = Buffer.from("legacy image").toString("base64")
  restored.appendMessage({ role: "user", content: [{ type: "image", mimeType: "image/png", data }], timestamp: 3 })

  expect(restored.header.version).toBe(1)
  expect(await readFile(file, "utf8")).toContain(data)
  expect(restored.messages().at(-1)).toMatchObject({ role: "user", content: [{ data }] })
})

test("session listing reads only bounded recent metadata and isolates invalid journals", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-session-list-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "global"))
  const first = SessionManager.create(paths, { sessionId: "first" })
  first.appendMessage({ role: "user", content: "  first\n  task  ", timestamp: 1 })
  first.appendMessage(assistantMessage(2))
  const second = SessionManager.create(paths, { sessionId: "second" })
  second.appendMessage({ role: "user", content: "x".repeat(maxSessionFirstMessageLength + 20), timestamp: 2 })
  second.appendMessage(assistantMessage(3))
  const otherPaths = new ZiPaths(join(root, "other-project"), join(root, "global"), paths.sessionDir)
  const other = SessionManager.create(otherPaths, { sessionId: "other-project" })
  other.appendMessage({ role: "user", content: "other", timestamp: 1 })
  other.appendMessage(assistantMessage(2))
  const invalid = join(paths.sessionDir, "invalid.jsonl")
  await writeFile(invalid, "not json\n")
  await utimes(first.file!, new Date(1_000), new Date(1_000))
  await utimes(second.file!, new Date(3_000), new Date(3_000))
  await utimes(invalid, new Date(4_000), new Date(4_000))

  const result = await SessionManager.list(paths, { limit: 1 })

  expect(result.invalid).toBe(1)
  expect(result.omitted).toBe(2)
  expect(result.sessions).toHaveLength(1)
  expect(result.sessions[0]).toMatchObject({ id: "second", cwd: paths.cwd })
  expect(result.sessions[0]!.firstMessage).toHaveLength(maxSessionFirstMessageLength)
  expect(result.sessions[0]!.firstMessage.endsWith("…")).toBe(true)
})

test("continue recent opens the newest valid session or creates the first one", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-session-continue-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "global"))

  const created = await SessionManager.continueRecent(paths)
  expect(created.file).toBeDefined()
  created.appendMessage({ role: "user", content: "continue me", timestamp: 1 })
  created.appendMessage(assistantMessage(2))

  const continued = await SessionManager.continueRecent(paths)
  expect(continued.sessionId).toBe(created.sessionId)
  expect(continued.messages()).toEqual([{ role: "user", content: "continue me", timestamp: 1 }, assistantMessage(2)])
})

test("opening a session ignores only a malformed unterminated tail", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-session-tail-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "global"))
  const created = SessionManager.create(paths)
  const file = created.file!
  created.appendMessage({ role: "user", content: "kept", timestamp: 1 })
  created.appendMessage(assistantMessage(2))
  await appendFile(file, '{"type":"message","id":"torn"')

  expect(SessionManager.open(file).messages()).toEqual([
    { role: "user", content: "kept", timestamp: 1 },
    assistantMessage(2)
  ])

  const tornOnly = SessionManager.create(paths, { sessionId: "torn-only" })
  tornOnly.appendMessage({ role: "user", content: "kept", timestamp: 1 })
  tornOnly.appendMessage(assistantMessage(2))
  await appendFile(tornOnly.file!, '{"type":"message","id":"torn"')
  expect((await SessionManager.list(paths)).sessions.map(session => session.id)).toContain("torn-only")
  const repaired = SessionManager.open(tornOnly.file!)
  repaired.appendMessage({ role: "user", content: "after repair", timestamp: 3 })
  expect(SessionManager.open(tornOnly.file!).messages().at(-1)).toMatchObject({ role: "user", content: "after repair" })

  const content = await readFile(file, "utf8")
  await writeFile(file, `${content}\n`)
  expect(() => SessionManager.open(file)).toThrow(`Invalid session entry: ${file}`)
})

test("version 2 journals externalize image bytes and retain only the compacted active suffix", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-session-image-blobs-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "global"))
  const session = SessionManager.create(paths)
  const imageBytes = Buffer.from("a durable binary image payload")
  const imageData = imageBytes.toString("base64")
  const old = session.appendMessage({
    role: "user",
    content: [
      { type: "text", text: "inspect this" },
      { type: "image", mimeType: "image/png", data: imageData }
    ],
    timestamp: 1
  })
  session.appendMessage(assistantMessage(2))
  const kept = session.appendMessage({ role: "user", content: "keep", timestamp: 3 })
  session.appendCompaction({
    reason: "manual",
    summary: "image summarized",
    firstKeptEntryId: kept.id,
    tokensBefore: 100,
    estimatedTokensAfter: 10,
    details: emptyCompactionDetails()
  })

  const file = session.file!
  const persisted = await readFile(file, "utf8")
  const blobDir = file.replace(/\.jsonl$/u, ".blobs")
  const blobs = await readdir(blobDir)
  expect(session.header.version).toBe(2)
  expect(persisted).not.toContain(imageData)
  expect(persisted).toContain('"blob":{"sha256"')
  expect(blobs).toHaveLength(1)
  expect((await readFile(join(blobDir, blobs[0]!))).equals(imageBytes)).toBe(true)
  expect(session.memoryDiagnostics).toMatchObject({
    entries: 4,
    residentEntries: 2,
    coldEntries: 2,
    imageBlobBytes: imageBytes.byteLength,
    coldMemoryBytes: 0,
    coldMemoryLogicalBytes: 0,
    coldMemoryBlocks: 0
  })
  expect(session.retainedEntries().map(entry => entry.id)).toEqual([kept.id, session.latestCompaction()!.id])
  expect(session.entries().find(entry => entry.id === old.id)).toMatchObject({
    type: "message",
    message: { content: expect.arrayContaining([{ type: "image", mimeType: "image/png", data: imageData }]) }
  })

  const restored = SessionManager.open(file)
  expect(restored.memoryDiagnostics).toMatchObject({
    entries: 4,
    residentEntries: 2,
    coldEntries: 2,
    coldMemoryBytes: 0,
    coldMemoryLogicalBytes: 0,
    coldMemoryBlocks: 0
  })
  expect(restored.activeMessages()).toEqual(session.activeMessages())
  expect(restored.entries()).toEqual(session.entries())

  await writeFile(join(blobDir, blobs[0]!), Buffer.alloc(imageBytes.byteLength, 0xff))
  expect(() => SessionManager.open(file)).toThrow("Invalid session image blob")
})

test("in-memory compaction encodes its cold prefix without losing full journal access", () => {
  const session = SessionManager.inMemory("/work")
  const oldText = "x".repeat(128 * 1024)
  const old = session.appendMessage({ role: "user", content: oldText, timestamp: 1 })
  session.appendMessage(assistantMessage(2))
  const kept = session.appendMessage({ role: "user", content: "kept", timestamp: 3 })
  session.appendCompaction({
    reason: "manual",
    summary: "summary",
    firstKeptEntryId: kept.id,
    tokensBefore: 100,
    estimatedTokensAfter: 10,
    details: emptyCompactionDetails()
  })

  expect(session.memoryDiagnostics).toMatchObject({ entries: 4, residentEntries: 2, coldEntries: 2 })
  expect(session.memoryDiagnostics.coldMemoryLogicalBytes).toBeGreaterThan(128 * 1024)
  expect(session.memoryDiagnostics.coldMemoryBytes).toBeLessThan(session.memoryDiagnostics.coldMemoryLogicalBytes)
  expect(session.entries().map(entry => entry.id)).toEqual([old.id, expect.any(String), kept.id, expect.any(String)])
  expect(session.activeMessages().some(message => message.role === "user" && message.content === oldText)).toBe(false)
  expect(session.olderPromptHistoryEntry(kept.id)).toEqual({ entryId: old.id, text: oldText })
})

test("in-memory cold history materializes UTF-8 records spanning compression blocks", () => {
  const session = SessionManager.inMemory("/work")
  const oldText = `prefix-${"🙂".repeat(300_000)}-suffix`
  session.appendMessage({ role: "user", content: oldText, timestamp: 1 })
  session.appendMessage(assistantMessage(2))
  const kept = session.appendMessage({ role: "user", content: "kept", timestamp: 3 })
  session.appendCompaction({
    reason: "manual",
    summary: "summary",
    firstKeptEntryId: kept.id,
    tokensBefore: 100,
    estimatedTokensAfter: 10,
    details: emptyCompactionDetails()
  })

  expect(session.memoryDiagnostics.coldMemoryLogicalBytes).toBeGreaterThan(1024 * 1024)
  expect(session.messages()[0]).toEqual({ role: "user", content: oldText, timestamp: 1 })
})

test("in-memory cold history coalesces repeated compactions into bounded blocks", () => {
  const session = SessionManager.inMemory("/work")
  session.appendMessage({ role: "user", content: "old", timestamp: 0 })
  let kept = session.appendMessage({ role: "user", content: "kept-0", timestamp: 1 })
  session.appendCompaction({
    reason: "manual",
    summary: "summary-0",
    firstKeptEntryId: kept.id,
    tokensBefore: 100,
    estimatedTokensAfter: 10,
    details: emptyCompactionDetails()
  })

  for (let index = 1; index <= 16; index++) {
    kept = session.appendMessage({ role: "user", content: `kept-${index}`, timestamp: index + 1 })
    session.appendCompaction({
      reason: "threshold",
      summary: `summary-${index}`,
      firstKeptEntryId: kept.id,
      tokensBefore: 100,
      estimatedTokensAfter: 10,
      details: emptyCompactionDetails()
    })
  }

  expect(session.memoryDiagnostics.coldMemoryBlocks).toBe(1)
  expect(session.entries()).toHaveLength(35)
})

test("live session storage admission is transactional at the resumability bound", () => {
  const session = SessionManager.inMemory("/work")
  const entries = session.entries()

  expect(() =>
    session.appendMessage({ role: "user", content: "x".repeat(maxSessionStorageBytes), timestamp: 1 })
  ).toThrow(SessionCapacityError)
  expect(session.entries()).toBe(entries)
  expect(session.memoryDiagnostics).toMatchObject({ entries: 0, residentEntries: 0, coldEntries: 0 })
})

test("oversized session journals are refused before parsing", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-session-oversized-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "global"))
  const created = SessionManager.create(paths)
  const file = created.file!
  created.appendMessage({ role: "user", content: "persist", timestamp: 1 })
  created.appendMessage(assistantMessage(2))
  await truncate(file, maxSessionFileBytes + 1)

  expect(() => SessionManager.open(file)).toThrow(`Session file cannot exceed ${maxSessionFileBytes} bytes`)
  expect(await SessionManager.list(paths)).toMatchObject({ sessions: [], invalid: 1 })
})

function promptHistory(session: SessionManager) {
  const entries = []
  let current = session.latestPromptHistoryEntry()
  while (current) {
    entries.push(current)
    current = session.olderPromptHistoryEntry(current.entryId)
  }
  return entries
}

function jsonObject(value: SessionJson | undefined): { readonly [key: string]: SessionJson } {
  if (!isJsonObject(value)) throw new Error("Expected JSON object")
  return value
}

function isJsonObject(value: SessionJson | undefined): value is { readonly [key: string]: SessionJson } {
  return value !== null && value !== undefined && typeof value === "object" && !Array.isArray(value)
}

function assistantMessage(timestamp: number) {
  return {
    role: "assistant" as const,
    content: [],
    api: "test",
    provider: "test",
    model: "test",
    usage: emptyUsage(),
    stopReason: "stop" as const,
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

function emptyCompactionDetails() {
  return { readFiles: [], modifiedFiles: [], omittedReadFiles: 0, omittedModifiedFiles: 0 }
}

test("session listing returns an empty immutable result for a missing directory", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-session-missing-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "global"))
  await mkdir(paths.globalDir, { recursive: true })

  const result = await SessionManager.list(paths)
  expect(result).toEqual({ sessions: [], invalid: 0, omitted: 0 })
  expect(Object.isFrozen(result)).toBe(true)
  expect(Object.isFrozen(result.sessions)).toBe(true)
})
