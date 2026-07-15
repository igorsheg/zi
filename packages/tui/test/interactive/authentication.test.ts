import { expect, test } from "bun:test"
import { mkdtemp } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { TextareaRenderable, TextAttributes } from "@opentui/core"
import { createAgentRuntime, type AuthenticationEvent, type AuthenticationPrompt } from "@openzi/coding-agent"
import { createModels, fauxProvider } from "@openzi/coding-agent/testing"

import { createInteractiveTest, renderSettled } from "./harness.js"

test("exact /login uses hidden composer input and selects the provider model without leaking the secret", async () => {
  const faux = fauxProvider({ provider: "secured", models: [{ id: "secured-model" }] })
  const provider = {
    ...faux.provider,
    name: "Secured Provider",
    auth: {
      apiKey: {
        name: "Secured API key",
        login: async (callbacks: { prompt(prompt: AuthenticationPrompt): Promise<string> }) => {
          const account = await callbacks.prompt({ type: "text", message: "Enter account id" })
          const key = await callbacks.prompt({ type: "secret", message: "Enter secured key" })
          return { type: "api_key" as const, key, env: { ACCOUNT_ID: account } }
        },
        resolve: async ({ credential }: { credential?: { key?: string } }) =>
          credential?.key ? { auth: { apiKey: credential.key } } : undefined
      }
    }
  }
  const runtime = await createAgentRuntime({
    cwd: "/work",
    agentDir: await mkdtemp(join(tmpdir(), "openzi-tui-auth-secret-")),
    persist: false,
    modelFactory(credentials) {
      const models = createModels({ credentials })
      models.setProvider(provider)
      return models
    }
  })
  const setup = await createInteractiveTest(runtime.session, { width: 52, height: 12 })

  try {
    const input = promptInput(setup)
    input.setText("/login secured")
    input.gotoBufferEnd()
    setup.mockInput.pressEnter()
    await renderSettled(setup)

    expect(setup.captureCharFrame()).toContain("Enter account id")
    expect(input.attributes & TextAttributes.HIDDEN).toBe(0)
    await setup.mockInput.typeText("account", 0)
    setup.mockInput.pressEnter()
    await renderSettled(setup)

    expect(setup.captureCharFrame()).toContain("Enter secured key")
    expect(input.attributes & TextAttributes.HIDDEN).toBe(TextAttributes.HIDDEN)
    expect(input.selectable).toBe(false)

    await setup.mockInput.typeText("super-secret", 0)
    await setup.renderOnce()
    const hiddenSpan = setup
      .captureSpans()
      .lines.flatMap(line => line.spans)
      .find(span => span.text.includes("super-secret"))
    expect((hiddenSpan?.attributes ?? 0) & TextAttributes.HIDDEN).toBe(TextAttributes.HIDDEN)
    setup.mockInput.pressEnter()
    await renderSettled(setup)

    expect(runtime.session.modelState).toEqual({ type: "selected", model: faux.getModel() })
    expect(setup.captureCharFrame()).toContain("secured-model")
    expect(setup.captureCharFrame()).not.toContain("super-secret")
    expect(runtime.session.messages).toEqual([])
    expect(input.plainText).toBe("")
    expect(input.attributes & TextAttributes.HIDDEN).toBe(0)
    expect(input.selectable).toBe(true)

    input.setText("/logout")
    input.gotoBufferEnd()
    setup.mockInput.pressEnter()
    await renderSettled(setup)
    expect(setup.captureCharFrame()).toContain("environment")
    expect(await runtime.services.credentialStore.read("secured")).toBeUndefined()
  } finally {
    runtime.session.dispose()
    setup.destroy()
  }
})

test("Escape cancels secret entry, clears native text, and rejects credential persistence", async () => {
  const faux = fauxProvider({ provider: "cancel", models: [{ id: "model" }] })
  const provider = {
    ...faux.provider,
    auth: {
      apiKey: {
        name: "Cancelable key",
        login: async (callbacks: { prompt(prompt: AuthenticationPrompt): Promise<string> }) => ({
          type: "api_key" as const,
          key: await callbacks.prompt({ type: "secret", message: "Enter cancelable key" })
        }),
        resolve: async ({ credential }: { credential?: { key?: string } }) =>
          credential?.key ? { auth: { apiKey: credential.key } } : undefined
      }
    }
  }
  const runtime = await createAgentRuntime({
    cwd: "/work",
    agentDir: await mkdtemp(join(tmpdir(), "openzi-tui-auth-cancel-")),
    persist: false,
    modelFactory(credentials) {
      const models = createModels({ credentials })
      models.setProvider(provider)
      return models
    }
  })
  const setup = await createInteractiveTest(runtime.session, { width: 52, height: 12, kittyKeyboard: true })

  try {
    const input = promptInput(setup)
    input.setText("/login cancel")
    input.gotoBufferEnd()
    setup.mockInput.pressEnter()
    await renderSettled(setup)
    await setup.mockInput.typeText("do-not-store", 0)
    setup.mockInput.pressEscape()
    await runtime.session.waitForIdle()
    await renderSettled(setup)

    expect(input.plainText).toBe("")
    expect(input.attributes & TextAttributes.HIDDEN).toBe(0)
    expect(await runtime.services.credentialStore.read("cancel")).toBeUndefined()
    expect(runtime.session.modelState).toEqual({ type: "unselected" })
    expect(setup.captureCharFrame()).not.toContain("do-not-store")
  } finally {
    runtime.session.dispose()
    setup.destroy()
  }
})

