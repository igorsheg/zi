import { expect, test } from "bun:test"

import { BoxRenderable, parseKeypress } from "@opentui/core"
import type { AgentSessionEvent } from "@with-zi/coding-agent"
import {
  createModels,
  createTestAgentRuntime as createAgentRuntime,
  fauxAssistantMessage,
  fauxProvider,
  fauxToolCall
} from "@with-zi/coding-agent/testing"

import { createInteractiveTest, renderSettled } from "./harness.js"

test("the work plan opens as a bounded companion pane", async () => {
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
            { text: "Implement workspace pane", status: "in_progress" },
            { text: "Verify behavior", status: "pending" }
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
        { steps: [{ text: "Implement workspace pane", status: "completed" }] },
        { id: "plan-complete" }
      ),
      { stopReason: "toolUse" }
    ),
    fauxAssistantMessage("Complete.")
  ])
  const { session } = await createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })
  await session.prompt("Start the work.")
  const subscriptions = trackSubscriptions(session)
  const setup = await createInteractiveTest(session, { width: 120, height: 30 })
  const baselineSubscriptions = subscriptions.count()

  try {
    await renderSettled(setup)
    expect(setup.captureCharFrame()).toContain("Plan (1/3) — Implement workspace pane (Ctrl+P)")

    const listenersBeforePlan = new Set(subscriptions.listeners())
    pressRawKey(setup, "\x10")
    await renderSettled(setup)
    const stalePlanListener = subscriptions.listeners().find(listener => !listenersBeforePlan.has(listener))!
    const main = requiredBox(setup.renderer.root.findDescendantById("main-agent-pane"))
    const plan = requiredBox(setup.renderer.root.findDescendantById("work-plan-pane"))
    expect(subscriptions.count()).toBe(baselineSubscriptions + 1)
    expect(plan.focused).toBe(true)
    expect(setup.captureCharFrame()).toContain("✓ Already done")
    expect(setup.captureCharFrame()).toContain("◉ Implement workspace pane")
    expect(setup.captureCharFrame()).toContain("○ Verify behavior")
    expect(main.width / (main.width + plan.width)).toBeGreaterThan(0.6)
    expect(main.width / (main.width + plan.width)).toBeLessThan(0.64)

    setup.mockInput.pressKey("q")
    await renderSettled(setup)
    expect(setup.renderer.root.findDescendantById("work-plan-pane")).toBeUndefined()
    expect(subscriptions.count()).toBe(baselineSubscriptions)

    pressRawKey(setup, "\x10")
    await renderSettled(setup)
    const reopened = requiredBox(setup.renderer.root.findDescendantById("work-plan-pane"))
    stalePlanListener({ type: "work_plan_changed", plan: session.workPlan })
    expect(setup.renderer.root.findDescendantById("work-plan-pane")).toBe(reopened)

    await session.prompt("Finish the work.")
    await renderSettled(setup)
    expect(setup.renderer.root.findDescendantById("work-plan-pane")).toBeUndefined()
    expect(subscriptions.count()).toBe(baselineSubscriptions)
    expect(setup.captureCharFrame()).not.toContain("Plan (")
  } finally {
    setup.destroy()
    expect(subscriptions.count()).toBe(0)
    session.dispose()
  }
})

function trackSubscriptions(session: Parameters<typeof createInteractiveTest>[0]): {
  count(): number
  listeners(): readonly ((event: AgentSessionEvent) => void)[]
} {
  const original = session.subscribe.bind(session)
  const listeners = new Set<(event: AgentSessionEvent) => void>()
  Object.defineProperty(session, "subscribe", {
    configurable: true,
    value(listener: (event: AgentSessionEvent) => void) {
      listeners.add(listener)
      const release = original(listener)
      return () => {
        if (!listeners.delete(listener)) return
        release()
      }
    }
  })
  return { count: () => listeners.size, listeners: () => [...listeners] }
}

function pressRawKey(setup: Awaited<ReturnType<typeof createInteractiveTest>>, raw: string): void {
  const parsed = parseKeypress(raw)
  if (!parsed) throw new Error(`Could not parse key: ${JSON.stringify(raw)}`)
  setup.renderer.keyInput.processParsedKey(parsed)
}

function requiredBox(value: unknown): BoxRenderable {
  if (!(value instanceof BoxRenderable)) throw new Error("Workspace pane not found")
  return value
}
