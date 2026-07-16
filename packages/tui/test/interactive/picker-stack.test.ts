import { expect, test } from "bun:test"

import {
  createPickerStack,
  maxPickerDepth,
  maxPickerRows,
  maxSuspendedFilterLength
} from "../../src/interactive/prompt/picker.js"

test("picker stack filters only its top frame and restores suspended parent filters", () => {
  const stack = createPickerStack()

  try {
    stack.open({
      id: "settings",
      title: "Settings",
      filter: "fuzzy",
      rows: [
        { id: "codex", label: "Codex settings", searchText: "codex settings" },
        { id: "anthropic", label: "Anthropic settings", searchText: "anthropic settings" }
      ]
    })
    const root = stack.presentation("cod")
    expect(root).toMatchObject({ depth: 1, frame: { id: "settings" }, selectedId: "codex", rows: [{ id: "codex" }] })
    expect(root && "selectedIndex" in root.frame).toBe(false)
    expect(root && "parentFilter" in root.frame).toBe(false)

    stack.push(
      {
        id: "codex",
        title: "Codex settings",
        filter: "fuzzy",
        rows: [
          { id: "fast-mode", label: "Fast mode", searchText: "fast mode" },
          { id: "reasoning", label: "Reasoning", searchText: "reasoning effort" }
        ]
      },
      "cod"
    )
    stack.move("", 1)
    expect(stack.presentation("")).toMatchObject({ depth: 2, frame: { id: "codex" }, selectedId: "reasoning" })

    stack.push(
      {
        id: "fast-mode",
        title: "Fast mode",
        filter: "fuzzy",
        rows: [
          { id: "on", label: "On", searchText: "on enabled" },
          { id: "off", label: "Off", searchText: "off disabled" }
        ]
      },
      "reason"
    )
    expect(stack.presentation("")).toMatchObject({ depth: 3, frame: { id: "fast-mode" }, selectedId: "on" })

    expect(stack.back()).toEqual({ type: "revealed", filter: "reason" })
    expect(stack.presentation("reason")).toMatchObject({ depth: 2, frame: { id: "codex" }, selectedId: "reasoning" })
    expect(stack.back()).toEqual({ type: "revealed", filter: "cod" })
    expect(stack.presentation("cod")).toMatchObject({ depth: 1, frame: { id: "settings" }, selectedId: "codex" })
    expect(stack.back()).toEqual({ type: "closed" })
    expect(stack.presentation("")).toBeUndefined()
  } finally {
    stack.dispose()
  }
})

test("picker stack rejects unbounded and forbidden transitions", () => {
  const stack = createPickerStack()

  try {
    expect(() => stack.replaceTop(boundedFrame("closed"), "")).toThrow("closed")
    expect(() => stack.open(boundedFrame("wide", maxPickerRows + 1))).toThrow(`${maxPickerRows}`)

    stack.open(boundedFrame("root"))
    for (let depth = 1; depth < maxPickerDepth; depth++) stack.push(boundedFrame(`level-${depth}`), "filter")
    expect(() => stack.push(boundedFrame("too-deep"), "filter")).toThrow(`${maxPickerDepth}`)

    stack.close()
    stack.open(boundedFrame("filter-root"))
    expect(() => stack.push(boundedFrame("child"), "x".repeat(maxSuspendedFilterLength + 1))).toThrow(
      `${maxSuspendedFilterLength}`
    )
  } finally {
    stack.dispose()
  }
})

test("picker stack wraps top-frame selection without owning the filter input", () => {
  const stack = createPickerStack()

  try {
    stack.open({
      id: "models",
      title: "Models",
      filter: "fuzzy",
      selectedId: "current",
      rows: [
        { id: "current", label: "Current", searchText: "current provider" },
        { id: "target", label: "Target", searchText: "target provider" }
      ]
    })
    stack.move("", -1)
    expect(stack.presentation("")?.selectedId).toBe("target")
    stack.queryChanged("curr")
    expect(stack.presentation("curr")?.selectedId).toBe("current")
  } finally {
    stack.dispose()
  }
})

function boundedFrame(id: string, rows = 1) {
  return {
    id,
    title: id,
    filter: "none" as const,
    rows: Array.from({ length: rows }, (_, index) => ({
      id: `${id}-${index}`,
      label: `${id} ${index}`,
      searchText: `${id} ${index}`
    }))
  }
}
