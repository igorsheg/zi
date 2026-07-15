import { expect, test } from "bun:test"

import { BoxRenderable } from "@opentui/core"
import { createTestRenderer } from "@opentui/core/testing"

import { createCommandToolBlock, createToolBlock } from "../../src/interactive/components/tool-block.js"
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
