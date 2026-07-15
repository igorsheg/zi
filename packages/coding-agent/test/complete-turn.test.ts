import { expect, test } from "bun:test"
import { mkdtemp, readFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import {
  createModels,
  fauxAssistantMessage,
  fauxProvider,
  fauxText,
  fauxThinking,
  fauxToolCall
} from "@earendil-works/pi-ai"

import { createAgentRuntime } from "../src/runtime.js"

test("one turn can write, read, edit, execute, stream, and persist", async () => {
  const root = await mkdtemp(join(tmpdir(), "openzi-turn-"))
  const sessions = join(root, "sessions")
  const models = createModels()
  const faux = fauxProvider({ tokensPerSecond: 10_000 })
  models.setProvider(faux.provider)
  faux.setResponses([
    fauxAssistantMessage(fauxToolCall("write", { path: "result.txt", content: "alpha\n" }, { id: "write-1" }), {
      stopReason: "toolUse"
    }),
    fauxAssistantMessage(fauxToolCall("read", { path: "result.txt" }, { id: "read-1" }), { stopReason: "toolUse" }),
    fauxAssistantMessage(
      fauxToolCall("edit", { path: "result.txt", edits: [{ oldText: "alpha", newText: "beta" }] }, { id: "edit-1" }),
      { stopReason: "toolUse" }
    ),
    fauxAssistantMessage(fauxToolCall("bash", { command: "printf ':%s' \"$(cat result.txt)\"" }, { id: "bash-1" }), {
      stopReason: "toolUse"
    }),
    fauxAssistantMessage([fauxThinking("The tools completed."), fauxText("Finished with beta.")])
  ])

  const { session } = await createAgentRuntime({
    cwd: root,
    model: "faux/faux-1",
    models,
    sessionDir: sessions,
    settings: { thinkingLevel: "low" }
  })
  const events: string[] = []
  session.subscribe(event => events.push(event.type))

  await session.prompt("Create result.txt, inspect it, change alpha to beta, then verify it with bash.")

  expect(await readFile(join(root, "result.txt"), "utf8")).toBe("beta\n")
  expect(faux.state.callCount).toBe(5)
  expect(session.messages.filter(message => message.role === "toolResult")).toHaveLength(4)
  expect(events).toContain("message_update")
  expect(events.filter(event => event === "tool_execution_end")).toHaveLength(4)
  expect(session.sessionManager.file).toBeDefined()

  const journal = await readFile(session.sessionManager.file!, "utf8")
  const records = journal
    .trim()
    .split("\n")
    .map(line => JSON.parse(line))
  expect(records.filter(record => record.type === "message")).toHaveLength(session.messages.length)
  expect(journal).toContain("Finished with beta.")

  const restored = (await import("../src/session-manager.js")).SessionManager.open(session.sessionManager.file!)
  expect(restored.messages()).toEqual([...session.messages])
  const resumed = await createAgentRuntime({
    cwd: "/ignored-on-resume",
    sessionFile: session.sessionManager.file!,
    models,
    persist: true
  })
  expect(resumed.services.paths.cwd).toBe(root)
  expect(resumed.services.paths.sessionDir).toBe(sessions)
  expect([...resumed.session.messages]).toEqual([...session.messages])

  resumed.session.dispose()
  session.dispose()
})
