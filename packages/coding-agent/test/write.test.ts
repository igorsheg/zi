import { expect, test } from "bun:test"
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { projectToolPresentation } from "../src/tools/presentation/project.js"
import { DEFAULT_MAX_BYTES } from "../src/tools/truncate.js"
import { createWriteTool, isWriteToolDetails } from "../src/tools/write.js"

test("write creates exact content and projects a compact semantic success", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "openzi-write-"))
  const tool = createWriteTool(cwd)
  const path = "src/generated.ts"
  const content = "export const answer = 42\n"

  try {
    const result = await tool.execute("write-success", { path, content })
    expect(await readFile(join(cwd, path), "utf8")).toBe(content)
    expect(isWriteToolDetails(result.details)).toBe(true)
    expect(result.details).toEqual({ outcome: "success", bytes: 25, lines: 1 })

    const presentation = projectToolPresentation({ status: "done", name: "write", args: { path, content }, result })
    expect(presentation.header).toEqual({
      label: "Write",
      subject: { type: "path", path },
      details: ["1 line", "25 bytes"]
    })
    expect(presentation.body).toEqual({ type: "source", text: content, path })
    expect(presentation.notices).toEqual([])
    expect(presentation.preview).toEqual({ compact: { type: "hidden" }, detailed: { type: "head", rows: 200 } })

    const restoredResult = JSON.parse(JSON.stringify(result))
    expect(
      projectToolPresentation({ status: "done", name: "write", args: { path, content }, result: restoredResult })
    ).toEqual(presentation)

    const singleByte = await tool.execute("write-single-byte", { path, content: "x" })
    expect(
      projectToolPresentation({ status: "done", name: "write", args: { path, content: "x" }, result: singleByte })
        .header.details
    ).toEqual(["1 line", "1 byte"])

    const empty = await tool.execute("write-empty", { path, content: "" })
    expect(await readFile(join(cwd, path), "utf8")).toBe("")
    const emptyPresentation = projectToolPresentation({
      status: "done",
      name: "write",
      args: { path, content: "" },
      result: empty
    })
    expect(emptyPresentation.header.details).toEqual(["0 lines", "0 bytes"])
    expect(emptyPresentation.body).toBeUndefined()
  } finally {
    await rm(cwd, { recursive: true, force: true })
  }
})

test("write projects bounded live counts from streamed arguments and exact counts after settlement", () => {
  for (const [content, detail] of [
    ["", "0 lines so far"],
    ["one", "1 line so far"],
    ["one\ntwo\n", "2 lines so far"]
  ] as const) {
    const presentation = projectToolPresentation({
      status: "preparing",
      name: "write",
      args: { path: "streamed.txt", content }
    })
    expect(presentation.header.details).toEqual([detail])
    expect(presentation.preview.compact).toEqual({ type: "hidden" })
  }

  const content = "x\n".repeat(DEFAULT_MAX_BYTES)
  const preparing = projectToolPresentation({
    status: "preparing",
    name: "write",
    args: { path: "streamed.txt", content }
  })
  expect(preparing.header.details).toEqual(["at least 25600 lines so far"])

  const ready = projectToolPresentation({ status: "ready", name: "write", args: { path: "streamed.txt", content } })
  expect(ready.header.details).toEqual(["51200 lines", "100 KiB"])
})

test("write exposes bounded operational failures without echoing attempted content", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "openzi-write-errors-"))
  const tool = createWriteTool(cwd)
  await mkdir(join(cwd, "directory"))
  await writeFile(join(cwd, "parent-file"), "parent")

  try {
    for (const expected of [
      {
        id: "invalid-path",
        input: { path: "invalid\0.txt", content: "private" },
        reason: "invalid_path",
        status: "invalid path"
      },
      { id: "directory", input: { path: "directory", content: "private" }, reason: "not_file", status: "not a file" },
      {
        id: "parent-file",
        input: { path: "parent-file/child.txt", content: "private" },
        reason: "not_file",
        status: "not a file"
      },
      {
        id: "large",
        input: { path: "large.txt", content: "x".repeat(8 * 1024 * 1024 + 1) },
        reason: "too_large",
        status: "too large"
      }
    ] as const) {
      // Tool executions are intentionally checked in source order.
      // oxlint-disable-next-line no-await-in-loop
      const result = await tool.execute(`write-${expected.id}`, expected.input)
      expect(result.details).toMatchObject({ outcome: "error", reason: expected.reason })
      const presentation = projectToolPresentation({ status: "failed", name: "write", args: expected.input, result })
      expect(presentation.header).toMatchObject({ label: "Write", details: [], status: expected.status })
      expect(presentation.body).toMatchObject({ type: "text", tone: "error" })
      expect(JSON.stringify(presentation.body)).not.toContain("private")
      expect(presentation.notices).toEqual([])
      expect(presentation.preview.compact).toEqual({ type: "head", rows: 4 })
    }
  } finally {
    await rm(cwd, { recursive: true, force: true })
  }
})

