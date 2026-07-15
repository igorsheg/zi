import { expect, test } from "bun:test"
import { mkdtemp } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join, relative, resolve } from "node:path"

import { OpenZiPaths } from "../src/paths.js"
import { SessionManager } from "../src/session-manager.js"

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
