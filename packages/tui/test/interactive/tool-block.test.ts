import { expect, test } from "bun:test"

import { BoxRenderable, TextRenderable } from "@opentui/core"
import { createTestRenderer } from "@opentui/core/testing"

import { createCommandToolBlock, createToolBlock, ToolCallView } from "../../src/interactive/transcript/tool-view.js"
import { defaultTheme } from "../../src/theme.js"

test("tool block owns title, rail, and body styling", async () => {
  const setup = await createTestRenderer({ width: 30, height: 8, useThread: false })
  const root = appRoot(setup.renderer)
  root.add(
    createCommandToolBlock(
      setup.renderer,
      { title: "$ echo hi", output: "hi\nthere\n", status: "running" },
      defaultTheme
    )
  )
  setup.renderer.root.add(root)

  try {
    await setup.renderOnce()
    const frame = setup.captureCharFrame()
    expect(frame).toContain(" $ echo hi")
    expect(frame).toContain(" ╭───")
    expect(frame).toContain(" │ hi")
    expect(frame).toContain(" │ there")
    expect(frame).toContain(" ╰───")

    const spans = setup.captureSpans().lines.flatMap(line => line.spans)
    expect(spans.find(span => span.text === "$ echo hi")?.fg.toInts()).toEqual([230, 195, 132, 255])
    expect(spans.find(span => span.text === "╭───")?.fg.toInts()).toEqual([122, 168, 159, 255])
    expect(spans.find(span => span.text === "hi")?.fg.toInts()).toEqual([127, 131, 129, 255])
  } finally {
    root.destroyRecursively()
    setup.renderer.destroy()
  }
})

test("failed tool block uses the error rail and terminal suffix", async () => {
  const setup = await createTestRenderer({ width: 40, height: 8, useThread: false })
  const block = createToolBlock(
    setup.renderer,
    { title: "edit source.ts", output: "No match found", status: "failed" },
    defaultTheme
  )
  setup.renderer.root.add(block)

  try {
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("edit source.ts (error)")
    const rail = setup
      .captureSpans()
      .lines.flatMap(line => line.spans)
      .find(span => span.text === "╭───")
    expect(rail?.fg.toInts()).toEqual([228, 104, 118, 255])
  } finally {
    block.destroyRecursively()
    setup.renderer.destroy()
  }
})

test("generic tool blocks keep the head of bounded output", async () => {
  const output = Array.from({ length: 14 }, (_, index) => `line ${index}`).join("\n")
  const setup = await createTestRenderer({ width: 40, height: 16, useThread: false })
  const block = createToolBlock(setup.renderer, { title: "read file", output, status: "done" }, defaultTheme)
  setup.renderer.root.add(block)

  try {
    await setup.renderOnce()
    const frame = setup.captureCharFrame()
    expect(frame).toContain("line 0")
    expect(frame).toContain("line 9")
    expect(frame).not.toContain("line 10")
    expect(frame).toContain("... (4 more lines)")
  } finally {
    block.destroyRecursively()
    setup.renderer.destroy()
  }
})

test("streamed write arguments truncate after visual wrapping and expand in place", async () => {
  const setup = await createTestRenderer({ width: 24, height: 18, useThread: false })
  const view = new ToolCallView(
    setup.renderer,
    {
      id: "write-stream",
      name: "write",
      args: { path: "notes.txt", content: "x".repeat(10_000) },
      status: "preparing"
    },
    defaultTheme,
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
    expect(view.root.getChildrenCount()).toBeLessThanOrEqual(204)
    expect(setup.captureCharFrame()).not.toContain("… Ctrl+O to expand")
  } finally {
    view.destroy()
    setup.renderer.destroy()
  }
})

test("collapsing a tool clears selection before destroying preview rows", async () => {
  const setup = await createTestRenderer({ width: 24, height: 18, useThread: false })
  const view = new ToolCallView(
    setup.renderer,
    {
      id: "selected-preview",
      name: "write",
      args: { path: "notes.txt", content: "x".repeat(10_000) },
      status: "preparing"
    },
    defaultTheme,
    "Ctrl+O"
  )
  setup.renderer.root.add(view.root)

  try {
    view.setExpanded(true)
    await setup.renderOnce()
    const selected = view.root.getChildren().at(-2)
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

test("bash results render structured truncation and full-output notices once", async () => {
  const setup = await createTestRenderer({ width: 60, height: 14, useThread: false })
  const fullOutputPath = "/tmp/openzi/bash-output.log"
  const view = new ToolCallView(
    setup.renderer,
    {
      id: "bash-truncated",
      name: "bash",
      args: { command: "generate-output" },
      status: "done",
      result: {
        content: [{ type: "text", text: `last line\n\n[Output truncated. Full output: ${fullOutputPath}]` }],
        details: {
          fullOutputPath,
          truncation: {
            content: "last line",
            truncated: true,
            truncatedBy: "lines",
            totalLines: 2500,
            totalBytes: 100000,
            outputLines: 2000,
            outputBytes: 50000,
            firstLineExceedsLimit: false,
            lastLinePartial: false
          }
        }
      }
    },
    defaultTheme
  )
  setup.renderer.root.add(view.root)

  try {
    await setup.renderOnce()
    const frame = setup.captureCharFrame()
    expect(frame).toContain(`Full output: ${fullOutputPath}`)
    expect(frame).toContain("showing the last 2000 of 2500 lines")
    expect(frame.split(fullOutputPath)).toHaveLength(2)
  } finally {
    view.destroy()
    setup.renderer.destroy()
  }
})

test("command tool blocks keep the tail of bounded output", async () => {
  const output = Array.from({ length: 12 }, (_, index) => `line ${index}`).join("\n")
  const setup = await createTestRenderer({ width: 40, height: 12, useThread: false })
  const block = createCommandToolBlock(setup.renderer, { title: "$ command", output, status: "done" }, defaultTheme)
  setup.renderer.root.add(block)

  try {
    await setup.renderOnce()
    const frame = setup.captureCharFrame()
    expect(frame).toContain("... (7 earlier lines)")
    expect(frame).not.toContain("line 6")
    expect(frame).toContain("line 7")
    expect(frame).toContain("line 11")
  } finally {
    block.destroyRecursively()
    setup.renderer.destroy()
  }
})

function appRoot(renderer: ConstructorParameters<typeof BoxRenderable>[0]): BoxRenderable {
  return new BoxRenderable(renderer, { width: "100%", height: "100%", backgroundColor: defaultTheme.surface.app })
}
