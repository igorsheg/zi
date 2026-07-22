import { expect, spyOn, test } from "bun:test"

import { BoxRenderable, TextareaRenderable } from "@opentui/core"
import {
  createModels,
  createTestAgentRuntime as createAgentRuntime,
  fauxAssistantMessage,
  fauxProvider
} from "@openzi/coding-agent/testing"

import { createInteractiveTest, renderMarkdownSettled, renderSettled } from "./harness.js"

test("retry countdown is visible and the semantic interrupt cancels its backoff", async () => {
  let now = 1_000
  const clock = spyOn(Date, "now").mockImplementation(() => now)
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  faux.setResponses([
    fauxAssistantMessage("", { stopReason: "error", errorMessage: "network error" }),
    fauxAssistantMessage("should not run")
  ])
  const { session } = await createAgentRuntime({
    cwd: "/work",
    models,
    persist: false,
    settings: { retryBaseDelayMs: 15_000 }
  })
  const setup = await createInteractiveTest(session, { width: 72, height: 10 })
  const retryStarted = deferred<void>()
  session.subscribe(event => {
    if (event.type === "auto_retry_start") retryStarted.resolve()
  })

  try {
    const input = setup.renderer.root.findDescendantById("prompt-input")
    if (!(input instanceof TextareaRenderable)) throw new Error("Prompt textarea not found")
    input.setText("try once")
    setup.mockInput.pressEnter()
    await retryStarted.promise
    await setup.renderOnce()

    expect(setup.captureCharFrame()).toContain("Retrying (1/3) in 15s… (Esc to cancel)")
    expect(setup.renderer.liveRequestCount).toBe(1)
    now = 3_000
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("Retrying (1/3) in 13s… (Esc to cancel)")

    setup.mockInput.pressEscape()
    await session.waitForIdle()
    await renderSettled(setup)

    const status = setup.renderer.root.findDescendantById("working-status")
    if (!(status instanceof BoxRenderable)) throw new Error("Working status not found")
    expect(status.visible).toBe(false)
    expect(setup.renderer.liveRequestCount).toBe(0)
    expect(faux.state.callCount).toBe(1)
  } finally {
    clock.mockRestore()
    session.dispose()
    setup.destroy()
  }
})

test("successful retry retains the failed attempt as transcript evidence", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  faux.setResponses([
    fauxAssistantMessage("", { stopReason: "error", errorMessage: "overloaded retry evidence" }),
    fauxAssistantMessage("recovered answer")
  ])
  const { session } = await createAgentRuntime({
    cwd: "/work",
    models,
    persist: false,
    settings: { retryBaseDelayMs: 0 }
  })
  const setup = await createInteractiveTest(session, { width: 72, height: 12 })
  const settled = deferred<void>()
  session.subscribe(event => {
    if (event.type === "agent_settled") settled.resolve()
  })

  try {
    await setup.renderOnce()
    const input = setup.renderer.root.findDescendantById("prompt-input")
    if (!(input instanceof TextareaRenderable)) throw new Error("Prompt textarea not found")
    input.setText("try once")
    input.submit()
    await settled.promise
    await Bun.sleep(0)
    await renderMarkdownSettled(setup)

    const frame = setup.captureCharFrame()
    expect(frame).toContain("overloaded retry evidence")
    expect(frame).toContain("recovered answer")
  } finally {
    session.dispose()
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
