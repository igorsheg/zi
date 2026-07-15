import { expect, mock, test } from "bun:test"

import { TextareaRenderable } from "@opentui/core"
import { createTestRenderer } from "@opentui/core/testing"
import { createAgentRuntime } from "@openzi/coding-agent"
import { createModels, fauxAssistantMessage, fauxProvider } from "@openzi/coding-agent/testing"

test("interactive exit restores the terminal before settlement and discards queued work", async () => {
  const priorSighupListeners = new Set(process.listeners("SIGHUP"))
  const setup = await createTestRenderer({ width: 40, height: 8, useThread: false })
  const core = await import("@opentui/core")
  await mock.module("@opentui/core", () => ({ ...core, createCliRenderer: async () => setup.renderer }))

  const models = createModels()
  const faux = fauxProvider()
  const providerStarted = deferred<void>()
  const release = deferred<void>()
  faux.setResponses([
    async () => {
      providerStarted.resolve()
      await release.promise
      return fauxAssistantMessage("aborted", { stopReason: "aborted" })
    },
    fauxAssistantMessage("must not continue")
  ])
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
    const input = setup.renderer.root.findDescendantById("prompt-input")
    if (!(input instanceof TextareaRenderable)) throw new Error("Prompt textarea not found")
    input.setText("start")
    setup.mockInput.pressEnter()
    await providerStarted.promise
    session.followUp("discard me")

    setup.mockInput.pressCtrlC()
    expect(setup.renderer.isDestroyed).toBe(false)
    expect(session.isStreaming).toBe(true)
    expect(session.queuedInputs.followUp).toHaveLength(1)
    setup.mockInput.pressCtrlC()

    expect(setup.renderer.isDestroyed).toBe(true)
    expect(session.queuedInputs.followUp).toHaveLength(0)
    expect(disposals).toBe(0)
    process.emit("SIGHUP")
    release.resolve()
    await running
    expect(faux.state.callCount).toBe(1)
    expect(titles).toEqual(["openzi", ""])
    expect(process.listeners("SIGHUP").filter(listener => !priorSighupListeners.has(listener))).toHaveLength(0)
  } finally {
    session.dispose()
    if (!setup.renderer.isDestroyed) setup.renderer.destroy()
    mock.restore()
  }
})

test("external renderer destruction joins normal terminal cleanup", async () => {
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

    expect(titles).toEqual(["openzi", ""])
    expect(disposals).toBe(0)
  } finally {
    session.dispose()
    if (!setup.renderer.isDestroyed) setup.renderer.destroy()
    mock.restore()
  }
})

test("shutdown failure surfaces only after terminal resources are restored", async () => {
  const setup = await createTestRenderer({ width: 40, height: 8, useThread: false })
  const core = await import("@opentui/core")
  await mock.module("@opentui/core", () => ({ ...core, createCliRenderer: async () => setup.renderer }))

  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  const { session } = await createAgentRuntime({ cwd: "/work", models, persist: false })
  session.abortAndDiscardQueuedInputs = () => Promise.reject(new Error("shutdown failed"))
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
    setup.mockInput.pressKey("d", { ctrl: true })

    expect(setup.renderer.isDestroyed).toBe(true)
    expect(titles).toEqual(["openzi", ""])
    expect((await rejection(running)).message).toContain("shutdown failed")
  } finally {
    session.dispose()
    if (!setup.renderer.isDestroyed) setup.renderer.destroy()
    mock.restore()
  }
})

async function rejection(promise: Promise<unknown>): Promise<Error> {
  try {
    await promise
  } catch (cause) {
    if (cause instanceof Error) return cause
    throw new Error(`Promise rejected with a non-Error value: ${String(cause)}`, { cause })
  }
  throw new Error("Expected promise to reject")
}

function deferred<T>() {
  let resolve!: (value: T | PromiseLike<T>) => void
  const promise = new Promise<T>(resolvePromise => {
    resolve = resolvePromise
  })
  return { promise, resolve }
}
