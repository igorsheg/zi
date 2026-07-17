import { expect, test } from "bun:test"

import { BoxRenderable, TextRenderable } from "@opentui/core"
import { createTestRenderer } from "@opentui/core/testing"

import { ToolCallView, type ToolViewFrame } from "../../src/interactive/transcript/tool-view.js"
import { defaultTheme } from "../../src/theme.js"

test("terminal body owns action, rail, and output styling", async () => {
  const setup = await createTestRenderer({ width: 36, height: 10, useThread: false })
  const root = appRoot(setup.renderer)
  const view = new ToolCallView(
    setup.renderer,
    "bash-running",
    frame("running", {
      header: { label: "Bash", subject: { type: "command", text: "echo hi" }, details: [] },
      body: { type: "terminal", text: "hi\nthere" },
      notices: [],
      preview: { type: "tail", rows: 5 }
    }),
    defaultTheme,
    "/work"
  )
  root.add(view.root)
  setup.renderer.root.add(root)

  try {
    await setup.renderOnce()
    const rendered = setup.captureCharFrame()
    expect(rendered).toContain("Bash $ echo hi")
    expect(rendered).toContain("╭───")
    expect(rendered).toContain("│ hi")
    expect(rendered).toContain("│ there")
    expect(rendered).toContain("╰───")

    const spans = setup.captureSpans().lines.flatMap(line => line.spans)
    expect(spans.find(span => span.text === "$ echo hi")?.fg.toInts()).toEqual([230, 195, 132, 255])
    expect(spans.find(span => span.text === "╭───")?.fg.toInts()).toEqual([122, 168, 159, 255])
  } finally {
    view.destroy()
    setup.renderer.destroy()
  }
})

test("failed semantic frame uses error lifecycle chrome", async () => {
  const setup = await createTestRenderer({ width: 40, height: 8, useThread: false })
  const view = new ToolCallView(
    setup.renderer,
    "edit-failed",
    frame("failed", {
      header: { label: "Edit", subject: { type: "path", path: "source.ts" }, details: [] },
      body: { type: "text", text: "No match found", tone: "error" },
      notices: [],
      preview: { type: "head", rows: 10 }
    }),
    defaultTheme,
    "/work"
  )
  setup.renderer.root.add(view.root)

  try {
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("Edit source.ts (error)")
    const rail = setup
      .captureSpans()
      .lines.flatMap(line => line.spans)
      .find(span => span.text === "╭───")
    expect(rail?.fg.toInts()).toEqual([228, 104, 118, 255])
  } finally {
    view.destroy()
    setup.renderer.destroy()
  }
})

test("compact previews truncate after cell wrapping and expand without replacing roots", async () => {
  const setup = await createTestRenderer({ width: 24, height: 18, useThread: false })
  const view = new ToolCallView(
    setup.renderer,
    "write-stream",
    frame("preparing", {
      header: { label: "Write", subject: { type: "path", path: "notes.txt" }, details: [] },
      body: { type: "source", text: "x".repeat(10_000), path: "notes.txt" },
      notices: [],
      preview: { type: "head", rows: 10 }
    }),
    defaultTheme,
    "/work",
    "Ctrl+O"
  )
  setup.renderer.root.add(view.root)

  try {
    await setup.flush()
    expect(setup.captureCharFrame()).toContain("… Ctrl+O to expand")
    const root = view.root

    expect(view.setExpanded(true)).toBe(true)
    await setup.renderOnce()
    expect(view.root).toBe(root)
    const body = view.root.getChildren()[1]
    if (!(body instanceof BoxRenderable)) throw new Error("Body not found")
    expect(body.getChildrenCount()).toBeLessThanOrEqual(202)
    expect(setup.captureCharFrame()).not.toContain("… Ctrl+O to expand")
  } finally {
    view.destroy()
    setup.renderer.destroy()
  }
})

