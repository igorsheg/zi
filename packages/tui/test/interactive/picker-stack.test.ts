import { expect, test } from "bun:test"

import { BoxRenderable } from "@opentui/core"
import { createTestRenderer } from "@opentui/core/testing"
import { createModels, createTestAgentRuntime, fauxProvider } from "@with-zi/coding-agent/testing"

import { InteractiveKeybindings } from "../../src/interactive/interactive-keybindings.js"
import { sessionFrame } from "../../src/interactive/prompt/frames.js"
import { PickerStackView } from "../../src/interactive/prompt/picker-view.js"
import {
  createPickerStack,
  maxPickerDepth,
  maxPickerRows,
  maxSuspendedFilterLength
} from "../../src/interactive/prompt/picker.js"
import { defaultTheme } from "../../src/theme.js"

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
    expect(() => stack.open({ ...boundedFrame("tall"), height: 11 })).toThrow("frame height")

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

test("picker view keeps a preferred total height while optional chrome changes", async () => {
  const setup = await createTestRenderer({ width: 40, height: 10, useThread: false })
  const stack = createPickerStack()
  const view = new PickerStackView(setup.renderer, stack, defaultTheme, new InteractiveKeybindings(), () => "")
  setup.renderer.root.add(view.root)
  const frame = { ...boundedFrame("stable", 20), title: "", height: 7 }

  try {
    stack.open(frame)
    view.update(10)
    await setup.renderOnce()
    const list = view.root.findDescendantById("picker-list")
    if (!(list instanceof BoxRenderable)) throw new Error("Picker list not found")
    expect(view.root.height).toBe(7)
    expect(list.height).toBe(7)

    stack.replaceTop({ ...frame, footer: "Search limited" }, "")
    view.update(10)
    await setup.renderOnce()
    expect(view.root.height).toBe(7)
    expect(list.height).toBe(6)
  } finally {
    view.destroy()
    stack.dispose()
    if (!setup.renderer.isDestroyed) setup.renderer.destroy()
  }
})

test("a footer-owned picker keeps its primary actions visible without duplicate generic hints", async () => {
  const setup = await createTestRenderer({ width: 32, height: 8, useThread: false })
  const stack = createPickerStack()
  const view = new PickerStackView(setup.renderer, stack, defaultTheme, new InteractiveKeybindings(), () => "")
  setup.renderer.root.add(view.root)

  try {
    stack.open({
      id: "agents",
      title: "Agents · All",
      filter: "fuzzy",
      rows: [
        {
          id: "/root/recursive/journal_probe",
          label: "working #12",
          metadata: "/root/recursive/journal_probe",
          metadataTruncation: "path",
          searchText: "journal probe"
        },
        {
          id: "/root/recursive/result_probe",
          label: "working #12",
          metadata: "/root/recursive/result_probe",
          metadataTruncation: "path",
          searchText: "result probe"
        }
      ],
      footer: "Enter inspect · Esc close · Tab show running",
      footerFallbacks: ["Enter inspect · Esc close", "Enter · Esc"],
      keyHintMode: "footer"
    })
    view.update(8)
    await setup.renderOnce()
    const frame = setup.captureCharFrame()
    expect(frame).toContain("working #12")
    expect(frame).toContain("jour")
    expect(frame).toContain("res")
    expect(frame).toContain("Enter inspect · Esc close")
    expect(frame).not.toContain("enter confirm")
    expect(frame).not.toContain("esc close\ntype to filter")

    setup.resize(24, 8)
    view.update(8)
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("jour")
    expect(setup.captureCharFrame()).toContain("res")

    setup.resize(16, 8)
    view.update(8)
    await setup.renderOnce()
    const narrowFrame = setup.captureCharFrame()
    expect(narrowFrame).toContain("jour")
    expect(narrowFrame).toContain("res")
    expect(narrowFrame).toContain("Enter · Esc")
  } finally {
    view.destroy()
    stack.dispose()
    if (!setup.renderer.isDestroyed) setup.renderer.destroy()
  }
})

test("changed fuzzy queries select the best match without disturbing navigation for the same query", () => {
  const stack = createPickerStack()

  try {
    stack.open({
      id: "models",
      title: "Models",
      filter: "fuzzy",
      height: 7,
      rows: [
        { id: "alpha", label: "Alpha", searchText: "provider alpha" },
        { id: "beta", label: "Beta", searchText: "provider beta" },
        { id: "gamma", label: "Gamma", searchText: "provider gamma" }
      ]
    })
    stack.move("", -1)
    expect(stack.presentation("")?.selectedId).toBe("gamma")

    stack.queryChanged("provider")
    expect(stack.presentation("provider")?.selectedId).toBe("alpha")
    stack.move("provider", 1)
    stack.queryChanged("provider")
    expect(stack.presentation("provider")?.selectedId).toBe("beta")
  } finally {
    stack.dispose()
  }
})

test("back reveals the parent frame and its owning workflow together", async () => {
  const stack = createPickerStack()
  const models = createModels()
  const provider = fauxProvider({ provider: "picker-stack", models: [{ id: "model" }] })
  models.setProvider(provider.provider)
  const { session } = await createTestAgentRuntime({
    cwd: process.cwd(),
    model: "picker-stack/model",
    models,
    projectTrust: { type: "trusted", cwd: process.cwd(), source: "runtime" },
    session: { type: "new", persist: false }
  })
  const rootWorkflow = { type: "choosing_settings_scope", operationId: 1, session } as const
  const childWorkflow = { type: "choosing_setting", operationId: 1, session, scope: "global" } as const

  try {
    stack.open(boundedFrame("scopes"), rootWorkflow)
    stack.push(boundedFrame("settings"), "glob", childWorkflow)
    expect(stack.presentation("")?.workflow).toBe(childWorkflow)
    expect(stack.back()).toEqual({ type: "revealed", filter: "glob", workflow: rootWorkflow })
    expect(stack.presentation("glob")?.workflow).toBe(rootWorkflow)
  } finally {
    stack.dispose()
    session.dispose()
  }
})

test("session rows expose relative recency and a bounded cwd", () => {
  const now = Date.parse("2026-08-05T12:00:00.000Z")
  const frame = sessionFrame(
    [
      {
        path: "/sessions/one.jsonl",
        id: "one",
        cwd: "/very/long/workspace/teams/zi",
        createdAt: "2026-08-05T09:00:00.000Z",
        modifiedAt: "2026-08-05T10:00:00.000Z",
        firstMessage: "Polish the picker"
      }
    ],
    undefined,
    {},
    now
  )

  expect(frame.rows[0]).toMatchObject({
    label: "Polish the picker",
    detail: "[2h ago]",
    metadata: "…/workspace/teams/zi"
  })
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