test("write interruption remains cancellation without a fabricated error body", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "openzi-write-abort-"))
  const tool = createWriteTool(cwd)
  const controller = new AbortController()
  controller.abort()

  try {
    expect(
      await rejection(tool.execute("write-aborted", { path: "cancelled.txt", content: "nope" }, controller.signal))
    ).toMatchObject({ message: "Operation aborted" })
    expect(await rejection(readFile(join(cwd, "cancelled.txt"), "utf8"))).toBeInstanceOf(Error)
    const presentation = projectToolPresentation({
      status: "aborted",
      name: "write",
      args: { path: "cancelled.txt", content: "nope" },
      result: undefined
    })
    expect(presentation.body).toBeUndefined()
    expect(presentation.preview).toEqual({ compact: { type: "hidden" }, detailed: { type: "hidden" } })
  } finally {
    await rm(cwd, { recursive: true, force: true })
  }
})

test("write reports a committed mutation as success instead of late cancellation", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "openzi-write-commit-"))
  const path = "committed.txt"
  let checks = 0
  const signal = new AbortController().signal
  Object.defineProperty(signal, "aborted", {
    get() {
      checks++
      return checks >= 3
    }
  })

  try {
    const result = await createWriteTool(cwd).execute("write-commit", { path, content: "committed" }, signal)
    expect(result.details).toEqual({ outcome: "success", bytes: 9, lines: 1 })
    expect(await readFile(join(cwd, path), "utf8")).toBe("committed")
    expect(checks).toBe(2)
  } finally {
    await rm(cwd, { recursive: true, force: true })
  }
})

test("write bounds detailed argument previews and keeps truncation guidance out of compact rows", () => {
  const content = Array.from({ length: 2_100 }, (_, index) => `line ${index + 1}`).join("\n")
  const bytes = Buffer.byteLength(content)
  const presentation = projectToolPresentation({
    status: "done",
    name: "write",
    args: { path: "generated.txt", content },
    result: {
      content: [{ type: "text", text: "Successfully wrote generated.txt" }],
      details: { outcome: "success", bytes, lines: 2_100 }
    }
  })

  expect(presentation.body).toMatchObject({ type: "source", text: expect.stringContaining("line 2000") })
  expect(presentation.body).not.toMatchObject({ text: expect.stringContaining("line 2001") })
  expect(presentation.notices).toEqual([
    {
      type: "message",
      tone: "warning",
      visibility: "detailed",
      text: `Content preview truncated (2100 lines, ${bytes} bytes)`
    }
  ])

  const largeContent = "界".repeat(DEFAULT_MAX_BYTES)
  const largeBytes = Buffer.byteLength(largeContent)
  const large = projectToolPresentation({
    status: "done",
    name: "write",
    args: { path: "large.txt", content: largeContent },
    result: {
      content: [{ type: "text", text: "Successfully wrote large.txt" }],
      details: { outcome: "success", bytes: largeBytes, lines: 1 }
    }
  })
  expect(large.body).toMatchObject({ type: "source" })
  if (large.body?.type !== "source") throw new Error("Missing bounded Write source")
  expect(Buffer.byteLength(large.body.text)).toBeLessThanOrEqual(DEFAULT_MAX_BYTES)
  expect(large.notices).toEqual([
    { type: "message", tone: "warning", visibility: "detailed", text: "Content preview truncated (1 line, 150 KiB)" }
  ])
})

async function rejection(operation: Promise<unknown>): Promise<unknown> {
  try {
    await operation
  } catch (cause) {
    return cause
  }
  throw new Error("Expected operation to reject")
}
