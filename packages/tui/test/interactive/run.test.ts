import { expect, mock, test } from "bun:test"

import { createTestRenderer } from "@opentui/core/testing"
import { createAgentRuntime } from "@openzi/coding-agent"
import { createModels, fauxProvider } from "@openzi/coding-agent/testing"

test("renderer destruction tears down terminal resources without taking session ownership", async () => {
  const setup = await createTestRenderer({ width: 40, height: 8, useThread: false })
  const core = await import("@opentui/core")
  await mock.module("@opentui/core", () => ({ ...core, createCliRenderer: async () => setup.renderer }))

  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  const { session } = await createAgentRuntime({ cwd: "/work", models, persist: false })
  const dispose = session.dispose.bind(session)
  let disposals = 0
  session.dispose = () => {
    disposals++
    dispose()
  }
  const titles: string[] = []
  const setTerminalTitle = setup.renderer.setTerminalTitle.bind(setup.renderer)
  setup.renderer.setTerminalTitle = title => {
    titles.push(title)
    setTerminalTitle(title)
  }

  try {
    const { runTui } = await import("../../src/interactive/run.js")
    const running = runTui({ session })
    await setup.renderOnce()
    setup.renderer.destroy()
    await running

    expect(disposals).toBe(0)
    expect(titles).toEqual(["openzi", ""])
  } finally {
    session.dispose()
    if (!setup.renderer.isDestroyed) setup.renderer.destroy()
    mock.restore()
  }
})
