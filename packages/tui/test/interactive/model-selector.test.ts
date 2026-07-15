import { expect, test } from "bun:test"

import { TextareaRenderable } from "@opentui/core"
import { createAgentRuntime } from "@openzi/coding-agent"
import { createModels, fauxProvider } from "@openzi/coding-agent/testing"

import { createInteractiveCommands } from "../../src/interactive/interactive-commands.js"
import { createInteractiveStore } from "../../src/interactive/stores/interactive.js"
import { createPromptStore } from "../../src/interactive/stores/prompt.js"
import { createInteractiveTest, renderSettled } from "./harness.js"

test("slash completion admits /model through the prompt workflow", async () => {
  const { session, setup } = await createModelFixture()

  try {
    const prompt = promptInput(setup)
    await setup.mockInput.typeText("/m", 0)
    await setup.renderOnce()

    expect(setup.captureCharFrame()).toContain("/model  <provider/model>")

    setup.mockInput.pressTab()
    expect(prompt.plainText).toBe("/model ")
    expect(setup.renderer.root.findDescendantById("model-search-input")).toBeUndefined()

    setup.mockInput.pressEnter()
    await renderSettled(setup)

    expect(prompt.plainText).toBe("")
    expect(setup.renderer.root.findDescendantById("model-search-input")).toBeDefined()
  } finally {
    session.dispose()
    setup.destroy()
  }
})

test("/model selects exact bare and provider/model references without opening the picker", async () => {
  const { session, setup } = await createModelFixture()

  try {
    const prompt = promptInput(setup)
    prompt.setText("/model target")
    setup.mockInput.pressEnter()
    await renderSettled(setup)

    expect(session.model.id).toBe("target")
    expect(setup.renderer.root.findDescendantById("model-search-input")).toBeUndefined()
    expect(prompt.plainText).toBe("")
    expect(setup.captureCharFrame()).toContain("Model: target")

    prompt.setText("/model select/current")
    setup.mockInput.pressEnter()
    await renderSettled(setup)

    expect(session.model.id).toBe("current")
    expect(setup.renderer.root.findDescendantById("model-search-input")).toBeUndefined()
    expect(setup.captureCharFrame()).toContain("Model: current")
  } finally {
    session.dispose()
    setup.destroy()
  }
})

test("/model with an unmatched term opens a prefiltered selector and Escape cancels", async () => {
  const { session, setup } = await createModelFixture()

  try {
    const prompt = promptInput(setup)
    prompt.setText("/model targ")
    setup.mockInput.pressEnter()
    await renderSettled(setup)

    const search = setup.renderer.root.findDescendantById("model-search-input")
    if (!(search instanceof TextareaRenderable)) throw new Error("Model search textarea not found")
    expect(search.plainText).toBe("targ")
    expect(setup.captureCharFrame()).toContain("target  [select]")
    expect(setup.captureCharFrame()).not.toContain("current  [select]")

    setup.mockInput.pressEscape()
    await setup.renderOnce()

    expect(session.model.id).toBe("current")
    expect(setup.renderer.root.findDescendantById("model-search-input")).toBeUndefined()
    expect(prompt.focused).toBe(true)
  } finally {
    session.dispose()
    setup.destroy()
  }
})

test("model selection failure closes the picker and reports the error", async () => {
  const { session, setup } = await createModelFixture()
  session.setModel = async () => {
    throw new Error("selection failed")
  }

  try {
    const prompt = promptInput(setup)
    prompt.setText("/model")
    setup.mockInput.pressEnter()
    await renderSettled(setup)

    setup.mockInput.pressArrow("down")
    setup.mockInput.pressEnter()
    await renderSettled(setup)

    expect(setup.renderer.root.findDescendantById("model-search-input")).toBeUndefined()
    expect(prompt.focused).toBe(true)
    expect(setup.captureCharFrame()).toContain("selection failed")
    expect(session.model.id).toBe("current")
  } finally {
    session.dispose()
    setup.destroy()
  }
})

test("cancelled model selection rejects stale completion", async () => {
  const { session } = await createModelSession()
  const interactive = createInteractiveStore(session)
  const prompt = createPromptStore(interactive, createInteractiveCommands())
  const selection = deferred<void>()
  session.setModel = () => selection.promise

  try {
    expect(prompt.submit("/model", "steer")).toBe(true)
    await waitFor(() => prompt.$state.get().surface.type === "model_selector")
    expect(prompt.$state.get().surface.type).toBe("model_selector")
    expect(prompt.submit("/model", "steer")).toBe(false)
    expect(prompt.selectModel("")).toBe(true)
    expect(prompt.cancelModelSelector()).toBe(true)

    selection.reject(new Error("stale selection failed"))
    await settle()

    expect(prompt.$state.get()).toMatchObject({ feedback: { type: "none" }, surface: { type: "composer" } })
  } finally {
    prompt.dispose()
    interactive.dispose()
    session.dispose()
  }
})