test("session replacement cancels pending authentication and cannot accept stale secret input", async () => {
  const oldFaux = fauxProvider({ provider: "old-auth", models: [{ id: "old-model" }] })
  const oldProvider = {
    ...oldFaux.provider,
    auth: {
      apiKey: {
        name: "Old key",
        login: async (callbacks: { prompt(prompt: AuthenticationPrompt): Promise<string> }) => ({
          type: "api_key" as const,
          key: await callbacks.prompt({ type: "secret", message: "Enter old key" })
        }),
        resolve: async ({ credential }: { credential?: { key?: string } }) =>
          credential?.key ? { auth: { apiKey: credential.key } } : undefined
      }
    }
  }
  const oldRuntime = await createAgentRuntime({
    cwd: "/old",
    agentDir: await mkdtemp(join(tmpdir(), "openzi-tui-auth-old-")),
    persist: false,
    modelFactory(credentials) {
      const models = createModels({ credentials })
      models.setProvider(oldProvider)
      return models
    }
  })
  const newFaux = fauxProvider({ provider: "new", models: [{ id: "new-model" }] })
  const newRuntime = await createAgentRuntime({
    cwd: "/new",
    agentDir: await mkdtemp(join(tmpdir(), "openzi-tui-auth-new-")),
    persist: false,
    modelFactory(credentials) {
      const models = createModels({ credentials })
      models.setProvider(newFaux.provider)
      return models
    }
  })
  const setup = await createInteractiveTest(oldRuntime.session, { width: 52, height: 12, kittyKeyboard: true })

  try {
    const input = promptInput(setup)
    input.setText("/login old-auth")
    input.gotoBufferEnd()
    setup.mockInput.pressEnter()
    await renderSettled(setup)
    await setup.mockInput.typeText("stale-secret", 0)

    setup.mode.replaceSession(newRuntime.session)
    await oldRuntime.session.waitForIdle()
    await renderSettled(setup)

    expect(setup.captureCharFrame()).toContain("/new")
    expect(setup.captureCharFrame()).toContain("new-model")
    expect(setup.captureCharFrame()).not.toContain("stale-secret")
    expect(await oldRuntime.services.credentialStore.read("old-auth")).toBeUndefined()
  } finally {
    oldRuntime.session.dispose()
    newRuntime.session.dispose()
    setup.destroy()
  }
})

test("/login nests provider and method pickers and restores the provider filter", async () => {
  const faux = fauxProvider({ provider: "dual", models: [{ id: "model" }] })
  const provider = {
    ...faux.provider,
    name: "Dual Provider",
    auth: {
      apiKey: {
        name: "Dual API key",
        login: async () => ({ type: "api_key" as const, key: "key" }),
        resolve: async ({ credential }: { credential?: { key?: string } }) =>
          credential?.key ? { auth: { apiKey: credential.key } } : undefined
      },
      oauth: {
        name: "Dual Subscription",
        login: async () => ({
          type: "oauth" as const,
          access: "access",
          refresh: "refresh",
          expires: Date.now() + 60_000
        }),
        refresh: async (credential: { type: "oauth"; access: string; refresh: string; expires: number }) => credential,
        toAuth: async (credential: { access: string }) => ({ apiKey: credential.access })
      }
    }
  }
  const runtime = await createAgentRuntime({
    cwd: "/work",
    agentDir: await mkdtemp(join(tmpdir(), "openzi-tui-auth-picker-")),
    persist: false,
    modelFactory(credentials) {
      const models = createModels({ credentials })
      models.setProvider(provider)
      return models
    }
  })
  const setup = await createInteractiveTest(runtime.session, { width: 56, height: 14, kittyKeyboard: true })

  try {
    const input = promptInput(setup)
    await setup.mockInput.typeText("/log", 0)
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("/login  <provider>")
    expect(setup.captureCharFrame()).toContain("/logout")
    setup.mockInput.pressTab()
    expect(input.plainText).toBe("/login ")
    setup.mockInput.pressEnter()
    await renderSettled(setup)
    expect(setup.captureCharFrame()).toContain("Dual Provider")

    await setup.mockInput.typeText("dual", 0)
    expect(input.plainText).toBe("dual")
    setup.mockInput.pressEnter()
    await renderSettled(setup)
    expect(input.plainText).toBe("")
    expect(setup.captureCharFrame()).toContain("Dual Subscription")
    expect(setup.captureCharFrame()).toContain("Dual API key")

    setup.mockInput.pressEscape()
    await renderSettled(setup)
    expect(setup.captureCharFrame()).toContain("Dual Provider")
    expect(setup.captureCharFrame()).not.toContain("Dual Subscription")
    expect(input.plainText).toBe("dual")
  } finally {
    runtime.session.dispose()
    setup.destroy()
  }
})

