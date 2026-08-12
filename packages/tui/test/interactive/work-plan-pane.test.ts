import { expect, test } from "bun:test"

import { TextRenderable } from "@opentui/core"
import { createTestRenderer } from "@opentui/core/testing"
import type { AgentSessionEvent, WorkPlanSnapshot } from "@with-zi/coding-agent"

import { WorkPlanPane } from "../../src/interactive/work-plan-pane.js"
import { defaultTheme } from "../../src/theme.js"

test("work-plan pane projects the bounded authoritative plan and releases its subscription", async () => {
  const setup = await createTestRenderer({ width: 40, height: 6, useThread: false })
  let plan = snapshot(1, [
    { text: "Inspect", status: "completed" },
    { text: "Implement", status: "in_progress" },
    ...Array.from({ length: 30 }, (_, index) => ({ text: `Verify ${index + 1}`, status: "pending" as const }))
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
  const pane = new WorkPlanPane(setup.renderer, session, defaultTheme, () => unavailable++)
  const staleListener = [...listeners][0]!
  setup.renderer.root.add(pane.root)

  try {
    await setup.renderOnce()
    expect(pane.root.getChildren()).toHaveLength(32)
    expect(pane.root.getChildren()[0]).toBeInstanceOf(TextRenderable)
    expect(setup.captureCharFrame()).toContain("✓ Inspect")
    expect(setup.captureCharFrame()).toContain("◉ Implement")
    expect(listeners.size).toBe(1)

    expect(pane.handleAction("tail")).toBe(true)
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("○ Verify 30")
    expect(pane.root.getChildren()).toHaveLength(32)

    plan = snapshot(2, [
      { text: "Inspect", status: "completed" },
      { text: "Implement", status: "completed" }
    ])
    for (const listener of listeners) listener({ type: "work_plan_changed", plan })
    expect(unavailable).toBe(1)
  } finally {
    pane.destroy()
    expect(listeners.size).toBe(0)
    staleListener({ type: "work_plan_changed", plan })
    expect(unavailable).toBe(1)
    if (!setup.renderer.isDestroyed) setup.renderer.destroy()
  }
})

function snapshot(revision: number, steps: WorkPlanSnapshot["steps"]): WorkPlanSnapshot {
  return { revision, steps }
}
