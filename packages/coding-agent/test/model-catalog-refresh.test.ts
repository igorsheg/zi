import { expect, jest, test } from "bun:test"
import { mkdir, mkdtemp, truncate, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { createProvider, type Model, type Provider } from "@earendil-works/pi-ai"

import { maxModelCatalogRefreshMs } from "../src/agent-session.js"
import { maxModelsStoreBytes } from "../src/model-catalog-store.js"
import { createAgentRuntime as createProductionAgentRuntime } from "../src/runtime.js"
import { createModels, createTestAgentRuntime as createAgentRuntime } from "../src/testing.js"

test("production runtime restores configured cached catalogs before resolving the selected model", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-model-catalog-runtime-"))
  const agentDir = join(root, "agent")
  await mkdir(agentDir, { recursive: true })
  await writeFile(join(agentDir, "auth.json"), JSON.stringify({ openrouter: { type: "api_key", key: "test" } }))
  await writeFile(
    join(agentDir, "models-store.json"),
    JSON.stringify({
      openrouter: {
        models: [{ ...model("remote-only"), provider: "openrouter" }],
        checkedAt: Date.now(),
        lastModified: Date.now() + 24 * 60 * 60 * 1000
      }
    })
  )

  const runtime = await createProductionAgentRuntime({
    cwd: root,
    agentDir,
    model: "openrouter/remote-only",
    session: { type: "new", persist: false }
  })
  try {
    expect(runtime.session.model.id).toBe("remote-only")
    expect(runtime.session.model.provider).toBe("openrouter")
  } finally {
    runtime.session.dispose()
    await runtime.session.waitForIdle()
  }
})

test("an oversized optional catalog cannot prevent startup with packaged models", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-model-catalog-oversized-"))
  const agentDir = join(root, "agent")
  await mkdir(agentDir, { recursive: true })
  await writeFile(join(agentDir, "auth.json"), JSON.stringify({ openrouter: { type: "api_key", key: "test" } }))
  await writeFile(join(agentDir, "models-store.json"), "")
  await truncate(join(agentDir, "models-store.json"), maxModelsStoreBytes + 1)

  const runtime = await createProductionAgentRuntime({
    cwd: root,
    agentDir,
    model: "openrouter/ai21/jamba-large-1.7",
    session: { type: "new", persist: false }
  })
  try {
    expect(runtime.session.model.id).toBe("ai21/jamba-large-1.7")
  } finally {
    runtime.session.dispose()
    await runtime.session.waitForIdle()
  }
})

test("custom model factories remain caller-owned and are not refreshed during startup", async () => {
  let refreshes = 0
  const models = createModels()
  models.setProvider(
    refreshingProvider(
      () => [model("static")],
      async () => {
        refreshes++
      }
    )
  )
  const runtime = await createProductionAgentRuntime({
    cwd: "/work",
    model: "refresh/static",
    modelFactory: () => models,
    session: { type: "new", persist: false }
  })
  try {
    expect(refreshes).toBe(0)
    expect(runtime.services.modelRegistry.list()).toEqual(models.getModels())
  } finally {
    runtime.session.dispose()
    await runtime.session.waitForIdle()
  }
})

test("model choice refresh is session-owned single-flight and publishes refreshed choices", async () => {
  const update = deferred<void>()
  const started = deferred<void>()
  let refreshes = 0
  let catalog = [model("static")]
  const provider = refreshingProvider(
    () => catalog,
    async context => {
      refreshes++
      started.resolve()
      await update.promise
      if (!context.signal?.aborted) catalog = [model("static"), model("dynamic")]
    }
  )
  const models = createModels()
  models.setProvider(provider)
  const { session } = await createAgentRuntime({
    cwd: "/work",
    model: "refresh/static",
    models,
    session: { type: "new", persist: false }
  })

  try {
    const first = session.refreshModelChoices()
    const overlapping = session.refreshModelChoices()
    expect(overlapping).toBe(first)
    await started.promise
    update.resolve()

    const result = await first
    expect(result.type).toBe("complete")
    if (result.type !== "complete") throw new Error("Expected completed refresh")
    expect(result.choices.map(choice => choice.model.id)).toEqual(["static", "dynamic"])
    expect(result.choices.every(choice => choice.configured)).toBe(true)
    expect(result.failedProviders).toEqual([])
    expect(refreshes).toBe(1)
  } finally {
    session.dispose()
    await session.waitForIdle()
  }
})

