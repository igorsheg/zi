import { expect, test } from "bun:test"

import {
  createProvider,
  InMemoryModelsStore,
  type Model,
  type Provider,
  type RefreshModelsContext
} from "@earendil-works/pi-ai"

import {
  maxRemoteCatalogBytes,
  remoteCatalogRefreshIntervalMs,
  withRemoteModelCatalog
} from "../src/remote-model-catalog.js"

const activeSignal = new AbortController().signal

test("remote model catalogs merge, persist, revalidate, and honor their freshness window", async () => {
  const requests: RequestInit[] = []
  const responses = [
    new Response(JSON.stringify({ dynamic: model("dynamic") }), {
      headers: { etag: '"catalog-1"', "last-modified": new Date(Date.now() + 60_000).toUTCString() }
    }),
    new Response(null, { status: 304 })
  ]
  const restore = replaceFetch(async (_input, init) => {
    requests.push(init ?? {})
    return responses.shift()!
  })
  try {
    const provider = testProvider()
    const store = new InMemoryModelsStore()

    await refresh(provider, store)
    await refresh(provider, store)
    await refresh(provider, store, { force: true })

    expect(provider.getModels().map(entry => entry.id)).toEqual(["static", "dynamic"])
    expect((await store.read(provider.id))?.models.map(entry => entry.id)).toEqual(["dynamic"])
    expect(requests).toHaveLength(2)
    expect(requests[0]?.headers).toMatchObject({ "user-agent": "zi/test" })
    expect(requests[1]?.headers).toMatchObject({ "if-none-match": '"catalog-1"' })
    expect(remoteCatalogRefreshIntervalMs).toBe(4 * 60 * 60 * 1000)
  } finally {
    restore()
  }
})

test("packaged catalogs win until the remote Last-Modified value is newer", async () => {
  const generatedAt = Date.parse("2026-08-01T00:00:00.000Z")
  const responses = [
    new Response(JSON.stringify([model("older")]), {
      headers: { "last-modified": new Date(generatedAt - 60_000).toUTCString() }
    }),
    new Response(JSON.stringify([model("newer")]), {
      headers: { "last-modified": new Date(generatedAt + 60_000).toUTCString() }
    })
  ]
  const restore = replaceFetch(async () => responses.shift()!)
  try {
    const provider = withRemoteModelCatalog(
      createProvider({
        id: "test-provider",
        auth: { apiKey: { name: "Test", resolve: async () => ({ auth: { apiKey: "test" } }) } },
        models: [model("static")],
        api: {
          stream: () => {
            throw new Error("not used")
          },
          streamSimple: () => {
            throw new Error("not used")
          }
        }
      }),
      { userAgent: "zi/test", localGeneratedAt: generatedAt }
    )
    const store = new InMemoryModelsStore()

    await refresh(provider, store)
    expect(provider.getModels().map(entry => entry.id)).toEqual(["static"])
    await refresh(provider, store, { force: true })
    expect(provider.getModels().map(entry => entry.id)).toEqual(["static", "newer"])
  } finally {
    restore()
  }
})

test("remote catalog failures and unavailable routes retain the last usable overlay", async () => {
  const generatedAt = Date.now()
  const remoteModifiedAt = Date.parse(new Date(generatedAt + 60_000).toUTCString())
  const responses = [
    new Response(JSON.stringify([model("dynamic")]), {
      headers: { etag: '"catalog-1"', "last-modified": new Date(remoteModifiedAt).toUTCString() }
    }),
    new Response("rate limited", { status: 429 }),
    new Response("missing", { status: 404 })
  ]
  const restore = replaceFetch(async () => responses.shift()!)
  try {
    const provider = testProvider(generatedAt)
    const store = new InMemoryModelsStore()

    await refresh(provider, store)
    const successfulCheck = (await store.read(provider.id))?.checkedAt
    expect(refresh(provider, store, { force: true })).rejects.toThrow("429")
    expect(provider.getModels().map(entry => entry.id)).toEqual(["static", "dynamic"])
    expect((await store.read(provider.id))?.checkedAt).toBe(successfulCheck)
    expect((await store.read(provider.id))?.etag).toBe('"catalog-1"')

    await refresh(provider, store, { force: true })
    expect(provider.getModels().map(entry => entry.id)).toEqual(["static", "dynamic"])
    expect((await store.read(provider.id))?.lastModified).toBe(remoteModifiedAt)
    expect((await store.read(provider.id))?.etag).toBeUndefined()

    const restored = testProvider(generatedAt)
    await refresh(restored, store, { allowNetwork: false })
    expect(restored.getModels().map(entry => entry.id)).toEqual(["static", "dynamic"])
  } finally {
    restore()
  }
})

test("remote catalogs reject oversized bodies and skip network access after cancellation", async () => {
  let calls = 0
  const restore = replaceFetch(async () => {
    calls++
    return new Response("{}", { headers: { "content-length": String(maxRemoteCatalogBytes + 1) } })
  })
  try {
    const provider = testProvider()
    const store = new InMemoryModelsStore()
    expect(refresh(provider, store)).rejects.toThrow(`cannot exceed ${maxRemoteCatalogBytes} bytes`)

    const controller = new AbortController()
    controller.abort()
    await refresh(provider, store, { signal: controller.signal, force: true })
    expect(calls).toBe(1)
    expect(provider.getModels().map(entry => entry.id)).toEqual(["static"])
  } finally {
    restore()
  }
})

function testProvider(localGeneratedAt?: number): Provider {
  return withRemoteModelCatalog(
    createProvider({
      id: "test-provider",
      auth: { apiKey: { name: "Test", resolve: async () => ({ auth: { apiKey: "test" } }) } },
      models: [model("static")],
      api: {
        stream: () => {
          throw new Error("not used")
        },
        streamSimple: () => {
          throw new Error("not used")
        }
      }
    }),
    { userAgent: "zi/test", ...(localGeneratedAt === undefined ? {} : { localGeneratedAt }) }
  )
}

async function refresh(
  provider: Provider,
  store: InMemoryModelsStore,
  overrides: Partial<Pick<RefreshModelsContext, "allowNetwork" | "force" | "signal">> = {}
): Promise<void> {
  await provider.refreshModels?.({
    credential: { type: "api_key", key: "test" },
    store: {
      read: () => store.read(provider.id),
      write: entry => store.write(provider.id, entry),
      delete: () => store.delete(provider.id)
    },
    allowNetwork: overrides.allowNetwork ?? true,
    ...(overrides.force === undefined ? {} : { force: overrides.force }),
    signal: overrides.signal ?? activeSignal
  })
}

type FetchCall = (...arguments_: Parameters<typeof fetch>) => ReturnType<typeof fetch>

function replaceFetch(implementation: FetchCall): () => void {
  const original = globalThis.fetch
  globalThis.fetch = Object.assign(implementation, { preconnect: original.preconnect })
  return () => {
    globalThis.fetch = original
  }
}

function model(id: string): Model<"openai-completions"> {
  return {
    id,
    name: id,
    api: "openai-completions",
    provider: "test-provider",
    baseUrl: "https://example.test/v1",
    reasoning: false,
    input: ["text"],
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    contextWindow: 1000,
    maxTokens: 100
  }
}