test("model loading completion cannot cross a session replacement", async () => {
  const { session: first } = await createModelSession("first")
  const { session: second } = await createModelSession("second")
  const load = deferred<readonly []>()
  first.listModelChoices = () => load.promise
  const setup = await createInteractiveTest(first, { width: 52, height: 16, kittyKeyboard: true })

  try {
    const prompt = promptInput(setup)
    prompt.setText("/model")
    setup.mockInput.pressEnter()
    expect(setup.renderer.root.findDescendantById("model-search-input")).toBeDefined()

    setup.mode.replaceSession(second)
    load.resolve([])
    await renderSettled(setup)

    expect(setup.mode.store.getSession() === second).toBe(true)
    expect(setup.renderer.root.findDescendantById("model-search-input")).toBeUndefined()
    expect(promptInput(setup).focused).toBe(true)
  } finally {
    first.dispose()
    second.dispose()
    setup.destroy()
  }
})

test("model picker omits unconfigured providers, sorts like Pi, and wraps selection", async () => {
  const models = createModels()
  const zeta = fauxProvider({
    provider: "zeta",
    models: [
      { id: "current", reasoning: true },
      { id: "other", reasoning: true }
    ]
  })
  const alpha = fauxProvider({ provider: "alpha", models: [{ id: "first", reasoning: true }] })
  const hidden = fauxProvider({ provider: "hidden", models: [{ id: "secret", reasoning: true }] })
  models.setProvider(zeta.provider)
  models.setProvider(alpha.provider)
  models.setProvider(hidden.provider)
  models.getAuth = async model =>
    model.provider === "hidden" ? undefined : { auth: { apiKey: "configured" }, source: "test" }
  const { session } = await createAgentRuntime({ cwd: "/work", model: "zeta/current", models, persist: false })
  const setup = await createInteractiveTest(session, { width: 52, height: 16, kittyKeyboard: true })

  try {
    const prompt = promptInput(setup)
    prompt.setText("/model")
    setup.mockInput.pressEnter()
    await renderSettled(setup)

    const frame = setup.captureCharFrame()
    expect(frame).not.toContain("secret")
    expect(frame.indexOf("current  [zeta]  ✓")).toBeLessThan(frame.indexOf("first  [alpha]"))
    expect(frame.indexOf("first  [alpha]")).toBeLessThan(frame.indexOf("other  [zeta]"))

    setup.mockInput.pressArrow("up")
    setup.mockInput.pressEnter()
    await renderSettled(setup)
    expect(session.model.id).toBe("other")
  } finally {
    session.dispose()
    setup.destroy()
  }
})

test("/model opens configured models and selects through the terminal picker", async () => {
  const { session, setup } = await createModelFixture()

  try {
    const prompt = promptInput(setup)
    prompt.setText("/model")
    setup.mockInput.pressEnter()
    await renderSettled(setup)

    expect(prompt.plainText).toBe("")
    const search = setup.renderer.root.findDescendantById("model-search-input")
    if (!(search instanceof TextareaRenderable)) throw new Error("Model search textarea not found")
    expect(search.focused).toBe(true)
    expect(setup.captureCharFrame()).toContain("current  [select]  ✓")
    expect(setup.captureCharFrame()).toContain("target  [select]")

    setup.mockInput.pressArrow("down")
    setup.mockInput.pressEnter()
    await renderSettled(setup)

    expect(session.model.id).toBe("target")
    expect(setup.renderer.root.findDescendantById("model-search-input")).toBeUndefined()
    expect(prompt.focused).toBe(true)
    expect(setup.captureCharFrame()).toContain("Model: target")
  } finally {
    session.dispose()
    setup.destroy()
  }
})

async function createModelFixture() {
  const { session } = await createModelSession()
  const setup = await createInteractiveTest(session, { width: 52, height: 16, kittyKeyboard: true })
  return { session, setup }
}

async function createModelSession(provider = "select") {
  const models = createModels()
  const faux = fauxProvider({
    provider,
    models: [
      { id: "current", name: "Current model", reasoning: true },
      { id: "target", name: "Target model", reasoning: true }
    ]
  })
  models.setProvider(faux.provider)
  models.getAuth = async () => ({ auth: { apiKey: "configured" }, source: "test" })
  const { session } = await createAgentRuntime({ cwd: "/work", model: `${provider}/current`, models, persist: false })
  return { session }
}

async function settle(): Promise<void> {
  await Promise.resolve()
  await Promise.resolve()
}

async function waitFor(predicate: () => boolean): Promise<void> {
  for (let attempt = 0; attempt < 20; attempt++) {
    if (predicate()) return
    // oxlint-disable-next-line no-await-in-loop
    await Promise.resolve()
  }
  throw new Error("Condition was not reached")
}

function deferred<T>() {
  let resolve!: (value: T | PromiseLike<T>) => void
  let reject!: (cause?: unknown) => void
  const promise = new Promise<T>((resolvePromise, rejectPromise) => {
    resolve = resolvePromise
    reject = rejectPromise
  })
  return { promise, resolve, reject }
}

function promptInput(setup: Awaited<ReturnType<typeof createInteractiveTest>>): TextareaRenderable {
  const prompt = setup.renderer.root.findDescendantById("prompt-input")
  if (!(prompt instanceof TextareaRenderable)) throw new Error("Prompt textarea not found")
  return prompt
}