test("model choice refresh times out, aborts its provider signal, and admits a later refresh", async () => {
  jest.useFakeTimers()
  const started = deferred<void>()
  const release = deferred<void>()
  let refreshes = 0
  let providerSignal: AbortSignal | undefined
  const provider = refreshingProvider(
    () => [model("static")],
    async context => {
      refreshes++
      providerSignal = context.signal
      if (refreshes === 1) {
        started.resolve()
        await release.promise
      }
    }
  )
  const models = createModels()
  models.setProvider(provider)
  const { session } = await createAgentRuntime({
    cwd: "/work",
    model: "refresh/static",
    models,
    session: { type: "new", persist: false }
  })

  try {
    const refresh = session.refreshModelChoices()
    await started.promise
    jest.advanceTimersByTime(maxModelCatalogRefreshMs)
    expect(await refresh).toEqual({ type: "aborted", reason: "timeout" })
    expect(providerSignal?.aborted).toBe(true)

    release.resolve()
    await settle()
    const next = await session.refreshModelChoices()
    expect(next.type).toBe("complete")
    expect(refreshes).toBe(2)
  } finally {
    release.resolve()
    jest.useRealTimers()
    session.dispose()
    await session.waitForIdle()
  }
})

test("model choice refresh cancellation settles promptly and session disposal owns cancellation", async () => {
  const started = deferred<void>()
  const secondStarted = deferred<void>()
  const releaseCancelled = deferred<void>()
  let refreshes = 0
  const provider = refreshingProvider(
    () => [model("static")],
    async context => {
      refreshes++
      if (refreshes === 1) {
        started.resolve()
        await releaseCancelled.promise
        return
      }
      secondStarted.resolve()
      await new Promise<void>(resolve => context.signal?.addEventListener("abort", () => resolve(), { once: true }))
    }
  )
  const models = createModels()
  models.setProvider(provider)
  const { session } = await createAgentRuntime({
    cwd: "/work",
    model: "refresh/static",
    models,
    session: { type: "new", persist: false }
  })

  const controller = new AbortController()
  const refresh = session.refreshModelChoices(controller.signal)
  await started.promise
  controller.abort()
  expect(await refresh).toEqual({ type: "aborted", reason: "cancelled" })

  const disposingRefresh = session.refreshModelChoices()
  await secondStarted.promise
  expect(refreshes).toBe(2)
  session.dispose()
  releaseCancelled.resolve()
  expect(await disposingRefresh).toEqual({ type: "aborted", reason: "cancelled" })
  await session.waitForIdle()
})

test("model choice refresh reports provider failures while retaining static choices", async () => {
  const provider = refreshingProvider(
    () => [model("static")],
    async () => {
      throw new Error("catalog unavailable")
    }
  )
  const models = createModels()
  models.setProvider(provider)
  const { session } = await createAgentRuntime({
    cwd: "/work",
    model: "refresh/static",
    models,
    session: { type: "new", persist: false }
  })

  try {
    const result = await session.refreshModelChoices()
    expect(result.type).toBe("complete")
    if (result.type !== "complete") throw new Error("Expected completed refresh")
    expect(result.failedProviders).toEqual(["refresh"])
    expect(result.choices.map(choice => choice.model.id)).toEqual(["static"])
  } finally {
    session.dispose()
    await session.waitForIdle()
  }
})

function refreshingProvider(
  getModels: () => readonly Model<"openai-completions">[],
  refreshModels: NonNullable<Provider["refreshModels"]>
): Provider {
  const base = createProvider({
    id: "refresh",
    auth: { apiKey: { name: "Test", resolve: async () => ({ auth: { apiKey: "test" } }) } },
    models: getModels(),
    api: {
      stream: () => {
        throw new Error("not used")
      },
      streamSimple: () => {
        throw new Error("not used")
      }
    }
  })
  return { ...base, getModels, refreshModels }
}

function model(id: string): Model<"openai-completions"> {
  return {
    id,
    name: id,
    api: "openai-completions",
    provider: "refresh",
    baseUrl: "https://example.test/v1",
    reasoning: false,
    input: ["text"],
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    contextWindow: 1000,
    maxTokens: 100
  }
}

async function settle(): Promise<void> {
  await Promise.resolve()
  await Promise.resolve()
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
