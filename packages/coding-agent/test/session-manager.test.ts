import { expect, test } from "bun:test"
import { appendFile, mkdir, mkdtemp, readFile, truncate, utimes, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join, relative, resolve } from "node:path"

import { OpenZiPaths } from "../src/paths.js"
import { maxSessionFileBytes, maxSessionFirstMessageLength, SessionManager } from "../src/session-manager.js"

test("session entries form one append-only branch", () => {
  const session = SessionManager.inMemory("/work")

  const model = session.appendModelChange("anthropic", "claude")
  const thinking = session.appendThinkingLevelChange("medium")
  const message = session.appendMessage({ role: "user", content: "hello", timestamp: 1 })
  const entries = session.entries()

  expect(entries.map(entry => entry.id)).toEqual([model, thinking, message])
  expect(entries.map(entry => entry.parentId)).toEqual([null, model, thinking])
  expect(session.messages()).toEqual([{ role: "user", content: "hello", timestamp: 1 }])
})

test("persisted and explicitly opened session paths are canonical", async () => {
  const root = await mkdtemp(join(tmpdir(), "openzi-session-"))
  const paths = new OpenZiPaths(join(root, "project"), join(root, "global"), "sessions")
  const created = SessionManager.create(paths)
  const file = created.file
  if (!file) throw new Error("Session file was not created")

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
  const second = SessionManager.create(paths, { sessionId: "second" })
  second.appendMessage({ role: "user", content: "x".repeat(maxSessionFirstMessageLength + 20), timestamp: 2 })
  const otherPaths = new OpenZiPaths(join(root, "other-project"), join(root, "global"), paths.sessionDir)
  SessionManager.create(otherPaths, { sessionId: "other-project" })
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

  const continued = await SessionManager.continueRecent(paths)
  expect(continued.sessionId).toBe(created.sessionId)
  expect(continued.messages()).toEqual([{ role: "user", content: "continue me", timestamp: 1 }])
})

test("opening a session ignores only a malformed unterminated tail", async () => {
  const root = await mkdtemp(join(tmpdir(), "openzi-session-tail-"))
  const paths = new OpenZiPaths(join(root, "project"), join(root, "global"))
  const created = SessionManager.create(paths)
  const file = created.file!
  created.appendMessage({ role: "user", content: "kept", timestamp: 1 })
  await appendFile(file, '{"type":"message","id":"torn"')

  expect(SessionManager.open(file).messages()).toEqual([{ role: "user", content: "kept", timestamp: 1 }])

  const tornOnly = SessionManager.create(paths, { sessionId: "torn-only" })
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
  await truncate(file, maxSessionFileBytes + 1)

  expect(() => SessionManager.open(file)).toThrow(`Session file cannot exceed ${maxSessionFileBytes} bytes`)
  expect(await SessionManager.list(paths)).toMatchObject({ sessions: [], invalid: 1 })
})

test("session listing returns an empty immutable result for a missing directory", async () => {
  const root = await mkdtemp(join(tmpdir(), "openzi-session-missing-"))
  const paths = new OpenZiPaths(join(root, "project"), join(root, "global"))
  await mkdir(paths.globalDir, { recursive: true })

  const result = await SessionManager.list(paths)
  expect(result).toEqual({ sessions: [], invalid: 0, omitted: 0 })
  expect(Object.isFrozen(result)).toBe(true)
  expect(Object.isFrozen(result.sessions)).toBe(true)
})
