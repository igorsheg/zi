import { expect, test } from "bun:test"
import { mkdir, mkdtemp, readFile, rm, truncate, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { createEditTool, isEditToolDetails } from "../src/tools/edit.js"
import { projectToolPresentation } from "../src/tools/presentation/project.js"

test("edit applies disjoint replacements and returns a context-rich authoritative diff", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-edit-"))
  const path = "src/example.ts"
  const source = Array.from({ length: 24 }, (_, index) => `line ${index + 1}`).join("\n")
  await mkdir(join(cwd, "src"))
  await writeFile(join(cwd, path), source)
  const tool = createEditTool(cwd)
  const edits = [
    { oldText: "line 2\nline 3", newText: "const early = 2\nline 3" },
    { oldText: "line 22\nline 23", newText: "const late = 22\nline 23" }
  ]

  try {
    const result = await tool.execute("edit-success", { path, edits })
    expect(await readFile(join(cwd, path), "utf8")).toContain("const early = 2")
    expect(await readFile(join(cwd, path), "utf8")).toContain("const late = 22")
    expect(isEditToolDetails(result.details)).toBe(true)
    expect(result.details).toMatchObject({
      outcome: "success",
      replacements: 2,
      additions: 2,
      deletions: 2,
      diffTruncated: false,
      firstChangedLine: 2
    })
    if (result.details.outcome !== "success") throw new Error("Missing successful Edit details")
    expect(result.details.diff).toContain("@@ -1,5 +1,5 @@")
    expect(result.details.diff).toContain("-line 2\n+const early = 2")
    expect(result.details.diff).toContain(" line 3")
    expect(result.details.diff.match(/^@@/gm)).toHaveLength(2)

    const presentation = projectToolPresentation({ status: "done", name: "edit", args: { path, edits }, result })
    expect(presentation.header).toEqual({
      label: "Edit",
      subject: { type: "path", path },
      details: [],
      delta: { added: 2, removed: 2 }
    })
    expect(presentation.body).toEqual({ type: "diff", text: result.details.diff, path })
    expect(presentation.preview).toEqual({
      compact: { type: "edges", head: 5, tail: 5 },
      detailed: { type: "edges", head: 120, tail: 79 }
    })

    const restoredResult = JSON.parse(JSON.stringify(result))
    expect(
      projectToolPresentation({ status: "done", name: "edit", args: { path, edits }, result: restoredResult })
    ).toEqual(presentation)
  } finally {
    await rm(cwd, { recursive: true, force: true })
  }
})

test("edit preserves BOM and CRLF while diffing normalized source", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-edit-endings-"))
  const path = "windows.txt"
  await writeFile(join(cwd, path), "\uFEFFone\r\ntwo\r\nthree\r\n")
  const tool = createEditTool(cwd)

  try {
    const result = await tool.execute("edit-endings", { path, edits: [{ oldText: "two", newText: "second" }] })
    expect(await readFile(join(cwd, path), "utf8")).toBe("\uFEFFone\r\nsecond\r\nthree\r\n")
    expect(result.details).toMatchObject({ outcome: "success", additions: 1, deletions: 1, firstChangedLine: 2 })
  } finally {
    await rm(cwd, { recursive: true, force: true })
  }
})

test("edit bounds a large executed diff while retaining authoritative change counts", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-edit-bounded-"))
  const path = "large.txt"
  const oldLines = Array.from({ length: 64 }, (_, index) => `old-${index}-${"x".repeat(1_000)}`)
  const edits = oldLines.map((oldText, index) => ({ oldText, newText: `new-${index}-${"y".repeat(1_000)}` }))
  await writeFile(join(cwd, path), oldLines.join("\n"))
  const tool = createEditTool(cwd)

  try {
    const result = await tool.execute("edit-bounded", { path, edits })
    expect(result.details).toMatchObject({
      outcome: "success",
      replacements: 64,
      additions: 64,
      deletions: 64,
      diffTruncated: true
    })
    expect(isEditToolDetails(result.details)).toBe(true)
    if (result.details.outcome !== "success") throw new Error("Missing bounded Edit details")
    expect(Buffer.byteLength(result.details.diff)).toBeLessThanOrEqual(50 * 1024)
    const presentation = projectToolPresentation({ status: "done", name: "edit", args: { path, edits }, result })
    expect(presentation.header).toMatchObject({ details: [], delta: { added: 64, removed: 64 } })
    expect(presentation.notices).toEqual([
      {
        type: "message",
        tone: "warning",
        visibility: "detailed",
        text: "Diff preview truncated to bounded line, row, or byte limits"
      }
    ])
  } finally {
    await rm(cwd, { recursive: true, force: true })
  }
})

test("edit preserves review evidence when one changed line exceeds the presentation byte bound", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-edit-long-line-"))
  const path = "long-line.txt"
  const source = `${"a".repeat(30_000)}UNIQUE${"b".repeat(30_000)}`
  await writeFile(join(cwd, path), source)

  try {
    const edits = [{ oldText: "UNIQUE", newText: "CHANGED" }]
    const result = await createEditTool(cwd).execute("edit-long-line", { path, edits })
    expect(isEditToolDetails(result.details)).toBe(true)
    expect(result.details).toMatchObject({ outcome: "success", additions: 1, deletions: 1, diffTruncated: true })
    if (result.details.outcome !== "success") throw new Error("Missing successful Edit details")
    expect(result.details.diff).toContain("-… removed line omitted (60006 bytes)")
    expect(result.details.diff).toContain("+… added line omitted (60007 bytes)")

    const presentation = projectToolPresentation({ status: "done", name: "edit", args: { path, edits }, result })
    expect(presentation.body).toMatchObject({ type: "diff", text: expect.stringContaining("-… removed line omitted") })
    expect(
      isEditToolDetails({ ...result.details, diff: "--- a/long-line.txt\n+++ b/long-line.txt\n@@ -1,1 +1,1 @@" })
    ).toBe(false)
  } finally {
    await rm(cwd, { recursive: true, force: true })
  }
})

