import { expect, test } from "bun:test"
import { readFileSync } from "node:fs"
import { mkdir, mkdtemp, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join, resolve } from "node:path"

import { ZiPaths } from "../src/paths.js"
import { SessionManager } from "../src/session-manager.js"
import { SubagentSupervisor } from "../src/subagents/supervisor.js"

const mockChild = resolve(import.meta.dir, "fixtures/mock-rpc-child.ts")

test("SubagentSupervisor spawns, durably publishes completion, waits, and closes", async () => {
  const harness = await createHarness("vertical-slice", { reply: "supervisor-ok", delayMs: 20 })
  try {
    const agentId = await harness.supervisor.spawn("inspect the project", undefined)
    expect(harness.supervisor.snapshots()).toHaveLength(1)
    expect(harness.supervisor.snapshots()[0]).toMatchObject({
      agentId,
      lifecycle: "running",
      definition: { name: "general" },
      workCycle: 1,
      sessionId: "mock-child-session"
    })
    expect(harness.supervisor.status()).toEqual({ workingAgentIds: [agentId], readyAgentIds: [] })

    await waitFor(() => harness.supervisor.completionNotice() !== undefined, 5_000)
    expect(harness.supervisor.status()).toEqual({ workingAgentIds: [], readyAgentIds: [agentId] })
    expect(harness.supervisor.completionNotice()).toBe(
      `Subagents completed: ${agentId}. Call wait_subagents for their output.`
    )
    expect(harness.sessionManager.subagentEntries().at(-1)).toMatchObject({
      event: "work_cycle_finished",
      agentId,
      workCycle: 1,
      status: "completed",
      preview: "supervisor-ok"
    })

    const deliveryEvents: string[] = []
    const unsubscribe = harness.supervisor.subscribe(event => {
      if (event.type === "changed") deliveryEvents.push(event.agentId)
    })
    const waited = await harness.supervisor.wait([agentId], 5_000)
    unsubscribe()
    expect(waited).toHaveLength(1)
    expect(deliveryEvents).toContain(agentId)
    expect(waited[0]).toMatchObject({
      agentId,
      lifecycle: "idle",
      completionDelivery: "durable",
      completion: { status: "completed", text: "supervisor-ok", workCycle: 1 }
    })
    expect(harness.supervisor.snapshots()[0]).toMatchObject({ completionDelivery: "delivered" })
    expect(harness.supervisor.status()).toEqual({ workingAgentIds: [], readyAgentIds: [] })
    expect(harness.supervisor.completionNotice()).toBeUndefined()

    await harness.supervisor.close(agentId)
    expect(harness.supervisor.snapshots()[0]).toMatchObject({ agentId, lifecycle: "exited" })
    expect(harness.sessionManager.subagentEntries().at(-1)).toMatchObject({ event: "exited", agentId })
  } finally {
    await harness.dispose()
  }
}, 15_000)

test("spawn cancellation before admission closes the starting child", async () => {
  const harness = await createHarness("startup-cancel", { delayMs: 300 })
  try {
    const controller = new AbortController()
    controller.abort()
    expect(harness.supervisor.spawn("cancel", undefined, controller.signal)).rejects.toThrow("was cancelled")
    await waitFor(() => harness.supervisor.snapshots()[0]?.lifecycle === "exited", 5_000)
  } finally {
    await harness.dispose()
  }
}, 15_000)

test("spawn cancellation ends at background ownership transfer", async () => {
  const harness = await createHarness("ownership-transfer", { delayMs: 300 })
  try {
    const controller = new AbortController()
    const agentId = await harness.supervisor.spawn("background work", undefined, controller.signal)
    controller.abort()
    expect(harness.supervisor.snapshots()[0]).toMatchObject({ agentId, lifecycle: "running" })
    const waited = await harness.supervisor.wait([agentId], 5_000)
    expect(waited[0]).toMatchObject({ lifecycle: "idle", completion: { status: "completed" } })
  } finally {
    await harness.dispose()
  }
}, 15_000)

