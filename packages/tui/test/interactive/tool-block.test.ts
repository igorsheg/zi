import { expect, test } from "bun:test"

import { BoxRenderable, type RenderContext, type Renderable, TextRenderable } from "@opentui/core"
import { createTestRenderer } from "@opentui/core/testing"
import { projectToolPresentation, type ToolPresentation } from "@openzi/coding-agent"

import { ToolCallView, type ToolViewFrame } from "../../src/interactive/transcript/tool-view.js"
import { defaultTheme } from "../../src/theme.js"

test("completed Bash keeps compact evidence and details reveal bounded context and notices", async () => {
  const setup = await createTestRenderer({ width: 54, height: 16, useThread: false })
  const path = "/tmp/openzi/full-output.log"
  const view = new ToolCallView(
    setup.renderer,
    "bash-done",
    frame(
      "done",
      presentation({
        header: {
          label: "Run",
          subject: { type: "text", text: "unit tests" },
          secondary: { type: "command", text: "bun test", prompt: true },
          details: [],
          status: "truncated"
        },
        body: { type: "terminal", text: "41 passed\n1 failed" },
        notices: [{ type: "path", tone: "warning", visibility: "detailed", label: "Full output", path }],
        preview: { compact: { type: "tail", rows: 5 }, detailed: { type: "edges", head: 80, tail: 119 } }
      })
    ),
    defaultTheme,
    "/work",
    "Ctrl+O"
  )
  setup.renderer.root.add(view.root)

  try {
    await setup.renderOnce()
    const compact = setup.captureCharFrame()
    expect(compact).toContain("◆ Run unit tests · truncated")
    expect(compact).toContain("$ bun test")
    expect(compact).toContain("│ 41 passed")
    expect(compact).toContain("│ 1 failed")
    expect(compact).not.toContain(path)

    expect(view.setExpanded(true)).toBe(true)
    await setup.renderOnce()
    const detailed = setup.captureCharFrame()
    expect(detailed).toContain("◆ Run unit tests · truncated")
    expect(detailed).toContain("$ bun test")
    expect(detailed).toContain("│ 41 passed")
    expect(detailed).toContain(`Full output: ${path}`)
    expect(detailed).not.toContain("╭───")
    expect(detailed).toContain("╰───")
  } finally {
    view.destroy()
    setup.renderer.destroy()
  }
})

test("Bash preserves its tail body and exact command from running through completion", async () => {
  const setup = await createTestRenderer({ width: 48, height: 14, useThread: false })
  const view = new ToolCallView(
    setup.renderer,
    "bash-running",
    frame(
      "running",
      presentation({
        header: {
          label: "Run",
          subject: { type: "text", text: "unit tests" },
          secondary: { type: "command", text: "bun test", prompt: true },
          details: []
        },
        body: { type: "terminal", text: "one\ntwo\nthree\nfour\nfive\nsix\n" },
        preview: { compact: { type: "tail", rows: 5 }, detailed: { type: "tail", rows: 200 } }
      })
    ),
    defaultTheme,
    "/work",
    "Ctrl+O"
  )
  view.setActionHint("Ctrl+G background · Esc interrupt")
  setup.renderer.root.add(view.root)

  try {
    const root = view.root
    const body = toolBody(root)
    await setup.renderOnce()
    const rendered = setup.captureCharFrame()
    expect(rendered).toContain("◈ Run unit tests · 0.0s")
    expect(rendered).toContain("$ bun test")
    expect(rendered).toContain("… earlier output · Ctrl+O details")
    expect(rendered).toContain("│ six")
    expect(rendered).toContain("Ctrl+G background · Esc interrupt")

    expect(
      view.update(
        frame(
          "done",
          presentation({
            header: {
              label: "Run",
              subject: { type: "text", text: "unit tests" },
              secondary: { type: "command", text: "bun test", prompt: true },
              details: []
            },
            body: { type: "terminal", text: "one\ntwo\nthree\nfour\nfive\nsix\n" },
            preview: { compact: { type: "tail", rows: 5 }, detailed: { type: "edges", head: 80, tail: 119 } }
          })
        )
      )
    ).toBe(true)
    expect(view.setActionHint(undefined)).toBe(true)
    expect(view.root).toBe(root)
    expect(toolBody(root)).toBe(body)

    await setup.renderOnce()
    const completed = setup.captureCharFrame()
    expect(completed).toContain("◆ Run unit tests")
    expect(completed).toContain("$ bun test")
    expect(completed).toContain("… earlier output · Ctrl+O details")
    expect(completed).toContain("│ six")
    expect(completed).not.toContain("background · Esc interrupt")
  } finally {
    view.destroy()
    setup.renderer.destroy()
  }
})

test("failed semantic frame keeps first and last output with exact status", async () => {
  const setup = await createTestRenderer({ width: 48, height: 18, useThread: false })
  const view = new ToolCallView(
    setup.renderer,
    "bash-failed",
    frame(
      "failed",
      presentation({
        header: {
          label: "Run",
          subject: { type: "command", text: "bun test", prompt: false },
          details: [],
          status: "exit 1"
        },
        body: { type: "terminal", text: "one\ntwo\nthree\nfour\nfive\nsix\nseven" },
        notices: [{ type: "message", tone: "error", visibility: "always", text: "Command exited with code 1" }],
        preview: { compact: { type: "edges", head: 2, tail: 3 }, detailed: { type: "edges", head: 80, tail: 119 } }
      })
    ),
    defaultTheme,
    "/work",
    "Ctrl+O"
  )
  setup.renderer.root.add(view.root)

  try {
    await setup.renderOnce()
    const rendered = setup.captureCharFrame()
    expect(rendered).toContain("◆ Run bun test · exit 1")
    expect(rendered).toContain("│ one")
    expect(rendered).toContain("│ two")
    expect(rendered).toContain("… middle output · Ctrl+O details")
    expect(rendered).toContain("│ seven")
    expect(rendered).toContain("Command exited with code 1")

    const bullet = setup
      .captureSpans()
      .lines.flatMap(line => line.spans)
      .find(span => span.text === "◆ ")
    expect(bullet?.fg.toInts()).toEqual([228, 104, 118, 255])
  } finally {
    view.destroy()
    setup.renderer.destroy()
  }
})

