import { expect, test } from "bun:test"

import { TextareaRenderable } from "@opentui/core"
import { testRender } from "@opentui/react/test-utils"
import { createAgentRuntime } from "@openzi/coding-agent"
import { createModels, fauxProvider } from "@openzi/coding-agent/testing"
import { act } from "react"

import { App } from "../src/app.js"

test("the session app fills the terminal and protects the prompt", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  const { session } = await createAgentRuntime({ cwd: "/work", models, persist: false })
  let exits = 0
  const setup = await testRender(<App session={session} onExit={() => exits++} />, { width: 40, height: 8 })

  try {
    await setup.renderOnce()
    const frame = setup.captureCharFrame()
    expect(frame).toContain("/work")
    expect(frame).toContain("Ask anything")
    expect(frame).toContain("faux/faux-1 · off")

    const spans = setup.captureSpans()
    expect(spans.lines[0]?.spans[0]?.bg.toInts()).toEqual([9, 14, 19, 255])
    const placeholder = spans.lines.flatMap(line => line.spans).find(span => span.text === "Ask anything")
    expect(placeholder?.fg.toInts()).toEqual([127, 131, 129, 255])

    const input = setup.renderer.root.findDescendantById("prompt-input")
    if (!(input instanceof TextareaRenderable)) throw new Error("Prompt textarea not found")
    act(() => {
      input.setText("discard me")
      setup.mockInput.pressCtrlC()
    })
    expect(input.plainText).toBe("")
    expect(exits).toBe(0)

    act(() => setup.mockInput.pressKey("d", { ctrl: true }))
    expect(exits).toBe(1)
  } finally {
    session.dispose()
    act(() => setup.renderer.destroy())
  }
})
