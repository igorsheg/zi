import { expect, test } from "bun:test"

import {
  createModels,
  createTestAgentRuntime,
  fauxAssistantMessage,
  fauxProvider,
  fauxText,
  fauxThinking,
  fauxToolCall
} from "../src/testing.js"

test("last assistant text follows Pi copy semantics", async () => {
  const models = createModels()
  const faux = fauxProvider({ provider: "copy", models: [{ id: "model" }] })
  models.setProvider(faux.provider)
  const { session } = await createTestAgentRuntime({
    cwd: "/work",
    models,
    model: "copy/model",
    session: { type: "new", persist: false }
  })

  try {
    expect(session.getLastAssistantText()).toBeUndefined()

    session.sessionManager.appendMessage({ role: "user", content: "question", timestamp: 1 })
    session.sessionManager.appendMessage(fauxAssistantMessage("previous answer", { timestamp: 2 }))
    session.sessionManager.appendMessage(fauxAssistantMessage([], { stopReason: "aborted", timestamp: 3 }))
    expect(session.getLastAssistantText()).toBe("previous answer")

    session.sessionManager.appendMessage(
      fauxAssistantMessage(
        [
          fauxThinking("private reasoning"),
          fauxText("  first"),
          fauxToolCall("read", { path: "file.ts" }),
          fauxText(" second  ")
        ],
        { timestamp: 4 }
      )
    )
    expect(session.getLastAssistantText()).toBe("first second")

    session.sessionManager.appendMessage(
      fauxAssistantMessage(fauxToolCall("read", { path: "other.ts" }), { stopReason: "toolUse", timestamp: 5 })
    )
    expect(session.getLastAssistantText()).toBeUndefined()
  } finally {
    session.dispose()
    await session.waitForIdle()
  }
})
