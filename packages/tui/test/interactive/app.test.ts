import { expect, test } from "bun:test"

import { TextareaRenderable } from "@opentui/core"
import { createAgentRuntime } from "@openzi/coding-agent"
import { createModels, fauxProvider } from "@openzi/coding-agent/testing"

import { createInteractiveTest } from "./harness.js"

test("the session app fills the terminal and protects the prompt", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  const { session } = await createAgentRuntime({ cwd: "/work", models, persist: false })
  let exits = 0
  const setup = await createInteractiveTest(session, { width: 40, height: 8 }, () => exits++)

  try {
    await setup.renderOnce()
    const frame = setup.captureCharFrame()
    expect(frame).toContain("/work")
    expect(frame).toContain("faux-1")

    const spans = setup.captureSpans()
    expect(spans.lines[0]?.spans[0]?.bg.toInts()).toEqual([9, 14, 19, 255])

    const input = setup.renderer.root.findDescendantById("prompt-input")
    if (!(input instanceof TextareaRenderable)) throw new Error("Prompt textarea not found")
    input.setText("discard me")
    setup.mockInput.pressCtrlC()
    expect(input.plainText).toBe("")
    expect(exits).toBe(0)

    setup.mockInput.pressKey("d", { ctrl: true })
    expect(exits).toBe(1)
  } finally {
    session.dispose()
    setup.destroy()
  }
})