test("SubagentSupervisor keeps queue-only send idle and continue extends the current cycle", async () => {
  const harness = await createHarness("delivery", { reply: "delivery-ok", delayMs: 250 })
  try {
    const agentId = await harness.supervisor.spawn("first cycle", undefined)
    await harness.supervisor.wait([agentId], 5_000)
    expect(harness.supervisor.snapshots()[0]).toMatchObject({ lifecycle: "idle", workCycle: 1 })

    await harness.supervisor.send(agentId, "queue without waking")
    expect(harness.supervisor.snapshots()[0]).toMatchObject({ lifecycle: "idle", workCycle: 1 })

    await harness.supervisor.continue(agentId, "wake second cycle")
    expect(harness.supervisor.snapshots()[0]).toMatchObject({ lifecycle: "running", workCycle: 2 })
    await harness.supervisor.continue(agentId, "extend second cycle")

    const waited = await harness.supervisor.wait([agentId], 5_000)
    expect(waited[0]).toMatchObject({
      lifecycle: "idle",
      workCycle: 2,
      completion: { status: "completed", text: "delivery-ok", workCycle: 2 }
    })
    expect(
      harness.sessionManager
        .subagentEntries()
        .filter(entry => entry.event === "work_cycle_started")
        .map(entry => entry.workCycle)
    ).toEqual([1, 2])
  } finally {
    await harness.dispose()
  }
}, 15_000)

test("ready results remain visible while the same child starts another cycle", async () => {
  const harness = await createHarness("ready-while-working", { reply: "cycle-ok", delayMs: 200 })
  try {
    const agentId = await harness.supervisor.spawn("first cycle", undefined)
    await waitFor(() => harness.supervisor.status().readyAgentIds.length === 1, 5_000)

    await harness.supervisor.continue(agentId, "second cycle")
    expect(harness.supervisor.status()).toEqual({ workingAgentIds: [agentId], readyAgentIds: [agentId] })

    await harness.supervisor.wait([agentId], 5_000)
    expect(harness.supervisor.status()).toEqual({ workingAgentIds: [], readyAgentIds: [] })
  } finally {
    await harness.dispose()
  }
}, 15_000)

test("closing new work synthesizes its failure even when an earlier result remains ready", async () => {
  const harness = await createHarness("close-new-cycle", { reply: "cycle-ok", delayMs: 300 })
  try {
    const agentId = await harness.supervisor.spawn("first cycle", undefined)
    await waitFor(() => harness.supervisor.status().readyAgentIds.length === 1, 5_000)

    await harness.supervisor.continue(agentId, "second cycle")
    await harness.supervisor.close(agentId)

    expect(harness.supervisor.snapshots()[0]).toMatchObject({
      lifecycle: "exited",
      completionDelivery: "durable",
      completion: { workCycle: 2, status: "failed", reason: "child_exited" }
    })
  } finally {
    await harness.dispose()
  }
}, 15_000)

test("SubagentSupervisor interrupts a child and reuses it for another cycle", async () => {
  const harness = await createHarness("interrupt", { reply: "reused-ok", delayMs: 250 })
  try {
    const agentId = await harness.supervisor.spawn("long first cycle", undefined)
    expect(await harness.supervisor.interrupt(agentId)).toBe("interrupted")

    const interrupted = await harness.supervisor.wait([agentId], 5_000)
    expect(interrupted[0]).toMatchObject({
      lifecycle: "idle",
      workCycle: 1,
      completion: { status: "cancelled", workCycle: 1 }
    })

    await harness.supervisor.continue(agentId, "reuse child")
    const reused = await harness.supervisor.wait([agentId], 5_000)
    expect(reused[0]).toMatchObject({
      lifecycle: "idle",
      workCycle: 2,
      completion: { status: "completed", text: "reused-ok", workCycle: 2 }
    })
  } finally {
    await harness.dispose()
  }
}, 15_000)

test("SubagentSupervisor admits four live children and rejects a fifth", async () => {
  const harness = await createHarness("capacity", { delayMs: 20 })
  try {
    const agentIds: string[] = []
    for (let index = 0; index < 4; index++) {
      // oxlint-disable-next-line no-await-in-loop -- capacity is admitted one child at a time
      agentIds.push(await harness.supervisor.spawn(`task ${index}`, undefined))
    }

    expect(new Set(agentIds).size).toBe(4)
    expect(harness.supervisor.snapshots()).toHaveLength(4)
    expect(harness.supervisor.spawn("one too many", undefined)).rejects.toThrow(
      "Subagent capacity exceeded: at most 4 live children"
    )
  } finally {
    await harness.dispose()
  }
}, 15_000)

