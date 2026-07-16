import { expect, test } from "bun:test"
import { mkdir, mkdtemp, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { getSupportedThinkingLevels, type AuthResult } from "@earendil-works/pi-ai"

import {
  createModels,
  createTestAgentRuntime as createAgentRuntime,
  fauxAssistantMessage,
  fauxProvider
} from "../src/testing.js"

test("model choices preserve registry identity and resolve provider configuration once per bounded catalog", async () => {
  const models = createModels()
  const first = fauxProvider({
    provider: "first",
    models: [
      { id: "a", name: "A", reasoning: true },
      { id: "b", name: "B", reasoning: true }
    ]
  })
  const second = fauxProvider({ provider: "second", models: [{ id: "c", name: "C", reasoning: false }] })
  models.setProvider(first.provider)
  models.setProvider(second.provider)
  const { session } = await createAgentRuntime({ cwd: "/work", model: "first/a", models, persist: false })

  try {
    const auth = new Map([
      ["first", undefined],
      ["second", configuredAuth()]
    ])
    const calls: string[] = []
    models.getAuth = async model => {
      calls.push(model.provider)
      return auth.get(model.provider)
    }

    const firstLoad = session.listModelChoices()
    const overlappingLoad = session.listModelChoices()
    expect(overlappingLoad).toBe(firstLoad)
    const choices = await firstLoad

    expect(calls).toEqual(["first", "second"])
    expect(choices.map(choice => choice.model)).toEqual(first.models.concat(second.models))
    expect(choices.map(choice => choice.model === models.getModel(choice.model.provider, choice.model.id))).toEqual([
      true,
      true,
      true
    ])
    expect(choices.map(choice => choice.configured)).toEqual([false, false, true])
    expect(Object.isFrozen(choices)).toBe(true)
    expect(choices.every(Object.isFrozen)).toBe(true)

    calls.length = 0
    auth.set("first", configuredAuth())
    expect((await session.listModelChoices()).map(choice => choice.configured)).toEqual([true, true, true])
    expect(calls).toEqual(["first", "second"])
  } finally {
    session.dispose()
  }
})

test("model and thinking selections persist a coherent canonical transition", async () => {
  const root = await mkdtemp(join(tmpdir(), "openzi-thinking-selection-"))
  const cwd = join(root, "project")
  await mkdir(cwd, { recursive: true })
  const models = createModels()
  const faux = fauxProvider({
    provider: "select",
    models: [
      { id: "reasoning", name: "Reasoning", reasoning: true },
      { id: "plain", name: "Plain", reasoning: false }
    ]
  })
  models.setProvider(faux.provider)
  const reasoning = faux.getModel("reasoning")
  const plain = faux.getModel("plain")
  if (!reasoning || !plain) throw new Error("Selection models not found")
  const { session } = await createAgentRuntime({
    cwd,
    model: "select/reasoning",
    models,
    persist: false,
    settings: { thinkingLevel: "high" }
  })
  models.getAuth = async () => configuredAuth()

  try {
    const events: string[] = []
    const observed: string[] = []
    session.subscribe(event => {
      if (event.type !== "model_changed" && event.type !== "thinking_level_changed") return
      events.push(event.type)
      observed.push(`${session.model.id}/${session.thinkingLevel}`)
    })
    const entryStart = session.sessionManager.entries().length

    await session.setModel(plain)

    expect(session.model).toBe(plain)
    expect(session.thinkingLevel).toBe("off")
    expect(session.settingsManager.get()).toMatchObject({ model: "select/plain", thinkingLevel: "off" })
    expect(
      session.sessionManager
        .entries()
        .slice(entryStart)
        .map(entry => entry.type)
    ).toEqual(["model_change", "thinking_level_change"])
    expect(events).toEqual(["thinking_level_changed", "model_changed"])
    expect(observed).toEqual(["plain/off", "plain/off"])
    expect(session.getSupportedThinkingLevels()).toEqual(["off"])
    const unsupportedThinkingEntryStart = session.sessionManager.entries().length
    session.setThinkingLevel("high")
    expect(session.thinkingLevel).toBe("off")
    expect(session.sessionManager.entries()).toHaveLength(unsupportedThinkingEntryStart)

    const sameModelEntryStart = session.sessionManager.entries().length
    events.length = 0
    await session.setModel(plain)
    expect(
      session.sessionManager
        .entries()
        .slice(sameModelEntryStart)
        .map(entry => entry.type)
    ).toEqual(["model_change"])
    expect(events).toEqual(["model_changed"])

    reasoning.thinkingLevelMap = { minimal: null, xhigh: "xhigh", max: "max" }
    await session.setModel(reasoning)
    expect(session.getSupportedThinkingLevels()).toEqual(getSupportedThinkingLevels(reasoning))
    expect(session.getSupportedThinkingLevels()).toEqual(["off", "low", "medium", "high", "xhigh", "max"])

    const thinkingEntryStart = session.sessionManager.entries().length
    events.length = 0
    session.setThinkingLevel("xhigh")
    session.setThinkingLevel("xhigh")
    expect(session.thinkingLevel).toBe("xhigh")
    expect(session.settingsManager.get().thinkingLevel).toBe("xhigh")
    expect(
      session.sessionManager
        .entries()
        .slice(thinkingEntryStart)
        .map(entry => entry.type)
    ).toEqual(["thinking_level_change"])
    expect(events).toEqual(["thinking_level_changed"])

    expect(session.setThinkingLevel("low", "project")).toEqual({ scope: "project", requested: "low", effective: "low" })
    expect(session.thinkingLevel).toBe("low")
    expect(session.settingsManager.getProject().thinkingLevel).toBe("low")
  } finally {
    session.dispose()
  }
})

test("thinking mutations report an effective project override without false events", async () => {
  const root = await mkdtemp(join(tmpdir(), "openzi-thinking-shadow-"))
  const cwd = join(root, "project")
  const agentDir = join(root, "global")
  await mkdir(join(cwd, ".openzi"), { recursive: true })
  await mkdir(agentDir, { recursive: true })
  await writeFile(join(agentDir, "settings.json"), JSON.stringify({ thinkingLevel: "medium" }))
  await writeFile(join(cwd, ".openzi", "settings.json"), JSON.stringify({ thinkingLevel: "high" }))
  const models = createModels()
  const faux = fauxProvider({ provider: "thinking-shadow", models: [{ id: "model", reasoning: true }] })
  models.setProvider(faux.provider)
  const { session } = await createAgentRuntime({
    cwd,
    agentDir,
    model: "thinking-shadow/model",
    models,
    persist: false
  })
  const events: string[] = []
  session.subscribe(event => {
    if (event.type === "thinking_level_changed") events.push(event.type)
  })

  try {
    const entries = session.sessionManager.entries().length
    expect(session.setThinkingLevel("low", "global")).toEqual({ scope: "global", requested: "low", effective: "high" })
    expect(session.thinkingLevel).toBe("high")
    expect(session.settingsManager.get().thinkingLevel).toBe("high")
    expect(session.settingsManager.getGlobal().thinkingLevel).toBe("low")
    expect(session.sessionManager.entries()).toHaveLength(entries)
    expect(events).toEqual([])
  } finally {
    session.dispose()
  }
})

test("model selection rejects unconfigured and non-idle sessions before domain mutation", async () => {
  const models = createModels()
  const faux = fauxProvider({
    provider: "admission",
    models: [
      { id: "current", reasoning: true },
      { id: "target", reasoning: true }
    ]
  })
  models.setProvider(faux.provider)
  const current = faux.getModel("current")
  const target = faux.getModel("target")
  if (!current || !target) throw new Error("Admission models not found")
  const { session } = await createAgentRuntime({ cwd: "/work", model: "admission/current", models, persist: false })
  const modelEvents: string[] = []
  session.subscribe(event => {
    if (event.type === "model_changed" || event.type === "thinking_level_changed") modelEvents.push(event.type)
  })

  try {
    const entryStart = session.sessionManager.entries().length
    const settingsBefore = { ...session.settingsManager.get() }
    models.getAuth = async () => undefined
    expect((await rejection(session.setModel(target))).message).toContain("not authenticated")
    expect(session.model).toBe(current)
    expect(session.settingsManager.get()).toEqual(settingsBefore)
    expect(session.sessionManager.entries()).toHaveLength(entryStart)
    expect(modelEvents).toEqual([])

    const providerStarted = deferred<void>()
    const release = deferred<void>()
    faux.setResponses([
      async () => {
        providerStarted.resolve()
        await release.promise
        return fauxAssistantMessage("done")
      }
    ])
    const run = session.prompt("running")
    await providerStarted.promise
    models.getAuth = async () => configuredAuth()
    expect((await rejection(session.setModel(target))).message).toContain("while the agent is running")
    session.steer("pending")
    const aborted = session.takeQueuedInputsAndAbort()
    expect((await rejection(session.setModel(target))).message).toContain("while the agent is running")
    release.resolve()
    await aborted.settled
    await run

    const failedStarted = deferred<void>()
    const failedRelease = deferred<void>()
    faux.setResponses([
      async () => {
        failedStarted.resolve()
        await failedRelease.promise
        return fauxAssistantMessage("cannot persist")
      }
    ])
    const appendMessage = session.sessionManager.appendMessage.bind(session.sessionManager)
    let failPersistence = false
    session.sessionManager.appendMessage = message => {
      if (failPersistence) throw new Error("persistence failed")
      return appendMessage(message)
    }
    const failedRun = session.prompt("failed")
    await failedStarted.promise
    session.steer("recover")
    failPersistence = true
    failedRelease.resolve()
    await rejection(failedRun)
    expect((await rejection(session.setModel(target))).message).toContain("while the agent is running")
    session.sessionManager.appendMessage = appendMessage
    session.takeQueuedInputs()

    session.dispose()
    expect((await rejection(session.setModel(target))).message).toContain("disposed")
    expect(session.model).toBe(current)
    expect(modelEvents).toEqual([])
  } finally {
    session.dispose()
  }
})

test("model validation rejects prompt, disposal, and out-of-order completion races", async () => {
  const models = createModels()
  const currentProvider = fauxProvider({ provider: "race-current", models: [{ id: "current", reasoning: true }] })
  const firstProvider = fauxProvider({ provider: "race-first", models: [{ id: "first", reasoning: true }] })
  const latestProvider = fauxProvider({ provider: "race-latest", models: [{ id: "latest", reasoning: true }] })
  models.setProvider(currentProvider.provider)
  models.setProvider(firstProvider.provider)
  models.setProvider(latestProvider.provider)
  const first = firstProvider.getModel()
  const latest = latestProvider.getModel()
  const { session } = await createAgentRuntime({ cwd: "/work", model: "race-current/current", models, persist: false })

  try {
    const firstAuth = deferred<AuthResult | undefined>()
    const latestAuth = deferred<AuthResult | undefined>()
    models.getAuth = model => {
      if (model.provider === "race-first") return firstAuth.promise
      if (model.provider === "race-latest") return latestAuth.promise
      return Promise.resolve(configuredAuth())
    }
    const earlier = session.setModel(first)
    const later = session.setModel(latest)
    latestAuth.resolve(configuredAuth())
    await later
    firstAuth.resolve(configuredAuth())
    expect((await rejection(earlier)).message).toContain("superseded")
    expect(session.model).toBe(latest)

    const promptAuth = deferred<AuthResult | undefined>()
    models.getAuth = model => (model.provider === "race-first" ? promptAuth.promise : Promise.resolve(configuredAuth()))
    latestProvider.setResponses([fauxAssistantMessage("done")])
    const staleForPrompt = session.setModel(first)
    await session.prompt("invalidate model validation")
    promptAuth.resolve(configuredAuth())
    expect((await rejection(staleForPrompt)).message).toContain("superseded")
    expect(session.model).toBe(latest)

    const disposeAuth = deferred<AuthResult | undefined>()
    models.getAuth = model =>
      model.provider === "race-first" ? disposeAuth.promise : Promise.resolve(configuredAuth())
    const staleForDispose = session.setModel(first)
    session.dispose()
    disposeAuth.resolve(configuredAuth())
    expect((await rejection(staleForDispose)).message).toContain("superseded")
    expect(session.model).toBe(latest)
  } finally {
    session.dispose()
  }
})

test("model change publishes every committed event when a subscriber throws", async () => {
  const models = createModels()
  const faux = fauxProvider({
    provider: "events",
    models: [
      { id: "reasoning", reasoning: true },
      { id: "plain", reasoning: false }
    ]
  })
  models.setProvider(faux.provider)
  const plain = faux.getModel("plain")
  if (!plain) throw new Error("Plain model not found")
  const { session } = await createAgentRuntime({
    cwd: "/work",
    model: "events/reasoning",
    models,
    persist: false,
    settings: { thinkingLevel: "high" }
  })
  models.getAuth = async () => configuredAuth()

  try {
    const events: string[] = []
    session.subscribe(event => {
      if (event.type === "thinking_level_changed") throw new Error("listener failed")
    })
    session.subscribe(event => {
      if (event.type === "thinking_level_changed" || event.type === "model_changed") events.push(event.type)
    })

    await session.setModel(plain)
    expect(session.model).toBe(plain)
    expect(session.thinkingLevel).toBe("off")
    expect(events).toEqual(["thinking_level_changed", "model_changed"])
  } finally {
    session.dispose()
  }
})

test("catalog configuration work is bounded to four providers and propagates auth failures", async () => {
  const models = createModels()
  const providers = Array.from({ length: 6 }, (_, index) =>
    fauxProvider({ provider: `provider-${index}`, models: [{ id: `model-${index}`, reasoning: true }] })
  )
  for (const provider of providers) models.setProvider(provider.provider)
  const { session } = await createAgentRuntime({ cwd: "/work", model: "provider-0/model-0", models, persist: false })

  try {
    const release = deferred<void>()
    let active = 0
    let peak = 0
    let started = 0
    models.getAuth = async () => {
      active++
      started++
      peak = Math.max(peak, active)
      await release.promise
      active--
      return configuredAuth()
    }

    const load = session.listModelChoices()
    await waitFor(() => started === 4)
    expect(peak).toBe(4)
    expect(started).toBe(4)
    release.resolve()
    expect(await load).toHaveLength(6)
    expect(started).toBe(6)
    expect(peak).toBe(4)

    models.getAuth = async () => {
      throw new Error("credential store failed")
    }
    expect((await rejection(session.listModelChoices())).message).toContain("credential store failed")
  } finally {
    session.dispose()
  }
})

test("catalog, selection, and failure retries share one four-provider auth bound", async () => {
  const models = createModels()
  const providers = Array.from({ length: 6 }, (_, index) =>
    fauxProvider({ provider: `shared-${index}`, models: [{ id: `model-${index}`, reasoning: true }] })
  )
  for (const provider of providers) models.setProvider(provider.provider)
  const external = fauxProvider({ provider: "external", models: [{ id: "target", reasoning: true }] }).getModel()
  const { session } = await createAgentRuntime({ cwd: "/work", model: "shared-0/model-0", models, persist: false })

  try {
    const release = deferred<void>()
    let active = 0
    let peak = 0
    let started = 0
    models.getAuth = async () => {
      active++
      started++
      peak = Math.max(peak, active)
      await release.promise
      active--
      return configuredAuth()
    }

    const catalog = session.listModelChoices()
    await waitFor(() => started === 4)
    const selection = session.setModel(external)
    await Promise.resolve()
    expect(started).toBe(4)
    release.resolve()
    await Promise.all([catalog, selection])
    expect(peak).toBe(4)

    let failed = false
    active = 0
    peak = 0
    const retryRelease = deferred<void>()
    models.getAuth = async model => {
      active++
      peak = Math.max(peak, active)
      if (model.provider === "shared-0" && !failed) {
        failed = true
        active--
        throw new Error("first lookup failed")
      }
      await retryRelease.promise
      active--
      return configuredAuth()
    }

    expect((await rejection(session.listModelChoices())).message).toContain("first lookup failed")
    const retry = session.listModelChoices()
    await Promise.resolve()
    expect(peak).toBeLessThanOrEqual(4)
    retryRelease.resolve()
    await retry
    expect(peak).toBeLessThanOrEqual(4)
  } finally {
    session.dispose()
  }
})

function configuredAuth(): AuthResult {
  return { auth: { apiKey: "configured" }, source: "test" }
}

async function waitFor(predicate: () => boolean): Promise<void> {
  for (let attempt = 0; attempt < 20; attempt++) {
    if (predicate()) return
    // oxlint-disable-next-line no-await-in-loop
    await Promise.resolve()
  }
  throw new Error("Condition was not reached")
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
  let reject!: (reason?: unknown) => void
  const promise = new Promise<T>((resolvePromise, rejectPromise) => {
    resolve = resolvePromise
    reject = rejectPromise
  })
  return { promise, resolve, reject }
}
