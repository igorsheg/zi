import { expect, test } from "bun:test"

import { BoxRenderable, TextareaRenderable } from "@opentui/core"
import { createModels, createTestAgentRuntime as createAgentRuntime, fauxProvider } from "@with-zi/coding-agent/testing"

import { createInteractiveTest } from "./harness.js"

test("prompt footer yields the below-composer surface to pickers", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  const { session } = await createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })
  const setup = await createInteractiveTest(session, { width: 48, height: 12 })

  try {
    await setup.renderOnce()
    const footer = setup.renderer.root.findDescendantById("prompt-footer")
    if (!(footer instanceof BoxRenderable)) throw new Error("Prompt footer not found")
    expect(footer.visible).toBe(true)

    await setup.mockInput.typeText("/m", 0)
    await setup.renderOnce()
    expect(footer.visible).toBe(false)

    const input = setup.renderer.root.findDescendantById("prompt-input")
    if (!(input instanceof TextareaRenderable)) throw new Error("Prompt textarea not found")
    input.setText("")
    await setup.renderOnce()
    expect(footer.visible).toBe(true)
  } finally {
    session.dispose()
    setup.destroy()
  }
})

test("prompt footer derives metadata from the replacement session", async () => {
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

test("prompt footer preserves a transcript row and follows compact composer geometry", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  const { session } = await createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })
  const setup = await createInteractiveTest(session, { width: 40, height: 8 })

  try {
    await setup.renderOnce()
    const footer = setup.renderer.root.findDescendantById("prompt-footer")
    if (!(footer instanceof BoxRenderable)) throw new Error("Prompt footer not found")
    expect(footer.visible).toBe(true)

    setup.resize(40, 6)
    await setup.renderOnce()
    expect(footer.visible).toBe(true)

    setup.resize(40, 7)
    await setup.renderOnce()
    expect(footer.visible).toBe(true)

    setup.resize(40, 8)
    await setup.renderOnce()
    expect(footer.visible).toBe(true)

    setup.resize(20, 4)
    await setup.renderOnce()
    expect(footer.visible).toBe(false)
  } finally {
    session.dispose()
    setup.destroy()
  }
})