test("detailed previews remain bounded without stale expansion hints", async () => {
  const setup = await createTestRenderer({ width: 40, height: 210, useThread: false })
  const output = Array.from({ length: 250 }, (_, index) => `line ${index + 1}`).join("\n")
  const view = new ToolCallView(
    setup.renderer,
    "bash-bounded",
    frame(
      "done",
      presentation({
        header: { label: "Run", subject: { type: "command", text: "many-lines", prompt: false }, details: [] },
        body: { type: "terminal", text: output },
        preview: { compact: { type: "tail", rows: 5 }, detailed: { type: "edges", head: 80, tail: 119 } }
      })
    ),
    defaultTheme,
    "/work",
    "Ctrl+O"
  )
  setup.renderer.root.add(view.root)

  try {
    view.setExpanded(true)
    await setup.renderOnce()
    const rendered = setup.captureCharFrame()
    expect(rendered).toContain("line 1")
    expect(rendered).toContain("line 250")
    expect(rendered).toContain("middle output")
    expect(rendered).not.toContain("Ctrl+O details")
    const body = view.root.getChildren()[1]
    if (!(body instanceof BoxRenderable)) throw new Error("Body not found")
    expect(body.getChildrenCount()).toBeLessThanOrEqual(200)
  } finally {
    view.destroy()
    setup.renderer.destroy()
  }
})

test("collapsing details clears native selection before removing rows", async () => {
  const setup = await createTestRenderer({ width: 24, height: 18, useThread: false })
  const view = new ToolCallView(
    setup.renderer,
    "selected-preview",
    frame(
      "done",
      presentation({
        header: { label: "Write", subject: { type: "path", path: "notes.txt" }, details: [] },
        body: { type: "text", text: "x".repeat(10_000), tone: "normal" },
        preview: { compact: { type: "hidden" }, detailed: { type: "head", rows: 200 } }
      })
    ),
    defaultTheme,
    "/work"
  )
  setup.renderer.root.add(view.root)

  try {
    view.setExpanded(true)
    await setup.renderOnce()
    const body = toolBody(view.root)
    const selected = lastSelectableText(body)
    setup.renderer.startSelection(selected, selected.x, selected.y)
    expect(setup.renderer.hasSelection).toBe(true)

    view.setExpanded(false)
    expect(setup.renderer.hasSelection).toBe(false)
  } finally {
    view.destroy()
    setup.renderer.destroy()
  }
})

test("body-kind replacement clears selection and preserves the tool root", async () => {
  const setup = await createTestRenderer({ width: 40, height: 12, useThread: false })
  const initial = frame(
    "running",
    presentation({
      header: { label: "Edit", subject: { type: "path", path: "file.ts" }, details: [] },
      body: { type: "text", text: "- before\n+ after", tone: "normal" },
      preview: { compact: { type: "head", rows: 12 }, detailed: { type: "head", rows: 200 } }
    })
  )
  const view = new ToolCallView(setup.renderer, "edit-replace", initial, defaultTheme, "/work")
  setup.renderer.root.add(view.root)

  try {
    await setup.renderOnce()
    const root = view.root
    const body = toolBody(root)
    const selected = lastSelectableText(body)
    setup.renderer.startSelection(selected, selected.x, selected.y)

    expect(
      view.update(
        frame("done", {
          ...initial.presentation,
          body: { type: "diff", text: "--- a/file.ts\n+++ b/file.ts\n-before\n+after", path: "file.ts" }
        })
      )
    ).toBe(true)
    expect(view.root).toBe(root)
    expect(setup.renderer.hasSelection).toBe(false)
  } finally {
    view.destroy()
    setup.renderer.destroy()
  }
})

test("Read stays compact after success and reveals bounded absolute source lines", async () => {
  const setup = await createTestRenderer({ width: 60, height: 210, useThread: false })
  const content = Array.from({ length: 240 }, (_, index) => `line ${index + 50}`).join("\n")
  const result = {
    content: [{ type: "text" as const, text: `${content}\n\n[continuation footer]` }],
    details: {
      outcome: "success" as const,
      startLine: 50,
      endLine: 289,
      totalLines: 400,
      nextOffset: 290,
      remainingLines: 111,
      truncation: {
        truncated: false,
        truncatedBy: null,
        totalLines: 240,
        totalBytes: Buffer.byteLength(content),
        outputLines: 240,
        outputBytes: Buffer.byteLength(content),
        firstLineExceedsLimit: false,
        lastLinePartial: false
      }
    }
  }
  const view = new ToolCallView(
    setup.renderer,
    "read-detailed",
    frame(
      "done",
      projectToolPresentation({
        status: "done",
        name: "read",
        args: { path: "src/long-example.ts", offset: 50, limit: 240 },
        result
      })
    ),
    defaultTheme,
    "/work",
    "Ctrl+O"
  )
  setup.renderer.root.add(view.root)

  try {
    const root = view.root
    await setup.renderOnce()
    const compact = setup.captureCharFrame()
    expect(compact).toContain("◆ Read long-example.ts")
    expect(compact).toContain("· 50-289 of 400")
    expect(compact).not.toContain("line 50")
    expect(compact).not.toContain("continue at offset")

    view.setExpanded(true)
    await setup.renderOnce()
    const detailed = setup.captureCharFrame()
    expect(view.root).toBe(root)
    expect(detailed).toContain("◆ Read src/long-example.ts · 50-289 of 400")
    expect(detailed).toContain("50 │ line 50")
    expect(detailed).toContain("289 │ line 289")
    expect(detailed).toContain("middle output")
    expect(detailed).toContain("111 lines remain; continue at offset 290")
    expect(detailed).not.toContain("continuation footer")

    const gutter = setup
      .captureSpans()
      .lines.flatMap(line => line.spans)
      .find(span => span.text.includes("50 │ "))
    expect(gutter?.fg.toInts()).toEqual([127, 131, 129, 255])
  } finally {
    view.destroy()
    setup.renderer.destroy()
  }
})

test("Read keeps one root from streamed path through numbered completion", async () => {
  const setup = await createTestRenderer({ width: 44, height: 12, useThread: false })
  const preparing = projectToolPresentation({ status: "preparing", name: "read", args: {} })
  const view = new ToolCallView(setup.renderer, "read-lifecycle", frame("preparing", preparing), defaultTheme, "/work")
  setup.renderer.root.add(view.root)

  try {
    const root = view.root
    for (const source of [
      { status: "ready" as const, name: "read", args: { path: "src/value.ts" } },
      { status: "running" as const, name: "read", args: { path: "src/value.ts" } },
      {
        status: "done" as const,
        name: "read",
        args: { path: "src/value.ts" },
        result: {
          content: [{ type: "text", text: "export const value = 42" }],
          details: {
            outcome: "success",
            startLine: 1,
            endLine: 1,
            totalLines: 1,
            truncation: {
              truncated: false,
              truncatedBy: null,
              totalLines: 1,
              totalBytes: 23,
              outputLines: 1,
              outputBytes: 23,
              firstLineExceedsLimit: false,
              lastLinePartial: false
            }
          }
        }
      }
    ]) {
      expect(view.update(frame(source.status, projectToolPresentation(source)))).toBe(true)
      expect(view.root).toBe(root)
    }

    view.setExpanded(true)
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("1 │ export const value = 42")
  } finally {
    view.destroy()
    setup.renderer.destroy()
  }
})

