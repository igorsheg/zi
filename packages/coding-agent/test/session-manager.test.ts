import { expect, test } from "bun:test"
import { existsSync } from "node:fs"
import { appendFile, mkdir, mkdtemp, readFile, rename, rm, truncate, utimes, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join, relative, resolve } from "node:path"

import { OpenZiPaths } from "../src/paths.js"
import {
  maxSessionFileBytes,
  maxSessionFirstMessageLength,
  maxSessionPromptHistoryEntries,
  maxSessionPromptHistoryEntryBytes,
  SessionManager
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

test("session prompt history is bounded by references and rejects oversized text", () => {
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

test("session prompt history survives compaction, append, and journal restore by stable entry ID", async () => {
  const root = await mkdtemp(join(tmpdir(), "openzi-session-prompt-history-"))
  const paths = new OpenZiPaths(join(root, "project"), join(root, "global"))
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
  const root = await mkdtemp(join(tmpdir(), "openzi-session-lazy-"))
  const paths = new OpenZiPaths(join(root, "project"), join(root, "global"))
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

test("a failed first journal write leaves pending entries retryable", async () => {
  const root = await mkdtemp(join(tmpdir(), "openzi-session-lazy-failure-"))
  const paths = new OpenZiPaths(join(root, "project"), join(root, "global"))
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
})

test("persisted compaction markers restore the same active projection", async () => {
  const root = await mkdtemp(join(tmpdir(), "openzi-session-compaction-restore-"))
  const paths = new OpenZiPaths(join(root, "project"), join(root, "global"))
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

test("opening rejects completed compaction markers with invalid semantic references", async () => {
  const root = await mkdtemp(join(tmpdir(), "openzi-session-invalid-compaction-"))
  const paths = new OpenZiPaths(join(root, "project"), join(root, "global"))
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
  const root = await mkdtemp(join(tmpdir(), "openzi-session-append-failure-"))
  const paths = new OpenZiPaths(join(root, "project"), join(root, "global"))
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
  const root = await mkdtemp(join(tmpdir(), "openzi-session-"))
  const paths = new OpenZiPaths(join(root, "project"), join(root, "global"), "sessions")
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

test("session listing reads only bounded recent metadata and isolates invalid journals", async () => {
  const root = await mkdtemp(join(tmpdir(), "openzi-session-list-"))
  const paths = new OpenZiPaths(join(root, "project"), join(root, "global"))
  const first = SessionManager.create(paths, { sessionId: "first" })
  first.appendMessage({ role: "user", content: "  first\n  task  ", timestamp: 1 })
  first.appendMessage(assistantMessage(2))
  const second = SessionManager.create(paths, { sessionId: "second" })
  second.appendMessage({ role: "user", content: "x".repeat(maxSessionFirstMessageLength + 20), timestamp: 2 })
  second.appendMessage(assistantMessage(3))
  const otherPaths = new OpenZiPaths(join(root, "other-project"), join(root, "global"), paths.sessionDir)
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
  const root = await mkdtemp(join(tmpdir(), "openzi-session-continue-"))
  const paths = new OpenZiPaths(join(root, "project"), join(root, "global"))

  const created = await SessionManager.continueRecent(paths)
  expect(created.file).toBeDefined()
  created.appendMessage({ role: "user", content: "continue me", timestamp: 1 })
  created.appendMessage(assistantMessage(2))

  const continued = await SessionManager.continueRecent(paths)
  expect(continued.sessionId).toBe(created.sessionId)
  expect(continued.messages()).toEqual([{ role: "user", content: "continue me", timestamp: 1 }, assistantMessage(2)])
})

test("opening a session ignores only a malformed unterminated tail", async () => {
  const root = await mkdtemp(join(tmpdir(), "openzi-session-tail-"))
  const paths = new OpenZiPaths(join(root, "project"), join(root, "global"))
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

  const content = await readFile(file, "utf8")
  await writeFile(file, `${content}\n`)
  expect(() => SessionManager.open(file)).toThrow(`Invalid session entry: ${file}`)
})

test("oversized session journals are refused before parsing", async () => {
  const root = await mkdtemp(join(tmpdir(), "openzi-session-oversized-"))
  const paths = new OpenZiPaths(join(root, "project"), join(root, "global"))
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
  const root = await mkdtemp(join(tmpdir(), "openzi-session-missing-"))
  const paths = new OpenZiPaths(join(root, "project"), join(root, "global"))
  await mkdir(paths.globalDir, { recursive: true })

  const result = await SessionManager.list(paths)
  expect(result).toEqual({ sessions: [], invalid: 0, omitted: 0 })
  expect(Object.isFrozen(result)).toBe(true)
  expect(Object.isFrozen(result.sessions)).toBe(true)
})
