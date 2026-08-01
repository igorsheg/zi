import { expect, test } from "bun:test"
import { mkdir, mkdtemp, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join, resolve } from "node:path"

import { createAgentRuntime } from "../src/runtime.js"
import type { AgentSettings } from "../src/settings-manager.js"
import { createModels, fauxAssistantMessage, fauxProvider, fauxToolCall } from "../src/testing.js"

const mockRpcChild = resolve(import.meta.dir, "fixtures/mock-rpc-child.ts")
const childCommand = Object.freeze([process.execPath, mockRpcChild])
const workerCommand = Object.freeze([process.execPath, resolve(import.meta.dir, "../../../packages/cli/src/main.ts")])

test("normal runtime exposes native subagent tools and depth one omits them", async () => {
  const enabled = await runtimeWithResponses([
    fauxAssistantMessage(fauxToolCall("list_subagents", {}, { id: "list-native" }), { stopReason: "toolUse" }),
    fauxAssistantMessage("listed")
  ])
  try {
    await enabled.runtime.session.prompt("List children")
    expect(toolText(enabled.runtime.session.messages, "list-native")).toBe('{"agents":[]}')
    expect(toolResult(enabled.runtime.session.messages, "list-native").details).toEqual({
      type: "subagent",
      outcome: "success",
      operation: "list",
      agents: [],
      workingNames: [],
      readyNames: []
    })
  } finally {
    enabled.runtime.session.dispose()
    await enabled.runtime.session.waitForIdle()
    await rm(enabled.root, { recursive: true, force: true })
  }

  const child = await runtimeWithResponses(
    [
      fauxAssistantMessage(fauxToolCall("list_subagents", {}, { id: "list-child" }), { stopReason: "toolUse" }),
      fauxAssistantMessage("done")
    ],
    1
  )
  try {
    await child.runtime.session.prompt("Try unavailable child delegation")
    expect(toolText(child.runtime.session.messages, "list-child")).toContain("not found")
  } finally {
    child.runtime.session.dispose()
    await child.runtime.session.waitForIdle()
    await rm(child.root, { recursive: true, force: true })
  }
})

test("subagentsEnabled disables the complete native capability", async () => {
  const setup = await runtimeWithResponses(
    [
      fauxAssistantMessage(fauxToolCall("list_subagents", {}, { id: "list-disabled" }), { stopReason: "toolUse" }),
      fauxAssistantMessage("done")
    ],
    0,
    { subagentsEnabled: false }
  )
  try {
    await setup.runtime.session.prompt("Try delegation")
    expect(toolText(setup.runtime.session.messages, "list-disabled")).toContain("not found")
    expect(setup.runtime.session.subagents).toEqual([])
  } finally {
    setup.runtime.session.dispose()
    await setup.runtime.session.waitForIdle()
    await rm(setup.root, { recursive: true, force: true })
  }
})

test("native wait uses the configured default timeout when the tool omits one", async () => {
  const setup = await runtimeWithResponses(
    [
      fauxAssistantMessage(
        fauxToolCall("spawn_subagent", { name: "slow-worker", prompt: "work" }, { id: "spawn-slow" }),
        { stopReason: "toolUse" }
      ),
      fauxAssistantMessage(fauxToolCall("wait_subagents", { names: ["slow-worker"] }, { id: "wait-slow" }), {
        stopReason: "toolUse"
      }),
      fauxAssistantMessage("still running")
    ],
    0,
    { delayMs: 200, settings: { subagentWaitTimeoutMs: 0 } }
  )
  try {
    await setup.runtime.session.prompt("Start and check")
    expect(JSON.parse(toolText(setup.runtime.session.messages, "wait-slow"))).toEqual({
      agents: [{ name: "slow-worker", status: "running" }],
      all_completed: false,
      omitted_bytes: 0
    })
  } finally {
    setup.runtime.session.dispose()
    await setup.runtime.session.waitForIdle()
    await rm(setup.root, { recursive: true, force: true })
  }
}, 15_000)

