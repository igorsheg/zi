import { expect, test } from "bun:test"
import { mkdir, mkdtemp, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join, resolve } from "node:path"

import { createProcessTreeTracker } from "../src/processes/process-tree.js"
import { SessionManager } from "../src/session-manager.js"
import { maxWaitTimeoutMs, SubagentSupervisor } from "../src/subagents/supervisor.js"
import { isSubagentToolDetails } from "../src/subagents/tool-details.js"
import { createSubagentTools, maxWaitResultBytes } from "../src/subagents/tools.js"

const mockChild = resolve(import.meta.dir, "fixtures/mock-rpc-child.ts")

test("spawn_subagent requires a model-authored name and exposes no type selector", async () => {
  const supervisor = new SubagentSupervisor({
    command: [process.execPath],
    cwd: "/work",
    env: {},
    selection: () => ({ model: "faux/faux-1", thinkingLevel: "off" }),
    sessionManager: SessionManager.inMemory("/work"),
    processTreeTracker: createProcessTreeTracker()
  })
  try {
    const spawn = createSubagentTools(supervisor).find(tool => tool.name === "spawn_subagent")
    if (!spawn) throw new Error("Expected spawn_subagent")

    const required: unknown = Reflect.get(spawn.parameters, "required")
    const properties: unknown = Reflect.get(spawn.parameters, "properties")
    if (typeof properties !== "object" || properties === null || Array.isArray(properties)) {
      throw new Error("Expected spawn properties")
    }
    const name: unknown = Reflect.get(properties, "name")
    if (typeof name !== "object" || name === null || Array.isArray(name)) throw new Error("Expected name schema")
    expect(required).toEqual(["name", "prompt"])
    expect(Reflect.get(name, "pattern")).toBe("^[a-z][a-z0-9_-]*$")
    expect(Reflect.get(name, "description")).toContain("Unique short name")
    expect(Object.hasOwn(properties, "type")).toBe(false)

    for (const toolName of ["send_subagent", "continue_subagent", "interrupt_subagent", "close_subagent"]) {
      const tool = createSubagentTools(supervisor).find(candidate => candidate.name === toolName)
      if (!tool) throw new Error(`Expected ${toolName}`)
      const toolProperties: unknown = Reflect.get(tool.parameters, "properties")
      expect(toolProperties).toHaveProperty("name")
      expect(toolProperties).not.toHaveProperty("agent_id")
    }
    const wait = createSubagentTools(supervisor).find(tool => tool.name === "wait_subagents")
    if (!wait) throw new Error("Expected wait_subagents")
    const waitProperties: unknown = Reflect.get(wait.parameters, "properties")
    if (typeof waitProperties !== "object" || waitProperties === null || Array.isArray(waitProperties)) {
      throw new Error("Expected wait properties")
    }
    expect(waitProperties).toHaveProperty("names")
    expect(waitProperties).not.toHaveProperty("agent_ids")
    const timeout: unknown = Reflect.get(waitProperties, "timeout_ms")
    if (typeof timeout !== "object" || timeout === null || Array.isArray(timeout)) {
      throw new Error("Expected timeout schema")
    }
    expect(Reflect.get(timeout, "maximum")).toBe(maxWaitTimeoutMs)
  } finally {
    await supervisor.shutdown()
  }
})

test("list_subagents separates current status from undelivered result readiness", async () => {
  const harness = await createHarness("list-projection", "private completion body")
  try {
    const name = await harness.supervisor.spawn("inspector", "inspect")
    await waitFor(() => harness.supervisor.completionNotice() !== undefined, 5_000)
    const list = createSubagentTools(harness.supervisor).find(tool => tool.name === "list_subagents")
    if (!list) throw new Error("Expected list_subagents")

    const ready = await list.execute("list-ready", {}, undefined)
    expect(JSON.parse(resultText(ready))).toEqual({
      agents: [{ name, status: "idle", result_ready: { status: "completed" } }]
    })
    expect(resultText(ready)).not.toContain("private completion body")
    expect(isSubagentToolDetails(ready.details)).toBe(true)

    await harness.supervisor.wait([name], 5_000)
    const delivered = await list.execute("list-delivered", {}, undefined)
    expect(JSON.parse(resultText(delivered))).toEqual({ agents: [{ name, status: "idle" }] })
  } finally {
    await harness.dispose()
  }
}, 15_000)

test("send and continue state whether they started a child turn", async () => {
  const harness = await createHarness("delivery-intent", "done", 150)
  try {
    const name = await harness.supervisor.spawn("message-worker", "first")
    await harness.supervisor.wait([name], 5_000)
    const tools = createSubagentTools(harness.supervisor)
    const send = tools.find(tool => tool.name === "send_subagent")
    const continueTool = tools.find(tool => tool.name === "continue_subagent")
    if (!send || !continueTool) throw new Error("Expected send and continue tools")

    const sent = await send.execute("send", { name, text: "context only" }, undefined)
    expect(JSON.parse(resultText(sent))).toEqual({ name, accepted: true, started_turn: false })
    expect(harness.supervisor.snapshots()[0]?.lifecycle).toBe("idle")

    const continued = await continueTool.execute("continue", { name, text: "start work" }, undefined)
    expect(JSON.parse(resultText(continued))).toEqual({ name, accepted: true, started_turn: true })
    expect(harness.supervisor.snapshots()[0]?.lifecycle).toBe("running")
  } finally {
    await harness.dispose()
  }
}, 15_000)

