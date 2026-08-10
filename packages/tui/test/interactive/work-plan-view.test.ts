import { expect, test } from "bun:test"

import { TextRenderable } from "@opentui/core"
import { createTestRenderer } from "@opentui/core/testing"
import type { WorkPlanSnapshot } from "@with-zi/coding-agent"

import { WorkPlanView } from "../../src/interactive/prompt/work-plan-view.js"
import { defaultTheme } from "../../src/theme.js"

test("work plan renders only active items with one text row per item", async () => {
  const setup = await createTestRenderer({ width: 40, height: 10, useThread: false })
  const view = new WorkPlanView(setup.renderer, defaultTheme)
  setup.renderer.root.add(view.root)

  try {
    const occupiedRows = view.update(
      snapshot([
        step("pending", "Inspect the current state"),
        step("completed", "Discard completed work"),
        step("cancelled", "Discard cancelled work"),
        step("in_progress", "Implement the panel")
      ]),
      40,
      8
    )
    await setup.renderOnce()

    const rows = textRows(view)
    expect(occupiedRows).toBe(2)
    expect(rows).toHaveLength(2)
    expect(rows.map(rowContent)).toEqual(["○ Inspect the current state", "◉ Implement the panel"])
    expect(view.root.visible).toBe(true)
    expect(view.root.height).toBe(2)

    expect(view.update(snapshot([step("completed", "Everything is done")]), 40, 8)).toBe(0)
    expect(view.root.visible).toBe(false)
    expect(textRows(view)).toHaveLength(0)
  } finally {
    view.destroy()
    if (!setup.renderer.isDestroyed) setup.renderer.destroy()
  }
})

test("work plan reserves its final bounded row for the omission marker", async () => {
  const setup = await createTestRenderer({ width: 40, height: 12, useThread: false })
  const view = new WorkPlanView(setup.renderer, defaultTheme)
  setup.renderer.root.add(view.root)

  try {
    const plan = snapshot(Array.from({ length: 10 }, (_, index) => step("pending", `Item ${index + 1}`)))
    expect(view.update(plan, 40, 20)).toBe(8)

    let rows = textRows(view)
    expect(rows).toHaveLength(8)
    expect(rowContent(rows.at(-1))).toBe("… 3 more")

    expect(view.update(plan, 40, 3)).toBe(3)
    rows = textRows(view)
    expect(rows.map(rowContent)).toEqual(["○ Item 1", "○ Item 2", "… 8 more"])
  } finally {
    view.destroy()
    if (!setup.renderer.isDestroyed) setup.renderer.destroy()
  }
})

test("work plan truncates cell text to one row and destroys replaced rows", async () => {
  const setup = await createTestRenderer({ width: 20, height: 4, useThread: false })
  const view = new WorkPlanView(setup.renderer, defaultTheme)
  setup.renderer.root.add(view.root)

  try {
    view.update(snapshot([step("pending", "界界界界界\nsecond line")]), 9, 8)
    const staleRow = textRows(view)[0]
    expect(rowContent(staleRow)).toBe("○ 界界...")
    expect(rowContent(staleRow)).not.toContain("\n")
    expect(staleRow?.height).toBe(1)

    view.update(snapshot([step("in_progress", "Replacement")]), 20, 8)
    expect(staleRow?.isDestroyed).toBe(true)
    expect(textRows(view).map(rowContent)).toEqual(["◉ Replacement"])

    expect(view.update(snapshot([step("pending", "Hidden")]), 20, 0)).toBe(0)
    expect(view.root.visible).toBe(false)
    expect(textRows(view)).toHaveLength(0)
  } finally {
    view.destroy()
    if (!setup.renderer.isDestroyed) setup.renderer.destroy()
  }
})

test("unchanged render inputs preserve row identity", async () => {
  const setup = await createTestRenderer({ width: 30, height: 4, useThread: false })
  const view = new WorkPlanView(setup.renderer, defaultTheme)
  setup.renderer.root.add(view.root)

  try {
    const plan = snapshot([step("pending", "Keep this row"), step("in_progress", "And this row")])
    expect(view.update(plan, 30, 20)).toBe(2)
    const rows = textRows(view)

    view.hide()
    expect(view.update(plan, 30, 9)).toBe(2)
    expect(view.root.visible).toBe(true)
    expect(textRows(view)[0]).toBe(rows[0])
    expect(textRows(view)[1]).toBe(rows[1])
    expect(rows.every(row => !row.isDestroyed)).toBe(true)
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

function textRows(view: WorkPlanView): TextRenderable[] {
  return view.root.getChildren().map(child => {
    if (!(child instanceof TextRenderable)) throw new Error("Expected a work plan text row")
    return child
  })
}

function rowContent(row: TextRenderable | undefined): string | undefined {
  return row?.content.chunks.map(chunk => chunk.text).join("")
}