test("Write keeps one root and collapses completed content into a semantic success row", async () => {
  const setup = await createTestRenderer({ width: 64, height: 210, useThread: false })
  const path = "src/generated.ts"
  const content = Array.from({ length: 260 }, (_, index) => `line ${index + 1}`).join("\n")
  const bytes = Buffer.byteLength(content)
  const view = new ToolCallView(
    setup.renderer,
    "write-lifecycle",
    frame("preparing", projectToolPresentation({ status: "preparing", name: "write", args: {} })),
    defaultTheme,
    "/work",
    "Ctrl+O"
  )
  setup.renderer.root.add(view.root)

  try {
    const root = view.root
    for (const streamedContent of ["line 1", "line 1\nline 2\n"] as const) {
      expect(
        view.update(
          frame(
            "preparing",
            projectToolPresentation({ status: "preparing", name: "write", args: { path, content: streamedContent } })
          )
        )
      ).toBe(true)
      expect(view.root).toBe(root)
    }
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("◇ Write generated.ts · 2 lines so far")

    for (const source of [
      { status: "ready" as const, name: "write", args: { path, content } },
      { status: "running" as const, name: "write", args: { path, content } },
      {
        status: "done" as const,
        name: "write",
        args: { path, content },
        result: {
          content: [{ type: "text", text: `Successfully wrote ${path}` }],
          details: { outcome: "success", bytes, lines: 260 }
        }
      }
    ]) {
      expect(view.update(frame(source.status, projectToolPresentation(source)))).toBe(true)
      expect(view.root).toBe(root)
    }

    await setup.renderOnce()
    const compact = setup.captureCharFrame()
    expect(compact).toContain(`◆ Write generated.ts · 260 lines · ${bytes} bytes`)
    expect(compact).not.toContain("1 │ line 1")

    view.setExpanded(true)
    await setup.renderOnce()
    const detailed = setup.captureCharFrame()
    expect(view.root).toBe(root)
    expect(detailed).toContain(`◆ Write src/generated.ts · 260 lines · ${bytes} bytes`)
    expect(detailed).toContain("1 │ line 1")
    expect(detailed).toContain("199 │ line 199")
    expect(detailed).toContain("more output")
    expect(detailed).not.toContain("200 │ line 200")

    view.setExpanded(false)
    setup.resize(40, 210)
    await setup.renderOnce()
    await setup.renderOnce()
    const narrow = setup.captureCharFrame()
    expect(narrow).toContain("◆ Write generated.ts · 260 lines")
    expect(narrow).not.toContain(`${bytes} bytes`)
    expect(narrow).not.toContain("src/generated.ts")
  } finally {
    view.destroy()
    setup.renderer.destroy()
  }
})

test("Edit stays header-only in flight and reveals only the successful authoritative diff", async () => {
  const setup = await createTestRenderer({ width: 64, height: 40, useThread: false })
  const path = "src/example.ts"
  const first = { oldText: "old value", newText: "new value" }
  const partialArgs = { path, edits: [first, { oldText: "old tail" }] }
  const args = { path, edits: [first, { oldText: "old tail", newText: "new tail" }] }
  const view = new ToolCallView(
    setup.renderer,
    "edit-lifecycle",
    frame("preparing", projectToolPresentation({ status: "preparing", name: "edit", args: partialArgs })),
    defaultTheme,
    "/work",
    "Ctrl+O"
  )
  setup.renderer.root.add(view.root)

  try {
    const root = view.root
    await setup.renderOnce()
    const partial = setup.captureCharFrame()
    expect(partial).toContain("◇ Edit example.ts · 1 replacement so far")
    expect(partial).not.toContain("old value")
    expect(partial).not.toContain("new value")

    view.setExpanded(true)
    await setup.renderOnce()
    const expandedInFlight = setup.captureCharFrame()
    expect(expandedInFlight).toContain("◇ Edit src/example.ts · 1 replacement so far")
    expect(expandedInFlight).not.toContain("old value")
    view.setExpanded(false)

    expect(view.update(frame("preparing", projectToolPresentation({ status: "preparing", name: "edit", args })))).toBe(
      true
    )
    expect(view.root).toBe(root)
    await setup.renderOnce()
    const preparing = setup.captureCharFrame()
    expect(preparing).toContain("◇ Edit example.ts · 2 replacements so far")
    expect(preparing).not.toContain("old tail")
    expect(preparing).not.toContain("new tail")

    expect(view.update(frame("ready", projectToolPresentation({ status: "ready", name: "edit", args })))).toBe(true)
    await setup.renderOnce()
    const ready = setup.captureCharFrame()
    expect(ready).toContain("◇ Edit example.ts · 2 replacements · waiting")
    expect(ready).not.toContain("old value")

    expect(view.update(frame("running", projectToolPresentation({ status: "running", name: "edit", args })))).toBe(true)
    await setup.renderOnce()
    const running = setup.captureCharFrame()
    expect(running).toContain("◈ Edit example.ts · 2 replacements")
    expect(running).not.toContain("old value")

    const diff = [
      "--- a/src/example.ts",
      "+++ b/src/example.ts",
      "@@ -10,3 +10,3 @@",
      " context before",
      "-old value",
      "+new value that wraps across a constrained terminal width for coverage",
      " context after",
      "@@ -50,1 +50,2 @@",
      "---old tail",
      "+++new tail one",
      "+new tail two"
    ].join("\n")
    const source = {
      status: "done" as const,
      name: "edit",
      args,
      result: {
        content: [{ type: "text", text: `Successfully replaced 2 blocks in ${path}` }],
        details: {
          outcome: "success",
          replacements: 2,
          additions: 3,
          deletions: 2,
          diff,
          diffTruncated: false,
          firstChangedLine: 11
        }
      }
    }
    expect(view.update(frame("done", projectToolPresentation(source)))).toBe(true)
    expect(view.root).toBe(root)
    await setup.renderOnce()
    const compact = setup.captureCharFrame()
    expect(compact).toContain("◆ Edit example.ts +3/-2")
    expect(compact).toContain("11 − old value")
    expect(compact).toContain("11 + new value")
    expect(compact).toContain("… 37 unchanged lines")
    const compactSpans = setup.captureSpans().lines.flatMap(line => line.spans)
    expect(compactSpans.find(span => span.text === " +3")?.fg.toInts()).toEqual([152, 187, 108, 255])
    expect(compactSpans.find(span => span.text === "-2")?.fg.toInts()).toEqual([228, 104, 118, 255])
    expect(compact).not.toContain("@@")
    expect(compact).not.toContain("--- a/")

    view.setExpanded(true)
    await setup.renderOnce()
    const detailed = setup.captureCharFrame()
    expect(view.root).toBe(root)
    expect(detailed).toContain("◆ Edit src/example.ts")
    expect(detailed).not.toContain("+3/-2")
    expect(detailed).toContain("10   context before")
    expect(detailed).toContain("11 − old value")
    expect(detailed).toContain("11 + new value")
    expect(detailed).toContain("… 37 unchanged lines")
    expect(detailed).toContain("50 − --old tail")
    expect(detailed).toContain("50 + ++new tail one")
    expect(detailed).toContain("51 + new tail two")
    expect(detailed).not.toContain("--- a/")
    expect(detailed).not.toContain("@@ -")

    const spans = setup.captureSpans().lines.flatMap(line => line.spans)
    expect(spans.find(span => span.text === "11 ")?.fg.toInts()).toEqual([127, 131, 129, 255])
    expect(spans.find(span => span.text.startsWith("− "))?.fg.toInts()).toEqual([228, 104, 118, 255])
    expect(spans.find(span => span.text.startsWith("+ "))?.fg.toInts()).toEqual([152, 187, 108, 255])

    view.setExpanded(false)
    setup.resize(36, 20)
    await setup.renderOnce()
    await setup.renderOnce()
    const narrow = setup.captureCharFrame()
    expect(narrow).toContain("◆ Edit example.ts +3/-2")
  } finally {
    view.destroy()
    setup.renderer.destroy()
  }
})

