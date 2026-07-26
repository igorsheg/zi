import { expect, spyOn, test } from "bun:test"

import { TextareaRenderable } from "@opentui/core"
import { createModels, createTestAgentRuntime as createAgentRuntime, fauxProvider } from "@with-zi/coding-agent/testing"

import { createInteractiveTest, renderSettled } from "./harness.js"

test("the session app fills the terminal and protects the prompt", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  const { session } = await createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })
  let exits = 0
  const setup = await createInteractiveTest(session, { width: 40, height: 8 }, () => exits++)

  try {
    await setup.renderOnce()
    const frame = setup.captureCharFrame()
    expect(frame).toContain("/work")
    expect(frame).toContain("faux-1")

    const spans = setup.captureSpans()
    expect(spans.lines[0]?.spans[0]?.bg.toInts()).toEqual([9, 14, 19, 255])

    const input = setup.renderer.root.findDescendantById("prompt-input")
    if (!(input instanceof TextareaRenderable)) throw new Error("Prompt textarea not found")
    input.setText("discard me")
    setup.mockInput.pressCtrlC()
    expect(input.plainText).toBe("")
    expect(exits).toBe(0)

    setup.mockInput.pressKey("d", { ctrl: true })
    expect(exits).toBe(1)
  } finally {
    session.dispose()
    setup.destroy()
  }
})

test("interactive memory diagnostics compose process, session, renderer, and listener ownership", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  const { session } = await createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })
  const setup = await createInteractiveTest(session, { width: 40, height: 8 })

  try {
    await renderSettled(setup)
    expect(setup.renderer.root.findDescendantById("tui-memory-stats")).toBeUndefined()
    const snapshot = setup.mode.captureMemoryDiagnostics()
    expect(snapshot.process.rssBytes).toBeGreaterThan(0)
    expect(snapshot.process.heapUsedBytes).toBeGreaterThan(0)
    expect(snapshot.session).toMatchObject({ committedMessages: 0, committedMessageBytes: 0, subscribers: 1 })
    expect(snapshot.renderer.reachableRenderables).toBeGreaterThan(snapshot.renderer.transcriptRoots)
    expect(snapshot.renderer.registeredRenderables).toBeGreaterThanOrEqual(snapshot.renderer.reachableRenderables)
    expect(snapshot.renderer.bufferBytes).toBeGreaterThan(0)
    expect(snapshot.listeners.renderer).toBeGreaterThan(0)
    expect(snapshot.listeners.keyInput).toBeGreaterThan(0)
  } finally {
    session.dispose()
    setup.destroy()
  }
})

test("a second Ctrl+C within Pi's window exits the interactive mode", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  const { session } = await createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })
  let exits = 0
  const setup = await createInteractiveTest(session, { width: 40, height: 8 }, () => exits++)

  try {
    setup.mockInput.pressCtrlC()
    expect(exits).toBe(0)
    setup.mockInput.pressCtrlC()
    expect(exits).toBe(1)
  } finally {
    session.dispose()
    setup.destroy()
  }
})

test("a picker-consumed Ctrl+C resets an armed exit gesture", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  const { session } = await createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })
  let exits = 0
  const setup = await createInteractiveTest(session, { width: 40, height: 8 }, () => exits++)

  try {
    const input = setup.renderer.root.findDescendantById("prompt-input")
    if (!(input instanceof TextareaRenderable)) throw new Error("Prompt textarea not found")
    setup.mockInput.pressCtrlC()
    await setup.mockInput.typeText("/m")
    setup.mockInput.pressCtrlC()
    setup.mockInput.pressCtrlC()
    expect(exits).toBe(0)
    setup.mockInput.pressCtrlC()
    expect(exits).toBe(1)
  } finally {
    session.dispose()
    setup.destroy()
  }
})

test("interactive keybinding overrides drive clear and exit through semantic actions", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  const { session } = await createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })
  let exits = 0
  const setup = await createInteractiveTest(session, { width: 40, height: 8, kittyKeyboard: true }, () => exits++, {
    "app.clear": ["ctrl+x"],
    "app.exit": ["ctrl+q"],
    "tui.input.newLine": ["ctrl+j"]
  })

  try {
    const input = setup.renderer.root.findDescendantById("prompt-input")
    if (!(input instanceof TextareaRenderable)) throw new Error("Prompt textarea not found")
    input.setText("keep")
    setup.mockInput.pressCtrlC()
    expect(input.plainText).toBe("keep")
    setup.mockInput.pressKey("x", { ctrl: true })
    expect(input.plainText).toBe("")

    input.setText("line")
    input.gotoBufferEnd()
    setup.mockInput.pressEnter({ shift: true })
    expect(input.plainText).toBe("line")
    setup.mockInput.pressKey("j", { ctrl: true })
    expect(input.plainText).toBe("line\n")
    input.setText("")

    setup.mockInput.pressKey("d", { ctrl: true })
    expect(exits).toBe(0)
    setup.mockInput.pressKey("q", { ctrl: true })
    expect(exits).toBe(1)
  } finally {
    session.dispose()
    setup.destroy()
  }
})

test("provider failures paint after settlement without keyboard input", async () => {
  const models = createModels()
  const faux = fauxProvider()
  const providerStarted = deferred<void>()
  const releaseFailure = deferred<void>()
  faux.setResponses([
    async () => {
      providerStarted.resolve()
      await releaseFailure.promise
      throw new Error("provider failed")
    }
  ])
  models.setProvider(faux.provider)
  const { session } = await createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })
  const setup = await createInteractiveTest(session, { width: 40, height: 8 })

  try {
    const input = setup.renderer.root.findDescendantById("prompt-input")
    if (!(input instanceof TextareaRenderable)) throw new Error("Prompt textarea not found")
    input.setText("fail")
    setup.mockInput.pressEnter()
    await providerStarted.promise
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("Working…")

    releaseFailure.resolve()
    await session.waitForIdle()
    await setup.renderer.idle()

    const frame = setup.captureCharFrame()
    expect(frame).toContain("provider failed")
    expect(frame).not.toContain("Working…")
    expect(input.focused).toBe(true)
  } finally {
    session.dispose()
    setup.destroy()
  }
})

test("an expired Ctrl+C arm starts a new exit window", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  const { session } = await createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })
  let exits = 0
  const setup = await createInteractiveTest(session, { width: 40, height: 8 }, () => exits++)
  const now = spyOn(Date, "now").mockReturnValue(1_000)

  try {
    setup.mockInput.pressCtrlC()
    now.mockReturnValue(1_500)
    setup.mockInput.pressCtrlC()
    expect(exits).toBe(0)
    now.mockReturnValue(1_501)
    setup.mockInput.pressCtrlC()
    expect(exits).toBe(1)
  } finally {
    now.mockRestore()
    session.dispose()
    setup.destroy()
  }
})

function deferred<T>() {
  let resolve!: (value: T | PromiseLike<T>) => void
  const promise = new Promise<T>(resolvePromise => {
    resolve = resolvePromise
  })
  return { promise, resolve }
}
