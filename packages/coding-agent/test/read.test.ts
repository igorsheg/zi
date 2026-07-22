import { expect, test } from "bun:test"
import { mkdir, mkdtemp, rm, truncate, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { projectToolPresentation } from "../src/tools/presentation/project.js"
import { createReadTool, isReadToolDetails } from "../src/tools/read.js"

test("read returns exact ranges and compact semantic presentation", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-read-"))
  const tool = createReadTool(cwd)
  const path = "src/example.ts"
  await mkdir(join(cwd, "src"))
  await writeFile(join(cwd, path), `${Array.from({ length: 8 }, (_, index) => `line ${index + 1}`).join("\n")}\n`)

  try {
    const whole = await tool.execute("read-whole", { path })
    expect(isReadToolDetails(whole.details)).toBe(true)
    expect(whole.details).toMatchObject({ outcome: "success", startLine: 1, endLine: 8, totalLines: 8 })
    const wholePresentation = projectToolPresentation({ status: "done", name: "read", args: { path }, result: whole })
    expect(wholePresentation.header).toEqual({ label: "Read", subject: { type: "path", path }, details: [] })
    expect(wholePresentation.preview.compact).toEqual({ type: "hidden" })

    const ranged = await tool.execute("read-range", { path, offset: 3, limit: 3 })
    expect(ranged.details).toMatchObject({
      outcome: "success",
      startLine: 3,
      endLine: 5,
      totalLines: 8,
      nextOffset: 6,
      remainingLines: 3
    })
    const rangedPresentation = projectToolPresentation({
      status: "done",
      name: "read",
      args: { path, offset: 3, limit: 3 },
      result: ranged
    })
    expect(rangedPresentation.header.details).toEqual(["3-5 of 8"])
    expect(rangedPresentation.body).toMatchObject({ type: "source", text: "line 3\nline 4\nline 5", startLine: 3 })
    expect(rangedPresentation.notices).toContainEqual({
      type: "message",
      tone: "muted",
      visibility: "detailed",
      text: "3 lines remain; continue at offset 6"
    })
    const restoredResult = JSON.parse(JSON.stringify(ranged))
    expect(
      projectToolPresentation({
        status: "done",
        name: "read",
        args: { path, offset: 3, limit: 3 },
        result: restoredResult
      })
    ).toEqual(rangedPresentation)
  } finally {
    await rm(cwd, { recursive: true, force: true })
  }
})

test("read exposes empty files and operational failures as semantic states", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-read-errors-"))
  const tool = createReadTool(cwd)
  await writeFile(join(cwd, "empty.txt"), "")
  await mkdir(join(cwd, "directory"))
  await writeFile(join(cwd, "large.txt"), "x")
  await truncate(join(cwd, "large.txt"), 16 * 1024 * 1024 + 1)
  await writeFile(join(cwd, "short.txt"), "one\ntwo")

  try {
    const empty = await tool.execute("read-empty", { path: "empty.txt" })
    expect(
      projectToolPresentation({ status: "done", name: "read", args: { path: "empty.txt" }, result: empty }).header
    ).toMatchObject({ label: "Read", status: "empty" })

    for (const expected of [
      { id: "missing", input: { path: "missing.txt" }, reason: "not_found", status: "not found" },
      { id: "directory", input: { path: "directory" }, reason: "not_file", status: "not a file" },
      { id: "large", input: { path: "large.txt" }, reason: "too_large", status: "too large" },
      { id: "offset", input: { path: "short.txt", offset: 10 }, reason: "invalid_offset", status: "invalid offset" }
    ] as const) {
      // Tool executions are intentionally checked in source order.
      // oxlint-disable-next-line no-await-in-loop
      const result = await tool.execute(`read-${expected.id}`, expected.input)
      expect(result.details).toMatchObject({ outcome: "error", reason: expected.reason })
      const presentation = projectToolPresentation({ status: "failed", name: "read", args: expected.input, result })
      expect(presentation.header).toMatchObject({ label: "Read", status: expected.status })
      expect(presentation.body).toMatchObject({ type: "text", tone: "error" })
      expect(presentation.notices).toEqual([])
    }
  } finally {
    await rm(cwd, { recursive: true, force: true })
  }
})
