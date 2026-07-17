import { expect, test } from "bun:test"

import { createEditTool } from "../src/tools/edit.js"
import { projectToolPresentation } from "../src/tools/presentation/project.js"

test("bash presentation separates bounded output from structured notices", () => {
  const path = "/tmp/openzi/full-output.log"
  const presentation = projectToolPresentation({
    status: "done",
    name: "bash",
    args: { command: "run" },
    result: {
      content: [{ type: "text", text: `tail\n\n[Output truncated. Full output: ${path}]` }],
      details: {
        outcome: "success",
        taskId: "task-1",
        state: "completed",
        timeoutSeconds: 120,
        finalOutcome: { type: "exited", exitCode: 0 },
        output: {
          truncation: {
            truncated: true,
            truncatedBy: "lines",
            totalLines: 3_000,
            totalBytes: 100_000,
            outputLines: 2_000,
            outputBytes: 4,
            firstLineExceedsLimit: false,
            lastLinePartial: false
          },
          fullOutput: { type: "available", path, bytes: 100_000, truncated: true }
        }
      }
    }
  })

  expect(presentation.header.subject).toEqual({ type: "command", text: "run" })
  expect(presentation.body).toEqual({ type: "terminal", text: "tail" })
  expect(presentation.notices).toContainEqual({ type: "path", tone: "warning", label: "Full output", path })
  expect(presentation.notices).toContainEqual({
    type: "message",
    tone: "warning",
    text: "Showing the last 2000 of 3000 lines"
  })
})

test("read presentation derives continuation from details instead of model prose", () => {
  const presentation = projectToolPresentation({
    status: "done",
    name: "read",
    args: { path: "large.ts", offset: 1, limit: 100 },
    result: {
      content: [{ type: "text", text: "one\ntwo\n\n[Showing lines 1-2 of 500. Use offset=3 to continue.]" }],
      details: {
        outcome: "success",
        startLine: 1,
        endLine: 2,
        totalLines: 500,
        nextOffset: 3,
        remainingLines: 498,
        truncation: {
          truncated: true,
          truncatedBy: "lines",
          totalLines: 100,
          totalBytes: 1_000,
          outputLines: 2,
          outputBytes: 7,
          firstLineExceedsLimit: false,
          lastLinePartial: false
        }
      }
    }
  })

  expect(presentation.body).toEqual({ type: "source", text: "one\ntwo", path: "large.ts", startLine: 1 })
  expect(presentation.notices).toContainEqual({
    type: "message",
    tone: "muted",
    text: "498 lines remain; continue at offset 3"
  })
})

test("write, edit, task-output, and kill-task project only semantic primitives", () => {
  const write = projectToolPresentation({
    status: "done",
    name: "write",
    args: { path: "notes.ts", content: "export const answer = 42" },
    result: {
      content: [{ type: "text", text: "Successfully wrote notes.ts" }],
      details: { outcome: "success", bytes: 24, lines: 1 }
    }
  })
  expect(write.body).toEqual({ type: "source", text: "export const answer = 42", path: "notes.ts" })

  const edit = projectToolPresentation({
    status: "done",
    name: "edit",
    args: { path: "notes.ts", edits: [{ oldText: "41", newText: "42" }] },
    result: {
      content: [{ type: "text", text: "Replaced one block" }],
      details: {
        outcome: "success",
        replacements: 1,
        diff: "--- a/notes.ts\n+++ b/notes.ts\n@@ -1,1 +1,1 @@\n-41\n+42",
        diffTruncated: false,
        firstChangedLine: 1
      }
    }
  })
  expect(edit.body).toMatchObject({ type: "diff", path: "notes.ts", text: expect.stringContaining("+42") })

  const output = projectToolPresentation({
    status: "done",
    name: "task_output",
    args: { taskId: "task-1" },
    result: {
      content: [{ type: "text", text: "done\n\nTask task-1: completed (exit 0)" }],
      details: {
        outcome: "success",
        taskId: "task-1",
        state: "completed",
        finalOutcome: { type: "exited", exitCode: 0 },
        output: {
          truncation: {
            truncated: false,
            truncatedBy: null,
            totalLines: 1,
            totalBytes: 4,
            outputLines: 1,
            outputBytes: 4,
            firstLineExceedsLimit: false,
            lastLinePartial: false
          },
          fullOutput: { type: "available", path: "/tmp/task-1.log", bytes: 4, truncated: false }
        }
      }
    }
  })
  expect(output.body).toEqual({ type: "terminal", text: "done" })

  const kill = projectToolPresentation({
    status: "done",
    name: "kill_task",
    args: { taskId: "task-1" },
    result: {
      content: [{ type: "text", text: "Stopping task-1" }],
      details: { outcome: "success", taskId: "task-1", stop: "stopping" }
    }
  })
  expect(kill.body).toBeUndefined()
  expect(kill.preview).toEqual({ type: "hidden" })
})

