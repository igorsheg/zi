import { expect, test } from "bun:test"
import { readFileSync } from "node:fs"
import { mkdir, mkdtemp, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join, resolve } from "node:path"

import { ZiPaths } from "../src/paths.js"
import { createProcessTreeTracker } from "../src/processes/process-tree.js"
import { SessionManager } from "../src/session-manager.js"
import { SubagentSupervisor } from "../src/subagents/supervisor.js"

const mockChild = resolve(import.meta.dir, "fixtures/mock-rpc-child.ts")

test("SubagentSupervisor spawns, durably publishes completion, waits, and closes", async () => {
  const harness = await createHarness("vertical-slice", { reply: "supervisor-ok", delayMs: 20 })
  try {
    const name = await harness.supervisor.spawn("project-inspector", "inspect the project")
    expect(name).toBe("project-inspector")
    expect(harness.supervisor.snapshots()).toHaveLength(1)
    expect(harness.supervisor.snapshots()[0]).toMatchObject({
      name,
      lifecycle: "running",
      workCycle: 1,
      sessionId: "mock-child-session"
    })
    expect(harness.supervisor.status()).toEqual({ workingNames: [name], readyNames: [] })

    await waitFor(() => harness.supervisor.status().readyNames.length > 0, 5_000)
    expect(harness.supervisor.status()).toEqual({ workingNames: [], readyNames: [name] })
    expect(harness.sessionManager.subagentEntries().at(-1)).toMatchObject({
      event: "work_cycle_finished",
      name,
      workCycle: 1,
      status: "completed",
      preview: "supervisor-ok"
    })

    const deliveryEvents: string[] = []
    const unsubscribe = harness.supervisor.subscribe(event => {
      if (event.type === "changed") deliveryEvents.push(event.name)
    })
    const waited = await harness.supervisor.wait([name], 5_000)
    unsubscribe()
    expect(waited).toHaveLength(1)
    expect(deliveryEvents).toContain(name)
    expect(waited[0]).toMatchObject({
      name,
      lifecycle: "idle",
      completionDelivery: "durable",
      completion: { status: "completed", text: "supervisor-ok", workCycle: 1 }
    })
    expect(harness.supervisor.snapshots()[0]).toMatchObject({ completionDelivery: "delivered" })
    expect(harness.supervisor.status()).toEqual({ workingNames: [], readyNames: [] })

    await harness.supervisor.close(name)
    expect(harness.supervisor.snapshots()[0]).toMatchObject({ name, lifecycle: "exited" })
    expect(harness.sessionManager.subagentEntries().at(-1)).toMatchObject({ event: "exited", name })
  } finally {
    await harness.dispose()
  }
}, 15_000)

test("wait holds until every requested subagent has completed", async () => {
  const harness = await createHarness("wait-all", { delayMs: 120 })
  try {
    const first = await harness.supervisor.spawn("first-worker", "first")
    await harness.supervisor.wait([first], 5_000)
    const second = await harness.supervisor.spawn("second-worker", "second")

    const waited = await harness.supervisor.wait([first, second], 5_000)

    expect(waited).toEqual([
      expect.objectContaining({ name: first, completion: expect.objectContaining({ status: "completed" }) }),
      expect.objectContaining({ name: second, completion: expect.objectContaining({ status: "completed" }) })
    ])
  } finally {
    await harness.dispose()
  }
}, 15_000)

test("spawn cancellation before admission closes the starting child", async () => {
  const harness = await createHarness("startup-cancel", { delayMs: 300 })
  try {
    const controller = new AbortController()
    controller.abort()
    expect(harness.supervisor.spawn("cancelled-child", "cancel", controller.signal)).rejects.toThrow("was cancelled")
    await waitFor(() => harness.supervisor.snapshots()[0]?.lifecycle === "exited", 5_000)
  } finally {
    await harness.dispose()
  }
}, 15_000)