test("close_subagent returns the lifecycle and completion observed before shutdown", async () => {
  const harness = await createHarness("close-status", "done")
  try {
    const name = await harness.supervisor.spawn("closable-worker", "inspect")
    await harness.supervisor.wait([name], 5_000)
    const close = createSubagentTools(harness.supervisor).find(tool => tool.name === "close_subagent")
    if (!close) throw new Error("Expected close_subagent")

    const result = await close.execute("close", { name }, undefined)

    expect(JSON.parse(resultText(result))).toEqual({
      name,
      closed: true,
      previous_status: "idle",
      previous_completion: { status: "completed" }
    })
  } finally {
    await harness.dispose()
  }
}, 15_000)

test("wait_subagents does not present a previous completion as current work", async () => {
  const harness = await createHarness("wait-current-work", "done", 150)
  try {
    const name = await harness.supervisor.spawn("reusable-worker", "first")
    await harness.supervisor.wait([name], 5_000)
    await harness.supervisor.continue(name, "second")
    const wait = createSubagentTools(harness.supervisor).find(tool => tool.name === "wait_subagents")
    if (!wait) throw new Error("Expected wait_subagents")

    const result = await wait.execute("wait", { names: [name], timeout_ms: 0 }, undefined)

    expect(JSON.parse(resultText(result))).toEqual({
      agents: [{ name, status: "running" }],
      all_completed: false,
      omitted_bytes: 0
    })
  } finally {
    await harness.dispose()
  }
}, 15_000)

test("wait_subagents bounds aggregate result bytes and reports projection omissions", async () => {
  const reply = "界".repeat(Math.floor((40 * 1024) / 3))
  const harness = await createHarness("wait-bound", reply)
  try {
    const firstName = await harness.supervisor.spawn("first-worker", "first")
    const secondName = await harness.supervisor.spawn("second-worker", "second")
    await harness.supervisor.wait([firstName], 5_000)
    await harness.supervisor.wait([secondName], 5_000)
    const wait = createSubagentTools(harness.supervisor).find(tool => tool.name === "wait_subagents")
    if (!wait) throw new Error("Expected wait_subagents")

    const result = await wait.execute("wait", { names: [firstName, secondName], timeout_ms: 0 }, undefined)
    const text = resultText(result)
    const output = JSON.parse(text)
    expect(Buffer.byteLength(text)).toBeLessThanOrEqual(maxWaitResultBytes)
    expect(output.omitted_bytes).toBeGreaterThan(0)
    expect(output.agents.some((agent: { completion?: { truncated?: boolean } }) => agent.completion?.truncated)).toBe(
      true
    )
    expect(
      output.agents.reduce(
        (total: number, agent: { completion?: { omitted_bytes?: number } }) =>
          total + (agent.completion?.omitted_bytes ?? 0),
        0
      )
    ).toBe(output.omitted_bytes)
    expect(isSubagentToolDetails(result.details)).toBe(true)
  } finally {
    await harness.dispose()
  }
}, 15_000)

async function createHarness(name: string, reply: string, delayMs = 10) {
  const root = await mkdtemp(join(tmpdir(), `zi-subagent-tools-${name}-`))
  const cwd = join(root, "project")
  await mkdir(cwd)
  const supervisor = new SubagentSupervisor({
    command: [process.execPath, mockChild],
    cwd,
    env: { ...process.env, MOCK_RPC_REPLY: reply, MOCK_RPC_DELAY_MS: String(delayMs) },
    selection: () => ({ model: "faux/faux-1", thinkingLevel: "off" }),
    sessionManager: SessionManager.inMemory(cwd),
    processTreeTracker: createProcessTreeTracker()
  })
  return {
    supervisor,
    async dispose() {
      await supervisor.shutdown()
      await rm(root, { recursive: true, force: true })
    }
  }
}

function waitFor(predicate: () => boolean, timeoutMs: number): Promise<void> {
  const deadline = Date.now() + timeoutMs
  const poll = async (): Promise<void> => {
    if (predicate()) return
    if (Date.now() >= deadline) throw new Error(`Condition did not become true within ${timeoutMs}ms`)
    await Bun.sleep(10)
    return poll()
  }
  return poll()
}

function resultText(result: {
  readonly content: readonly { readonly type: string; readonly text?: string }[]
}): string {
  const content = result.content[0]
  if (content?.type !== "text" || content.text === undefined) throw new Error("Expected text tool result")
  return content.text
}
