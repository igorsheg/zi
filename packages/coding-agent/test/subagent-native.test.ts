import { expect, test } from "bun:test"
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join, resolve } from "node:path"

import type { Context } from "@earendil-works/pi-ai"

import { createAgentRuntime } from "../src/runtime.js"
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
      workingAgentIds: [],
      readyAgentIds: []
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

test("native tools spawn, wait, and close through the session-owned supervisor", async () => {
  const setup = await runtimeWithResponses([
    fauxAssistantMessage(fauxToolCall("spawn_subagent", { prompt: "solve it" }, { id: "spawn-native" }), {
      stopReason: "toolUse"
    }),
    fauxAssistantMessage("spawned")
  ])
  const events: string[] = []
  const unsubscribe = setup.runtime.session.subscribe(event => events.push(event.type))
  try {
    await setup.runtime.session.prompt("Spawn")
    const spawned = parseAgentId(toolText(setup.runtime.session.messages, "spawn-native"))
    expect(toolResult(setup.runtime.session.messages, "spawn-native").details).toMatchObject({
      type: "subagent",
      outcome: "success",
      operation: "spawn",
      agent: { agentId: spawned.agent_id, definitionName: "general", workCycle: 1 }
    })
    setup.faux.setResponses([
      fauxAssistantMessage(
        fauxToolCall("wait_subagents", { agent_ids: [spawned.agent_id], timeout_ms: 5_000 }, { id: "wait-native" }),
        { stopReason: "toolUse" }
      ),
      fauxAssistantMessage(fauxToolCall("close_subagent", { agent_id: spawned.agent_id }, { id: "close-native" }), {
        stopReason: "toolUse"
      }),
      fauxAssistantMessage("closed")
    ])
    await setup.runtime.session.prompt("Wait and close")
    expect(JSON.parse(toolText(setup.runtime.session.messages, "wait-native"))).toMatchObject({
      agents: [{ agent_id: spawned.agent_id, completion: { status: "completed", text: "native-runtime-ok" } }]
    })
    expect(JSON.parse(toolText(setup.runtime.session.messages, "close-native"))).toEqual({
      agent_id: spawned.agent_id,
      closed: true
    })
    expect(setup.runtime.session.subagents[0]).toMatchObject({ agentId: spawned.agent_id, lifecycle: "exited" })
    expect(events).toContain("subagent_changed")
    expect(events).toContain("entry_appended")
  } finally {
    unsubscribe()
    setup.runtime.session.dispose()
    await setup.runtime.session.waitForIdle()
    await rm(setup.root, { recursive: true, force: true })
  }
}, 30_000)

test("extension reload replaces definitions without closing a running native child", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-native-reload-"))
  const extension = join(root, "reviewer.ts")
  await writeDefinitionExtension(extension)
  const setup = await runtimeWithResponses(
    [
      fauxAssistantMessage(
        fauxToolCall("spawn_subagent", { prompt: "review", type: "reviewer" }, { id: "spawn-reload" }),
        { stopReason: "toolUse" }
      ),
      fauxAssistantMessage("spawned")
    ],
    0,
    { root, extensionPaths: [extension], delayMs: 1_000 }
  )
  try {
    await setup.runtime.session.prompt("Spawn reviewer")
    const spawned = parseAgentId(toolText(setup.runtime.session.messages, "spawn-reload"))
    await writeFile(extension, "export default () => {}\n")
    expect((await setup.runtime.session.reload()).extensions?.outcome).toBe("replaced")
    expect(setup.runtime.session.subagents.find(value => value.agentId === spawned.agent_id)).toMatchObject({
      definition: { name: "reviewer" }
    })
    expect(setup.runtime.session.extensionHostSnapshot?.subagentTypes).toEqual([])
  } finally {
    setup.runtime.session.dispose()
    await setup.runtime.session.waitForIdle()
    await rm(root, { recursive: true, force: true })
  }
}, 30_000)

