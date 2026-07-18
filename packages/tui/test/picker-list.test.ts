import { expect, test } from "bun:test"

import { createTestRenderer } from "@opentui/core/testing"

import { createPickerList } from "../src/components/picker-list.js"
import { defaultTheme } from "../src/theme.js"

test("PickerList renders rows without owning domain actions", async () => {
  const setup = await createTestRenderer({ width: 40, height: 4, useThread: false })
  const picker = createPickerList(setup.renderer, {
    scope: "test",
    rows: [
      { id: "first", label: "First", detail: "detail" },
      { id: "second", label: "Second", metadata: "unavailable" }
    ],
    selectedId: "first",
    height: 4,
    theme: defaultTheme
  })
  setup.renderer.root.add(picker.root)

  try {
    await setup.renderOnce()
    expect(frameRows(setup.captureCharFrame(), 4)).toEqual(["› First  detail", "  Second  unavailable", "", ""])
    const spans = setup.captureSpans().lines.flatMap(line => line.spans)
    expect(span(spans, "› ").fg.toInts()).toEqual([122, 168, 159, 255])
    expect(span(spans, "First").fg.toInts()).toEqual([197, 201, 199, 255])
  } finally {
    picker.destroy()
    setup.renderer.destroy()
  }
})

test("PickerList centers a middle selection like Pi selectors", async () => {
  const rows = Array.from({ length: 12 }, (_, index) => ({ id: String(index), label: `Row ${index}` }))
  const setup = await createTestRenderer({ width: 20, height: 5, useThread: false })
  const picker = createPickerList(setup.renderer, {
    scope: "test",
    rows,
    selectedId: "5",
    height: 5,
    theme: defaultTheme
  })
  setup.renderer.root.add(picker.root)

  try {
    await setup.renderOnce()
    expect(frameRows(setup.captureCharFrame(), 5)).toEqual(["  Row 3", "  Row 4", "› Row 5", "  Row 6", "  Row 7"])
  } finally {
    picker.destroy()
    setup.renderer.destroy()
  }
})

test("PickerList windows selection and leaves empty-state policy to its caller", async () => {
  const rows = Array.from({ length: 6 }, (_, index) => ({ id: String(index), label: `Row ${index}` }))
  const setup = await createTestRenderer({ width: 20, height: 3, useThread: false })
  const picker = createPickerList(setup.renderer, {
    scope: "test",
    rows,
    selectedId: "5",
    height: 3,
    theme: defaultTheme
  })
  setup.renderer.root.add(picker.root)

  try {
    await setup.renderOnce()
    expect(frameRows(setup.captureCharFrame(), 3)).toEqual(["  Row 3", "  Row 4", "› Row 5"])
  } finally {
    picker.destroy()
    setup.renderer.destroy()
  }

  const emptySetup = await createTestRenderer({ width: 20, height: 2, useThread: false })
  const empty = createPickerList(emptySetup.renderer, {
    scope: "test",
    rows: [],
    height: 2,
    emptyText: "nothing here",
    theme: defaultTheme
  })
  emptySetup.renderer.root.add(empty.root)

  try {
    await emptySetup.renderOnce()
    expect(frameRows(emptySetup.captureCharFrame(), 2)).toEqual(["  nothing here", ""])
  } finally {
    empty.destroy()
    emptySetup.renderer.destroy()
  }
})

test("PickerList retains visible rows by ID and bounds native children", async () => {
  const setup = await createTestRenderer({ width: 20, height: 12, useThread: false })
  const rows = Array.from({ length: 20 }, (_, index) => ({ id: String(index), label: `Row ${index}` }))
  const picker = createPickerList(setup.renderer, {
    scope: "first-frame",
    rows,
    selectedId: "0",
    height: 20,
    theme: defaultTheme
  })
  setup.renderer.root.add(picker.root)

  try {
    const first = picker.root.getChildren()[0]!
    const second = picker.root.getChildren()[1]!
    expect(picker.root.getChildrenCount()).toBe(10)

    picker.update({ scope: "first-frame", rows, selectedId: "1", height: 20, theme: defaultTheme })
    expect(picker.root.getChildren()[0]).toBe(first)
    expect(picker.root.getChildren()[1]).toBe(second)

    picker.update({ scope: "first-frame", rows: rows.slice(1), selectedId: "1", height: 10, theme: defaultTheme })
    expect(picker.root.getChildren()[0]).toBe(second)
    expect(first.isDestroyed).toBe(true)
    expect(picker.root.getChildrenCount()).toBe(10)

    picker.update({ scope: "first-frame", rows, selectedId: "1", height: 0, theme: defaultTheme })
    expect(picker.root.visible).toBe(false)
    expect(picker.root.getChildrenCount()).toBe(0)
  } finally {
    picker.destroy()
    setup.renderer.destroy()
  }
})

test("PickerList scopes retained row identity to the active frame", async () => {
  const setup = await createTestRenderer({ width: 20, height: 2, useThread: false })
  const picker = createPickerList(setup.renderer, {
    scope: "first-frame",
    rows: [{ id: "same", label: "First domain row" }],
    selectedId: "same",
    height: 1,
    theme: defaultTheme
  })
  setup.renderer.root.add(picker.root)

  try {
    const first = picker.root.getChildren()[0]!
    picker.update({
      scope: "second-frame",
      rows: [{ id: "same", label: "Second domain row" }],
      selectedId: "same",
      height: 1,
      theme: defaultTheme
    })

    expect(picker.root.getChildren()[0]).not.toBe(first)
    expect(first.isDestroyed).toBe(true)
  } finally {
    picker.destroy()
    setup.renderer.destroy()
  }
})

function frameRows(frame: string, height: number): string[] {
  return frame
    .split("\n")
    .slice(0, height)
    .map(line => line.trimEnd())
}

function span<T extends { text: string }>(spans: readonly T[], text: string): T {
  const found = spans.find(candidate => candidate.text === text)
  if (!found) throw new Error(`Missing span: ${text}`)
  return found
}