test("completed Edit keeps a bounded first/last diff review in compact density", async () => {
  const setup = await createTestRenderer({ width: 48, height: 20, useThread: false })
  const removed = Array.from({ length: 15 }, (_, index) => `-old ${index + 1}`)
  const added = Array.from({ length: 15 }, (_, index) => `+new ${index + 1}`)
  const diff = ["--- a/file.ts", "+++ b/file.ts", "@@ -1,15 +1,15 @@", ...removed, ...added].join("\n")
  const view = new ToolCallView(
    setup.renderer,
    "edit-compact-edges",
    frame(
      "done",
      projectToolPresentation({
        status: "done",
        name: "edit",
        args: { path: "file.ts", edits: [{ oldText: removed.join("\n"), newText: added.join("\n") }] },
        result: {
          content: [{ type: "text", text: "Successfully replaced 1 block in file.ts" }],
          details: {
            outcome: "success",
            replacements: 1,
            additions: 15,
            deletions: 15,
            diff,
            diffTruncated: false,
            firstChangedLine: 1
          }
        }
      })
    ),
    defaultTheme,
    "/work",
    "Ctrl+O"
  )
  setup.renderer.root.add(view.root)

  try {
    await setup.renderOnce()
    const compact = setup.captureCharFrame()
    expect(compact).toContain("1 − old 1")
    expect(compact).toContain("5 − old 5")
    expect(compact).toContain("… middle output · Ctrl+O details")
    expect(compact).toContain("15 + new 15")
    expect(compact).not.toContain("old 6")
    const body = toolBody(view.root)
    expect(body.getChildrenCount()).toBe(11)
    expect(textWith(body, "… middle output · Ctrl+O details").selectable).toBe(false)
  } finally {
    view.destroy()
    setup.renderer.destroy()
  }
})

test("oversized Edit lines retain explicit changed-line evidence", async () => {
  const setup = await createTestRenderer({ width: 54, height: 10, useThread: false })
  const path = "long-line.txt"
  const diff = [
    "--- a/long-line.txt",
    "+++ b/long-line.txt",
    "@@ -1,1 +1,1 @@",
    "-… removed line omitted (60006 bytes)",
    "+… added line omitted (60007 bytes)"
  ].join("\n")
  const view = new ToolCallView(
    setup.renderer,
    "edit-long-line",
    frame(
      "done",
      projectToolPresentation({
        status: "done",
        name: "edit",
        args: { path, edits: [{ oldText: "UNIQUE", newText: "CHANGED" }] },
        result: {
          content: [{ type: "text", text: "Successfully replaced 1 block in long-line.txt" }],
          details: {
            outcome: "success",
            replacements: 1,
            additions: 1,
            deletions: 1,
            diff,
            diffTruncated: true,
            firstChangedLine: 1
          }
        }
      })
    ),
    defaultTheme,
    "/work",
    "Ctrl+O"
  )
  setup.renderer.root.add(view.root)

  try {
    await setup.renderOnce()
    const rendered = setup.captureCharFrame()
    expect(rendered).toContain("1 − … removed line omitted (60006 bytes)")
    expect(rendered).toContain("1 + … added line omitted (60007 bytes)")
    expect(rendered).not.toContain("--- a/")
    expect(rendered).not.toContain("@@ -")
  } finally {
    view.destroy()
    setup.renderer.destroy()
  }
})

test("failed Edit exposes one bounded semantic error", async () => {
  const setup = await createTestRenderer({ width: 48, height: 10, useThread: false })
  const view = new ToolCallView(
    setup.renderer,
    "edit-missing",
    frame(
      "failed",
      projectToolPresentation({
        status: "failed",
        name: "edit",
        args: { path: "src/example.ts", edits: [{ oldText: "private old", newText: "private new" }] },
        result: {
          content: [{ type: "text", text: "Could not find oldText in src/example.ts" }],
          details: { outcome: "error", reason: "match_missing", error: "Could not find oldText in src/example.ts" }
        }
      })
    ),
    defaultTheme,
    "/work",
    "Ctrl+O"
  )
  setup.renderer.root.add(view.root)

  try {
    await setup.renderOnce()
    const rendered = setup.captureCharFrame()
    expect(rendered).toContain("◆ Edit example.ts · match not found")
    expect(rendered).toContain("│ Could not find oldText in src/example.ts")
    expect(rendered.match(/Could not find/g)).toHaveLength(1)
    expect(rendered).not.toContain("private old")
    expect(rendered).not.toContain("private new")
  } finally {
    view.destroy()
    setup.renderer.destroy()
  }
})

test("failed Write uses semantic status and never echoes attempted content", async () => {
  const setup = await createTestRenderer({ width: 52, height: 10, useThread: false })
  const view = new ToolCallView(
    setup.renderer,
    "write-denied",
    frame(
      "failed",
      projectToolPresentation({
        status: "failed",
        name: "write",
        args: { path: "src/generated.ts", content: "private content" },
        result: {
          content: [{ type: "text", text: "Permission denied: src/generated.ts" }],
          details: {
            outcome: "error",
            reason: "permission_denied",
            bytes: 15,
            lines: 1,
            error: "Permission denied: src/generated.ts"
          }
        }
      })
    ),
    defaultTheme,
    "/work",
    "Ctrl+O"
  )
  setup.renderer.root.add(view.root)

  try {
    await setup.renderOnce()
    const rendered = setup.captureCharFrame()
    expect(rendered).toContain("◆ Write generated.ts · permission denied")
    expect(rendered).toContain("│ Permission denied: src/generated.ts")
    expect(rendered.match(/Permission denied/g)).toHaveLength(1)
    expect(rendered).not.toContain("private content")

    setup.resize(30, 10)
    await setup.renderOnce()
    await setup.renderOnce()
    const narrow = setup.captureCharFrame()
    expect(narrow).toContain("Write")
    expect(narrow).toContain("permission denied")
    expect(narrow).not.toContain("private content")
  } finally {
    view.destroy()
    setup.renderer.destroy()
  }
})