test("native tools spawn, wait, and close through the session-owned supervisor", async () => {
  const setup = await runtimeWithResponses([
    fauxAssistantMessage(
      fauxToolCall("spawn_subagent", { name: "solver", prompt: "solve it" }, { id: "spawn-native" }),
      { stopReason: "toolUse" }
    ),
    fauxAssistantMessage("spawned")
  ])
  const events: string[] = []
  const unsubscribe = setup.runtime.session.subscribe(event => events.push(event.type))
  try {
    await setup.runtime.session.prompt("Spawn")
    const spawned = parseAgentName(toolText(setup.runtime.session.messages, "spawn-native"))
    expect(spawned.name).toBe("solver")
    expect(toolResult(setup.runtime.session.messages, "spawn-native").details).toMatchObject({
      type: "subagent",
      outcome: "success",
      operation: "spawn",
      agent: { name: "solver", workCycle: 1 }
    })
    setup.faux.setResponses([
      fauxAssistantMessage(
        fauxToolCall("wait_subagents", { names: [spawned.name], timeout_ms: 5_000 }, { id: "wait-native" }),
        { stopReason: "toolUse" }
      ),
      fauxAssistantMessage(fauxToolCall("close_subagent", { name: spawned.name }, { id: "close-native" }), {
        stopReason: "toolUse"
      }),
      fauxAssistantMessage("closed")
    ])
    await setup.runtime.session.prompt("Wait and close")
    expect(JSON.parse(toolText(setup.runtime.session.messages, "wait-native"))).toMatchObject({
      agents: [{ name: "solver", completion: { status: "completed", text: "native-runtime-ok" } }]
    })
    expect(JSON.parse(toolText(setup.runtime.session.messages, "close-native"))).toEqual({
      name: spawned.name,
      closed: true,
      previous_status: "idle",
      previous_completion: { status: "completed" }
    })
    expect(setup.runtime.session.subagents[0]).toMatchObject({ name: "solver", lifecycle: "exited" })
    expect(events).toContain("subagent_changed")
    expect(events).toContain("entry_appended")
  } finally {
    unsubscribe()
    setup.runtime.session.dispose()
    await setup.runtime.session.waitForIdle()
    await rm(setup.root, { recursive: true, force: true })
  }
}, 30_000)

test("Code Mode captures native subagent tools in its immutable catalog", async () => {
  const setup = await runtimeWithResponses([
    fauxAssistantMessage(
      fauxToolCall("code", { code: "async () => await zi.list_subagents({})" }, { id: "code-native" }),
      { stopReason: "toolUse" }
    ),
    fauxAssistantMessage("done")
  ])
  try {
    await setup.runtime.session.prompt("Use code mode")
    expect(toolText(setup.runtime.session.messages, "code-native")).toContain('"agents"')
  } finally {
    setup.runtime.session.dispose()
    await setup.runtime.session.waitForIdle()
    await rm(setup.root, { recursive: true, force: true })
  }
}, 20_000)

async function runtimeWithResponses(
  responses: Parameters<ReturnType<typeof fauxProvider>["setResponses"]>[0],
  depth = 0,
  options: {
    readonly root?: string
    readonly extensionPaths?: readonly string[]
    readonly delayMs?: number
    readonly settings?: Readonly<Partial<AgentSettings>>
    readonly subagentsEnabled?: boolean
  } = {}
) {
  const root = options.root ?? (await mkdtemp(join(tmpdir(), "zi-native-runtime-")))
  await mkdir(root, { recursive: true })
  const models = createModels()
  const faux = fauxProvider()
  faux.setResponses(responses)
  models.setProvider(faux.provider)
  const runtime = await createAgentRuntime({
    cwd: root,
    agentDir: join(root, "agent"),
    model: "faux/faux-1",
    modelFactory: () => models,
    session: { type: "new", persist: false },
    settings: {
      ...options.settings,
      ...(options.subagentsEnabled === undefined ? {} : { subagentsEnabled: options.subagentsEnabled })
    },
    extensionWorkerCommand: workerCommand,
    extensionPaths: options.extensionPaths ?? [],
    subagentCommand: childCommand,
    internalSubagentEnvironment: {
      ...process.env,
      MOCK_RPC_REPLY: "native-runtime-ok",
      MOCK_RPC_DELAY_MS: String(options.delayMs ?? 20),
      ZI_SUBAGENT_DEPTH: "1"
    },
    internalSubagentDepth: depth === 1 ? 1 : 0
  })
  return { runtime, faux, root }
}

function parseAgentName(text: string): { readonly name: string } {
  const value: unknown = JSON.parse(text)
  if (typeof value !== "object" || value === null || Array.isArray(value)) throw new Error("Expected object")
  const name = Reflect.get(value, "name")
  if (typeof name !== "string" || name.length === 0) throw new Error("Expected name")
  return { name }
}

function toolResult(
  messages: readonly { role?: string; toolCallId?: string; content?: unknown; details?: unknown }[],
  id: string
): { readonly content: readonly unknown[]; readonly details?: unknown } {
  const result = messages.find(message => message.role === "toolResult" && message.toolCallId === id)
  if (!result || !Array.isArray(result.content)) throw new Error(`Missing tool result ${id}`)
  return { content: result.content, ...(result.details !== undefined ? { details: result.details } : {}) }
}

function toolText(messages: readonly { role?: string; toolCallId?: string; content?: unknown }[], id: string): string {
  return toolResult(messages, id)
    .content.map(part =>
      typeof part === "object" && part && "text" in part && typeof part.text === "string" ? part.text : ""
    )
    .join("")
}
