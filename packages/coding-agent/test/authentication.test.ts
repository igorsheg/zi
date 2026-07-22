import { expect, test } from "bun:test"
import { mkdtemp } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type { AuthEvent, AuthPrompt } from "@earendil-works/pi-ai"

import { Authentication } from "../src/authentication.js"
import { FileCredentialStore } from "../src/credential-store.js"
import { ZiPaths } from "../src/paths.js"
import { createAgentRuntime } from "../src/runtime.js"
import { createModels, fauxProvider } from "../src/testing.js"

test("authentication derives provider methods and persists an API-key login through the shared store", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-authentication-"))
  const credentials = new FileCredentialStore(new ZiPaths(join(root, "project"), join(root, "global")))
  const faux = fauxProvider({ provider: "secured", models: [{ id: "model" }] })
  const provider = {
    ...faux.provider,
    name: "Secured Provider",
    auth: {
      apiKey: {
        name: "Secured API key",
        login: async (callbacks: { prompt(prompt: AuthPrompt): Promise<string> }) => {
          const account = await callbacks.prompt({ type: "text", message: "Enter account id" })
          const key = await callbacks.prompt({ type: "secret", message: "Enter secured key" })
          return { type: "api_key" as const, key, env: { ACCOUNT_ID: account } }
        },
        resolve: async ({ credential }: { credential?: { key?: string } }) =>
          credential?.key ? { auth: { apiKey: credential.key }, source: "stored credential" } : undefined
      }
    }
  }
  const models = createModels({ credentials })
  models.setProvider(provider)
  const authentication = new Authentication(models, credentials)
  const prompts: AuthPrompt[] = []

  expect(authentication.methods()).toEqual([
    { providerId: "secured", providerName: "Secured Provider", type: "api_key", name: "Secured API key" }
  ])

  await authentication.login("secured", "api_key", {
    async prompt(prompt) {
      prompts.push(prompt)
      return prompt.type === "text" ? "account" : "stored-key"
    },
    notify() {}
  })

  expect(prompts).toMatchObject([
    { type: "text", message: "Enter account id" },
    { type: "secret", message: "Enter secured key" }
  ])
  expect(await credentials.read("secured")).toEqual({
    type: "api_key",
    key: "stored-key",
    env: { ACCOUNT_ID: "account" }
  })
  expect((await models.getAuth(faux.getModel()))?.auth.apiKey).toBe("stored-key")
})

test("authentication forwards generic OAuth events and prompts before persisting credentials", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-authentication-oauth-"))
  const credentials = new FileCredentialStore(new ZiPaths(join(root, "project"), join(root, "global")))
  const faux = fauxProvider({ provider: "oauth", models: [{ id: "model" }] })
  let refreshes = 0
  const provider = {
    ...faux.provider,
    name: "OAuth Provider",
    auth: {
      oauth: {
        name: "OAuth Subscription",
        async login(callbacks: { prompt(prompt: AuthPrompt): Promise<string>; notify(event: AuthEvent): void }) {
          callbacks.notify({ type: "auth_url", url: "https://example.com/login", instructions: "Sign in" })
          callbacks.notify({ type: "device_code", userCode: "ABCD", verificationUri: "https://example.com/device" })
          const method = await callbacks.prompt({
            type: "select",
            message: "Choose login method",
            options: [{ id: "browser", label: "Browser" }]
          })
          const code = await callbacks.prompt({ type: "manual_code", message: "Paste code" })
          callbacks.notify({ type: "progress", message: "Exchanging code" })
          return { type: "oauth" as const, access: `${method}:${code}`, refresh: "refresh", expires: 0 }
        },
        async refresh() {
          refreshes++
          return { type: "oauth" as const, access: "refreshed", refresh: "rotated", expires: Date.now() + 60_000 }
        },
        async toAuth(credential: { access: string }) {
          return { apiKey: credential.access }
        }
      }
    }
  }
  const models = createModels({ credentials })
  models.setProvider(provider)
  const authentication = new Authentication(models, credentials)
  const prompts: AuthPrompt[] = []
  const events: AuthEvent[] = []

  await authentication.login("oauth", "oauth", {
    async prompt(prompt) {
      prompts.push(prompt)
      return prompt.type === "select" ? "browser" : "code"
    },
    notify(event) {
      events.push(event)
    }
  })

  expect(prompts.map(prompt => prompt.type)).toEqual(["select", "manual_code"])
  expect(events.map(event => event.type)).toEqual(["auth_url", "device_code", "progress"])
  expect(await credentials.list()).toEqual([{ providerId: "oauth", type: "oauth" }])
  expect(refreshes).toBe(0)
  expect((await models.getAuth(faux.getModel()))?.auth.apiKey).toBe("refreshed")
  expect(refreshes).toBe(1)
  expect(await credentials.read("oauth")).toMatchObject({ access: "refreshed", refresh: "rotated" })
})