test("failed Read uses semantic status and one bounded error body", async () => {
  const setup = await createTestRenderer({ width: 48, height: 10, useThread: false })
  const view = new ToolCallView(
    setup.renderer,
    "read-missing",
    frame(
      "failed",
      projectToolPresentation({
        status: "failed",
        name: "read",
        args: { path: "src/missing.ts" },
        result: {
          content: [{ type: "text", text: "File not found: src/missing.ts" }],
          details: { outcome: "error", reason: "not_found", error: "File not found: src/missing.ts" }
        }
      })
    ),
    defaultTheme,
    "/work",
    "Ctrl+O"
  )
  setup.renderer.root.add(view.root)

  try {
    await setup.renderOnce()
    const rendered = setup.captureCharFrame()
    expect(rendered).toContain("◆ Read missing.ts · not found")
    expect(rendered).toContain("│ File not found: src/missing.ts")
    expect(rendered.match(/File not found/g)).toHaveLength(1)
  } finally {
    view.destroy()
    setup.renderer.destroy()
  }
})

test("tool chrome uses lifecycle-only glyphs, tones, and stable transparent rows", async () => {
  const setup = await createTestRenderer({ width: 36, height: 10, useThread: false })
  const makeFrame = (status: ToolViewFrame["status"]) =>
    frame(
      status,
      presentation({
        header: { label: "Tool", subject: { type: "text", text: "example" }, details: [] },
        body: { type: "text", text: "evidence", tone: "normal" },
        preview: { compact: { type: "head", rows: 12 }, detailed: { type: "head", rows: 200 } }
      })
    )
  const view = new ToolCallView(setup.renderer, "chrome", makeFrame("preparing"), defaultTheme, "/work")
  setup.renderer.root.add(view.root)

  try {
    const root = view.root
    const body = toolBody(root)
    const row = body.getChildren()[0]
    const expected = {
      preparing: { glyph: "◇ ", color: [127, 131, 129, 255] },
      ready: { glyph: "◇ ", color: [122, 168, 159, 255] },
      running: { glyph: "◈ ", color: [122, 168, 159, 255] },
      done: { glyph: "◆ ", color: [135, 169, 135, 255] },
      failed: { glyph: "◆ ", color: [228, 104, 118, 255] },
      aborted: { glyph: "◆ ", color: [228, 104, 118, 255] }
    } as const

    for (const status of ["preparing", "ready", "running", "done", "failed", "aborted"] as const) {
      if (status !== "preparing") view.update(makeFrame(status))
      // Lifecycle frames are asserted in transition order.
      // oxlint-disable-next-line no-await-in-loop
      await setup.renderOnce()
      expect(view.root).toBe(root)
      expect(toolBody(root).getChildren()[0]).toBe(row)
      const spans = setup.captureSpans().lines.flatMap(line => line.spans)
      expect(spans.find(span => span.text === expected[status].glyph)?.fg.toInts()).toEqual([...expected[status].color])
      expect(spans.find(span => span.text.startsWith("│ "))?.fg.toInts()).toEqual([...expected[status].color])
      expect(spans.find(span => span.text === "╰───")?.fg.toInts()).toEqual([...expected[status].color])
    }

    for (const renderable of descendants(view.root)) {
      if (renderable instanceof BoxRenderable) expect(renderable.backgroundColor.toInts()[3]).toBe(0)
      if (renderable instanceof TextRenderable) expect(renderable.bg.toInts()[3]).toBe(0)
    }
    const evidence = setup
      .captureSpans()
      .lines.flatMap(line => line.spans)
      .find(span => span.text === "evidence")
    expect(evidence?.fg.toInts()).toEqual([127, 131, 129, 255])
  } finally {
    view.destroy()
    setup.renderer.destroy()
  }
})

test("header-only, notices-only, and action-only tools share the open-rail grammar", async () => {
  const setup = await createTestRenderer({ width: 40, height: 16, useThread: false })
  const headerOnly = new ToolCallView(
    setup.renderer,
    "header-only",
    frame(
      "done",
      presentation({
        header: { label: "Read", subject: { type: "path", path: "config.ts" }, details: [] },
        preview: { compact: { type: "hidden" }, detailed: { type: "hidden" } }
      })
    ),
    defaultTheme,
    "/work"
  )
  const noticesOnly = new ToolCallView(
    setup.renderer,
    "notices-only",
    frame(
      "failed",
      presentation({
        header: { label: "Tool", details: [] },
        notices: [{ type: "message", tone: "warning", visibility: "always", text: "Check input" }],
        preview: { compact: { type: "hidden" }, detailed: { type: "hidden" } }
      })
    ),
    defaultTheme,
    "/work"
  )
  const actionOnly = new ToolCallView(
    setup.renderer,
    "action-only",
    frame(
      "running",
      presentation({
        header: { label: "Wait", details: [] },
        preview: { compact: { type: "hidden" }, detailed: { type: "hidden" } }
      })
    ),
    defaultTheme,
    "/work"
  )
  actionOnly.setActionHint("Esc interrupt")
  setup.renderer.root.add(headerOnly.root)
  setup.renderer.root.add(noticesOnly.root)
  setup.renderer.root.add(actionOnly.root)

  try {
    await setup.renderOnce()
    const rows = setup
      .captureCharFrame()
      .split("\n")
      .map(line => line.trimEnd())
    expect(rows).toContain(" ◆ Read config.ts")
    expect(rows.slice(rows.indexOf(" ◆ Read config.ts") + 1, rows.indexOf(" ◆ Tool · failed"))).not.toContain(" ╰───")
    const notice = rows.indexOf(" │ Check input")
    const action = rows.indexOf(" │ Esc interrupt")
    expect(rows[notice + 1]).toBe(" ╰───")
    expect(rows[action + 1]).toBe(" ╰───")
  } finally {
    headerOnly.destroy()
    noticesOnly.destroy()
    actionOnly.destroy()
    setup.renderer.destroy()
  }
})

