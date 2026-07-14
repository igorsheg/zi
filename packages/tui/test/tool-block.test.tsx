import { expect, test } from "bun:test"

import { testRender } from "@opentui/react/test-utils"
import { act } from "react"

import { ThemeProvider, ziTheme } from "../src/theme.js"
import { CommandToolBlock, ToolBlock } from "../src/tool-block.js"

test("tool block owns Zi's title, rail, and body styling", async () => {
  const setup = await testRender(
    <ThemeProvider theme={ziTheme}>
      <box width="100%" height="100%" backgroundColor={ziTheme.surface.app}>
        <CommandToolBlock title="$ echo hi" output={"hi\nthere\n"} status="running" />
      </box>
    </ThemeProvider>,
    { width: 30, height: 8 }
  )

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
    act(() => setup.renderer.destroy())
  }
})

test("failed tool block uses the error rail and terminal suffix", async () => {
  const setup = await testRender(
    <ThemeProvider theme={ziTheme}>
      <ToolBlock title="edit source.ts" output="No match found" status="failed" />
    </ThemeProvider>,
    { width: 40, height: 8 }
  )

  try {
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("edit source.ts (error)")
    const rail = setup
      .captureSpans()
      .lines.flatMap(line => line.spans)
      .find(span => span.text === "╭───")
    expect(rail?.fg.toInts()).toEqual([228, 104, 118, 255])
  } finally {
    act(() => setup.renderer.destroy())
  }
})

test("generic tool blocks keep the head of bounded output", async () => {
  const output = Array.from({ length: 14 }, (_, index) => `line ${index}`).join("\n")
  const setup = await testRender(
    <ThemeProvider theme={ziTheme}>
      <ToolBlock title="read file" output={output} status="done" />
    </ThemeProvider>,
    { width: 40, height: 16 }
  )

  try {
    await setup.renderOnce()
    const frame = setup.captureCharFrame()
    expect(frame).toContain("line 0")
    expect(frame).toContain("line 9")
    expect(frame).not.toContain("line 10")
    expect(frame).toContain("... (4 more lines)")
  } finally {
    act(() => setup.renderer.destroy())
  }
})

test("command tool blocks keep the tail of bounded output", async () => {
  const output = Array.from({ length: 12 }, (_, index) => `line ${index}`).join("\n")
  const setup = await testRender(
    <ThemeProvider theme={ziTheme}>
      <CommandToolBlock title="$ command" output={output} status="done" />
    </ThemeProvider>,
    { width: 40, height: 12 }
  )

  try {
    await setup.renderOnce()
    const frame = setup.captureCharFrame()
    expect(frame).toContain("... (7 earlier lines)")
    expect(frame).not.toContain("line 6")
    expect(frame).toContain("line 7")
    expect(frame).toContain("line 11")
  } finally {
    act(() => setup.renderer.destroy())
  }
})
