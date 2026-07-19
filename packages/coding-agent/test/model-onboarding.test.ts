import { expect, test } from "bun:test"
import { mkdir, mkdtemp, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type { CredentialStore } from "@earendil-works/pi-ai"

import { OpenZiPaths } from "../src/paths.js"
import { createAgentRuntime } from "../src/runtime.js"
import { SessionManager } from "../src/session-manager.js"
import { createModels, fauxAssistantMessage, fauxProvider } from "../src/testing.js"

test("a runtime without configured providers starts with an explicit unselected model", async () => {
  const root = await mkdtemp(join(tmpdir(), "openzi-onboarding-"))
  const faux = fauxProvider({ provider: "login-required", models: [{ id: "model", reasoning: true }] })
  const provider = {
    ...faux.provider,
    auth: {
      apiKey: {
        name: "Login-required API key",
        resolve: async ({ credential }: { credential?: { key?: string } }) =>
          credential?.key ? { auth: { apiKey: credential.key } } : undefined
      }
    }
  }

  const { session } = await createAgentRuntime({
    cwd: join(root, "project"),
    agentDir: join(root, "global"),
    persist: false,
    modelFactory(credentials) {
      const models = createModels({ credentials })
      models.setProvider(provider)
      return models
    }
  })

  try {
    expect(session.modelState).toEqual({ type: "unselected" })
    expect(session.thinkingLevel).toBe("off")
    expect(session.sessionManager.entries().some(entry => entry.type === "model_change")).toBe(false)
    expect(() => session.prompt("hello")).toThrow("/login")
    expect(session.messages).toEqual([])
  } finally {
    session.dispose()
  }
})

test("selecting an authenticated model leaves the unselected state once and persists it", async () => {
  const root = await mkdtemp(join(tmpdir(), "openzi-onboarding-select-"))
  const faux = fauxProvider({ provider: "login-required", models: [{ id: "model", reasoning: true }] })
  const provider = {
    ...faux.provider,
    auth: {
      apiKey: {
        name: "Login-required API key",
        login: async () => ({ type: "api_key" as const, key: "configured" }),
        resolve: async ({ credential }: { credential?: { key?: string } }) =>
          credential?.key ? { auth: { apiKey: credential.key } } : undefined
      }
    }
  }
  const runtime = await createAgentRuntime({
    cwd: join(root, "project"),
    agentDir: join(root, "global"),
    persist: false,
    modelFactory(credentials) {
      const models = createModels({ credentials })
      models.setProvider(provider)
      return models
    }
  })

  try {
    const events: string[] = []
    runtime.session.subscribe(event => events.push(event.type))
    await runtime.session.login("login-required", "api_key", { prompt: async () => "", notify() {} })

    expect(runtime.session.modelState).toEqual({ type: "selected", model: faux.getModel() })
    expect(runtime.session.sessionManager.entries().filter(entry => entry.type === "model_change")).toHaveLength(1)
    expect(runtime.session.settingsManager.get()).toMatchObject({
      defaultProvider: "login-required",
      defaultModel: "model"
    })
    expect(runtime.session.thinkingLevel).toBe("medium")
    expect(runtime.session.settingsManager.getDefaultThinkingLevel()).toBe("medium")
    expect(events).toEqual(["authentication_changed", "thinking_level_changed", "model_changed"])
  } finally {
    runtime.session.dispose()
  }
})

test("an unavailable settings default falls back to the first configured model", async () => {
  const root = await mkdtemp(join(tmpdir(), "openzi-onboarding-removed-"))
  const globalDir = join(root, "global")
  await mkdir(globalDir, { recursive: true })
  await writeFile(
    join(globalDir, "settings.json"),
    JSON.stringify({ defaultProvider: "removed", defaultModel: "model" })
  )
  const faux = fauxProvider({ provider: "available", models: [{ id: "model" }] })
  const runtime = await createAgentRuntime({
    cwd: join(root, "project"),
    agentDir: globalDir,
    persist: false,
    modelFactory(credentials) {
      const models = createModels({ credentials })
      models.setProvider(faux.provider)
      return models
    }
  })

  try {
    expect(runtime.session.modelState).toEqual({ type: "selected", model: faux.getModel() })
    expect(runtime.session.thinkingLevel).toBe("off")
  } finally {
    runtime.session.dispose()
  }
})

test("automatic selection prefers Pi's provider default over registry order", async () => {
  const models = createModels()
  const faux = fauxProvider({
    provider: "openai",
    models: [
      { id: "other", reasoning: false },
      { id: "gpt-5.5", reasoning: true }
    ]
  })
  models.setProvider(faux.provider)
  const preferred = faux.getModel("gpt-5.5")
  if (!preferred) throw new Error("Preferred model not found")
  const runtime = await createAgentRuntime({ cwd: "/work", persist: false, modelFactory: () => models })

  try {
    expect(runtime.session.model).toBe(preferred)
  } finally {
    runtime.session.dispose()
  }
})

test("resume warns when its saved model is unavailable and names the configured fallback", async () => {
  const root = await mkdtemp(join(tmpdir(), "openzi-onboarding-fallback-"))
  const journal = SessionManager.create(new OpenZiPaths(join(root, "project"), join(root, "global")))
  journal.appendMessage({ role: "user", content: "saved prompt", timestamp: 1 })
  journal.appendMessage({ ...fauxAssistantMessage("saved response"), provider: "removed", model: "old-model" })
  const sessionFile = journal.file
  if (!sessionFile) throw new Error("Session file was not created")

  const faux = fauxProvider({ provider: "available", models: [{ id: "fallback-model" }] })
  const runtime = await createAgentRuntime({
    cwd: join(root, "ignored"),
    agentDir: join(root, "global"),
    sessionFile,
    modelFactory() {
      const models = createModels()
      models.setProvider(faux.provider)
      return models
    }
  })

  try {
    expect(runtime.session.modelState).toEqual({ type: "selected", model: faux.getModel() })
    expect(runtime.bootstrapDiagnostic).toEqual({
      type: "model_fallback",
      savedModel: { provider: "removed", modelId: "old-model" },
      fallbackModel: { provider: "available", modelId: "fallback-model" },
      message: "Could not restore model removed/old-model. Using available/fallback-model."
    })
  } finally {
    runtime.session.dispose()
  }
})

test("resuming a session whose model is no longer authenticated preserves history as unselected", async () => {
  const root = await mkdtemp(join(tmpdir(), "openzi-onboarding-resume-"))
  const globalDir = join(root, "global")
  await mkdir(globalDir, { recursive: true })
  await writeFile(
    join(globalDir, "auth.json"),
    JSON.stringify({ "login-required": { type: "api_key", key: "configured" } })
  )
  const faux = fauxProvider({ provider: "login-required", models: [{ id: "model" }] })
  faux.setResponses([fauxAssistantMessage("saved response")])
  const provider = {
    ...faux.provider,
    auth: {
      apiKey: {
        name: "Login-required API key",
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
  const created = await createAgentRuntime({
    cwd: join(root, "project"),
    agentDir: globalDir,
    model: "login-required/model",
    modelFactory
  })
  const sessionFile = created.session.sessionManager.file
  if (!sessionFile) throw new Error("Session file was not created")
  await created.session.prompt("saved prompt")
  await created.services.credentialStore.delete("login-required")
  created.session.dispose()

  const resumed = await createAgentRuntime({
    cwd: join(root, "ignored"),
    agentDir: globalDir,
    sessionFile,
    modelFactory
  })

  try {
    expect(resumed.session.modelState).toEqual({ type: "unselected" })
    expect(resumed.bootstrapDiagnostic).toEqual({
      type: "resumed_model_unavailable",
      savedModel: { provider: "login-required", modelId: "model" },
      message: "Could not restore model login-required/model. No configured models are available."
    })
    expect(resumed.session.sessionManager.entries().filter(entry => entry.type === "model_change")).toHaveLength(1)
  } finally {
    resumed.session.dispose()
  }
})
