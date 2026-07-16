import { expect, test } from "bun:test"

import { projectToolDisplay } from "../src/tools/presentation.js"

test("bash presentation separates retained output from structured notices", () => {
  const path = "/tmp/openzi/full-output.log"
  const display = projectToolDisplay({
    name: "bash",
    args: { command: "run" },
    result: {
      content: [
        {
          type: "text",
          text: `tail\n\n[Output truncated. Full output: ${path}]\n[Full output file reached its retention limit.]`
        }
      ],
      details: {
        fullOutputPath: path,
        fullOutputTruncated: true,
        truncation: {
          content: "tail",
          truncated: true,
          truncatedBy: "lines",
          totalLines: 3000,
          totalBytes: 100000,
          outputLines: 2000,
          outputBytes: 50000,
          firstLineExceedsLimit: false,
          lastLinePartial: false
        }
      }
    },
    isError: false
  })

  expect(display.type).toBe("command")
  if (display.type !== "command") throw new Error("Expected command display")
  expect(display.output).toBe("tail")
  expect(display.notices.map(notice => notice.text)).toEqual([
    `Full output: ${path}`,
    "Truncated: showing the last 2000 of 3000 lines",
    "Full output file reached its retention limit"
  ])
})

test("read presentation retains actionable continuation separately from content", () => {
  const display = projectToolDisplay({
    name: "read",
    args: { path: "large.ts", offset: 1, limit: 100 },
    result: {
      content: [{ type: "text", text: "line one\nline two\n\n[Showing lines 1-2 of 500. Use offset=3 to continue.]" }]
    },
    isError: false
  })

  expect(display.type).toBe("read")
  if (display.type !== "read") throw new Error("Expected read display")
  expect(display.output).toBe("line one\nline two")
  expect(display.notices).toEqual([{ tone: "warning", text: "Showing lines 1-2 of 500. Use offset=3 to continue." }])
})

test("structured notices are bounded before entering the TUI", () => {
  const notices = Array.from({ length: 12 }, (_, index) => `[notice ${index} ${"x".repeat(5_000)}]`).join("\n")
  const display = projectToolDisplay({
    name: "bash",
    args: { command: "run" },
    result: { content: [{ type: "text", text: notices }], details: { fullOutputPath: `/tmp/${"y".repeat(10_000)}` } },
    isError: false
  })

  expect(display.type).toBe("command")
  if (display.type !== "command") throw new Error("Expected command display")
  expect(display.notices).toHaveLength(8)
  expect(display.notices.every(notice => notice.text.length <= 4_096)).toBe(true)
})

test("write and edit argument projections are bounded before entering the TUI", () => {
  const write = projectToolDisplay({
    name: "write",
    args: { path: "large.txt", content: Array.from({ length: 2100 }, (_, index) => `line ${index}`).join("\n") },
    isError: false
  })
  expect(write.type).toBe("write")
  if (write.type !== "write") throw new Error("Expected write display")
  expect(write.contentTruncated).toBe(true)
  expect(write.contentLines).toBe(2100)
  expect(write.content.split("\n").length).toBeLessThanOrEqual(2000)

  const edit = projectToolDisplay({
    name: "edit",
    args: {
      path: "file.ts",
      edits: Array.from({ length: 12 }, (_, index) => ({ oldText: `old ${index}`, newText: `new ${index}` }))
    },
    isError: false
  })
  expect(edit.type).toBe("edit")
  if (edit.type !== "edit") throw new Error("Expected edit display")
  expect(edit.changes).toHaveLength(8)
  expect(edit.changesTruncated).toBe(true)

  const stringEdits = projectToolDisplay({
    name: "edit",
    args: { path: "file.ts", edits: JSON.stringify([{ oldText: "before", newText: "after" }]) },
    isError: false
  })
  expect(stringEdits.type === "edit" ? stringEdits.changes : []).toEqual([{ oldText: "before", newText: "after" }])
})
