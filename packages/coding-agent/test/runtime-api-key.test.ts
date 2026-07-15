import { expect, test } from "bun:test"
import { existsSync } from "node:fs"
import { mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type { CredentialStore } from "@earendil-works/pi-ai"

import { createAgentRuntime } from "../src/runtime.js"
import { createModels, fauxAssistantMessage, fauxProvider } from "../src/testing.js"

test("runtime API key wins for its selected provider without changing stored credentials", async () => {
  const root = await mkdtemp(join(tmpdir(), "openzi-runtime-api-key-"))
  const globalDir = join(root, "global")
  await mkdir(globalDir, { recursive: true })
  const authFile = join(globalDir, "auth.json")
  await writeFile(authFile, JSON.stringify({ secured: { type: "api_key", key: "stored-key" } }))
  const faux = fauxProvider({ provider: "secured", models: [{ id: "model" }] })
  const provider = {
    ...faux.provider,
    auth: {
      apiKey: {
        name: "Secured key",
        resolve: async ({ credential }: { credential?: { key?: string } }) =>
          credential?.key ? { auth: { apiKey: credential.key } } : undefined
      }
    }
  }
  const modelFactory = (credentials: CredentialStore) => {
    const models = createModels({ credentials })
    models.setProvider(provider)
    return models
  }
  const seenKeys: Array<string | undefined> = []
  faux.setResponses([
    (_context, options) => {
      seenKeys.push(options?.apiKey)
      return fauxAssistantMessage("override")
    },
    (_context, options) => {
      seenKeys.push(options?.apiKey)
      return fauxAssistantMessage("stored")
    }
  ])

  const overridden = await createAgentRuntime({
    cwd: join(root, "project"),
    agentDir: globalDir,
    model: "secured/model",
    apiKey: "runtime-key",
    persist: false,
    modelFactory
  })
  try {
    await overridden.session.prompt("first")
    expect(seenKeys).toEqual(["runtime-key"])
    expect(await overridden.services.credentialStore.read("secured")).toEqual({ type: "api_key", key: "stored-key" })
    expect(JSON.parse(await readFile(authFile, "utf8"))).toEqual({ secured: { type: "api_key", key: "stored-key" } })
  } finally {
    overridden.session.dispose()
  }

  const ordinary = await createAgentRuntime({
    cwd: join(root, "project"),
    agentDir: globalDir,
    model: "secured/model",
    persist: false,
    modelFactory
  })
  try {
    await ordinary.session.prompt("second")
    expect(seenKeys).toEqual(["runtime-key", "stored-key"])
  } finally {
    ordinary.session.dispose()
  }
})

test("runtime API key alone authenticates its explicit model without creating auth storage", async () => {
  const root = await mkdtemp(join(tmpdir(), "openzi-runtime-api-key-only-"))
  const globalDir = join(root, "global")
  const faux = fauxProvider({ provider: "key-only", models: [{ id: "model" }] })
  let seenKey: string | undefined
  faux.setResponses([
    (_context, options) => {
      seenKey = options?.apiKey
      return fauxAssistantMessage("ok")
    }
  ])
  const provider = { ...faux.provider, auth: { apiKey: { name: "Key only", resolve: async () => undefined } } }
  const runtime = await createAgentRuntime({
    cwd: join(root, "project"),
    agentDir: globalDir,
    model: "key-only/model",
    apiKey: "runtime-key",
    persist: false,
    modelFactory(credentials) {
      const models = createModels({ credentials })
      models.setProvider(provider)
      return models
    }
  })

  try {
    expect(runtime.session.modelState.type).toBe("selected")
    expect((await runtime.session.listModelChoices())[0]?.configured).toBe(true)
    await runtime.session.prompt("hello")
    expect(seenKey).toBe("runtime-key")
    expect(existsSync(join(globalDir, "auth.json"))).toBe(false)
  } finally {
    runtime.session.dispose()
  }
})

test("runtime API key requires a model provider", async () => {
  const root = await mkdtemp(join(tmpdir(), "openzi-runtime-api-key-missing-model-"))

  const error = await rejection(
    createAgentRuntime({
      cwd: join(root, "project"),
      agentDir: join(root, "global"),
      apiKey: "runtime-key",
      persist: false,
      modelFactory: credentials => createModels({ credentials })
    })
  )

  expect(error.message).toBe("--api-key requires a model so its provider can be determined")
  expect(error.message).not.toContain("runtime-key")
})

async function rejection(promise: Promise<unknown>): Promise<Error> {
  try {
    await promise
  } catch (cause) {
    return cause instanceof Error ? cause : new Error(String(cause))
  }
  throw new Error("Expected promise to reject")
}
