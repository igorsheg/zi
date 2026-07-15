import { expect, test } from "bun:test"
import { mkdir, mkdtemp, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { dirname, join, resolve } from "node:path"

import type { CredentialStore } from "@earendil-works/pi-ai"

import { OpenZiPaths } from "../src/paths.js"
import { createAgentRuntime } from "../src/runtime.js"
import { createModels, createTestAgentRuntime, fauxProvider } from "../src/testing.js"

const modelReference = "paths/model"

test("runtime settings and sessions share the resumed session cwd path policy", async () => {
  const root = await mkdtemp(join(tmpdir(), "openzi-runtime-paths-"))
  const globalDir = join(root, "global")
  const cwd = join(root, "project")
  await mkdir(join(cwd, ".openzi"), { recursive: true })
  await mkdir(globalDir, { recursive: true })
  await writeFile(join(globalDir, "settings.json"), JSON.stringify({ model: modelReference }))
  await writeFile(join(cwd, ".openzi", "settings.json"), JSON.stringify({ thinkingLevel: "low" }))

  const models = createModels()
  models.setProvider(fauxProvider({ provider: "paths", models: [{ id: "model", reasoning: true }] }).provider)
  const created = await createTestAgentRuntime({ cwd, agentDir: globalDir, models })
  const sessionFile = created.session.sessionManager.file
  if (!sessionFile) throw new Error("Session file was not created")

  expect(created.services.paths.cwd).toBe(resolve(cwd))
  expect(created.session.settingsManager.get()).toMatchObject({ model: modelReference, thinkingLevel: "low" })
  expect(dirname(sessionFile)).toBe(new OpenZiPaths(cwd, globalDir).sessionDir)
  created.session.dispose()

  const resumed = await createTestAgentRuntime({ cwd: join(root, "ignored"), agentDir: globalDir, sessionFile, models })
  try {
    expect(resumed.services.paths.cwd).toBe(resolve(cwd))
    expect(resumed.services.paths.projectDir).toBe(join(resolve(cwd), ".openzi"))
    expect(resumed.session.sessionManager.file).toBe(sessionFile)
  } finally {
    resumed.session.dispose()
  }
})

test("the model factory receives the runtime-owned credential store", async () => {
  const root = await mkdtemp(join(tmpdir(), "openzi-runtime-models-"))
  const faux = fauxProvider({ provider: "factory", models: [{ id: "model" }] })
  const secured = fauxProvider({ provider: "secured", models: [{ id: "model" }] })
  const securedProvider = {
    ...secured.provider,
    auth: {
      apiKey: {
        name: "Secured API key",
        resolve: async ({ credential }: { credential?: { key?: string } }) =>
          credential?.key ? { auth: { apiKey: credential.key }, source: "stored credential" } : undefined
      }
    }
  }
  let received: CredentialStore | undefined

  const { session, services } = await createAgentRuntime({
    cwd: join(root, "project"),
    agentDir: join(root, "global"),
    model: "factory/model",
    persist: false,
    modelFactory(credentials) {
      received = credentials
      const models = createModels({ credentials })
      models.setProvider(faux.provider)
      models.setProvider(securedProvider)
      return models
    }
  })

  try {
    expect(received).toBe(services.credentialStore)
    await services.credentialStore.modify("secured", async () => ({ type: "api_key", key: "shared-key" }))
    expect((await services.modelRegistry.models.getAuth(secured.getModel()))?.auth.apiKey).toBe("shared-key")
  } finally {
    session.dispose()
  }
})
