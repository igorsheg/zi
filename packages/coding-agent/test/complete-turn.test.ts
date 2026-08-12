import { expect, test } from "bun:test"
import { mkdtemp, readFile, writeFile } from "node:fs/promises"
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
        fauxToolCall("kill_task", { taskId: "missing-task" }, { id: "kill-error" }),
        fauxToolCall("code", { code: `async () => { throw new Error("expected code failure") }` }, { id: "code-error" })
      ],
      { stopReason: "toolUse" }
    ),
    fauxAssistantMessage(fauxText("Failures observed."))
  ])

  const { session } = await createAgentRuntime({
    cwd: root,
    model: "faux/faux-1",
    models,
    session: { type: "new", persist: false }
  })
  try {
    await session.prompt("Exercise expected tool failures.")
    const results = session.messages.filter(message => message.role === "toolResult")
    expect(results).toHaveLength(7)
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

test("update_plan changes the authoritative session plan and emits journal evidence", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-work-plan-turn-"))
  const models = createModels()
  const faux = fauxProvider({ tokensPerSecond: 10_000 })
  models.setProvider(faux.provider)
  faux.setResponses([
    fauxAssistantMessage(
      fauxToolCall(
        "update_plan",
        {
          explanation: "Starting implementation",
          steps: [
            { text: "Inspect", status: "completed" },
            { text: "Implement", status: "in_progress" },
            { text: "Verify", status: "pending" }
          ]
        },
        { id: "plan-1" }
      ),
      { stopReason: "toolUse" }
    ),
    fauxAssistantMessage("Implementation started.")
  ])
  const { session } = await createAgentRuntime({
    cwd: root,
    model: "faux/faux-1",
    models,
    session: { type: "new", persist: true }
  })
  const events: string[] = []
  let workPlanEntries = 0
  session.subscribe(event => {
    events.push(event.type)
    if (event.type === "entry_appended" && event.entry.type === "work_plan") workPlanEntries++
  })

  try {
    await session.prompt("Implement the change.")
    expect(session.workPlan).toEqual({
      revision: 1,
      explanation: "Starting implementation",
      steps: [
        { text: "Inspect", status: "completed" },
        { text: "Implement", status: "in_progress" },
        { text: "Verify", status: "pending" }
      ]
    })
    expect(
      session.messages.find(message => message.role === "toolResult" && message.toolCallId === "plan-1")
    ).toMatchObject({ isError: false, details: { revision: 1 } })
    expect(events.filter(event => event === "work_plan_changed")).toHaveLength(1)
    expect(workPlanEntries).toBe(1)

    const file = session.sessionManager.file
    if (!file) throw new Error("Expected persistent work plan journal")
    session.dispose()
    faux.setResponses([
      fauxAssistantMessage(
        fauxToolCall("update_plan", { steps: [{ text: "Verify", status: "completed" }] }, { id: "plan-2" }),
        { stopReason: "toolUse" }
      ),
      fauxAssistantMessage("Verified.")
    ])
    const resumed = await createAgentRuntime({
      cwd: "/ignored-on-resume",
      model: "faux/faux-1",
      models,
      session: { type: "resume", file }
    })
    try {
      expect(resumed.session.workPlan).toEqual(session.workPlan)
      const resumedEvents: string[] = []
      resumed.session.subscribe(event => resumedEvents.push(event.type))
      await resumed.session.prompt("Finish verification.")
      expect(resumed.session.workPlan).toEqual({ revision: 2, steps: [{ text: "Verify", status: "completed" }] })
      expect(resumedEvents.filter(event => event === "work_plan_changed")).toHaveLength(1)
    } finally {
      resumed.session.dispose()
    }
  } finally {
    session.dispose()
  }
})

test("code runs through the normal turn lifecycle with durable nested evidence", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-code-turn-"))
  await writeFile(join(root, "input.txt"), "needle\n")
  const models = createModels()
  const faux = fauxProvider({ tokensPerSecond: 10_000 })
  models.setProvider(faux.provider)
  faux.setResponses([
    fauxAssistantMessage(
      fauxToolCall(
        "code",
        {
          code: `async () => {
  const file = await zi.read({ path: "input.txt" });
  return file.includes("needle");
}`
        },
        { id: "code-1" }
      ),
      { stopReason: "toolUse" }
    ),
    fauxAssistantMessage("Nested evidence observed.")
  ])
  const { session } = await createAgentRuntime({
    cwd: root,
    model: "faux/faux-1",
    models,
    session: { type: "new", persist: false }
  })
  const events: string[] = []
  session.subscribe(event => events.push(event.type))

  try {
    await session.prompt("Inspect input through code.")
    const result = session.messages.find(message => message.role === "toolResult" && message.toolCallId === "code-1")
    expect(result).toMatchObject({
      role: "toolResult",
      toolName: "code",
      isError: false,
      content: [{ type: "text", text: "true" }],
      details: {
        type: "code_mode",
        outcome: "success",
        calls: [expect.objectContaining({ name: "read", state: "succeeded", arguments: { path: "input.txt" } })]
      }
    })
    expect(events.filter(event => event === "tool_execution_start")).toHaveLength(1)
    expect(events.filter(event => event === "tool_execution_end")).toHaveLength(1)
  } finally {
    session.dispose()
  }
})

test("background shell settlement appends one durable operation outcome", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-background-outcome-turn-"))
  const models = createModels()
  const faux = fauxProvider({ tokensPerSecond: 10_000 })
  models.setProvider(faux.provider)
  faux.setResponses([
    fauxAssistantMessage(
      fauxToolCall(
        "bash",
        { command: `node -e "setTimeout(() => console.log('private output'), 30)"`, background: true },
        { id: "background-1" }
      ),
      { stopReason: "toolUse" }
    ),
    fauxAssistantMessage("Background work admitted.")
  ])
  const { session } = await createAgentRuntime({
    cwd: root,
    model: "faux/faux-1",
    models,
    session: { type: "new", persist: true }
  })
  const appended: string[] = []
  let resolveOutcome!: () => void
  const outcomeAppended = new Promise<void>(resolve => {
    resolveOutcome = resolve
  })
  session.subscribe(event => {
    if (event.type !== "entry_appended" || event.entry.type !== "operation_outcome") return
    appended.push(event.entry.id)
    resolveOutcome()
  })

  try {
    await session.prompt("Start background work.")
    await Promise.race([
      outcomeAppended,
      Bun.sleep(2_000).then(() => {
        throw new Error("Background outcome did not persist")
      })
    ])
    const [outcome] = session.sessionManager.operationOutcomeEntries()
    expect(outcome).toMatchObject({
      capability: "shell",
      operation: "background_task",
      origin: "requested",
      result: "succeeded",
      exitCode: 0
    })
    expect(outcome).toBeDefined()
    expect(appended).toEqual([outcome!.id])
    expect(JSON.stringify(outcome)).not.toContain("private output")
    expect(JSON.stringify(outcome)).not.toContain("node -e")
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
    session: { type: "resume", file: session.sessionManager.file! },
    models
  })
  expect(resumed.services.paths.cwd).toBe(root)
  expect(resumed.services.paths.sessionDir).toBe(sessions)
  expect([...resumed.session.messages]).toEqual([...session.messages])

  resumed.session.dispose()
  session.dispose()
})
