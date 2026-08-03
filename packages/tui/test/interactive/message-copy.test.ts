import { expect, test } from "bun:test"

import { TextareaRenderable } from "@opentui/core"
import { createModels, createTestAgentRuntime, fauxAssistantMessage, fauxProvider } from "@with-zi/coding-agent/testing"

import type { ClipboardWriter } from "../../src/interactive/clipboard.js"
import { createInteractiveTest, renderSettled } from "./harness.js"

test("/copy writes the last assistant message without entering the conversation", async () => {
  const models = createModels()
  const faux = fauxProvider({ provider: "message-copy", models: [{ id: "model" }] })
  models.setProvider(faux.provider)
  const { session } = await createTestAgentRuntime({
    cwd: "/work",
    models,
    model: "message-copy/model",
    session: { type: "new", persist: false }
  })
  session.sessionManager.appendMessage({ role: "user", content: "question", timestamp: 1 })
  session.sessionManager.appendMessage(fauxAssistantMessage("answer", { timestamp: 2 }))

  const writes: string[] = []
  const writer: ClipboardWriter = {
    async write(text) {
      writes.push(text)
      return { type: "copied", route: "native" }
    }
  }
  const setup = await createInteractiveTest(
    session,
    { width: 60, height: 12 },
    undefined,
    undefined,
    undefined,
    undefined,
    undefined,
    writer
  )

  try {
    const input = setup.renderer.root.findDescendantById("prompt-input")
    if (!(input instanceof TextareaRenderable)) throw new Error("Prompt textarea not found")
    input.setText("/copy")
    setup.mockInput.pressEnter()
    await renderSettled(setup)

    expect(writes).toEqual(["answer"])
    expect(input.plainText).toBe("")
    expect(session.messages.filter(message => message.role === "user")).toHaveLength(1)
    expect(setup.captureCharFrame()).toContain("Copied last assistant message to clipboard")
  } finally {
    setup.destroy()
    session.dispose()
    await session.waitForIdle()
  }
})