test("edit interruption remains cancellation without mutating the file", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-edit-abort-"))
  const path = "source.txt"
  await writeFile(join(cwd, path), "before")
  const tool = createEditTool(cwd)
  const controller = new AbortController()
  controller.abort()

  try {
    expect(
      await rejection(
        tool.execute("edit-aborted", { path, edits: [{ oldText: "before", newText: "after" }] }, controller.signal)
      )
    ).toMatchObject({ message: "Operation aborted" })
    expect(await readFile(join(cwd, path), "utf8")).toBe("before")
    const presentation = projectToolPresentation({
      status: "aborted",
      name: "edit",
      args: { path, edits: [{ oldText: "before", newText: "after" }] },
      result: undefined
    })
    expect(presentation.body).toBeUndefined()
  } finally {
    await rm(cwd, { recursive: true, force: true })
  }
})

test("edit reports a committed mutation as success instead of late cancellation", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-edit-commit-"))
  const path = "source.txt"
  await writeFile(join(cwd, path), "before")
  let checks = 0
  const signal = new AbortController().signal
  Object.defineProperty(signal, "aborted", {
    get() {
      checks++
      return checks >= 3
    }
  })

  try {
    const result = await createEditTool(cwd).execute(
      "edit-commit",
      { path, edits: [{ oldText: "before", newText: "after" }] },
      signal
    )
    expect(result.details).toMatchObject({ outcome: "success", replacements: 1 })
    expect(await readFile(join(cwd, path), "utf8")).toBe("after")
    expect(checks).toBe(2)
  } finally {
    await rm(cwd, { recursive: true, force: true })
  }
})

test("edit exposes closed matching and filesystem failures", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-edit-errors-"))
  const tool = createEditTool(cwd)
  await writeFile(join(cwd, "source.txt"), "abcdef\nfoo foo\n")
  await mkdir(join(cwd, "directory"))
  await writeFile(join(cwd, "large.txt"), "x")
  await truncate(join(cwd, "large.txt"), 16 * 1024 * 1024 + 1)

  try {
    for (const expected of [
      {
        id: "invalid-path",
        input: { path: "invalid\0.txt", edits: [{ oldText: "a", newText: "b" }] },
        reason: "invalid_path",
        status: "invalid path"
      },
      {
        id: "missing-file",
        input: { path: "missing.txt", edits: [{ oldText: "a", newText: "b" }] },
        reason: "not_found",
        status: "not found"
      },
      {
        id: "directory",
        input: { path: "directory", edits: [{ oldText: "a", newText: "b" }] },
        reason: "not_file",
        status: "not a file"
      },
      {
        id: "large",
        input: { path: "large.txt", edits: [{ oldText: "a", newText: "b" }] },
        reason: "too_large",
        status: "too large"
      },
      {
        id: "empty",
        input: { path: "source.txt", edits: [{ oldText: "", newText: "b" }] },
        reason: "invalid_edit",
        status: "invalid edit"
      },
      {
        id: "missing-match",
        input: { path: "source.txt", edits: [{ oldText: "missing", newText: "b" }] },
        reason: "match_missing",
        status: "match not found"
      },
      {
        id: "ambiguous",
        input: { path: "source.txt", edits: [{ oldText: "foo", newText: "bar" }] },
        reason: "match_ambiguous",
        status: "ambiguous match"
      },
      {
        id: "overlap",
        input: {
          path: "source.txt",
          edits: [
            { oldText: "abc", newText: "ABC" },
            { oldText: "cde", newText: "CDE" }
          ]
        },
        reason: "overlap",
        status: "overlapping edits"
      },
      {
        id: "no-change",
        input: { path: "source.txt", edits: [{ oldText: "abcdef", newText: "abcdef" }] },
        reason: "no_change",
        status: "no change"
      }
    ] as const) {
      const input = {
        path: expected.input.path,
        edits: expected.input.edits.map(edit => ({ oldText: edit.oldText, newText: edit.newText }))
      }
      // Tool executions are intentionally checked in source order.
      // oxlint-disable-next-line no-await-in-loop
      const result = await tool.execute(`edit-${expected.id}`, input)
      expect(result.details).toMatchObject({ outcome: "error", reason: expected.reason })
      const presentation = projectToolPresentation({ status: "failed", name: "edit", args: input, result })
      expect(presentation.header).toMatchObject({ label: "Edit", details: [], status: expected.status })
      expect(presentation.body).toMatchObject({ type: "text", tone: "error" })
      expect(presentation.notices).toEqual([])
    }
  } finally {
    await rm(cwd, { recursive: true, force: true })
  }
})

async function rejection(operation: Promise<unknown>): Promise<unknown> {
  try {
    await operation
  } catch (cause) {
    return cause
  }
  throw new Error("Expected operation to reject")
}