test("spawn cancellation ends at background ownership transfer", async () => {
  const harness = await createHarness("ownership-transfer", { delayMs: 300 })
  try {
    const controller = new AbortController()
    const name = await harness.supervisor.spawn("background-worker", "background work", controller.signal)
    controller.abort()
    expect(harness.supervisor.snapshots()[0]).toMatchObject({ name, lifecycle: "running" })
    const waited = await harness.supervisor.wait([name], 5_000)
    expect(waited[0]).toMatchObject({ lifecycle: "idle", completion: { status: "completed" } })
  } finally {
    await harness.dispose()
  }
}, 15_000)

test("SubagentSupervisor keeps queue-only send idle and continue extends the current cycle", async () => {
  const harness = await createHarness("delivery", { reply: "delivery-ok", delayMs: 250 })
  try {
    const name = await harness.supervisor.spawn("cycle-worker", "first cycle")
    await harness.supervisor.wait([name], 5_000)
    expect(harness.supervisor.snapshots()[0]).toMatchObject({ lifecycle: "idle", workCycle: 1 })

    await harness.supervisor.send(name, "queue without waking")
    expect(harness.supervisor.snapshots()[0]).toMatchObject({ lifecycle: "idle", workCycle: 1 })

    await harness.supervisor.continue(name, "wake second cycle")
    expect(harness.supervisor.snapshots()[0]).toMatchObject({ lifecycle: "running", workCycle: 2 })
    await harness.supervisor.continue(name, "extend second cycle")

    const waited = await harness.supervisor.wait([name], 5_000)
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
    const name = await harness.supervisor.spawn("cycle-worker", "first cycle")
    await waitFor(() => harness.supervisor.status().readyNames.length === 1, 5_000)

    await harness.supervisor.continue(name, "second cycle")
    expect(harness.supervisor.status()).toEqual({ workingNames: [name], readyNames: [name] })

    await harness.supervisor.wait([name], 5_000)
    expect(harness.supervisor.status()).toEqual({ workingNames: [], readyNames: [] })
  } finally {
    await harness.dispose()
  }
}, 15_000)

test("closing new work synthesizes its failure even when an earlier result remains ready", async () => {
  const harness = await createHarness("close-new-cycle", { reply: "cycle-ok", delayMs: 300 })
  try {
    const name = await harness.supervisor.spawn("cycle-worker", "first cycle")
    await waitFor(() => harness.supervisor.status().readyNames.length === 1, 5_000)

    await harness.supervisor.continue(name, "second cycle")
    await harness.supervisor.close(name)

    expect(harness.supervisor.snapshots()[0]).toMatchObject({
      lifecycle: "exited",
      completionDelivery: "durable",
      completion: { workCycle: 2, status: "failed", reason: "child_exited" }
    })
  } finally {
    await harness.dispose()
  }
}, 15_000)

test("SubagentSupervisor publishes bounded actionable diagnostics when a child protocol fails", async () => {
  const harness = await createHarness("protocol-failure", { delayMs: 1_000, protocolCrash: true })
  try {
    const name = await harness.supervisor.spawn("protocol-worker", "start work")
    const waited = await harness.supervisor.wait([name], 5_000)
    expect(waited[0]).toMatchObject({
      lifecycle: "exited",
      completion: { status: "failed", reason: "child_failed", error: "Subagent RPC emitted invalid JSONL" }
    })
    expect(harness.sessionManager.subagentEntries().at(-2)).toMatchObject({
      event: "work_cycle_finished",
      status: "failed",
      reason: "child_failed",
      error: "Subagent RPC emitted invalid JSONL"
    })
  } finally {
    await harness.dispose()
  }
}, 15_000)

