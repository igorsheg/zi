import { expect, test } from "bun:test"

import { BoxRenderable } from "@opentui/core"
import {
  createModels,
  createTestAgentRuntime as createAgentRuntime,
  fauxAssistantMessage,
  fauxProvider,
  fauxToolCall
} from "@with-zi/coding-agent/testing"

import { createInteractiveTest } from "./harness.js"

test("the session work plan renders immediately above the composer and hides when complete", async () => {
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
            { text: "Implement panel", status: "in_progress" },
            { text: "Verify layout", status: "pending" },
            { text: "Obsolete path", status: "cancelled" }
          ]
        },
        { id: "plan-start" }
      ),
      { stopReason: "toolUse" }
    ),
    fauxAssistantMessage("Started."),
    fauxAssistantMessage(
      fauxToolCall(
        "update_plan",
        {
          steps: [
            { text: "Implement panel", status: "completed" },
            { text: "Verify layout", status: "completed" }
          ]
        },
        { id: "plan-complete" }
      ),
      { stopReason: "toolUse" }
    ),
    fauxAssistantMessage("Complete.")
  ])
  const { session } = await createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })
  await session.prompt("Start the work.")
  const setup = await createInteractiveTest(session, { width: 40, height: 18 })

  try {
    await setup.renderOnce()
    const plan = setup.renderer.root.findDescendantById("prompt-work-plan")
    const composer = setup.renderer.root.findDescendantById("prompt-composer")
    if (!(plan instanceof BoxRenderable) || !(composer instanceof BoxRenderable)) {
      throw new Error("Prompt work plan layout not found")
    }
    expect(plan.visible).toBe(true)
    expect(plan.height).toBe(2)
    expect(plan.screenY + plan.height).toBeLessThanOrEqual(composer.screenY)
    const frame = setup.captureCharFrame()
    expect(frame).toContain("Implement panel")
    expect(frame).toContain("Verify layout")
    expect(frame).not.toContain("Already done")
    expect(frame).not.toContain("Obsolete path")

    await session.prompt("Finish the work.")
    await setup.renderOnce()
    expect(plan.visible).toBe(false)
    expect(plan.getChildren()).toHaveLength(0)
  } finally {
    setup.destroy()
  }
})