test("extension reload atomically rebuilds direct and Code Mode type catalogs", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-native-catalog-"))
  const extension = join(root, "reviewer.ts")
  await writeFile(
    extension,
    `export default zi => zi.registerSubagentType({ name: "reviewer", description: "Review\\n changes", instructions: "SECRET CHILD POLICY" })\n`
  )
  const catalogs: ModelToolCatalog[] = []
  const setup = await runtimeWithResponses(
    [
      (context: Context) => {
        catalogs.push(modelToolCatalog(context))
        return fauxAssistantMessage("first")
      }
    ],
    0,
    { root, extensionPaths: [extension] }
  )
  try {
    await setup.runtime.session.prompt("Inspect catalog")
    await writeFile(extension, "export default () => {}\n")
    expect((await setup.runtime.session.reload()).extensions?.outcome).toBe("replaced")
    setup.faux.setResponses([
      (context: Context) => {
        catalogs.push(modelToolCatalog(context))
        return fauxAssistantMessage("second")
      }
    ])
    await setup.runtime.session.prompt("Inspect reloaded catalog")

    expect(catalogs[0]?.typeDescription).toContain("- general — General coding")
    expect(catalogs[0]?.typeDescription).toContain("- reviewer — Review changes")
    expect(catalogs[0]?.typeDescription).not.toContain("SECRET CHILD POLICY")
    expect(catalogs[0]?.codeDescription).toContain("- reviewer — Review changes")
    expect(catalogs[1]?.typeDescription).toContain("- general — General coding")
    expect(catalogs[1]?.typeDescription).not.toContain("reviewer")
    expect(catalogs[1]?.codeDescription).not.toContain("reviewer")
  } finally {
    setup.runtime.session.dispose()
    await setup.runtime.session.waitForIdle()
    await rm(root, { recursive: true, force: true })
  }
}, 30_000)

test("extension worker crash removes definitions without closing a running native child", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-native-crash-"))
  const extension = join(root, "crashing-reviewer.ts")
  await writeDefinitionExtension(extension, true)
  const setup = await runtimeWithResponses(
    [
      fauxAssistantMessage(
        fauxToolCall("spawn_subagent", { prompt: "review", type: "reviewer" }, { id: "spawn-crash" }),
        { stopReason: "toolUse" }
      ),
      fauxAssistantMessage("spawned")
    ],
    0,
    { root, extensionPaths: [extension], delayMs: 3_000 }
  )
  try {
    await setup.runtime.session.prompt("Spawn reviewer")
    const spawned = parseAgentId(toolText(setup.runtime.session.messages, "spawn-crash"))
    await waitFor(() => setup.runtime.session.extensionHostSnapshot?.status === "failed", 5_000)
    expect(setup.runtime.session.extensionHostSnapshot?.subagentTypes).toEqual([])
    expect(setup.runtime.session.subagents.find(value => value.agentId === spawned.agent_id)).toMatchObject({
      definition: { name: "reviewer" }
    })
  } finally {
    setup.runtime.session.dispose()
    await setup.runtime.session.waitForIdle()
    await rm(root, { recursive: true, force: true })
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
    settings: options.subagentsEnabled === undefined ? {} : { subagentsEnabled: options.subagentsEnabled },
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

async function writeDefinitionExtension(path: string, crash = false): Promise<void> {
  await writeFile(
    path,
    `export default zi => {\n  zi.registerSubagentType({ name: "reviewer", description: "Review changes", instructions: "Review without editing." })\n  ${crash ? "setTimeout(() => process.exit(19), 1000)" : ""}\n}\n`
  )
}

async function waitFor(predicate: () => boolean, timeoutMs: number): Promise<void> {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    if (predicate()) return
    // oxlint-disable-next-line no-await-in-loop -- bounded process-state observation
    await Bun.sleep(20)
  }
  throw new Error("condition not met before deadline")
}

interface ModelToolCatalog {
  readonly typeDescription: string
  readonly codeDescription: string
}

function modelToolCatalog(context: Context): ModelToolCatalog {
  const spawn = context.tools?.find(tool => tool.name === "spawn_subagent")
  const code = context.tools?.find(tool => tool.name === "code")
  if (!spawn || !code) throw new Error("Expected native subagent and Code Mode tools")
  const properties = recordProperty(spawn.parameters, "properties")
  const type = recordProperty(properties, "type")
  const description = recordProperty(type, "description")
  if (typeof description !== "string") throw new Error("Expected spawn_subagent type description")
  return { typeDescription: description, codeDescription: code.description }
}

function recordProperty(value: unknown, property: string): unknown {
  if (typeof value !== "object" || value === null || Array.isArray(value)) throw new Error("Expected record")
  return Reflect.get(value, property)
}

function parseAgentId(text: string): { readonly agent_id: string } {
  const value: unknown = JSON.parse(text)
  if (typeof value !== "object" || value === null || Array.isArray(value)) throw new Error("Expected object")
  const agentId = Reflect.get(value, "agent_id")
  if (typeof agentId !== "string" || agentId.length === 0) throw new Error("Expected agent_id")
  return { agent_id: agentId }
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