test("SubagentSupervisor interrupts a child and reuses it for another cycle", async () => {
  const harness = await createHarness("interrupt", { reply: "reused-ok", delayMs: 250 })
  try {
    const name = await harness.supervisor.spawn("reusable-worker", "long first cycle")
    expect(await harness.supervisor.interrupt(name)).toBe("interrupted")

    const interrupted = await harness.supervisor.wait([name], 5_000)
    expect(interrupted[0]).toMatchObject({
      lifecycle: "idle",
      workCycle: 1,
      completion: { status: "cancelled", workCycle: 1 }
    })

    await harness.supervisor.continue(name, "reuse child")
    const reused = await harness.supervisor.wait([name], 5_000)
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
    expect(harness.supervisor.capacity()).toEqual({ live: 0, maximum: 4 })
    const names: string[] = []
    for (let index = 0; index < 4; index++) {
      // oxlint-disable-next-line no-await-in-loop -- capacity is admitted one child at a time
      names.push(await harness.supervisor.spawn(`worker-${index}`, `task ${index}`))
    }

    expect(new Set(names).size).toBe(4)
    expect(harness.supervisor.snapshots()).toHaveLength(4)
    expect(harness.supervisor.capacity()).toEqual({ live: 4, maximum: 4 })
    expect(harness.supervisor.spawn("extra-worker", "one too many")).rejects.toThrow(
      "Subagent capacity exceeded: at most 4 live children"
    )
    await harness.supervisor.close(names[0]!)
    expect(harness.supervisor.capacity()).toEqual({ live: 3, maximum: 4 })
  } finally {
    await harness.dispose()
  }
}, 15_000)

test("SubagentSupervisor validates names and keeps them unique for the parent session", async () => {
  const harness = await createHarness("names", { delayMs: 20 })
  try {
    for (const name of ["", "Uppercase", "two words", "1worker", "worker/path", "éclair", `a${"x".repeat(64)}`]) {
      expect(harness.supervisor.spawn(name, "invalid name")).rejects.toThrow("Subagent name")
    }
    expect(harness.sessionManager.subagentEntries()).toEqual([])

    const name = await harness.supervisor.spawn("unique-worker", "first task")
    await harness.supervisor.close(name)
    expect(harness.supervisor.spawn("unique-worker", "second task")).rejects.toThrow(
      "Subagent name already in use: unique-worker"
    )
    expect(harness.sessionManager.subagentEntries().filter(entry => entry.event === "starting")).toHaveLength(1)
  } finally {
    await harness.dispose()
  }
}, 15_000)

