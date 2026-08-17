import { expect, test } from "bun:test"

import { BoxRenderable, parseKeypress, ScrollBoxRenderable, TextareaRenderable } from "@opentui/core"
import {
  createTestAgentRuntime as createAgentRuntime,
  createModels,
  fauxAssistantMessage,
  fauxProvider,
  fauxToolCall
} from "@with-zi/coding-agent/testing"

import { createInteractiveTest, renderSettled } from "./harness.js"

test("the work plan opens as a full-width shelf above the composer", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  faux.setResponses([
    fauxAssistantMessage(
      fauxToolCall(
        "update_plan",
        {
          steps: [
            { text: "Already done", status: "completed" },
            {
              text: "Implement the expanded work plan shelf with a long description that must wrap in a narrow terminal",
              status: "in_progress"
            },
            { text: "Verify behavior", status: "pending" }
          ]
        },
        { id: "plan-start" }
      ),
      { stopReason: "toolUse" }
    ),
    fauxAssistantMessage("Started.")
  ])
  const { session } = await createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })
  await session.prompt("Start the work.")
  const setup = await createInteractiveTest(session, { width: 60, height: 20 })

  try {
    await renderSettled(setup)
    expect(setup.captureCharFrame()).toContain("Plan (1/3)")

    setup.mockInput.pressKey("p", { ctrl: true })
    await renderSettled(setup)
    const shelf = setup.renderer.root.findDescendantById("work-plan-shelf")
    if (!shelf) throw new Error("Work-plan shelf not found")
    expect(shelf.visible).toBe(true)
    const expandedFrame = setup.captureCharFrame()
    expect(expandedFrame).toContain("Plan 1/3")
    expect(expandedFrame).not.toContain("Plan (1/3)")
    expect(expandedFrame).toContain("Implement the expanded work")
    expect(expandedFrame).toContain("narrow terminal")
    expect(expandedFrame).not.toContain("Main agent")

    const transcript = setup.renderer.root.findDescendantById("transcript-scroll")
    if (!(transcript instanceof ScrollBoxRenderable)) throw new Error("Transcript scrollbox not found")
    const composer = setup.renderer.root.findDescendantById("prompt-composer")
    if (!(composer instanceof BoxRenderable)) throw new Error("Prompt composer not found")
    const input = setup.renderer.root.findDescendantById("prompt-input")
    if (!(input instanceof TextareaRenderable)) throw new Error("Prompt textarea not found")
    expect(transcript.width).toBe(setup.renderer.width)
    expect(shelf.width).toBe(setup.renderer.width)
    expect(composer.screenY + composer.height).toBe(setup.renderer.height)
    expect(input.focused).toBe(false)

    pressRawKey(setup, "\x1b")
    await renderSettled(setup)
    expect(shelf.visible).toBe(false)
    expect(input.focused).toBe(true)

    setup.mockInput.pressKey("p", { ctrl: true })
    await renderSettled(setup)
    expect(shelf.visible).toBe(true)
    setup.mockInput.pressKey("p", { ctrl: true })
    await renderSettled(setup)
    expect(shelf.visible).toBe(false)

    setup.resize(32, 8)
    await renderSettled(setup)
    setup.mockInput.pressKey("p", { ctrl: true })
    await renderSettled(setup)
    expect(shelf.visible).toBe(true)
    expect(composer.screenY + composer.height).toBe(setup.renderer.height)

    faux.setResponses([
      fauxAssistantMessage(
        fauxToolCall(
          "update_plan",
          { steps: [{ text: "Implement the expanded work plan shelf", status: "completed" }] },
          { id: "plan-complete" }
        ),
        { stopReason: "toolUse" }
      ),
      fauxAssistantMessage("Complete.")
    ])
    await session.prompt("Finish the work.")
    await renderSettled(setup)
    expect(shelf.visible).toBe(false)
    expect(input.focused).toBe(true)
  } finally {
    setup.destroy()
    session.dispose()
  }
})

function pressRawKey(setup: Awaited<ReturnType<typeof createInteractiveTest>>, raw: string): void {
  const parsed = parseKeypress(raw)
  if (!parsed) throw new Error(`Could not parse key: ${JSON.stringify(raw)}`)
  setup.renderer.keyInput.processParsedKey(parsed)
}
