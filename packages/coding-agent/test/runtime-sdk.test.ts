import { expect, test } from "bun:test"
import { existsSync } from "node:fs"
import { mkdir, mkdtemp, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import {
  createAgentSession,
  createSessionResources,
  FileCredentialStore,
  maxResourceFileBytes,
  ModelRegistry,
  ZiPaths,
  ResourceLoader,
  SessionManager,
  SettingsManager,
  type AgentRuntime,
  type AgentSession,
  type AgentSessionServices,
  type SessionResources
} from "../src/index.js"
import { createModels, createTestAgentRuntime, fauxAssistantMessage, fauxProvider } from "../src/testing.js"
import { snapshotToolSurface } from "../src/tool-surface.js"

test("the high-level runtime is a frozen caller-owned SDK shell", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  faux.setResponses([fauxAssistantMessage("ready")])

  const runtime: AgentRuntime = await createTestAgentRuntime({
    cwd: "/work",
    models,
    session: { type: "new", persist: false }
  })
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

test("runtime session intents validate external resume input", async () => {
  const models = createModels()

  expect(createTestAgentRuntime({ cwd: "/work", models, session: { type: "resume", file: " " } })).rejects.toThrow(
    "Resumed runtime session requires a file"
  )
  expect(() => snapshotToolSurface("invalid")).toThrow("Unknown tool surface: invalid")
})

test("runtime invocation prompts override discovered system prompt inputs", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-runtime-prompts-"))
  const cwd = join(root, "project")
  await mkdir(join(cwd, ".zi"), { recursive: true })
  await writeFile(join(cwd, ".zi", "APPEND_SYSTEM.md"), "Discovered addition")
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  let systemPrompt = ""
  faux.setResponses([
    context => {
      systemPrompt = context.systemPrompt ?? ""
      return fauxAssistantMessage("ready")
    }
  ])
  const runtime = await createTestAgentRuntime({
    cwd,
    models,
    session: { type: "new", persist: false },
    systemPrompt: "Invocation system prompt",
    appendSystemPrompt: ["First addition", "Second addition"]
  })

  try {
    await runtime.session.prompt("start")
    expect(systemPrompt).toStartWith("Invocation system prompt")
    expect(systemPrompt).toContain("First addition\n\nSecond addition")
    expect(systemPrompt).not.toContain("Discovered addition")
  } finally {
    runtime.session.dispose()
  }
})

test("runtime invocation prompts retain resource bounds", async () => {
  const models = createModels()
  const runtime = await createTestAgentRuntime({
    cwd: "/work",
    models,
    session: { type: "new", persist: false },
    systemPrompt: "x".repeat(maxResourceFileBytes + 1)
  })

  try {
    expect(runtime.session.resources.systemPrompt).toBeUndefined()
    expect(runtime.session.resourceDiagnostics).toContainEqual({
      type: "limit",
      resource: "system-prompt",
      limit: maxResourceFileBytes,
      path: "<runtime>",
      message: `Inline resource cannot exceed ${maxResourceFileBytes} bytes`
    })
  } finally {
    runtime.session.dispose()
  }
})

test("session memory diagnostics account for owned messages, queues, and subscribers", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  faux.setResponses([fauxAssistantMessage("measured response")])
  const { session } = await createTestAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })

  try {
    expect(session.memoryDiagnostics).toEqual({
      committedMessages: 0,
      committedMessageBytes: 0,
      streamingMessageBytes: 0,
      queuedInputs: 0,
      queuedInputBytes: 0,
      subscribers: 0,
      journal: session.sessionManager.memoryDiagnostics
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
      subscribers: 0,
      journal: session.sessionManager.memoryDiagnostics
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
  const runtime = await createTestAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })

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
    resourceLoader: new ResourceLoader({ paths, project: "trusted" })
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

test("a disposed session rejects stale resource reload completion", async () => {
  const cwd = "/work"
  const paths = new ZiPaths(cwd, "/unused-global")
  const models = createModels()
  const loaded = deferred<SessionResources>()
  const resourceLoader = new (class extends ResourceLoader {
    override load(): Promise<SessionResources> {
      return loaded.promise
    }
  })({ paths, project: "trusted" })
  const services: AgentSessionServices = Object.freeze({
    paths,
    settingsManager: new SettingsManager(),
    credentialStore: new FileCredentialStore(paths),
    modelRegistry: new ModelRegistry(models),
    resourceLoader
  })
  const initial = createSessionResources({ appendSystemPrompt: ["Initial policy"] })
  const replacement = createSessionResources({ appendSystemPrompt: ["Stale policy"] })
  const { session } = await createAgentSession({
    services,
    sessionManager: SessionManager.inMemory(cwd),
    tools: [],
    resources: initial
  })

  const reload = session.reload()
  session.dispose()
  loaded.resolve(replacement)

  expect((await reload).resources).toBe(replacement)
  expect(session.resources.appendSystemPrompt).toEqual(["Initial policy"])
  expect(session.resources).not.toBe(replacement)
  await session.waitForIdle()
})

test("low-level code-only sessions require a Code Mode owner", async () => {
  const cwd = "/work"
  const paths = new ZiPaths(cwd, "/unused-global")
  const models = createModels()
  const services: AgentSessionServices = Object.freeze({
    paths,
    settingsManager: new SettingsManager(),
    credentialStore: new FileCredentialStore(paths),
    modelRegistry: new ModelRegistry(models),
    resourceLoader: new ResourceLoader({ paths, project: "trusted" })
  })

  expect(
    createAgentSession({
      services,
      sessionManager: SessionManager.inMemory(cwd),
      tools: [],
      resources: createSessionResources(),
      toolSurface: "code-only"
    })
  ).rejects.toThrow("Tool surface selection requires Code Mode")
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
    session: { type: "new", persist: false },
    settings: { steeringMode: "all" }
  })
  const second = await createTestAgentRuntime({
    cwd: join(root, "second-project"),
    agentDir: join(root, "second-global"),
    models: secondModels,
    session: { type: "new", persist: false }
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
