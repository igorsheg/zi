import { expect, test } from "bun:test"
import { mkdtemp } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { createModels, fauxAssistantMessage, fauxProvider } from "@earendil-works/pi-ai"

import { createTestAgentRuntime as createAgentRuntime } from "../src/testing.js"

test("abort settles the active session", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-abort-"))
  const models = createModels()
  const faux = fauxProvider({ tokensPerSecond: 5, tokenSize: { min: 1, max: 1 } })
  models.setProvider(faux.provider)
  faux.setResponses([fauxAssistantMessage("This response should be interrupted before it finishes.")])
  const { session } = await createAgentRuntime({ cwd, model: "faux/faux-1", models, persist: false })

  const run = session.prompt("Start a long response")
  await Bun.sleep(30)
  await session.abort()
  await run

  const last = session.messages.at(-1)
  expect(session.isStreaming).toBe(false)
  expect(last?.role).toBe("assistant")
  if (last?.role === "assistant") expect(last.stopReason).toBe("aborted")
  session.dispose()
})
