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

import { createTestAgentRuntime as createAgentRuntime } from "../src/testing.js"

test("built-in expected failures keep typed details and are finalized as Pi errors once", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-tool-errors-"))
  const models = createModels()
  const faux = fauxProvider({ tokensPerSecond: 10_000 })
  models.setProvider(faux.provider)
  faux.setResponses([
    fauxAssistantMessage(
      [
        fauxToolCall("bash", { command: "exit 7" }, { id: "bash-error" }),
        fauxToolCall("read", { path: "missing.txt" }, { id: "read-error" }),
        fauxToolCall("write", { path: ".", content: "cannot replace a directory" }, { id: "write-error" }),
        fauxToolCall(
          "edit",
          { path: "missing-edit.txt", edits: [{ oldText: "before", newText: "after" }] },
          { id: "edit-error" }
        ),
        fauxToolCall("task_output", { taskId: "missing-task" }, { id: "output-error" }),
        fauxToolCall("kill_task", { taskId: "missing-task" }, { id: "kill-error" })
      ],
      { stopReason: "toolUse" }
    ),
    fauxAssistantMessage(fauxText("Failures observed."))
  ])

  const { session } = await createAgentRuntime({ cwd: root, model: "faux/faux-1", models, persist: false })
  try {
    await session.prompt("Exercise expected tool failures.")
    const results = session.messages.filter(message => message.role === "toolResult")
    expect(results).toHaveLength(6)
    for (const result of results) {
      expect(result.isError).toBe(true)
      expect(result.details).toMatchObject({ outcome: "error" })
    }
    expect(JSON.stringify(results.find(result => result.toolCallId === "bash-error")?.details)).not.toContain('"text"')
    expect(JSON.stringify(results.find(result => result.toolCallId === "output-error")?.details)).not.toContain(
      '"text"'
    )
  } finally {
    session.dispose()
  }
})

test("one turn can write, read, edit, execute, stream, and persist", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-turn-"))
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
    settings: { defaultThinkingLevel: "low" }
  })
  const events: string[] = []
  const streamedWriteArguments: unknown[] = []
  session.subscribe(event => {
    events.push(event.type)
    if (event.type !== "message_update" || event.assistantMessageEvent.type !== "toolcall_delta") return
    if (event.message.role !== "assistant") return
    const part = event.message.content[event.assistantMessageEvent.contentIndex]
    if (part?.type === "toolCall" && part.name === "write") streamedWriteArguments.push(part.arguments)
  })

  await session.prompt("Create result.txt, inspect it, change alpha to beta, then verify it with bash.")

  expect(await readFile(join(root, "result.txt"), "utf8")).toBe("beta\n")
  expect(faux.state.callCount).toBe(5)
  expect(session.messages.filter(message => message.role === "toolResult")).toHaveLength(4)
  const editResult = session.messages.find(message => message.role === "toolResult" && message.toolCallId === "edit-1")
  if (editResult?.role !== "toolResult") throw new Error("Missing edit result")
  expect(editResult.details).toMatchObject({
    replacements: 1,
    diff: expect.stringContaining("@@ -1,1 +1,1 @@\n-alpha\n+beta")
  })
  expect(events).toContain("message_update")
  expect(streamedWriteArguments.length).toBeGreaterThan(0)
  expect(
    streamedWriteArguments.some(
      args => JSON.stringify(args) !== JSON.stringify({ path: "result.txt", content: "alpha\n" })
    )
  ).toBe(true)
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