test("cancelling a login rejects stale provider completion before persistence", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-authentication-cancel-"))
  const credentials = new FileCredentialStore(new ZiPaths(join(root, "project"), join(root, "global")))
  const started = deferred<void>()
  const release = deferred<void>()
  const faux = fauxProvider({ provider: "slow", models: [{ id: "model" }] })
  const provider = {
    ...faux.provider,
    auth: {
      apiKey: {
        name: "Slow key",
        async login() {
          started.resolve(undefined)
          await release.promise
          return { type: "api_key" as const, key: "must-not-persist" }
        },
        resolve: async ({ credential }: { credential?: { key?: string } }) =>
          credential?.key ? { auth: { apiKey: credential.key } } : undefined
      }
    }
  }
  const models = createModels({ credentials })
  models.setProvider(provider)
  const authentication = new Authentication(models, credentials)

  const login = authentication.login("slow", "api_key", { prompt: async () => "", notify() {} })
  await started.promise
  const cancelled = authentication.cancel()
  const overlap = authentication.login("slow", "api_key", { prompt: async () => "", notify() {} })
  release.resolve(undefined)

  expect((await rejection(overlap)).message).toContain("active")
  expect((await rejection(login)).message).toContain("cancelled")
  await cancelled
  expect(await credentials.read("slow")).toBeUndefined()
})

test("disposal joins an ignored abort signal and permanently rejects late persistence", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-authentication-dispose-"))
  const credentials = new FileCredentialStore(new ZiPaths(join(root, "project"), join(root, "global")))
  const started = deferred<void>()
  const release = deferred<void>()
  const faux = fauxProvider({ provider: "dispose", models: [{ id: "model" }] })
  const models = createModels({ credentials })
  models.setProvider({
    ...faux.provider,
    auth: {
      apiKey: {
        name: "Dispose key",
        async login() {
          started.resolve(undefined)
          await release.promise
          return { type: "api_key" as const, key: "must-not-persist" }
        },
        resolve: async () => undefined
      }
    }
  })
  const authentication = new Authentication(models, credentials)
  const login = authentication.login("dispose", "api_key", { prompt: async () => "", notify() {} })
  await started.promise
  const disposal = authentication.dispose()
  release.resolve(undefined)

  expect((await rejection(login)).message).toContain("cancelled")
  await disposal
  expect(() => authentication.methods()).toThrow("disposed")
  expect(await credentials.read("dispose")).toBeUndefined()
})

