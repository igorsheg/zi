import { expect, test } from "bun:test"

import { createAgentSession, SessionManager } from "../src/index.js"
import {
  createModels,
  createTestAgentRuntime as createAgentRuntime,
  fauxAssistantMessage,
  fauxProvider
} from "../src/testing.js"

test("AgentSession exposes provider context usage plus its estimated trailing messages", async () => {
  const models = createModels()
  const faux = fauxProvider({ provider: "context", models: [{ id: "model", contextWindow: 247_000 }] })
  models.setProvider(faux.provider)
  const bootstrap = await createAgentRuntime({ cwd: "/work", model: "context/model", models, persist: false })
  const model = bootstrap.session.model
  bootstrap.session.dispose()

  const sessionManager = SessionManager.inMemory("/work")
  const assistant = fauxAssistantMessage("reported response")
  sessionManager.appendMessage({
    ...assistant,
    usage: {
      input: 36_000,
      output: 1_000,
      cacheRead: 0,
      cacheWrite: 0,
      totalTokens: 37_000,
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 }
    }
  })
  sessionManager.appendMessage({
    role: "user",
    content: [{ type: "text", text: "12345678" }],
    timestamp: assistant.timestamp + 1
  })

  const session = await createAgentSession({ services: bootstrap.services, sessionManager, model, tools: [] })
  try {
    expect(session.getContextUsage()).toEqual({
      tokens: 37_002,
      contextWindow: 247_000,
      percent: (37_002 / 247_000) * 100
    })
    expect(session.getContextUsage()).toBe(session.getContextUsage())
  } finally {
    session.dispose()
  }
})
