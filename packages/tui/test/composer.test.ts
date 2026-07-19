import { expect, test } from "bun:test"

import { createTestRenderer } from "@opentui/core/testing"

import { composerGeometry, createComposer } from "../src/components/composer.js"
import { defaultTheme } from "../src/theme.js"

test("reapplying the same composer presentation does not schedule another frame", async () => {
  const setup = await createTestRenderer({ width: 40, height: 8, useThread: false })
  const geometry = composerGeometry(40, 8)
  const slots = { topLeft: "/workspace/openzi", topRight: ["model (high)", "(ctx 15%/247k)"] }
  const composer = createComposer(setup.renderer, { geometry, slots, theme: defaultTheme, onSubmit() {} })
  setup.renderer.root.add(composer.root)

  try {
    await setup.waitForVisualIdle()
    expect(setup.renderer.getSchedulerState().hasScheduledRender).toBe(false)

    composer.update(composerGeometry(40, 8), {
      topLeft: "/workspace/openzi",
      topRight: ["model (high)", "(ctx 15%/247k)"]
    })

    expect(setup.renderer.getSchedulerState().hasScheduledRender).toBe(false)
  } finally {
    composer.destroy()
    if (!setup.renderer.isDestroyed) setup.renderer.destroy()
  }
})
