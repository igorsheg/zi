import { expect, test } from "bun:test"

import { createTestRenderer } from "@opentui/core/testing"

import { textWidth } from "../../src/components/cell-text.js"
import {
  layoutPromptFooter,
  type PromptFooterPresentation,
  PromptFooterView
} from "../../src/interactive/prompt/footer-view.js"
import { defaultTheme } from "../../src/theme.js"

const sessionFooter: PromptFooterPresentation = {
  type: "session",
  cwd: "/workspace/zi",
  model: { type: "selected", id: "faux-1", thinking: "high" },
  context: { type: "measured", tokens: 37_050, contextWindow: 247_000, percent: 15 }
}

test("footer drops semantic fields at exact content-fit boundaries", () => {
  expect(layoutPromptFooter(sessionFooter, 48)).toEqual({
    type: "line",
    left: "/workspace/zi",
    right: "ctx 15%/247k • faux-1 (high)"
  })
  expect(layoutPromptFooter(sessionFooter, 40)).toEqual({
    type: "line",
    left: "zi",
    right: "ctx 15%/247k • faux-1 (high)"
  })
  expect(layoutPromptFooter(sessionFooter, 30)).toEqual({ type: "line", left: "zi", right: "ctx 15% • faux-1" })
  expect(layoutPromptFooter(sessionFooter, 20)).toEqual({ type: "line", left: "zi", right: "ctx 15%" })
  expect(layoutPromptFooter(sessionFooter, 9)).toEqual({ type: "line", left: "", right: "ctx 15%" })
  expect(layoutPromptFooter(sessionFooter, 8)).toEqual({ type: "hidden" })
})

test("footer keeps onboarding and unavailable-context fallbacks explicit", () => {
  const unselected: PromptFooterPresentation = {
    type: "session",
    cwd: "/workspace/zi",
    model: { type: "unselected" },
    context: { type: "unavailable", reason: "no_model" }
  }
  expect(layoutPromptFooter(unselected, 40)).toEqual({
    type: "line",
    left: "/workspace/zi",
    right: "No model selected"
  })
  expect(layoutPromptFooter(unselected, 12)).toEqual({ type: "line", left: "", right: "No model" })

  const unknownWindow: PromptFooterPresentation = {
    type: "session",
    cwd: "/workspace/zi",
    model: { type: "selected", id: "faux-1", thinking: "off" },
    context: { type: "unavailable", reason: "unknown_window" }
  }
  expect(layoutPromptFooter(unknownWindow, 20)).toEqual({ type: "line", left: "zi", right: "faux-1" })
})

test("footer measures Unicode terminal cells rather than string length", () => {
  const presentation: PromptFooterPresentation = {
    type: "session",
    cwd: "/工作/项目",
    model: { type: "selected", id: "模型", thinking: "off" },
    context: { type: "unavailable", reason: "unknown_window" }
  }
  const exactWidth = 2 + textWidth("/工作/项目") + 2 + textWidth("模型")

  expect(layoutPromptFooter(presentation, exactWidth)).toEqual({ type: "line", left: "/工作/项目", right: "模型" })
  expect(layoutPromptFooter(presentation, exactWidth - 1)).toEqual({ type: "line", left: "项目", right: "模型" })
})

test("footer keeps native rows stable and skips identical assignments", async () => {
  const setup = await createTestRenderer({ width: 40, height: 8, useThread: false })
  const footer = new PromptFooterView(setup.renderer, defaultTheme)
  setup.renderer.root.add(footer.root)
  const layout = layoutPromptFooter(sessionFooter, 40)

  try {
    expect(footer.update(layout)).toBe(3)
    await setup.waitForVisualIdle()
    const children = [...footer.root.getChildren()]
    expect(setup.renderer.getSchedulerState().hasScheduledRender).toBe(false)

    expect(footer.update({ ...layout })).toBe(3)
    expect([...footer.root.getChildren()]).toEqual(children)
    expect(setup.renderer.getSchedulerState().hasScheduledRender).toBe(false)

    expect(footer.update({ type: "hidden" })).toBe(0)
    expect(footer.root.visible).toBe(false)
  } finally {
    footer.destroy()
    if (!setup.renderer.isDestroyed) setup.renderer.destroy()
  }
})
