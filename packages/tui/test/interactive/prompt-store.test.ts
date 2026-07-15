import { expect, test } from "bun:test"

import { createAgentRuntime, type AgentSession } from "@openzi/coding-agent"
import { createModels, fauxProvider } from "@openzi/coding-agent/testing"

import { createInteractiveCommands } from "../../src/interactive/interactive-commands.js"
import { createInteractiveStore } from "../../src/interactive/stores/interactive.js"
import { createPromptStore } from "../../src/interactive/stores/prompt.js"

test("prompt store restores queued text, images, and status without a renderer", async () => {
  const session = await createSession("restore")
  const mode = createInteractiveStore(session)
  const prompt = createPromptStore(mode, createInteractiveCommands())

  try {
    session.steer("queued text", [{ type: "image", data: "aW1hZ2U=", mimeType: "image/png" }])
    const text = prompt.restoreQueuedInputs("current draft")

    expect(text).toBe("queued text\n\ncurrent draft")
    expect(prompt.$state.get()).toEqual({
      feedback: { type: "status", message: "Restored 1 queued message to editor with 1 image" },
      images: [{ type: "image", data: "aW1hZ2U=", mimeType: "image/png" }],
      workflow: { type: "idle" },
      inputEdit: { revision: 0, text: "" }
    })
    expect(session.queuedInputs.steering).toHaveLength(0)
  } finally {
    mode.dispose()
    session.dispose()
  }
})

test("prompt store retains rejected input and exposes the admission error", async () => {
  const session = await createSession("disposed")
  const mode = createInteractiveStore(session)
  const prompt = createPromptStore(mode, createInteractiveCommands())

  session.dispose()
  expect(prompt.submit("keep this", "steer")).toBe(false)
  expect(prompt.$state.get().feedback).toEqual({ type: "error", message: "AgentSession is disposed" })

  mode.dispose()
})

async function createSession(provider: string): Promise<AgentSession> {
  const models = createModels()
  const faux = fauxProvider({ provider, models: [{ id: "model" }] })
  models.setProvider(faux.provider)
  return (await createAgentRuntime({ cwd: "/work", models, persist: false })).session
}
