import { expect, test } from "bun:test"
import { mkdir, mkdtemp, readFile, truncate, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type { Model } from "@earendil-works/pi-ai"

import { FileModelCatalogStore, maxCatalogModelsPerProvider, maxModelsStoreBytes } from "../src/model-catalog-store.js"
import { ZiPaths } from "../src/paths.js"

test("model catalog storage preserves provider entries and admits negative sentinel costs", async () => {
  const { path, store } = await createStore()

  await store.write("one", { models: [model("one", "first", -1)], checkedAt: 100 })
  await store.write("two", { models: [model("two", "second")], checkedAt: 200 })

  const reloaded = new FileModelCatalogStore(new ZiPaths("/work", path))
  expect((await reloaded.read("one"))?.models.map(entry => entry.id)).toEqual(["first"])
  expect((await reloaded.read("one"))?.models[0]?.cost.input).toBe(-1)
  expect((await reloaded.read("two"))?.models.map(entry => entry.id)).toEqual(["second"])

  await reloaded.delete("one")
  expect(await reloaded.read("one")).toBeUndefined()
  expect((await reloaded.read("two"))?.models.map(entry => entry.id)).toEqual(["second"])
  expect((await readFile(join(path, "models-store.json"), "utf8")).length).toBeLessThan(maxModelsStoreBytes)
})

test("model catalog storage ignores malformed persisted input and rejects oversized provider catalogs", async () => {
  const { path, store } = await createStore()
  await writeFile(
    join(path, "models-store.json"),
    JSON.stringify({
      good: { models: [{ ...model("good", "usable"), provider: "good" }] },
      broken: { models: [{ id: "incomplete" }] }
    })
  )

  expect((await store.read("good"))?.models.map(entry => entry.id)).toEqual(["usable"])
  expect(await store.read("broken")).toBeUndefined()
  expect(
    store.write("too-many", {
      models: Array.from({ length: maxCatalogModelsPerProvider + 1 }, (_, index) => model("too-many", String(index)))
    })
  ).rejects.toThrow(`Invalid stored model catalog for too-many`)

  await truncate(join(path, "models-store.json"), maxModelsStoreBytes + 1)
  expect(store.read("good")).rejects.toThrow(`cannot exceed ${maxModelsStoreBytes} bytes`)
})

async function createStore(): Promise<{ path: string; store: FileModelCatalogStore }> {
  const root = await mkdtemp(join(tmpdir(), "zi-model-catalog-store-"))
  const path = join(root, "agent")
  await mkdir(path, { recursive: true })
  return { path, store: new FileModelCatalogStore(new ZiPaths("/work", path)) }
}

function model(provider: string, id: string, inputCost = 0): Model<"openai-completions"> {
  return {
    id,
    name: id,
    api: "openai-completions",
    provider,
    baseUrl: "https://example.test/v1",
    reasoning: false,
    input: ["text"],
    cost: { input: inputCost, output: 0, cacheRead: 0, cacheWrite: 0 },
    contextWindow: 1000,
    maxTokens: 100
  }
}