test("SubagentSupervisor recovers journal evidence without recreating a process", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-subagent-recovery-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "agent"))
  await mkdir(paths.cwd, { recursive: true })
  const sessionManager = SessionManager.create(paths, { persist: false })
  sessionManager.appendSubagent({ event: "starting", agentId: "orphaned-agent", definitionName: "general" })

  const supervisor = new SubagentSupervisor({
    command: [join(root, "must-not-be-executed")],
    cwd: paths.cwd,
    env: {},
    selection: () => ({ model: "faux/faux-1", thinkingLevel: "off" }),
    sessionManager
  })
  try {
    expect(supervisor.runningCount()).toBe(0)
    expect(supervisor.snapshots()).toEqual([
      expect.objectContaining({
        agentId: "orphaned-agent",
        lifecycle: "exited",
        definition: expect.objectContaining({ name: "general" })
      })
    ])
    expect(sessionManager.subagentEntries().map(entry => entry.event)).toEqual(["starting", "lost"])
    expect(sessionManager.subagentEntries().at(-1)).toMatchObject({
      event: "lost",
      agentId: "orphaned-agent",
      reason: "session_restored"
    })
  } finally {
    await supervisor.shutdown()
    await rm(root, { recursive: true, force: true })
  }
})

test("recovered completion and exited projections stay bounded", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-subagent-recovery-bounds-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "agent"))
  await mkdir(paths.cwd, { recursive: true })
  const sessionManager = SessionManager.create(paths, { persist: false })
  for (let index = 0; index < 40; index++) {
    const agentId = `agent-${index}`
    sessionManager.appendSubagent({ event: "starting", agentId, definitionName: "general" })
    sessionManager.appendSubagent({ event: "work_cycle_started", agentId, workCycle: 1 })
    sessionManager.appendSubagent({
      event: "work_cycle_finished",
      agentId,
      workCycle: 1,
      status: "completed",
      preview: `result-${index}`,
      originalBytes: 9,
      omittedBytes: 0,
      truncated: false,
      durationMs: 1
    })
  }
  const supervisor = new SubagentSupervisor({
    command: [join(root, "unused")],
    cwd: paths.cwd,
    env: {},
    selection: () => ({ model: "faux/faux-1", thinkingLevel: "off" }),
    sessionManager
  })
  try {
    expect(supervisor.snapshots()).toHaveLength(32)
    expect(supervisor.snapshots()[0]?.agentId).toBe("agent-8")
    expect(supervisor.completionNotice()?.split(",").length).toBeLessThanOrEqual(16)
    expect(supervisor.spawn("no capacity", undefined)).rejects.toThrow("Subagent completion capacity exceeded")
    expect(await supervisor.wait(["agent-39"], 0)).toMatchObject([
      { completion: { text: "result-39" }, completionDelivery: "durable" }
    ])
  } finally {
    await supervisor.shutdown()
    await rm(root, { recursive: true, force: true })
  }
})

test("SubagentSupervisor resolves the parent's current model selection at spawn", async () => {
  const argvPath = join(tmpdir(), `zi-subagent-selection-${crypto.randomUUID()}.json`)
  let model = "faux/current"
  let thinkingLevel: "off" | "high" = "off"
  const harness = await createHarness("selection", {
    argvPath,
    selection: () => ({ model, thinkingLevel, apiKey: "ephemeral-key" })
  })
  try {
    model = "faux/changed"
    thinkingLevel = "high"
    const agentId = await harness.supervisor.spawn("inspect selection", undefined)
    const argv: unknown = JSON.parse(readFileSync(argvPath, "utf8"))
    expect(argv).toEqual(
      expect.arrayContaining(["--model", "faux/changed", "--api-key", "ephemeral-key", "--thinking", "high"])
    )
    await harness.supervisor.close(agentId)
  } finally {
    await harness.dispose()
    await rm(argvPath, { force: true })
  }
}, 15_000)

