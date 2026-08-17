import { expect, test } from "bun:test"

import { ScrollBoxRenderable, TextRenderable } from "@opentui/core"
import { createTestRenderer } from "@opentui/core/testing"
import type { AgentSessionEvent, WorkPlanSnapshot } from "@with-zi/coding-agent"

import { InteractiveKeybindings } from "../../src/interactive/interactive-keybindings.js"
import { WorkPlanView } from "../../src/interactive/work-plan-view.js"
import { defaultTheme } from "../../src/theme.js"

test("work-plan shelf wraps the current plan, follows revisions, and releases its subscription", async () => {
  const setup = await createTestRenderer({ width: 40, height: 12, useThread: false })
  let plan = snapshot(1, [
    ...Array.from({ length: 6 }, (_, index) => ({ text: `Completed ${index + 1}`, status: "completed" as const })),
    {
      text: "Implement a change whose description remains readable when the terminal is narrow",
      status: "in_progress"
    },
    ...Array.from({ length: 5 }, (_, index) => ({ text: `Verify ${index + 1}`, status: "pending" as const }))
  ])
  const listeners = new Set<(event: AgentSessionEvent) => void>()
  const session = {
    get workPlan() {
      return plan
    },
    subscribe(listener: (event: AgentSessionEvent) => void) {
      listeners.add(listener)
      return () => listeners.delete(listener)
    }
  }
  let unavailable = 0
  const view = new WorkPlanView(
    setup.renderer,
    session,
    new InteractiveKeybindings(),
    defaultTheme,
    () => unavailable++
  )
  setup.renderer.root.add(view.root)

  let staleListener: ((event: AgentSessionEvent) => void) | undefined
  try {
    expect(listeners.size).toBe(0)
    expect(view.open()).toBe(true)
    staleListener = [...listeners][0]
    expect(listeners.size).toBe(1)
    await setup.renderOnce()
    await setup.renderer.idle()

    const scroll = view.root.findDescendantById("work-plan-scroll")
    if (!(scroll instanceof ScrollBoxRenderable)) throw new Error("Plan scrollbox not found")
    expect(scroll.getChildren()).toHaveLength(12)
    const current = scroll.getChildren()[6]
    if (!(current instanceof TextRenderable)) throw new Error("Current plan step not found")
    expect(current.height).toBeGreaterThan(1)
    expect(setup.captureCharFrame()).toContain("◉ Implement")
    expect(view.handleAction("page_down")).toBe(true)
    expect(view.handleAction("tail")).toBe(true)

    view.close()
    expect(listeners.size).toBe(0)
    plan = snapshot(2, [
      { text: "Inspect", status: "completed" },
      { text: "Reopened plan uses the latest revision", status: "in_progress" }
    ])
    expect(view.open()).toBe(true)
    await setup.renderOnce()
    await setup.renderer.idle()
    expect(setup.captureCharFrame()).toContain("Reopened plan uses")

    plan = snapshot(3, [
      { text: "Inspect", status: "completed" },
      { text: "Implement", status: "completed" }
    ])
    for (const listener of listeners) listener({ type: "work_plan_changed", plan })
    expect(unavailable).toBe(1)
    expect(view.expanded).toBe(false)
    expect(listeners.size).toBe(0)

    view.destroy()
    staleListener?.({ type: "work_plan_changed", plan })
    expect(unavailable).toBe(1)
  } finally {
    view.destroy()
    if (!setup.renderer.isDestroyed) setup.renderer.destroy()
  }
})

function snapshot(revision: number, steps: WorkPlanSnapshot["steps"]): WorkPlanSnapshot {
  return { revision, steps }
}