test("OAuth login renders URL, device, select, manual-code, and progress steps through one composer", async () => {
  const afterUrl = deferred<void>()
  const afterDevice = deferred<void>()
  const afterProgress = deferred<void>()
  const faux = fauxProvider({ provider: "oauth", models: [{ id: "oauth-model" }] })
  const provider = {
    ...faux.provider,
    name: "OAuth Provider",
    auth: {
      oauth: {
        name: "OAuth Subscription",
        async login(callbacks: {
          prompt(prompt: AuthenticationPrompt): Promise<string>
          notify(event: AuthenticationEvent): void
        }) {
          callbacks.notify({ type: "auth_url", url: "https://example.com/login", instructions: "Visit login" })
          await afterUrl.promise
          callbacks.notify({ type: "device_code", userCode: "ABCD", verificationUri: "https://example.com/device" })
          await afterDevice.promise
          const method = await callbacks.prompt({
            type: "select",
            message: "Choose OAuth method",
            options: [
              { id: "browser", label: "Browser callback" },
              { id: "manual", label: "Manual code" }
            ]
          })
          const code = await callbacks.prompt({ type: "manual_code", message: "Paste authorization code" })
          callbacks.notify({ type: "progress", message: "Exchanging authorization code" })
          await afterProgress.promise
          return {
            type: "oauth" as const,
            access: `${method}:${code}`,
            refresh: "refresh",
            expires: Date.now() + 60_000
          }
        },
        refresh: async (credential: { type: "oauth"; access: string; refresh: string; expires: number }) => credential,
        toAuth: async (credential: { access: string }) => ({ apiKey: credential.access })
      }
    }
  }
  const runtime = await createAgentRuntime({
    cwd: "/work",
    agentDir: await mkdtemp(join(tmpdir(), "openzi-tui-auth-oauth-")),
    persist: false,
    modelFactory(credentials) {
      const models = createModels({ credentials })
      models.setProvider(provider)
      return models
    }
  })
  const openedUrls: string[] = []
  const setup = await createInteractiveTest(
    runtime.session,
    { width: 64, height: 14, kittyKeyboard: true },
    undefined,
    undefined,
    { open: async url => void openedUrls.push(url), dispose() {} }
  )

  try {
    const input = promptInput(setup)
    input.setText("/login oauth")
    input.gotoBufferEnd()
    setup.mockInput.pressEnter()
    await renderSettled(setup)
    expect(setup.captureCharFrame()).toContain("https://example.com/login")
    expect(openedUrls).toEqual(["https://example.com/login"])

    afterUrl.resolve(undefined)
    await settle(setup)
    expect(setup.captureCharFrame()).toContain("ABCD")
    expect(setup.captureCharFrame()).toContain("https://example.com/device")
    expect(openedUrls).toEqual(["https://example.com/login", "https://example.com/device"])

    afterDevice.resolve(undefined)
    await settle(setup)
    expect(setup.captureCharFrame()).toContain("Browser callback")
    expect(setup.captureCharFrame()).toContain("Manual code")
    setup.mockInput.pressEnter()
    await settle(setup)
    expect(setup.captureCharFrame()).toContain("Paste authorization code")
    expect(input.selectable).toBe(true)

    await setup.mockInput.typeText("oauth-code", 0)
    setup.mockInput.pressEnter()
    await settle(setup)
    expect(setup.captureCharFrame()).toContain("Exchanging authorization code")
    expect(input.plainText).toBe("")

    const modelChanged = new Promise<void>(resolve => {
      const unsubscribe = runtime.session.subscribe(event => {
        if (event.type !== "model_changed") return
        unsubscribe()
        resolve()
      })
    })
    afterProgress.resolve(undefined)
    await modelChanged
    await settle(setup)
    expect(runtime.session.modelState).toEqual({ type: "selected", model: faux.getModel() })
    expect(setup.captureCharFrame()).toContain("oauth-model")
    expect(setup.captureCharFrame()).not.toContain("oauth-code")
  } finally {
    runtime.session.dispose()
    setup.destroy()
  }
})

function promptInput(setup: Awaited<ReturnType<typeof createInteractiveTest>>): TextareaRenderable {
  const input = setup.renderer.root.findDescendantById("prompt-input")
  if (!(input instanceof TextareaRenderable)) throw new Error("Prompt textarea not found")
  return input
}

async function settle(setup: Awaited<ReturnType<typeof createInteractiveTest>>): Promise<void> {
  await Promise.resolve()
  await Promise.resolve()
  await renderSettled(setup)
}

function deferred<T>() {
  let resolve!: (value: T) => void
  const promise = new Promise<T>(resolvePromise => {
    resolve = resolvePromise
  })
  return { promise, resolve }
}
