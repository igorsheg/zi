import { expect, test } from "bun:test"
import { mkdir, mkdtemp, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type { CredentialStore } from "@earendil-works/pi-ai"

import { createAgentRuntime } from "../src/runtime.js"
import { createModels, fauxProvider } from "../src/testing.js"

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
    expect(runtime.session.settingsManager.get().model).toBe("login-required/model")
    expect(events).toEqual(["authentication_changed", "model_changed"])
  } finally {
    runtime.session.dispose()
  }
})

test("a configured model removed from the active catalog falls back to unselected startup", async () => {
  const root = await mkdtemp(join(tmpdir(), "openzi-onboarding-removed-"))
  const globalDir = join(root, "global")
  await mkdir(globalDir, { recursive: true })
  await writeFile(join(globalDir, "settings.json"), JSON.stringify({ model: "removed/model" }))
  const faux = fauxProvider({ provider: "available", models: [{ id: "model" }] })
  const provider = { ...faux.provider, auth: { apiKey: { name: "Available key", resolve: async () => undefined } } }
  const runtime = await createAgentRuntime({
    cwd: join(root, "project"),
    agentDir: globalDir,
    persist: false,
    modelFactory(credentials) {
      const models = createModels({ credentials })
      models.setProvider(provider)
      return models
    }
  })

  try {
    expect(runtime.session.modelState).toEqual({ type: "unselected" })
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
    expect(resumed.session.sessionManager.entries().filter(entry => entry.type === "model_change")).toHaveLength(1)
  } finally {
    resumed.session.dispose()
  }
})