test("logout removes only stored credentials and leaves ambient authentication available", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-authentication-logout-"))
  const credentials = new FileCredentialStore(new ZiPaths(join(root, "project"), join(root, "global")))
  await credentials.modify("secured", async () => ({ type: "api_key", key: "stored-key" }))
  const faux = fauxProvider({ provider: "secured", models: [{ id: "model" }] })
  const provider = {
    ...faux.provider,
    auth: {
      apiKey: {
        name: "Secured API key",
        login: async () => ({ type: "api_key" as const, key: "new-key" }),
        resolve: async ({
          credential,
          ctx
        }: {
          credential?: { key?: string }
          ctx: { env(name: string): Promise<string | undefined> }
        }) => {
          const key = credential?.key ?? (await ctx.env("SECURED_API_KEY"))
          return key
            ? { auth: { apiKey: key }, source: credential ? "stored credential" : "SECURED_API_KEY" }
            : undefined
        }
      }
    }
  }
  const models = createModels({
    credentials,
    authContext: {
      env: async name => (name === "SECURED_API_KEY" ? "ambient-key" : undefined),
      fileExists: async () => false
    }
  })
  models.setProvider(provider)
  const authentication = new Authentication(models, credentials)

  expect(await authentication.stored()).toEqual([{ providerId: "secured", type: "api_key" }])
  await authentication.logout("secured")

  expect(await authentication.stored()).toEqual([])
  expect((await models.getAuth(faux.getModel()))?.auth.apiKey).toBe("ambient-key")
})

test("authentication rejects unbounded provider interaction before presentation or persistence", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-authentication-bound-"))
  const credentials = new FileCredentialStore(new ZiPaths(join(root, "project"), join(root, "global")))
  const faux = fauxProvider({ provider: "unbounded", models: [{ id: "model" }] })
  const provider = {
    ...faux.provider,
    auth: {
      apiKey: {
        name: "Unbounded key",
        async login(callbacks: { prompt(prompt: AuthPrompt): Promise<string> }) {
          await callbacks.prompt({
            type: "select",
            message: "Too many",
            options: Array.from({ length: 129 }, (_, index) => ({ id: String(index), label: String(index) }))
          })
          return { type: "api_key" as const, key: "must-not-persist" }
        },
        resolve: async () => undefined
      }
    }
  }
  const models = createModels({ credentials })
  models.setProvider(provider)
  const authentication = new Authentication(models, credentials)
  let presented = false

  const error = await rejection(
    authentication.login("unbounded", "api_key", {
      async prompt() {
        presented = true
        return "0"
      },
      notify() {}
    })
  )

  expect(error.message).toContain("option count")
  expect(presented).toBe(false)
  expect(await credentials.read("unbounded")).toBeUndefined()
})

test("AgentSession gates model work and joins authentication cancellation", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-authentication-session-"))
  const started = deferred<void>()
  const release = deferred<void>()
  const faux = fauxProvider({ provider: "session-auth", models: [{ id: "model" }] })
  const provider = {
    ...faux.provider,
    auth: {
      apiKey: {
        name: "Session key",
        async login() {
          started.resolve(undefined)
          await release.promise
          return { type: "api_key" as const, key: "must-not-persist" }
        },
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
    const login = runtime.session.login("session-auth", "api_key", { prompt: async () => "", notify() {} })
    await started.promise
    const modelChange = runtime.session.setModel(faux.getModel())
    const aborted = runtime.session.abort()
    release.resolve(undefined)

    expect((await rejection(modelChange)).message).toContain("authentication is active")
    expect((await rejection(login)).message).toContain("cancelled")
    await aborted
    expect(await runtime.services.credentialStore.read("session-auth")).toBeUndefined()
    expect(runtime.session.modelState).toEqual({ type: "unselected" })
  } finally {
    runtime.session.dispose()
  }
})

function deferred<T>() {
  let resolve!: (value: T) => void
  let reject!: (cause: unknown) => void
  const promise = new Promise<T>((resolvePromise, rejectPromise) => {
    resolve = resolvePromise
    reject = rejectPromise
  })
  return { promise, resolve, reject }
}

async function rejection(promise: Promise<unknown>): Promise<Error> {
  try {
    await promise
  } catch (cause) {
    return cause instanceof Error ? cause : new Error(String(cause))
  }
  throw new Error("Expected promise to reject")
}
