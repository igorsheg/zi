import { expect, test } from "bun:test"

import { createTestRenderer } from "@opentui/core/testing"

import { InteractiveKeybindings } from "../../src/interactive/interactive-keybindings.js"
import { transcriptStatusRows, TranscriptStatusView } from "../../src/interactive/transcript/status-view.js"
import { defaultTheme } from "../../src/theme.js"

test("transcript status keeps native truncation on one row", async () => {
  const setup = await createTestRenderer({ width: 20, height: 2, useThread: false })
  const view = new TranscriptStatusView(setup.renderer, new InteractiveKeybindings(), defaultTheme)
  setup.renderer.root.add(view.root)

  try {
    view.update({ type: "working_with_unseen_output", text: "Working…" })
    await setup.renderOnce()
    const rows = setup.captureCharFrame().split("\n")
    expect(rows[0]?.trimEnd()).toStartWith("Working… • New")
    expect(rows[1]?.trimEnd()).toBe("")
    expect(view.root.height).toBe(transcriptStatusRows)

    view.update({ type: "unseen_output" })
    await setup.renderOnce()
    expect(setup.captureCharFrame().split("\n")[0]?.trimEnd()).toStartWith("New output")
  } finally {
    view.destroy()
    if (!setup.renderer.isDestroyed) setup.renderer.destroy()
  }
})

test("transcript status composes activity and unseen output in one stable row", async () => {
  const setup = await createTestRenderer({ width: 60, height: 2, useThread: false })
  const view = new TranscriptStatusView(setup.renderer, new InteractiveKeybindings(), defaultTheme)
  setup.renderer.root.add(view.root)

  try {
    await setup.renderOnce()
    expect(view.root.height).toBe(transcriptStatusRows)
    expect(view.root.visible).toBe(true)
    expect(setup.captureCharFrame()).not.toContain("Working…")

    view.update({ type: "working", text: "Working…" })
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("Working…")

    view.setAvailable(false)
    expect(view.root.visible).toBe(false)
    expect(setup.renderer.liveRequestCount).toBe(0)
    view.setAvailable(true)

    view.update({ type: "working_with_unseen_output", text: "Working…" })
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("Working… • New output (Ctrl+End to jump)")

    view.update({ type: "unseen_output" })
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("New output (Ctrl+End to jump)")
    expect(setup.captureCharFrame()).not.toContain("• New output")

    view.update({ type: "empty" })
    await setup.renderOnce()
    expect(view.root.height).toBe(transcriptStatusRows)
    expect(view.root.visible).toBe(true)
    expect(setup.renderer.liveRequestCount).toBe(0)

    view.update({ type: "working", text: "Working…" })
    expect(setup.renderer.liveRequestCount).toBe(1)
    view.destroy()
    expect(setup.renderer.liveRequestCount).toBe(0)
  } finally {
    view.destroy()
    if (!setup.renderer.isDestroyed) setup.renderer.destroy()
  }
})