test("wrapped secondary commands copy exactly without decorative prompts or visual newlines", async () => {
  const setup = await createTestRenderer({ width: 24, height: 20, useThread: false })
  const command = "bun run --filter @openzi/tui test --watch=false"
  const view = new ToolCallView(
    setup.renderer,
    "wrapped-command",
    frame(
      "done",
      presentation({
        header: {
          label: "Run",
          subject: { type: "text", text: "TUI tests" },
          secondary: { type: "command", text: command, prompt: true },
          details: []
        },
        body: { type: "terminal", text: "passed" },
        preview: { compact: { type: "head", rows: 12 }, detailed: { type: "head", rows: 200 } }
      })
    ),
    defaultTheme,
    "/work"
  )
  setup.renderer.root.add(view.root)

  try {
    await setup.renderOnce()
    const content = textWith(view.root, command)
    expect(content.height).toBeGreaterThan(1)
    setup.renderer.startSelection(content, content.x, content.y)
    setup.renderer.updateSelection(content, content.x + content.width, content.y + content.height - 1, {
      finishDragging: true
    })
    expect(setup.renderer.getSelection()?.getSelectedText()).toBe(command)
    expect(setup.renderer.getSelection()?.getSelectedText()).not.toContain("$ ")
    expect(setup.renderer.getSelection()?.getSelectedText()).not.toContain("\n")
  } finally {
    view.destroy()
    setup.renderer.destroy()
  }
})

test("wrapped path notices preserve exact selection and reserve visible path cells", async () => {
  const setup = await createTestRenderer({ width: 24, height: 24, useThread: false })
  const path = "/tmp/very-long-path/to/full-output.log"
  const view = new ToolCallView(
    setup.renderer,
    "wrapped-path",
    frame(
      "failed",
      presentation({
        header: { label: "Run", details: [] },
        notices: [{ type: "path", tone: "warning", visibility: "always", label: "Full output", path }],
        preview: { compact: { type: "hidden" }, detailed: { type: "hidden" } }
      })
    ),
    defaultTheme,
    "/work",
    "Ctrl+O"
  )
  setup.renderer.root.add(view.root)

  try {
    await setup.renderOnce()
    const content = textWith(view.root, path)
    expect(content.height).toBeGreaterThan(1)
    setup.renderer.startSelection(content, content.x, content.y)
    setup.renderer.updateSelection(content, content.x + content.width, content.y + content.height - 1, {
      finishDragging: true
    })
    expect(setup.renderer.getSelection()?.getSelectedText()).toBe(path)
    expect(setup.renderer.getSelection()?.getSelectedText()).not.toContain("\n")
    setup.renderer.clearSelection()

    setup.resize(5, 24)
    await setup.renderOnce()
    await setup.renderOnce()
    expect(
      setup
        .captureCharFrame()
        .split("\n")
        .some(row => row.includes("│ /"))
    ).toBe(true)
  } finally {
    view.destroy()
    setup.renderer.destroy()
  }
})

test("hiding a secondary command clears its native selection", async () => {
  const setup = await createTestRenderer({ width: 32, height: 12, useThread: false })
  const withCommand = presentation({
    header: {
      label: "Run",
      subject: { type: "text", text: "tests" },
      secondary: { type: "command", text: "bun test", prompt: true },
      details: []
    },
    body: { type: "terminal", text: "running" },
    preview: { compact: { type: "head", rows: 12 }, detailed: { type: "head", rows: 200 } }
  })
  const view = new ToolCallView(setup.renderer, "hide-command", frame("running", withCommand), defaultTheme, "/work")
  setup.renderer.root.add(view.root)

  try {
    await setup.renderOnce()
    const command = textWith(view.root, "bun test")
    selectText(setup.renderer, command)
    expect(setup.renderer.hasSelection).toBe(true)

    view.update(
      frame("running", {
        ...withCommand,
        header: { label: "Run", subject: { type: "text", text: "tests" }, details: [] }
      })
    )
    expect(setup.renderer.hasSelection).toBe(false)
    await setup.renderOnce()
    expect(setup.captureCharFrame()).not.toContain("bun test")
  } finally {
    view.destroy()
    setup.renderer.destroy()
  }
})

test("trailing-LF commands keep a rail on every bounded visual row", async () => {
  const setup = await createTestRenderer({ width: 40, height: 18, useThread: false })
  const command = "x\n".repeat(11)
  const presentationFor = (text: string) =>
    presentation({
      header: {
        label: "Run",
        subject: { type: "text", text: "lines" },
        secondary: { type: "command", text, prompt: true },
        details: []
      },
      body: { type: "terminal", text: "ok" },
      preview: { compact: { type: "head", rows: 12 }, detailed: { type: "head", rows: 200 } }
    })
  const view = new ToolCallView(
    setup.renderer,
    "trailing-lf",
    frame("done", presentationFor(command)),
    defaultTheme,
    "/work",
    "Ctrl+O"
  )
  setup.renderer.root.add(view.root)

  try {
    await setup.renderOnce()
    const secondary = view.root.getChildren()[1]
    if (!(secondary instanceof BoxRenderable)) throw new Error("Secondary root not found")
    expect(secondary.height).toBe(12)
    expect(textWith(secondary, Array.from({ length: 12 }, () => "│ ").join("\n"))).toBeDefined()
    expect(
      descendants(secondary).some(row => row instanceof TextRenderable && row.plainText.includes("more context"))
    ).toBe(false)

    view.update(frame("done", presentationFor("x\n".repeat(12))))
    await setup.renderOnce()
    expect(secondary.height).toBeLessThanOrEqual(12)
    expect(
      descendants(secondary).some(row => row instanceof TextRenderable && row.plainText.includes("more context"))
    ).toBe(true)
  } finally {
    view.destroy()
    setup.renderer.destroy()
  }
})