test("expanded tail previews retain newest output without an expand hint", async () => {
  const setup = await createTestRenderer({ width: 40, height: 210, useThread: false })
  const output = Array.from({ length: 250 }, (_, index) => `line ${index + 1}`).join("\n")
  const view = new ToolCallView(
    setup.renderer,
    "bash-tail-expand",
    frame("done", {
      header: { label: "Bash", subject: { type: "command", text: "many-lines" }, details: [] },
      body: { type: "terminal", text: output },
      notices: [],
      preview: { type: "tail", rows: 5 }
    }),
    defaultTheme,
    "/work",
    "Ctrl+O"
  )
  setup.renderer.root.add(view.root)

  try {
    view.setExpanded(true)
    await setup.renderOnce()
    const rendered = setup.captureCharFrame()
    expect(rendered).toContain("line 250")
    expect(rendered).not.toContain("line 1\n")
    expect(rendered).not.toContain("Ctrl+O to expand")
    expect(rendered).toContain("earlier output")
  } finally {
    view.destroy()
    setup.renderer.destroy()
  }
})

test("collapsing a body clears native selection before removing preview rows", async () => {
  const setup = await createTestRenderer({ width: 24, height: 18, useThread: false })
  const view = new ToolCallView(
    setup.renderer,
    "selected-preview",
    frame("preparing", {
      header: { label: "Write", subject: { type: "path", path: "notes.txt" }, details: [] },
      body: { type: "text", text: "x".repeat(10_000), tone: "normal" },
      notices: [],
      preview: { type: "head", rows: 10 }
    }),
    defaultTheme,
    "/work",
    "Ctrl+O"
  )
  setup.renderer.root.add(view.root)

  try {
    view.setExpanded(true)
    await setup.renderOnce()
    const body = view.root.getChildren()[1]
    if (!(body instanceof BoxRenderable)) throw new Error("Body not found")
    const selected = body.getChildren().at(-2)
    if (!(selected instanceof TextRenderable)) throw new Error("Expanded preview row not found")
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
  const initial = frame("running", {
    header: { label: "Edit", subject: { type: "path", path: "file.ts" }, details: [] },
    body: { type: "text", text: "- before\n+ after", tone: "normal" },
    notices: [],
    preview: { type: "head", rows: 12 }
  })
  const view = new ToolCallView(setup.renderer, "edit-replace", initial, defaultTheme, "/work")
  setup.renderer.root.add(view.root)

  try {
    await setup.renderOnce()
    const root = view.root
    const body = root.getChildren()[1]
    if (!(body instanceof BoxRenderable)) throw new Error("Body not found")
    const selected = body.getChildren().at(-2)
    if (!(selected instanceof TextRenderable)) throw new Error("Preview row not found")
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

test("notices remain visible outside hidden body previews", async () => {
  const setup = await createTestRenderer({ width: 60, height: 12, useThread: false })
  const path = "/tmp/openzi/full-output.log"
  const view = new ToolCallView(
    setup.renderer,
    "read-hidden",
    frame("done", {
      header: { label: "Read", subject: { type: "path", path: "large.ts" }, details: ["1-10"] },
      body: { type: "source", text: "hidden source", path: "large.ts", startLine: 1 },
      notices: [{ type: "path", tone: "warning", label: "Full output", path }],
      preview: { type: "hidden" }
    }),
    defaultTheme,
    "/work"
  )
  setup.renderer.root.add(view.root)

  try {
    await setup.renderOnce()
    const rendered = setup.captureCharFrame()
    expect(rendered).not.toContain("hidden source")
    expect(rendered).toContain(`Full output: ${path}`)
  } finally {
    view.destroy()
    setup.renderer.destroy()
  }
})

test("source bodies render semantic starting line numbers", async () => {
  const setup = await createTestRenderer({ width: 40, height: 10, useThread: false })
  const view = new ToolCallView(
    setup.renderer,
    "read-lines",
    frame("failed", {
      header: { label: "Read", subject: { type: "path", path: "file.ts" }, details: [] },
      body: { type: "source", text: "first\nsecond", path: "file.ts", startLine: 41 },
      notices: [],
      preview: { type: "head", rows: 10 }
    }),
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

function frame(status: ToolViewFrame["status"], presentation: ToolViewFrame["presentation"]): ToolViewFrame {
  return { status, presentation }
}

function appRoot(renderer: ConstructorParameters<typeof BoxRenderable>[0]): BoxRenderable {
  return new BoxRenderable(renderer, { width: "100%", height: "100%", backgroundColor: defaultTheme.surface.app })
}
