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

test("the work plan shares the transcript status slot and expands upward", async () => {
  const models = createModels()
  const faux = fauxProvider()
  const workingStarted = deferred<void>()
  const workingRelease = deferred<void>()
  models.setProvider(faux.provider)
  faux.setResponses([
    fauxAssistantMessage(
      fauxToolCall(
        "update_plan",
        {
          steps: [
            { text: "Already done", status: "completed" },
            { text: "Implement status composition", status: "in_progress" },
            { text: "Verify layout", status: "pending" },
            { text: "Obsolete path", status: "cancelled" }
          ]
        },
        { id: "plan-start" }
      ),
      { stopReason: "toolUse" }
    ),
    fauxAssistantMessage("Started."),
    async () => {
      workingStarted.resolve()
      await workingRelease.promise
      return fauxAssistantMessage("Continued.")
    },
    fauxAssistantMessage(
      fauxToolCall(
        "update_plan",
        {
          steps: [
            { text: "Implement status composition", status: "completed" },
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
  const setup = await createInteractiveTest(session, { width: 80, height: 18 }, undefined, {
    "app.plan.toggle": ["alt+x"]
  })

  try {
    await setup.renderOnce()
    const status = setup.renderer.root.findDescendantById("transcript-status")
    const composer = setup.renderer.root.findDescendantById("prompt-composer")
    if (!(status instanceof BoxRenderable) || !(composer instanceof BoxRenderable)) {
      throw new Error("Session status layout not found")
    }
    expect(status.height).toBe(1)
    expect(status.screenY + status.height).toBeLessThanOrEqual(composer.screenY)
    const composerHeight = composer.height
    const composerY = composer.screenY
    let frame = setup.captureCharFrame()
    expect(frame).toContain("◉ Plan · 1/3 · Implement status composition (Alt+X to expand)")
    expect(frame).not.toContain("Already done")
    expect(frame).not.toContain("Obsolete path")

    const activeRun = session.prompt("Continue the work.")
    await workingStarted.promise
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("Working…")
    expect(setup.captureCharFrame()).toContain("Plan ·")
    setup.resize(20, 18)
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("Working…")
    expect(setup.captureCharFrame()).not.toContain("Plan ·")
    setup.resize(80, 18)
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("Plan ·")
    workingRelease.resolve()
    await activeRun

    setup.mockInput.pressKey("x", { meta: true })
    await setup.renderOnce()
    frame = setup.captureCharFrame()
    expect(status.height).toBe(5)
    expect(frame).toContain("  ✓ Already done")
    expect(frame).toContain("  ◉ Implement status composition")
    expect(frame).toContain("  ○ Verify layout")
    expect(frame).toContain("  – Obsolete path")
    expect(frame).toContain("▾ Plan · 1/3 (Alt+X to collapse)")
    expect(composer.height).toBe(composerHeight)
    expect(composer.screenY).toBe(composerY)

    setup.resize(80, 4)
    await setup.renderOnce()
    expect(status.visible).toBe(false)
    expect(setup.captureCharFrame()).not.toContain("Alt+X")
    expect(composer.screenY + composer.height).toBeLessThanOrEqual(setup.renderer.height)
    setup.mockInput.pressKey("x", { meta: true })

    setup.resize(80, 18)
    await setup.renderOnce()
    expect(status.visible).toBe(true)
    expect(status.height).toBe(5)
    expect(setup.captureCharFrame()).toContain("▾ Plan · 1/3 (Alt+X to collapse)")

    await session.prompt("Finish the work.")
    await setup.renderOnce()
    expect(status.height).toBe(1)
    expect(setup.captureCharFrame()).not.toContain("Plan ·")
  } finally {
    setup.destroy()
  }
})

function deferred<T>() {
  let resolve!: (value: T | PromiseLike<T>) => void
  const promise = new Promise<T>(resolvePromise => {
    resolve = resolvePromise
  })
  return { promise, resolve }
}