test("SubagentSupervisor shutdown preempts a blocked serialized child command", async () => {
  const harness = await createHarness("shutdown-blocked-command", { delayMs: 1_000 })
  try {
    const agentId = await harness.supervisor.spawn("start", undefined)
    const blocked = harness.supervisor.send(agentId, "__block_prompt__").then(
      () => "fulfilled" as const,
      () => "rejected" as const
    )
    await Bun.sleep(50)

    await harness.supervisor.shutdown()

    expect(harness.supervisor.state).toEqual({ type: "closed" })
    expect(await blocked).toBe("rejected")
    expect(harness.supervisor.snapshots()[0]).toMatchObject({ agentId, lifecycle: "exited" })
  } finally {
    await harness.dispose()
  }
}, 15_000)

test("SubagentSupervisor shutdown disposes its live children and descendants and closes admission", async () => {
  const harness = await createHarness("shutdown", { delayMs: 400, descendant: true })
  try {
    const agentId = await harness.supervisor.spawn("keep working", undefined)
    expect(harness.supervisor.snapshots()[0]).toMatchObject({ agentId, lifecycle: "running" })
    const descendantPid = await readPid(harness.descendantMarker!)
    expect(processAlive(descendantPid)).toBe(true)

    await harness.supervisor.shutdown()
    await waitFor(() => !processAlive(descendantPid), 5_000)

    expect(harness.supervisor.state).toEqual({ type: "closed" })
    expect(harness.supervisor.snapshots()[0]).toMatchObject({ agentId, lifecycle: "exited" })
    expect(harness.sessionManager.subagentEntries().some(entry => entry.event === "closing")).toBe(true)
    expect(harness.sessionManager.subagentEntries().at(-1)).toMatchObject({ event: "exited", agentId })
    expect(harness.supervisor.spawn("too late", undefined)).rejects.toThrow("Subagent supervisor is closed")
  } finally {
    await harness.dispose()
  }
}, 15_000)

async function createHarness(
  name: string,
  options: {
    readonly reply?: string
    readonly delayMs?: number
    readonly descendant?: boolean
    readonly argvPath?: string
    readonly selection?: () => { readonly model: string; readonly thinkingLevel: "off" | "high" }
  } = {}
): Promise<{
  readonly supervisor: SubagentSupervisor
  readonly sessionManager: SessionManager
  readonly descendantMarker?: string
  dispose(): Promise<void>
}> {
  const root = await mkdtemp(join(tmpdir(), `zi-subagent-${name}-`))
  const paths = new ZiPaths(join(root, "project"), join(root, "agent"))
  await mkdir(paths.cwd, { recursive: true })
  const sessionManager = SessionManager.create(paths, { persist: false })
  const descendantMarker = options.descendant ? join(root, "descendant.pid") : undefined
  const supervisor = new SubagentSupervisor({
    command: [process.execPath, mockChild],
    cwd: paths.cwd,
    env: {
      ...process.env,
      MOCK_RPC_REPLY: options.reply ?? "child-done",
      MOCK_RPC_DELAY_MS: String(options.delayMs ?? 30),
      ...(descendantMarker ? { MOCK_RPC_DESCENDANT_PID: descendantMarker } : {}),
      ...(options.argvPath ? { MOCK_RPC_ARGV: options.argvPath } : {})
    },
    selection: options.selection ?? (() => ({ model: "faux/faux-1", thinkingLevel: "off" })),
    sessionManager
  })
  return {
    supervisor,
    sessionManager,
    ...(descendantMarker ? { descendantMarker } : {}),
    async dispose() {
      await supervisor.shutdown()
      await rm(root, { recursive: true, force: true })
    }
  }
}

async function readPid(path: string): Promise<number> {
  let value = 0
  await waitFor(() => {
    try {
      value = Number(readFileSync(path, "utf8"))
      return Number.isInteger(value) && value > 0
    } catch {
      return false
    }
  }, 5_000)
  return value
}

function processAlive(pid: number): boolean {
  try {
    process.kill(pid, 0)
    return true
  } catch {
    return false
  }
}

async function waitFor(predicate: () => boolean, timeoutMs: number): Promise<void> {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    if (predicate()) return
    // oxlint-disable-next-line no-await-in-loop -- bounded poll of public supervisor state
    await Bun.sleep(15)
  }
  throw new Error("condition not met before deadline")
}
