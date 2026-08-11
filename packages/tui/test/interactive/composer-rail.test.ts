import { expect, test } from "bun:test"
import { join } from "node:path"

import { BoxRenderable } from "@opentui/core"
import { createModels, createTestAgentRuntime as createAgentRuntime, fauxProvider } from "@with-zi/coding-agent/testing"

import { createInteractiveTest } from "./harness.js"

test("session metadata stays on the composer rail while a picker is open", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  const { session } = await createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })
  const setup = await createInteractiveTest(session, { width: 48, height: 12 })

  try {
    await setup.renderOnce()
    const composer = setup.renderer.root.findDescendantById("prompt-composer")
    if (!(composer instanceof BoxRenderable)) throw new Error("Prompt composer not found")
    expect(setup.renderer.root.findDescendantById("prompt-footer")).toBeUndefined()
    expect(composerRows(setup.captureCharFrame(), composer)).toEqual(
      expect.arrayContaining([expect.stringContaining("faux-1"), expect.stringContaining("/work")])
    )

    await setup.mockInput.typeText("/m", 0)
    await setup.renderOnce()
    expect(composerRows(setup.captureCharFrame(), composer)).toEqual(
      expect.arrayContaining([expect.stringContaining("faux-1"), expect.stringContaining("/work")])
    )
  } finally {
    session.dispose()
    setup.destroy()
  }
})

test("composer rail reads home contraction from the cwd-bound session paths", async () => {
  const homeDir = process.env.HOME
  if (!homeDir) throw new Error("Test home not configured")
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  const cwd = join(homeDir, "workspace", "dev", "personal", "zi")
  const { session } = await createAgentRuntime({ cwd, models, session: { type: "new", persist: false } })
  const setup = await createInteractiveTest(session, { width: 80, height: 12 })

  try {
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("~/workspace/dev/personal/zi")
    expect(setup.captureCharFrame()).not.toContain(homeDir)
  } finally {
    session.dispose()
    setup.destroy()
  }
})

test("composer rail derives metadata from the replacement session", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  const first = await createAgentRuntime({ cwd: "/first", models, session: { type: "new", persist: false } })
  const second = await createAgentRuntime({ cwd: "/second", models, session: { type: "new", persist: false } })
  const setup = await createInteractiveTest(first.session, { width: 48, height: 12 })

  try {
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("/first")

    setup.mode.replaceSession(second.session)
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("/second")
    expect(setup.captureCharFrame()).not.toContain("/first")
  } finally {
    first.session.dispose()
    second.session.dispose()
    setup.destroy()
  }
})

test("composer rail follows bordered composer geometry without occupying another row", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  const { session } = await createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })
  const setup = await createInteractiveTest(session, { width: 40, height: 8 })

  try {
    await setup.renderOnce()
    const composer = setup.renderer.root.findDescendantById("prompt-composer")
    if (!(composer instanceof BoxRenderable)) throw new Error("Prompt composer not found")
    expect(composer.border).toBe(true)
    expect(composerRows(setup.captureCharFrame(), composer).at(-1)).toContain("/work")

    setup.resize(20, 4)
    await setup.renderOnce()
    expect(composer.border).toBe(false)
    expect(composer.height).toBe(1)
  } finally {
    session.dispose()
    setup.destroy()
  }
})

function composerRows(frame: string, composer: BoxRenderable): string[] {
  return frame.split("\n").slice(composer.screenY, composer.screenY + composer.height)
}
