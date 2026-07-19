import { expect, test } from "bun:test"
import { existsSync } from "node:fs"
import { mkdir, mkdtemp, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { dirname, join, resolve } from "node:path"

import type { CredentialStore } from "@earendil-works/pi-ai"

import { OpenZiPaths } from "../src/paths.js"
import { createAgentRuntime } from "../src/runtime.js"
import { SessionManager } from "../src/session-manager.js"
import { createModels, createTestAgentRuntime, fauxAssistantMessage, fauxProvider } from "../src/testing.js"

test("runtime settings and sessions share the resumed session cwd path policy", async () => {
  const root = await mkdtemp(join(tmpdir(), "openzi-runtime-paths-"))
  const globalDir = join(root, "global")
  const cwd = join(root, "project")
  await mkdir(join(cwd, ".openzi"), { recursive: true })
  await mkdir(globalDir, { recursive: true })
  await writeFile(join(globalDir, "settings.json"), JSON.stringify({ defaultProvider: "paths", defaultModel: "model" }))
  await writeFile(join(cwd, ".openzi", "settings.json"), JSON.stringify({ defaultThinkingLevel: "low" }))

  const models = createModels()
  const faux = fauxProvider({ provider: "paths", models: [{ id: "model", reasoning: true }] })
  faux.setResponses([fauxAssistantMessage("saved")])
  models.setProvider(faux.provider)
  const created = await createTestAgentRuntime({ cwd, agentDir: globalDir, models })
  const sessionFile = created.session.sessionManager.file
  if (!sessionFile) throw new Error("Session file was not created")

  expect(created.services.paths.cwd).toBe(resolve(cwd))
  expect(created.session.model).toBe(faux.getModel())
  expect(created.session.thinkingLevel).toBe("low")
  expect(created.session.settingsManager.get()).toMatchObject({
    defaultProvider: "paths",
    defaultModel: "model",
    defaultThinkingLevel: "low"
  })
  expect(created.session.sessionManager.entries().map(entry => entry.type)).toEqual([
    "model_change",
    "thinking_level_change"
  ])
  expect(dirname(sessionFile)).toBe(new OpenZiPaths(cwd, globalDir).sessionDir)
  expect(existsSync(sessionFile)).toBe(false)

  await created.session.prompt("save this session")
  expect(existsSync(sessionFile)).toBe(true)
  expect(
    SessionManager.open(sessionFile)
      .entries()
      .map(entry => entry.type)
  ).toEqual(["model_change", "thinking_level_change", "message", "message"])
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

test("runtime continueRecent reuses the newest current-cwd journal", async () => {
  const root = await mkdtemp(join(tmpdir(), "openzi-runtime-continue-"))
  const cwd = join(root, "project")
  const agentDir = join(root, "global")
  const models = createModels()
  const original = fauxProvider({ provider: "continue", models: [{ id: "model", reasoning: true }] })
  const changedDefault = fauxProvider({ provider: "changed-default", models: [{ id: "model", reasoning: true }] })
  models.setProvider(original.provider)
  models.setProvider(changedDefault.provider)
  const created = await createTestAgentRuntime({ cwd, agentDir, model: "continue/model", models })
  const sessionId = created.session.sessionManager.sessionId
  created.session.sessionManager.appendMessage({ role: "user", content: "continued", timestamp: 1 })
  created.session.sessionManager.appendMessage({
    ...fauxAssistantMessage("continued answer"),
    provider: "continue",
    model: "model"
  })
  created.session.dispose()
  await created.session.waitForIdle()
  await writeFile(
    join(agentDir, "settings.json"),
    JSON.stringify({ defaultProvider: "changed-default", defaultModel: "model", defaultThinkingLevel: "high" })
  )

  const continued = await createTestAgentRuntime({ cwd, agentDir, continueRecent: true, models })
  try {
    expect(continued.session.sessionManager.sessionId).toBe(sessionId)
    expect(continued.session.model).toBe(original.getModel())
    expect(continued.session.thinkingLevel).toBe("medium")
    expect(continued.session.settingsManager.get()).toMatchObject({
      defaultProvider: "changed-default",
      defaultModel: "model",
      defaultThinkingLevel: "high"
    })
    expect(continued.session.messages).toContainEqual({ role: "user", content: "continued", timestamp: 1 })
  } finally {
    continued.session.dispose()
  }
})

test("resume derives an old journal model and repairs missing thinking metadata", async () => {
  const root = await mkdtemp(join(tmpdir(), "openzi-runtime-context-repair-"))
  const cwd = join(root, "project")
  const agentDir = join(root, "global")
  const paths = new OpenZiPaths(cwd, agentDir)
  const journal = SessionManager.create(paths)
  journal.appendMessage({ role: "user", content: "old prompt", timestamp: 1 })
  journal.appendMessage({ ...fauxAssistantMessage("old answer"), provider: "context-repair", model: "model" })
  await writeFile(join(agentDir, "settings.json"), JSON.stringify({ defaultThinkingLevel: "high" }))

  const models = createModels()
  const faux = fauxProvider({ provider: "context-repair", models: [{ id: "model", reasoning: true }] })
  models.setProvider(faux.provider)
  const resumed = await createTestAgentRuntime({ cwd: "/ignored", agentDir, sessionFile: journal.file!, models })

  try {
    expect(resumed.session.model).toBe(faux.getModel())
    expect(resumed.session.thinkingLevel).toBe("high")
    expect(resumed.session.sessionManager.entries().map(entry => entry.type)).toEqual([
      "message",
      "message",
      "thinking_level_change"
    ])
    expect(SessionManager.open(journal.file!).entries().at(-1)).toMatchObject({
      type: "thinking_level_change",
      thinkingLevel: "high"
    })
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
