import { expect, mock, test } from "bun:test"

import { type CliRendererConfig, TextareaRenderable } from "@opentui/core"
import { createTestRenderer } from "@opentui/core/testing"
import {
  createModels,
  createTestAgentRuntime as createAgentRuntime,
  fauxAssistantMessage,
  fauxProvider
} from "@openzi/coding-agent/testing"

test("initial CLI prompts run after interactive terminal ownership is established", async () => {
  const setup = await createTestRenderer({ width: 40, height: 8, useThread: false })
  const core = await import("@opentui/core")
  await mock.module("@opentui/core", () => ({ ...core, createCliRenderer: async () => setup.renderer }))

  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  faux.setResponses([fauxAssistantMessage("done")])
  const { session } = await createAgentRuntime({ cwd: "/work", models, persist: false })

  try {
    const { runTui } = await import("../../src/interactive/run.js")
    const running = runTui({ session, initialMessages: ["start"] })
    await waitUntil(() => faux.state.callCount === 1)
    await session.waitForIdle()
    expect(session.messages.filter(message => message.role === "user")).toHaveLength(1)
    setup.mockInput.pressKey("d", { ctrl: true })
    await running
  } finally {
    session.dispose()
    if (!setup.renderer.isDestroyed) setup.renderer.destroy()
    mock.restore()
  }
})

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

test("interactive shutdown restores the terminal before joining authentication cancellation", async () => {
  const setup = await createTestRenderer({ width: 40, height: 8, useThread: false })
  const core = await import("@opentui/core")
  await mock.module("@opentui/core", () => ({ ...core, createCliRenderer: async () => setup.renderer }))

  const models = createModels()
  const faux = fauxProvider({ provider: "shutdown-auth", models: [{ id: "model" }] })
  const started = deferred<void>()
  const release = deferred<void>()
  models.setProvider({
    ...faux.provider,
    auth: {
      apiKey: {
        name: "Shutdown key",
        async login() {
          started.resolve()
          await release.promise
          return { type: "api_key" as const, key: "must-not-persist" }
        },
        resolve: async () => ({ auth: { apiKey: "ambient" } })
      }
    }
  })
  const runtime = await createAgentRuntime({ cwd: "/work", models, persist: false })
  const loginFailure = rejection(
    runtime.session.login("shutdown-auth", "api_key", { prompt: async () => "", notify() {} })
  )
  await started.promise

  try {
    const { runTui } = await import("../../src/interactive/run.js")
    const running = runTui({ session: runtime.session })
    await setup.renderOnce()
    setup.mockInput.pressKey("d", { ctrl: true })

    expect(setup.renderer.isDestroyed).toBe(true)
    release.resolve()
    expect((await loginFailure).message).toContain("cancelled")
    await running
    expect(await runtime.services.credentialStore.read("shutdown-auth")).toBeUndefined()
  } finally {
    runtime.session.dispose()
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

test("development diagnostics are admitted from runtime flags", async () => {
  const previousTtfd = process.env.OPENZI_SHOW_TTFD
  const previousStats = process.env.OPENZI_TUI_STATS
  const previousMemory = process.env.OPENZI_TUI_MEMORY
  process.env.OPENZI_SHOW_TTFD = "1"
  process.env.OPENZI_TUI_STATS = "1"
  process.env.OPENZI_TUI_MEMORY = "1"

  const setup = await createTestRenderer({ width: 52, height: 10, useThread: false })
  const core = await import("@opentui/core")
  let config: CliRendererConfig | undefined
  await mock.module("@opentui/core", () => ({
    ...core,
    createCliRenderer: async (options?: CliRendererConfig) => {
      config = options
      setup.renderer.setGatherStats(options?.gatherStats ?? false)
      return setup.renderer
    }
  }))

  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  const { session } = await createAgentRuntime({ cwd: "/work", models, persist: false })

  try {
    const { runTui } = await import("../../src/interactive/run.js")
    const running = runTui({ session })
    await setup.renderOnce()

    expect(config).toMatchObject({ gatherStats: true, maxStatSamples: 300 })
    expect(setup.renderer.debugOverlay.enabled).toBe(true)
    expect(setup.renderer.root.findDescendantById("tui-time-to-first-draw")).toBeDefined()
    expect(setup.renderer.root.findDescendantById("tui-performance-stats")).toBeDefined()
    expect(setup.renderer.root.findDescendantById("tui-memory-stats")).toBeDefined()

    setup.mockInput.pressKey("d", { ctrl: true })
    await running
  } finally {
    if (previousTtfd === undefined) delete process.env.OPENZI_SHOW_TTFD
    else process.env.OPENZI_SHOW_TTFD = previousTtfd
    if (previousStats === undefined) delete process.env.OPENZI_TUI_STATS
    else process.env.OPENZI_TUI_STATS = previousStats
    if (previousMemory === undefined) delete process.env.OPENZI_TUI_MEMORY
    else process.env.OPENZI_TUI_MEMORY = previousMemory
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

async function waitUntil(predicate: () => boolean): Promise<void> {
  for (let attempt = 0; attempt < 20; attempt++) {
    if (predicate()) return
    // oxlint-disable-next-line no-await-in-loop
    await Promise.resolve()
  }
  throw new Error("Condition was not met")
}

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
