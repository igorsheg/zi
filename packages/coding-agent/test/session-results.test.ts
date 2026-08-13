import { expect, test } from "bun:test"
import { appendFile, mkdtemp, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { ZiPaths } from "../src/paths.js"
import { SessionManager } from "../src/session-manager.js"
import { maxSubagentWorkResultEntryBytes } from "../src/subagents/result.js"

const subagentResult = {
  name: "reviewer",
  workCycle: 1,
  profile: "reviewer",
  result: "succeeded",
  durationMs: 42,
  preview: "done",
  originalBytes: 4,
  omittedBytes: 0,
  truncated: false
} as const

const backgroundResult = {
  taskId: "shell-1",
  origin: "requested",
  result: "failed",
  durationMs: 20,
  outputBytes: 12,
  errorCode: "exit_nonzero",
  exitCode: 7
} as const

test("closed work results persist by natural identity and stay model invisible", () => {
  const session = SessionManager.inMemory("/work")
  const child = session.appendSubagentWorkResult(subagentResult)
  const shell = session.appendBackgroundTaskResult(backgroundResult)

  expect(session.subagentWorkResults()).toEqual([child])
  expect(session.backgroundTaskResults()).toEqual([shell])
  expect(session.activeMessages()).toEqual([])
  expect(session.presentationMessages()).toEqual([])
  expect(() => session.appendSubagentWorkResult(subagentResult)).toThrow("reviewer/1")
  expect(() => session.appendBackgroundTaskResult(backgroundResult)).toThrow("shell-1")
})

test("restored journals reject duplicate natural result identities", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-session-results-"))
  const paths = new ZiPaths(root, join(root, "agent"), join(root, "sessions"))
  try {
    const session = SessionManager.create(paths)
    const child = session.appendSubagentWorkResult(subagentResult)
    const shell = session.appendBackgroundTaskResult(backgroundResult)
    const file = session.file!

    await appendFile(file, `${JSON.stringify({ ...child, id: crypto.randomUUID(), parentId: shell.id })}\n`)
    expect(() => SessionManager.open(file)).toThrow("Duplicate subagent work result")
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test("subagent work results enforce their complete serialized bound", () => {
  const session = SessionManager.inMemory("/work")
  expect(() =>
    session.appendSubagentWorkResult({ ...subagentResult, preview: "x".repeat(maxSubagentWorkResultEntryBytes) })
  ).toThrow("Invalid session entry")
})
