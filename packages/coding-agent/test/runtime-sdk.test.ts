import { expect, test } from "bun:test"
import { existsSync } from "node:fs"
import { mkdtemp } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import {
  createAgentSession,
  createSessionResources,
  FileCredentialStore,
  ModelRegistry,
  ZiPaths,
  ResourceLoader,
  SessionManager,
  SettingsManager,
  type AgentRuntime,
  type AgentSession,
  type AgentSessionServices
} from "../src/index.js"
import { createModels, createTestAgentRuntime, fauxAssistantMessage, fauxProvider } from "../src/testing.js"

test("the high-level runtime is a frozen caller-owned SDK shell", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  faux.setResponses([fauxAssistantMessage("ready")])

  const runtime: AgentRuntime = await createTestAgentRuntime({ cwd: "/work", models, persist: false })
  const eventTypes: string[] = []
  const unsubscribe = runtime.session.subscribe(event => eventTypes.push(event.type))

  try {
    expect(Object.isFrozen(runtime)).toBe(true)
    expect(Object.isFrozen(runtime.services)).toBe(true)
    await runtime.session.prompt("start")
    await runtime.session.waitForIdle()
    await runtime.session.abort()
    expect(runtime.session.messages.at(-1)).toMatchObject({ role: "assistant" })
    expect(eventTypes).toContain("agent_settled")
  } finally {
    unsubscribe()
    runtime.session.dispose()
  }

  expect(() => runtime.session.prompt("disposed")).toThrow("AgentSession is disposed")
})

test("session memory diagnostics account for owned messages, queues, and subscribers", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  faux.setResponses([fauxAssistantMessage("measured response")])
  const { session } = await createTestAgentRuntime({ cwd: "/work", models, persist: false })

  try {
    expect(session.memoryDiagnostics).toEqual({
      committedMessages: 0,
      committedMessageBytes: 0,
      streamingMessageBytes: 0,
      queuedInputs: 0,
      queuedInputBytes: 0,
      subscribers: 0
    })

    const unsubscribe = session.subscribe(() => {})
    session.followUp("queued input")
    expect(session.memoryDiagnostics).toMatchObject({
      queuedInputs: 1,
      queuedInputBytes: Buffer.byteLength("queued input"),
      subscribers: 1
    })
    session.takeQueuedInputs()
    unsubscribe()

    await session.prompt("measure this")
    const expectedBytes = session.messages.reduce(
      (bytes, message) => bytes + Buffer.byteLength(JSON.stringify(message)),
      0
    )
    expect(session.memoryDiagnostics).toEqual({
      committedMessages: 2,
      committedMessageBytes: expectedBytes,
      streamingMessageBytes: 0,
      queuedInputs: 0,
      queuedInputBytes: 0,
      subscribers: 0
    })
  } finally {
    session.dispose()
  }
})

test("a consumer can return without disposing its caller-owned session", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  faux.setResponses([fauxAssistantMessage("first"), fauxAssistantMessage("second")])
  const runtime = await createTestAgentRuntime({ cwd: "/work", models, persist: false })

  try {
    await runOneTurn(runtime.session, "one")
    await runtime.session.prompt("two")
    expect(faux.state.callCount).toBe(2)
    expect(runtime.session.messages.at(-1)).toMatchObject({ role: "assistant", stopReason: "stop" })
  } finally {
    runtime.session.dispose()
  }
})

test("caller-supplied services keep a low-level session in memory", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-sdk-memory-"))
  const cwd = join(root, "project")
  const globalDir = join(root, "unused-global")
  const paths = new ZiPaths(cwd, globalDir)
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  faux.setResponses([fauxAssistantMessage("memory only")])
  const services: AgentSessionServices = Object.freeze({
    paths,
    settingsManager: new SettingsManager(),
    credentialStore: new FileCredentialStore(paths),
    modelRegistry: new ModelRegistry(models),
    resourceLoader: new ResourceLoader({ paths })
  })
  const { session } = await createAgentSession({
    services,
    sessionManager: SessionManager.inMemory(cwd),
    model: faux.getModel(),
    tools: [],
    resources: createSessionResources()
  })

  try {
    await session.prompt("start")
    session.setSteeringMode("all", "global")
    expect(session.sessionManager.file).toBeUndefined()
    expect(session.settingsManager.get().steeringMode).toBe("all")
    expect(existsSync(globalDir)).toBe(false)
  } finally {
    session.dispose()
  }
})

test("two runtimes isolate paths, settings, credentials, models, sessions, and cancellation", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-sdk-isolation-"))
  const firstModels = createModels()
  const firstProvider = fauxProvider({ provider: "first", models: [{ id: "model" }] })
  firstModels.setProvider(firstProvider.provider)
  const firstStarted = deferred<void>()
  firstProvider.setResponses([
    async (_context, options) => {
      firstStarted.resolve()
      await new Promise<void>(resolve => options?.signal?.addEventListener("abort", () => resolve(), { once: true }))
      return fauxAssistantMessage("aborted", { stopReason: "aborted" })
    }
  ])

  const secondModels = createModels()
  const secondProvider = fauxProvider({ provider: "second", models: [{ id: "model" }] })
  secondModels.setProvider(secondProvider.provider)
  secondProvider.setResponses([fauxAssistantMessage("second complete")])

  const first = await createTestAgentRuntime({
    cwd: join(root, "first-project"),
    agentDir: join(root, "first-global"),
    models: firstModels,
    persist: false,
    settings: { steeringMode: "all" }
  })
  const second = await createTestAgentRuntime({
    cwd: join(root, "second-project"),
    agentDir: join(root, "second-global"),
    models: secondModels,
    persist: false
  })

  try {
    await first.services.credentialStore.modify("first", async () => ({ type: "api_key", key: "first-key" }))
    const firstRun = first.session.prompt("wait")
    await firstStarted.promise
    await second.session.prompt("continue")
    await first.session.abort()
    await firstRun

    expect(first.services.paths.cwd).not.toBe(second.services.paths.cwd)
    expect(first.session.sessionId).not.toBe(second.session.sessionId)
    expect(first.session.model.provider).toBe("first")
    expect(second.session.model.provider).toBe("second")
    expect(first.session.steeringMode).toBe("all")
    expect(second.session.steeringMode).toBe("one-at-a-time")
    expect(await second.services.credentialStore.read("first")).toBeUndefined()
    expect(second.session.messages.at(-1)).toMatchObject({ role: "assistant", stopReason: "stop" })
  } finally {
    first.session.dispose()
    second.session.dispose()
  }
})

async function runOneTurn(session: AgentSession, prompt: string): Promise<void> {
  const unsubscribe = session.subscribe(() => {})
  try {
    await session.prompt(prompt)
  } finally {
    unsubscribe()
  }
}

function deferred<T>() {
  let resolve!: (value: T | PromiseLike<T>) => void
  const promise = new Promise<T>(resolvePromise => {
    resolve = resolvePromise
  })
  return { promise, resolve }
}