test("all built-ins accept streamed partial arguments with one semantic placeholder", () => {
  for (const name of ["bash", "read", "write", "edit", "task_output", "kill_task"]) {
    const presentation = projectToolPresentation({ status: "preparing", name, args: {} })
    expect(presentation.header.label).not.toBe("Tool")
    expect(JSON.stringify(presentation.header.subject)).toContain("…")
  }
})

test("malformed terminal built-ins and unknown tools use the bounded generic projection", () => {
  const malformed = projectToolPresentation({
    status: "done",
    name: "write",
    args: { path: "file.txt", content: "text" },
    result: { content: [{ type: "text", text: "old result" }], details: undefined }
  })
  expect(malformed.header).toMatchObject({ label: "Tool", subject: { type: "text", text: "write" } })

  const circular: { self?: unknown } = {}
  circular.self = circular
  const unknown = projectToolPresentation({ status: "preparing", name: "custom", args: circular })
  expect(unknown.body).toMatchObject({ type: "text", text: expect.stringContaining("unserializable arguments") })
})

test("malformed semantic details and lifecycle mismatches fall back as whole values", () => {
  const truncation = {
    truncated: false,
    truncatedBy: null,
    totalLines: 1,
    totalBytes: 3,
    outputLines: 1,
    outputBytes: 3,
    firstLineExceedsLimit: false,
    lastLinePartial: false
  } as const
  const malformedRead = projectToolPresentation({
    status: "done",
    name: "read",
    args: { path: "file.txt" },
    result: {
      content: [{ type: "text", text: "one" }],
      details: {
        outcome: "success",
        startLine: 1,
        endLine: 1,
        totalLines: 10,
        nextOffset: 2,
        remainingLines: 999,
        truncation
      }
    }
  })
  expect(malformedRead.header.label).toBe("Tool")

  const impossibleBash = projectToolPresentation({
    status: "failed",
    name: "bash",
    args: { command: "true" },
    result: {
      content: [{ type: "text", text: "impossible" }],
      details: {
        outcome: "error",
        state: "completed",
        taskId: "task-1",
        timeoutSeconds: 120,
        finalOutcome: { type: "exited", exitCode: 0 },
        output: {
          truncation: { ...truncation, totalLines: 0, totalBytes: 0, outputLines: 0, outputBytes: 0 },
          fullOutput: { type: "evicted", bytes: 0, truncated: false }
        },
        error: "Command failed"
      }
    }
  })
  expect(impossibleBash.header.label).toBe("Tool")

  const mismatchedLifecycle = projectToolPresentation({
    status: "failed",
    name: "write",
    args: { path: "file.txt", content: "one" },
    result: { content: [{ type: "text", text: "wrote" }], details: { outcome: "success", bytes: 3, lines: 1 } }
  })
  expect(mismatchedLifecycle.header.label).toBe("Tool")
})

test("generic projection bounds traversal before serialization", () => {
  const args = Array.from({ length: 200 }, (_, index) => ({ index }))
  Object.defineProperty(args, 150, {
    enumerable: true,
    get() {
      throw new Error("serializer traversed beyond its collection bound")
    }
  })
  const content = Array.from({ length: 40 }, (_, index) => ({ type: "text", text: `part ${index}` }))
  Object.defineProperty(content, 35, {
    enumerable: true,
    get() {
      throw new Error("result collector traversed beyond its part bound")
    }
  })

  const presentation = projectToolPresentation({ status: "done", name: "custom", args, result: { content } })
  if (presentation.body?.type !== "text") throw new Error("Expected generic text body")
  expect(presentation.body.text).toContain("more items")
  expect(presentation.body.text).toContain("part 31")
})

test("edit schema keeps every valid replacement batch within the persisted argument bound", () => {
  const parameters = createEditTool(process.cwd()).parameters
  const edits = objectProperty(objectProperty(parameters, "properties"), "edits")
  const replacement = objectProperty(edits, "items")
  const properties = objectProperty(replacement, "properties")
  const oldText = objectProperty(properties, "oldText")
  const newText = objectProperty(properties, "newText")
  const worstCaseUtf8Bytes =
    numberProperty(edits, "maxItems") *
    (numberProperty(oldText, "maxLength") + numberProperty(newText, "maxLength")) *
    4
  expect(worstCaseUtf8Bytes).toBeLessThanOrEqual(8 * 1024 * 1024)
})

test("projection strips ANSI and unsafe controls before values cross into clients", () => {
  const presentation = projectToolPresentation({
    status: "preparing",
    name: "bash",
    args: { command: "\u001b[31mecho\u001b[0m\u0000 hi" }
  })
  expect(presentation.header.subject).toEqual({ type: "command", text: "echo hi" })
})

function objectProperty(value: object, key: string): object {
  const property = Reflect.get(value, key)
  if (typeof property !== "object" || property === null) throw new Error(`Missing schema object: ${key}`)
  return property
}

function numberProperty(value: object, key: string): number {
  const property = Reflect.get(value, key)
  if (typeof property !== "number") throw new Error(`Missing schema number: ${key}`)
  return property
}