test("tab-heavy commands and paths stay inside projected rail bounds", async () => {
  const setup = await createTestRenderer({ width: 10, height: 220, useThread: false })
  const tabs = "\t".repeat(500)
  const command = new ToolCallView(
    setup.renderer,
    "tab-command",
    frame(
      "done",
      presentation({
        header: {
          label: "Run",
          subject: { type: "text", text: "tabs" },
          secondary: { type: "command", text: tabs, prompt: true },
          details: []
        },
        body: { type: "terminal", text: "ok" },
        preview: { compact: { type: "head", rows: 12 }, detailed: { type: "head", rows: 200 } }
      })
    ),
    defaultTheme,
    "/work",
    "Ctrl+O"
  )
  const path = new ToolCallView(
    setup.renderer,
    "tab-path",
    frame(
      "failed",
      presentation({
        header: { label: "Run", details: [] },
        notices: [{ type: "path", tone: "warning", visibility: "always", label: "Output", path: tabs }],
        preview: { compact: { type: "hidden" }, detailed: { type: "hidden" } }
      })
    ),
    defaultTheme,
    "/work",
    "Ctrl+O"
  )
  setup.renderer.root.add(command.root)
  setup.renderer.root.add(path.root)

  try {
    await setup.renderOnce()
    const secondary = command.root.getChildren()[1]
    const notices = path.root.getChildren()[3]
    if (!(secondary instanceof BoxRenderable) || !(notices instanceof BoxRenderable)) {
      throw new Error("Tabbed subordinate roots not found")
    }
    expect(secondary.height).toBeLessThanOrEqual(12)
    expect(notices.height).toBeLessThanOrEqual(12)
    const commandContent = descendants(secondary).find(
      row => row instanceof TextRenderable && row.selectable && row.plainText.includes("\t")
    )
    const commandRail = descendants(secondary).find(
      row => row instanceof TextRenderable && row.plainText.includes("│ \n")
    )
    const pathContent = descendants(notices).find(
      row => row instanceof TextRenderable && row.selectable && row.plainText.includes("\t")
    )
    const pathRail = descendants(notices).find(row => row instanceof TextRenderable && row.plainText.includes("│ \n"))
    if (
      !(commandContent instanceof TextRenderable) ||
      !(commandRail instanceof TextRenderable) ||
      !(pathContent instanceof TextRenderable) ||
      !(pathRail instanceof TextRenderable)
    ) {
      throw new Error("Tabbed content and rails not found")
    }
    expect(commandRail.plainText.split("\n")).toHaveLength(commandContent.height)
    expect(pathRail.plainText.split("\n")).toHaveLength(pathContent.height)
    expect(
      [...descendants(secondary), ...descendants(notices)].filter(
        row => row instanceof TextRenderable && row.plainText.includes("more")
      )
    ).toHaveLength(2)

    command.setExpanded(true)
    path.setExpanded(true)
    await setup.renderOnce()
    expect(secondary.height).toBeLessThanOrEqual(200)
    expect(notices.height).toBeLessThanOrEqual(200)
  } finally {
    command.destroy()
    path.destroy()
    setup.renderer.destroy()
  }
})

test("ordinary tabbed tool evidence uses native cell projection", async () => {
  const setup = await createTestRenderer({ width: 10, height: 90, useThread: false })
  const tabs = "\t".repeat(500)
  const preview = { compact: { type: "head" as const, rows: 12 }, detailed: { type: "head" as const, rows: 200 } }
  const bodyView = (id: string, body: NonNullable<ToolPresentation["body"]>) =>
    new ToolCallView(
      setup.renderer,
      id,
      frame("done", presentation({ header: { label: "Tool", details: [] }, body, preview })),
      defaultTheme,
      "/work",
      "Ctrl+O"
    )
  const terminal = bodyView("tab-terminal", { type: "terminal", text: tabs })
  const source = bodyView("tab-source", { type: "source", text: tabs, path: "file.ts", startLine: 1 })
  const diff = bodyView("tab-diff", { type: "diff", text: `+${tabs}` })
  const secondary = new ToolCallView(
    setup.renderer,
    "tab-secondary-text",
    frame(
      "done",
      presentation({
        header: { label: "Tool", secondary: { type: "text", text: tabs }, details: [] },
        body: { type: "terminal", text: "ok" },
        preview
      })
    ),
    defaultTheme,
    "/work",
    "Ctrl+O"
  )
  const notice = new ToolCallView(
    setup.renderer,
    "tab-message-notice",
    frame(
      "failed",
      presentation({
        header: { label: "Tool", details: [] },
        notices: [{ type: "message", tone: "warning", visibility: "always", text: tabs }],
        preview: { compact: { type: "hidden" }, detailed: { type: "hidden" } }
      })
    ),
    defaultTheme,
    "/work",
    "Ctrl+O"
  )
  const views = [terminal, source, diff, secondary, notice]
  for (const view of views) setup.renderer.root.add(view.root)

  try {
    await setup.renderOnce()
    for (const view of [terminal, source, diff]) {
      const body = toolBody(view.root)
      expect(body.getChildrenCount()).toBeLessThanOrEqual(12)
      for (const row of body.getChildren()) expect(textWith(row, "│ ")).toBeDefined()
      expect(descendants(body).some(row => row instanceof TextRenderable && row.plainText.includes("output"))).toBe(
        true
      )
    }
    const secondaryRows = secondary.root.getChildren()[1]
    const noticeRows = notice.root.getChildren()[3]
    if (!(secondaryRows instanceof BoxRenderable) || !(noticeRows instanceof BoxRenderable)) {
      throw new Error("Tabbed ordinary evidence roots not found")
    }
    expect(secondaryRows.height).toBeLessThanOrEqual(12)
    expect(noticeRows.height).toBeLessThanOrEqual(12)
    expect(
      descendants(secondaryRows).some(row => row instanceof TextRenderable && row.plainText.includes("context"))
    ).toBe(true)
    expect(
      descendants(noticeRows).some(row => row instanceof TextRenderable && row.plainText.includes("notices"))
    ).toBe(true)

    for (const view of views) view.setExpanded(true)
    await setup.renderOnce()
    for (const view of [terminal, source, diff]) expect(toolBody(view.root).getChildrenCount()).toBeLessThanOrEqual(200)
    expect(secondaryRows.height).toBeLessThanOrEqual(200)
    expect(noticeRows.height).toBeLessThanOrEqual(200)
  } finally {
    for (const view of views) view.destroy()
    setup.renderer.destroy()
  }
})

test("secondary context and notices retain bounded visual rows", async () => {
  const setup = await createTestRenderer({ width: 10, height: 220, useThread: false })
  const secondary = new ToolCallView(
    setup.renderer,
    "bounded-secondary",
    frame(
      "done",
      presentation({
        header: {
          label: "Run",
          subject: { type: "text", text: "bounded" },
          secondary: { type: "command", text: "x".repeat(4_096), prompt: true },
          details: []
        },
        body: { type: "terminal", text: "ok" },
        preview: { compact: { type: "head", rows: 12 }, detailed: { type: "head", rows: 200 } }
      })
    ),
    defaultTheme,
    "/work",
    "Ctrl+O"
  )
  const notices = new ToolCallView(
    setup.renderer,
    "bounded-notices",
    frame(
      "failed",
      presentation({
        header: { label: "Tool", details: [] },
        notices: Array.from({ length: 8 }, () => ({
          type: "message" as const,
          tone: "warning" as const,
          visibility: "always" as const,
          text: "n".repeat(4_096)
        })),
        preview: { compact: { type: "hidden" }, detailed: { type: "hidden" } }
      })
    ),
    defaultTheme,
    "/work",
    "Ctrl+O"
  )
  setup.renderer.root.add(secondary.root)
  setup.renderer.root.add(notices.root)

  try {
    await setup.renderOnce()
    const secondaryRows = secondary.root.getChildren()[1]
    const noticeRows = notices.root.getChildren()[3]
    if (!(secondaryRows instanceof BoxRenderable) || !(noticeRows instanceof BoxRenderable)) {
      throw new Error("Bounded subordinate roots not found")
    }
    expect(secondaryRows.height).toBeLessThanOrEqual(12)
    expect(noticeRows.getChildrenCount()).toBeLessThanOrEqual(12)
    expect(
      [...descendants(secondaryRows), ...descendants(noticeRows)].some(
        row => row instanceof TextRenderable && row.plainText.includes("Ctrl+O details")
      )
    ).toBe(true)

    secondary.setExpanded(true)
    notices.setExpanded(true)
    await setup.renderOnce()
    expect(secondaryRows.height).toBeLessThanOrEqual(200)
    expect(noticeRows.getChildrenCount()).toBeLessThanOrEqual(200)
  } finally {
    secondary.destroy()
    notices.destroy()
    setup.renderer.destroy()
  }
})

