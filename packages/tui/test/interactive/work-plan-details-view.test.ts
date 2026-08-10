import { expect, test } from "bun:test"

import { TextRenderable } from "@opentui/core"
import { createTestRenderer } from "@opentui/core/testing"
import type { WorkPlanSnapshot } from "@with-zi/coding-agent"

import { WorkPlanDetailsView } from "../../src/interactive/transcript/work-plan-details-view.js"
import { defaultTheme } from "../../src/theme.js"

test("expanded work plan details render every status in plan order", async () => {
  const setup = await createTestRenderer({ width: 40, height: 10, useThread: false })
  const view = new WorkPlanDetailsView(setup.renderer, defaultTheme)
  setup.renderer.root.add(view.root)

  try {
    const plan = snapshot([
      step("completed", "Inspect the current state"),
      step("in_progress", "Implement the status row"),
      step("pending", "Verify the layout"),
      step("cancelled", "Discard obsolete work")
    ])
    expect(view.update(plan, 40, 7, 1)).toBe(4)
    await setup.renderOnce()

    expect(textRows(view).map(rowContent)).toEqual([
      "  ✓ Inspect the current state",
      "  ◉ Implement the status row",
      "  ○ Verify the layout",
      "  – Discard obsolete work"
    ])
    expect(view.root.visible).toBe(true)
  } finally {
    view.destroy()
    if (!setup.renderer.isDestroyed) setup.renderer.destroy()
  }
})

test("expanded details retain the current step inside their seven-row bound", async () => {
  const setup = await createTestRenderer({ width: 40, height: 10, useThread: false })
  const view = new WorkPlanDetailsView(setup.renderer, defaultTheme)
  setup.renderer.root.add(view.root)

  try {
    const plan = snapshot(
      Array.from({ length: 12 }, (_, index) =>
        step(index === 7 ? "in_progress" : index < 7 ? "completed" : "pending", `Step ${index + 1}`)
      )
    )
    expect(view.update(plan, 40, 20, 7)).toBe(7)
    const rows = textRows(view).map(rowContent)
    expect(rows).toHaveLength(7)
    expect(rows).toContain("  ◉ Step 8")
    expect(rows.at(-1)).toBe("… 4 earlier · 2 later")

    expect(view.update(plan, 40, 1, 7)).toBe(1)
    expect(textRows(view).map(rowContent)).toEqual(["  ◉ Step 8"])
  } finally {
    view.destroy()
    if (!setup.renderer.isDestroyed) setup.renderer.destroy()
  }
})

test("expanded details truncate to one row and preserve unchanged row identity", async () => {
  const setup = await createTestRenderer({ width: 20, height: 4, useThread: false })
  const view = new WorkPlanDetailsView(setup.renderer, defaultTheme)
  setup.renderer.root.add(view.root)

  try {
    const plan = snapshot([step("in_progress", "界界界界界\nsecond line"), step("pending", "Verify")])
    expect(view.update(plan, 9, 7, 0)).toBe(2)
    const rows = textRows(view)
    expect(rowContent(rows[0])).toBe("  ◉ 界...")
    expect(rowContent(rows[0])).not.toContain("\n")

    view.hide()
    expect(view.update(plan, 9, 7, 0)).toBe(2)
    expect(view.root.visible).toBe(true)
    expect(textRows(view)[0]).toBe(rows[0])
    expect(textRows(view)[1]).toBe(rows[1])

    const revised = snapshot([step("completed", "Implement"), step("in_progress", "Verify")])
    expect(view.update(revised, 9, 7, 1)).toBe(2)
    expect(rows.every(row => row.isDestroyed)).toBe(true)
    expect(textRows(view)).toHaveLength(2)
  } finally {
    view.destroy()
    if (!setup.renderer.isDestroyed) setup.renderer.destroy()
  }
})

type FixtureStep = WorkPlanSnapshot["steps"][number]

function step(status: FixtureStep["status"], text: string): FixtureStep {
  return { status, text }
}

let nextRevision = 0

function snapshot(steps: readonly FixtureStep[]): WorkPlanSnapshot {
  return { revision: ++nextRevision, steps }
}

function textRows(view: WorkPlanDetailsView): TextRenderable[] {
  return view.root.getChildren().map(child => {
    if (!(child instanceof TextRenderable)) throw new Error("Expected a work plan detail row")
    return child
  })
}

function rowContent(row: TextRenderable | undefined): string | undefined {
  return row?.content.chunks.map(chunk => chunk.text).join("")
}