test("SubagentSupervisor recovers journal evidence without recreating a process", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-subagent-recovery-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "agent"))
  await mkdir(paths.cwd, { recursive: true })
  const sessionManager = SessionManager.create(paths, { persist: false })
  sessionManager.appendSubagent({ event: "starting", name: "orphaned-worker" })

  const supervisor = new SubagentSupervisor({
    command: [join(root, "must-not-be-executed")],
    cwd: paths.cwd,
    env: {},
    selection: () => ({ model: "faux/faux-1", thinkingLevel: "off" }),
    sessionManager,
    processTreeTracker: createProcessTreeTracker()
  })
  try {
    expect(supervisor.runningCount()).toBe(0)
    expect(supervisor.snapshots()).toEqual([expect.objectContaining({ name: "orphaned-worker", lifecycle: "exited" })])
    expect(sessionManager.subagentEntries().map(entry => entry.event)).toEqual(["starting", "lost"])
    expect(sessionManager.subagentEntries().at(-1)).toMatchObject({
      event: "lost",
      name: "orphaned-worker",
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
    const workerName = `worker-${index}`
    sessionManager.appendSubagent({ event: "starting", name: workerName })
    sessionManager.appendSubagent({ event: "work_cycle_started", name: workerName, workCycle: 1 })
    sessionManager.appendSubagent({
      event: "work_cycle_finished",
      name: workerName,
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
    sessionManager,
    processTreeTracker: createProcessTreeTracker()
  })
  try {
    expect(supervisor.snapshots()).toHaveLength(32)
    expect(supervisor.snapshots()[0]?.name).toBe("worker-8")
    expect(supervisor.spawn("worker-0", "duplicate evicted child")).rejects.toThrow(
      "Subagent name already in use: worker-0"
    )
    expect(supervisor.spawn("no-capacity", "no capacity")).rejects.toThrow("Subagent completion capacity exceeded")
    expect(await supervisor.wait(["worker-39"], 0)).toMatchObject([
      { completion: { text: "result-39" }, completionDelivery: "durable" }
    ])
  } finally {
    await supervisor.shutdown()
    await rm(root, { recursive: true, force: true })
  }
})

test("SubagentSupervisor resolves the parent's current model selection without exposing its credential in argv", async () => {
  const argvPath = join(tmpdir(), `zi-subagent-selection-${crypto.randomUUID()}.json`)
  const apiKeyPath = join(tmpdir(), `zi-subagent-api-key-${crypto.randomUUID()}.txt`)
  let model = "faux/current"
  let thinkingLevel: "off" | "high" = "off"
  const harness = await createHarness("selection", {
    argvPath,
    apiKeyPath,
    selection: () => ({ model, thinkingLevel, apiKey: "ephemeral-key" })
  })
  try {
    model = "faux/changed"
    thinkingLevel = "high"
    const name = await harness.supervisor.spawn("selection-inspector", "inspect selection")
    const argv: unknown = JSON.parse(readFileSync(argvPath, "utf8"))
    expect(argv).toEqual(expect.arrayContaining(["--model", "faux/changed", "--thinking", "high"]))
    expect(argv).not.toContain("--api-key")
    expect(argv).not.toContain("ephemeral-key")
    expect(readFileSync(apiKeyPath, "utf8")).toBe("ephemeral-key")
    await harness.supervisor.close(name)
  } finally {
    await harness.dispose()
    await Promise.all([rm(argvPath, { force: true }), rm(apiKeyPath, { force: true })])
  }
}, 15_000)

test("SubagentSupervisor shutdown preempts a blocked serialized child command", async () => {
  const harness = await createHarness("shutdown-blocked-command", { delayMs: 1_000 })
  try {
    const name = await harness.supervisor.spawn("blocked-worker", "start")
    const blocked = harness.supervisor.send(name, "__block_prompt__").then(
      () => "fulfilled" as const,
      () => "rejected" as const
    )
    await Bun.sleep(50)

    await harness.supervisor.shutdown()

    expect(harness.supervisor.state).toEqual({ type: "closed" })
    expect(await blocked).toBe("rejected")
    expect(harness.supervisor.snapshots()[0]).toMatchObject({ name, lifecycle: "exited" })
  } finally {
    await harness.dispose()
  }
}, 15_000)

test("SubagentSupervisor shutdown disposes its live children and descendants and closes admission", async () => {
  const harness = await createHarness("shutdown", { delayMs: 400, descendant: true })
  try {
    const name = await harness.supervisor.spawn("shutdown-worker", "keep working")
    expect(harness.supervisor.snapshots()[0]).toMatchObject({ name, lifecycle: "running" })
    const descendantPid = await readPid(harness.descendantMarker!)
    expect(processAlive(descendantPid)).toBe(true)

    await harness.supervisor.shutdown()
    await waitFor(() => !processAlive(descendantPid), 5_000)

    expect(harness.supervisor.state).toEqual({ type: "closed" })
    expect(harness.supervisor.snapshots()[0]).toMatchObject({ name, lifecycle: "exited" })
    expect(harness.sessionManager.subagentEntries().some(entry => entry.event === "closing")).toBe(true)
    expect(harness.sessionManager.subagentEntries().at(-1)).toMatchObject({ event: "exited", name })
    expect(harness.supervisor.spawn("late-worker", "too late")).rejects.toThrow("Subagent supervisor is closed")
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
    readonly apiKeyPath?: string
    readonly protocolCrash?: boolean
    readonly selection?: () => {
      readonly model: string
      readonly thinkingLevel: "off" | "high"
      readonly apiKey?: string
    }
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
      ...(options.argvPath ? { MOCK_RPC_ARGV: options.argvPath } : {}),
      ...(options.apiKeyPath ? { MOCK_RPC_INTERNAL_API_KEY: options.apiKeyPath } : {}),
      ...(options.protocolCrash ? { MOCK_RPC_PROTOCOL_CRASH: "1" } : {})
    },
    selection: options.selection ?? (() => ({ model: "faux/faux-1", thinkingLevel: "off" })),
    sessionManager,
    processTreeTracker: createProcessTreeTracker()
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
