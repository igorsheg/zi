import { expect, test } from "bun:test"

import { createAgentRuntime } from "@with-zi/coding-agent"
import { createModels, fauxProvider } from "@with-zi/coding-agent/testing"

import { createInteractiveTest } from "./harness.js"

test("interactive mode renders an unauthenticated session without requiring a model", async () => {
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
  const { session } = await createAgentRuntime({
    cwd: "/work",
    persist: false,
    modelFactory(credentials) {
      const models = createModels({ credentials })
      models.setProvider(provider)
      return models
    }
  })
  const setup = await createInteractiveTest(session, { width: 48, height: 8 })

  try {
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("No model selected")
  } finally {
    setup.destroy()
    session.dispose()
  }
})