test("source, diff, terminal, and command selection excludes structural chrome", async () => {
  const setup = await createTestRenderer({ width: 52, height: 24, useThread: false })
  const view = new ToolCallView(
    setup.renderer,
    "selection",
    frame(
      "done",
      presentation({
        header: {
          label: "Run",
          subject: { type: "text", text: "selection" },
          secondary: { type: "command", text: "bun test", prompt: true },
          details: []
        },
        body: { type: "diff", text: "-before\n+after" },
        notices: [],
        preview: { compact: { type: "head", rows: 12 }, detailed: { type: "head", rows: 200 } }
      })
    ),
    defaultTheme,
    "/work"
  )
  const terminal = new ToolCallView(
    setup.renderer,
    "terminal-selection",
    frame(
      "done",
      presentation({
        header: { label: "Run", details: [] },
        body: { type: "terminal", text: "terminal output" },
        preview: { compact: { type: "head", rows: 12 }, detailed: { type: "head", rows: 200 } }
      })
    ),
    defaultTheme,
    "/work"
  )
  const source = new ToolCallView(
    setup.renderer,
    "source-selection",
    frame(
      "done",
      presentation({
        header: { label: "Read", details: [] },
        body: { type: "source", text: "source output", path: "file.ts", startLine: 41 },
        preview: { compact: { type: "head", rows: 12 }, detailed: { type: "head", rows: 200 } }
      })
    ),
    defaultTheme,
    "/work"
  )
  setup.renderer.root.add(view.root)
  setup.renderer.root.add(terminal.root)
  setup.renderer.root.add(source.root)

  try {
    await setup.renderOnce()
    const command = textWith(view.root, "bun test")
    selectText(setup.renderer, command)
    expect(setup.renderer.getSelection()?.getSelectedText()).toBe("bun test")
    setup.renderer.clearSelection()

    const diff = toolBody(view.root)
    const marker = textWith(diff, "− ")
    const content = textWith(diff, "before")
    setup.renderer.startSelection(marker, marker.x, marker.y)
    setup.renderer.updateSelection(content, content.x + content.width, content.y, { finishDragging: true })
    expect(setup.renderer.getSelection()?.getSelectedText()).toBe("− before")
    expect(setup.renderer.getSelection()?.getSelectedText()).not.toContain("│")
    expect(setup.renderer.getSelection()?.getSelectedText()).not.toContain("╰")
    setup.renderer.clearSelection()

    const terminalContent = textWith(terminal.root, "terminal output")
    selectText(setup.renderer, terminalContent)
    expect(setup.renderer.getSelection()?.getSelectedText()).toBe("terminal output")
    setup.renderer.clearSelection()

    const sourceContent = textWith(source.root, "source output")
    selectText(setup.renderer, sourceContent)
    expect(setup.renderer.getSelection()?.getSelectedText()).toBe("source output")
    expect(setup.renderer.getSelection()?.getSelectedText()).not.toContain("41")
    expect(setup.renderer.getSelection()?.getSelectedText()).not.toContain("│")
  } finally {
    view.destroy()
    terminal.destroy()
    source.destroy()
    setup.renderer.destroy()
  }
})

test("source bodies keep semantic starting line numbers in the lightweight panel", async () => {
  const setup = await createTestRenderer({ width: 40, height: 10, useThread: false })
  const view = new ToolCallView(
    setup.renderer,
    "read-lines",
    frame(
      "done",
      presentation({
        header: { label: "Read", subject: { type: "path", path: "file.ts" }, details: [] },
        body: { type: "source", text: "first\nsecond", path: "file.ts", startLine: 41 },
        preview: { compact: { type: "head", rows: 10 }, detailed: { type: "head", rows: 200 } }
      })
    ),
    defaultTheme,
    "/work"
  )
  setup.renderer.root.add(view.root)

  try {
    await setup.renderOnce()
    const rendered = setup.captureCharFrame()
    expect(rendered).toContain("41 │ first")
    expect(rendered).toContain("42 │ second")
  } finally {
    view.destroy()
    setup.renderer.destroy()
  }
})

function descendants(root: Renderable): Renderable[] {
  const result: Renderable[] = []
  const pending = [...root.getChildren()]
  while (pending.length > 0) {
    const candidate = pending.shift()!
    result.push(candidate)
    pending.push(...candidate.getChildren())
  }
  return result
}

function textWith(root: Renderable, text: string): TextRenderable {
  const found = descendants(root).find(
    (candidate): candidate is TextRenderable => candidate instanceof TextRenderable && candidate.plainText === text
  )
  if (!found) throw new Error(`Text renderable not found: ${text}`)
  return found
}

function selectText(renderer: RenderContext, renderable: TextRenderable): void {
  renderer.startSelection(renderable, renderable.x, renderable.y)
  renderer.updateSelection(renderable, renderable.x + renderable.width, renderable.y, { finishDragging: true })
}

function toolBody(root: BoxRenderable): BoxRenderable {
  const body = root.getChildren()[3]
  if (!(body instanceof BoxRenderable)) throw new Error("Tool body not found")
  return body
}

function lastSelectableText(root: BoxRenderable): TextRenderable {
  const pending = [...root.getChildren()]
  let selected: TextRenderable | undefined
  while (pending.length > 0) {
    const candidate = pending.shift()!
    if (candidate instanceof TextRenderable && candidate.selectable) selected = candidate
    pending.push(...candidate.getChildren())
  }
  if (!selected) throw new Error("Selectable tool content not found")
  return selected
}

function presentation(
  overrides: Omit<ToolPresentation, "notices" | "timing"> & Partial<Pick<ToolPresentation, "notices" | "timing">>
): ToolPresentation {
  return { notices: [], timing: "duration", ...overrides }
}

function frame(status: ToolViewFrame["status"], presentationValue: ToolPresentation): ToolViewFrame {
  return { status, presentation: presentationValue }
}
