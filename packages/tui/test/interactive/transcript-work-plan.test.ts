import { expect, test } from "bun:test"

import { BoxRenderable, parseKeypress, TextareaRenderable } from "@opentui/core"
import type { AgentSessionEvent, SubagentSnapshot, SubagentTranscriptSnapshot } from "@with-zi/coding-agent"
import {
  createModels,
  createTestAgentRuntime as createAgentRuntime,
  fauxAssistantMessage,
  fauxProvider,
  fauxToolCall
} from "@with-zi/coding-agent/testing"

import { createInteractiveTest, renderSettled } from "./harness.js"

test("the work plan opens as a pane and coexists with a subagent transcript", async () => {
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
            { text: "Verify coexistence", status: "pending" },
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
            { text: "Implement workspace pane", status: "completed" },
            { text: "Verify coexistence", status: "completed" }
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
  installSubagent(session)
  const subscriptions = trackSubscriptions(session)
  const setup = await createInteractiveTest(session, { width: 120, height: 30 })
  const baselineSubscriptions = subscriptions.count()

  try {
    await renderSettled(setup)
    let frame = setup.captureCharFrame()
    expect(frame).toContain("Plan (1/3) — Implement workspace pane (Ctrl+P)")

    const listenersBeforePlan = new Set(subscriptions.listeners())
    pressRawKey(setup, "\x10")
    await renderSettled(setup)
    const stalePlanListener = subscriptions.listeners().find(listener => !listenersBeforePlan.has(listener))!
    expect(subscriptions.count()).toBe(baselineSubscriptions + 1)
    const main = requiredBox(setup.renderer.root.findDescendantById("main-agent-pane"))
    let plan = requiredBox(setup.renderer.root.findDescendantById("work-plan-pane"))
    expect(plan.borderStyle).toBe("rounded")
    expect(plan.focused).toBe(true)
    frame = setup.captureCharFrame()
    expect(frame).toContain("Work plan")
    expect(frame).toContain("✓ Already done")
    expect(frame).toContain("◉ Implement workspace pane")
    expect(frame).toContain("○ Verify coexistence")
    expect(frame).toContain("– Obsolete path")
    expect(main.width / (main.width + plan.width)).toBeGreaterThan(0.6)
    expect(main.width / (main.width + plan.width)).toBeLessThan(0.64)

    setup.mockInput.pressKey("q")
    await renderSettled(setup)
    expect(setup.renderer.root.findDescendantById("work-plan-pane")).toBeUndefined()
    expect(subscriptions.count()).toBe(baselineSubscriptions)
    pressRawKey(setup, "\x10")
    await renderSettled(setup)
    plan = requiredBox(setup.renderer.root.findDescendantById("work-plan-pane"))
    stalePlanListener({ type: "work_plan_changed", plan: session.workPlan })
    expect(setup.renderer.root.findDescendantById("work-plan-pane")).toBe(plan)
    expect(subscriptions.count()).toBe(baselineSubscriptions + 1)

    pressRawKey(setup, "\x17")
    pressRawKey(setup, "h")
    await renderSettled(setup)

    await setup.mockInput.typeText("/agent")
    setup.mockInput.pressEnter()
    await renderSettled(setup)
    setup.mockInput.pressEnter()
    await renderSettled(setup)
    let subagent = requiredBox(setup.renderer.root.findDescendantById("subagent-pane-review-risk"))
    expect(subscriptions.count()).toBe(baselineSubscriptions + 2)
    plan = requiredBox(setup.renderer.root.findDescendantById("work-plan-pane"))
    expect(subagent.focused).toBe(true)
    expect(setup.renderer.root.findDescendantById("workspace-secondary-stack")).toBeDefined()
    expect(subagent.screenX).toBe(plan.screenX)
    expect(subagent.width).toBe(plan.width)
    expect(subagent.screenY).toBeLessThan(plan.screenY)

    setup.mockInput.pressKey("q")
    await renderSettled(setup)
    expect(setup.renderer.root.findDescendantById("subagent-pane-review-risk")).toBeUndefined()
    expect(setup.renderer.root.findDescendantById("work-plan-pane")).toBe(plan)
    expect(plan.focused).toBe(true)
    expect(subscriptions.count()).toBe(baselineSubscriptions + 1)

    pressRawKey(setup, "\x17")
    pressRawKey(setup, "h")
    await renderSettled(setup)
    await setup.mockInput.typeText("/agent")
    setup.mockInput.pressEnter()
    await renderSettled(setup)
    setup.mockInput.pressEnter()
    await renderSettled(setup)
    subagent = requiredBox(setup.renderer.root.findDescendantById("subagent-pane-review-risk"))
    expect(setup.renderer.root.findDescendantById("work-plan-pane")).toBe(plan)
    expect(subagent.focused).toBe(true)
    expect(subscriptions.count()).toBe(baselineSubscriptions + 2)

    pressRawKey(setup, "\x10")
    await renderSettled(setup)
    expect(setup.renderer.root.findDescendantById("work-plan-pane")).toBeUndefined()
    expect(subscriptions.count()).toBe(baselineSubscriptions + 1)
    expect(subagent.focused).toBe(true)

    pressRawKey(setup, "\x10")
    await renderSettled(setup)
    plan = requiredBox(setup.renderer.root.findDescendantById("work-plan-pane"))
    expect(subscriptions.count()).toBe(baselineSubscriptions + 2)
    expect(plan.focused).toBe(true)
    expect(subagent.screenX).toBe(plan.screenX)
    expect(subagent.width).toBe(plan.width)
    expect(subagent.screenY).toBeLessThan(plan.screenY)

    pressRawKey(setup, "\x1b")
    await renderSettled(setup)
    expect(requiredPrompt(setup.renderer.root.findDescendantById("prompt-input")).focused).toBe(true)
    expect(setup.renderer.root.findDescendantById("work-plan-pane")).toBe(plan)
    expect(setup.renderer.root.findDescendantById("subagent-pane-review-risk")).toBe(subagent)

    pressRawKey(setup, "\x17")
    pressRawKey(setup, "l")
    await renderSettled(setup)
    pressRawKey(setup, "\x17")
    pressRawKey(setup, "j")
    await renderSettled(setup)
    expect(plan.focused).toBe(true)
    setup.mockInput.pressKey("q")
    await renderSettled(setup)
    expect(setup.renderer.root.findDescendantById("work-plan-pane")).toBeUndefined()
    expect(setup.renderer.root.findDescendantById("subagent-pane-review-risk")).toBe(subagent)
    expect(subscriptions.count()).toBe(baselineSubscriptions + 1)

    pressRawKey(setup, "\x10")
    await renderSettled(setup)
    plan = requiredBox(setup.renderer.root.findDescendantById("work-plan-pane"))
    expect(subscriptions.count()).toBe(baselineSubscriptions + 2)

    setup.resize(70, 24)
    await renderSettled(setup)
    expect(plan.visible).toBe(true)
    expect(subagent.visible).toBe(false)
    expect(main.visible).toBe(false)

    pressRawKey(setup, "\x17")
    pressRawKey(setup, "k")
    await renderSettled(setup)
    expect(subagent.visible).toBe(true)
    expect(plan.visible).toBe(false)
    expect(subagent.focused).toBe(true)

    setup.resize(120, 30)
    await renderSettled(setup)
    expect(main.visible).toBe(true)
    expect(plan.visible).toBe(true)

    await session.prompt("Finish the work.")
    await renderSettled(setup)
    expect(setup.renderer.root.findDescendantById("work-plan-pane")).toBeUndefined()
    expect(setup.renderer.root.findDescendantById("subagent-pane-review-risk")).toBe(subagent)
    expect(subscriptions.count()).toBe(baselineSubscriptions + 1)
    expect(subagent.focused).toBe(true)
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

function installSubagent(session: Parameters<typeof createInteractiveTest>[0]): void {
  const snapshot: SubagentSnapshot = {
    name: "review-risk",
    lifecycle: "running",
    workCycle: 1,
    task: "Review the workspace.",
    elapsedMs: 1_000,
    sessionId: "child-session"
  }
  const transcript: SubagentTranscriptSnapshot = {
    name: snapshot.name,
    messages: [fauxAssistantMessage("Reviewing the workspace.")],
    activeTools: [],
    omittedMessages: 0,
    omittedBytes: 0
  }
  Object.defineProperties(session, {
    subagentSnapshots: { configurable: true, value: () => [snapshot] },
    subagentSnapshot: { configurable: true, value: (name: string) => (name === snapshot.name ? snapshot : undefined) },
    subagentTranscript: {
      configurable: true,
      value: (name: string) => (name === transcript.name ? transcript : undefined)
    }
  })
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

function requiredPrompt(value: unknown): TextareaRenderable {
  if (!(value instanceof TextareaRenderable)) throw new Error("Prompt input not found")
  return value
}
