import { expect, test } from "bun:test"
import { readFileSync } from "node:fs"
import { mkdtemp, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join, resolve } from "node:path"

import { createProcessTreeTracker } from "../src/processes/process-tree.js"
import { ChildZiProcess } from "../src/subagents/child-process.js"

const mockChild = resolve(import.meta.dir, "fixtures/mock-rpc-child.ts")

test("ChildZiProcess spawn/wait/close vertical slice against a mock RPC child", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-child-zi-process-"))
  const logPath = join(root, "methods.log")
  try {
    const completions: Array<{ status: string; text: string }> = []
    const child = new ChildZiProcess({
      name: "agent-1",
      command: [process.execPath, mockChild],
      cwd: root,
      processTreeTracker: createProcessTreeTracker(),
      env: { ...process.env, MOCK_RPC_REPLY: "vertical-slice-ok", MOCK_RPC_DELAY_MS: "20", MOCK_RPC_LOG: logPath },
      onCompletion(completion) {
        completions.push({ status: completion.status, text: completion.text })
      }
    })

    await child.start()
    expect(child.state.type).toBe("idle")
    expect(child.snapshot().sessionId).toBe("mock-child-session")

    await child.spawnAdmit("do the work")
    expect(child.state.type).toBe("running")

    await waitFor(() => child.state.type === "idle", 5_000)
    expect(child.state.type).toBe("idle")
    expect(completions).toEqual([{ status: "completed", text: "vertical-slice-ok" }])
    expect(child.snapshot().completion).toMatchObject({ status: "completed", text: "vertical-slice-ok", workCycle: 1 })

    await child.close("test")
    expect(child.state.type).toBe("exited")

    const methods = (await Bun.file(logPath).text()).trim().split("\n")
    expect(methods).toContain("connection.set_events")
    expect(methods).toContain("session.prompt")
    expect(methods).toContain("session.await_idle")
    expect(methods).not.toContain("session.get_messages")
  } finally {
    await rm(root, { recursive: true, force: true })
  }
}, 15_000)

test("ChildZiProcess await-idle watch outlives ordinary RPC response deadlines", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-child-await-idle-deadline-"))
  try {
    const child = new ChildZiProcess({
      name: "agent-await-idle",
      command: [process.execPath, mockChild],
      cwd: root,
      processTreeTracker: createProcessTreeTracker(),
      responseTimeoutMs: 100,
      workTimeoutMs: 1_000,
      env: { ...process.env, MOCK_RPC_DELAY_MS: "250" }
    })

    await child.start()
    await child.spawnAdmit("longer than an ordinary response")
    await waitFor(() => child.state.type === "idle", 5_000)
    expect(child.snapshot().completion).toMatchObject({ status: "completed", workCycle: 1 })
    await child.close()
  } finally {
    await rm(root, { recursive: true, force: true })
  }
}, 15_000)

test("ChildZiProcess gives each work cycle a fresh deadline and remains reusable after timeout", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-child-work-timeout-"))
  try {
    const completions: Array<{ workCycle: number; status: string; reason?: string }> = []
    const child = new ChildZiProcess({
      name: "agent-work-timeout",
      command: [process.execPath, mockChild],
      cwd: root,
      processTreeTracker: createProcessTreeTracker(),
      responseTimeoutMs: 1_000,
      workTimeoutMs: 40,
      workTimeoutSettlementMs: 500,
      env: { ...process.env, MOCK_RPC_DELAY_MS: "30000" },
      onCompletion(completion) {
        completions.push({
          workCycle: completion.workCycle,
          status: completion.status,
          ...(completion.reason ? { reason: completion.reason } : {})
        })
      }
    })

    await child.start()
    await child.spawnAdmit("first timeout")
    await waitFor(() => child.state.type === "idle", 5_000)
    await child.continueWith("second timeout")
    await waitFor(() => child.state.type === "idle", 5_000)

    expect(completions).toEqual([
      { workCycle: 1, status: "failed", reason: "work_cycle_timeout" },
      { workCycle: 2, status: "failed", reason: "work_cycle_timeout" }
    ])
    expect(child.snapshot().completion?.error).toBe("Subagent work cycle exceeded 40ms")
    await child.close()
  } finally {
    await rm(root, { recursive: true, force: true })
  }
}, 15_000)

test("ChildZiProcess force-closes work and its descendants when timeout interruption is ignored", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-child-work-timeout-force-"))
  const marker = join(root, "descendant.pid")
  let descendantPid: number | undefined
  try {
    const failures: string[] = []
    const child = new ChildZiProcess({
      name: "agent-work-timeout-force",
      command: [process.execPath, mockChild],
      cwd: root,
      processTreeTracker: createProcessTreeTracker(),
      responseTimeoutMs: 1_000,
      workTimeoutMs: 30,
      workTimeoutSettlementMs: 50,
      env: {
        ...process.env,
        MOCK_RPC_DELAY_MS: "30000",
        MOCK_RPC_IGNORE_INTERRUPT: "1",
        MOCK_RPC_DESCENDANT_PID: marker
      },
      onFatal(error) {
        failures.push(error.message)
      }
    })

    await child.start()
    descendantPid = await readPid(marker)
    expect(processAlive(descendantPid)).toBe(true)
    await child.spawnAdmit("ignore interruption")
    await waitFor(() => child.state.type === "exited", 5_000)
    await waitFor(() => !processAlive(descendantPid!), 5_000)
    expect(failures).toEqual([
      "Subagent agent-work-timeout-force work cycle 1 exceeded 30ms and did not settle within 50ms"
    ])
    expect(child.snapshot().completion).toMatchObject({ workCycle: 1, status: "failed", reason: "work_cycle_timeout" })
  } finally {
    if (descendantPid && processAlive(descendantPid)) {
      try {
        process.kill(descendantPid, "SIGKILL")
      } catch {
        // already dead
      }
    }
    await rm(root, { recursive: true, force: true })
  }
}, 15_000)

test("closing timeout settlement preserves work-cycle timeout evidence", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-child-close-timeout-settlement-"))
  try {
    const child = new ChildZiProcess({
      name: "agent-close-timeout-settlement",
      command: [process.execPath, mockChild],
      cwd: root,
      processTreeTracker: createProcessTreeTracker(),
      workTimeoutMs: 30,
      workTimeoutSettlementMs: 1_000,
      env: { ...process.env, MOCK_RPC_DELAY_MS: "30000", MOCK_RPC_IGNORE_INTERRUPT: "1" }
    })

    await child.start()
    await child.spawnAdmit("expire then close")
    await waitFor(() => child.state.type === "interrupting" && child.state.reason === "work_timeout", 5_000)
    await child.close("test", 20, 20)

    expect(child.snapshot().completion).toMatchObject({ workCycle: 1, status: "failed", reason: "work_cycle_timeout" })
  } finally {
    await rm(root, { recursive: true, force: true })
  }
}, 15_000)

test("timeout evidence survives completion-enrichment failure", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-child-timeout-enrichment-failure-"))
  try {
    const child = new ChildZiProcess({
      name: "agent-timeout-enrichment-failure",
      command: [process.execPath, mockChild],
      cwd: root,
      processTreeTracker: createProcessTreeTracker(),
      responseTimeoutMs: 60,
      workTimeoutMs: 30,
      workTimeoutSettlementMs: 500,
      env: { ...process.env, MOCK_RPC_DELAY_MS: "30000", MOCK_RPC_INVALID_COMPLETION: "1" }
    })

    await child.start()
    await child.spawnAdmit("expire before enrichment")
    await waitFor(() => child.state.type === "exited", 5_000)

    expect(child.snapshot().completion).toMatchObject({ workCycle: 1, status: "failed", reason: "work_cycle_timeout" })
    expect(child.snapshot().completion?.error).toContain("settlement failed")
  } finally {
    await rm(root, { recursive: true, force: true })
  }
}, 15_000)

test("an idle child receives a fresh deadline after time spent between successful cycles", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-child-fresh-work-deadline-"))
  try {
    const child = new ChildZiProcess({
      name: "agent-fresh-work-deadline",
      command: [process.execPath, mockChild],
      cwd: root,
      processTreeTracker: createProcessTreeTracker(),
      workTimeoutMs: 100,
      env: { ...process.env, MOCK_RPC_DELAY_MS: "20" }
    })

    await child.start()
    await child.spawnAdmit("first")
    await waitFor(() => child.state.type === "idle", 5_000)
    await Bun.sleep(150)
    await child.continueWith("__delay_prompt__")
    await waitFor(() => child.state.type === "idle", 5_000)

    expect(child.snapshot().completion).toMatchObject({ workCycle: 2, status: "completed" })
    await child.close()
  } finally {
    await rm(root, { recursive: true, force: true })
  }
}, 15_000)

test("ChildZiProcess continue wakes an idle child for a second work cycle", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-child-continue-"))
  try {
    const completions: number[] = []
    const child = new ChildZiProcess({
      name: "agent-2",
      command: [process.execPath, mockChild],
      cwd: root,
      processTreeTracker: createProcessTreeTracker(),
      env: { ...process.env, MOCK_RPC_REPLY: "cycle-text", MOCK_RPC_DELAY_MS: "15" },
      onCompletion(completion) {
        completions.push(completion.workCycle)
      }
    })

    await child.start()
    await child.spawnAdmit("first")
    await waitFor(() => child.state.type === "idle", 5_000)
    expect(completions).toEqual([1])

    await child.continueWith("second")
    expect(child.state.type).toBe("running")
    await waitFor(() => child.state.type === "idle", 5_000)
    expect(completions).toEqual([1, 2])

    await child.close()
    expect(child.state.type).toBe("exited")
  } finally {
    await rm(root, { recursive: true, force: true })
  }
}, 15_000)

test("ChildZiProcess queue-only send keeps an idle child idle until continue", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-child-send-"))
  try {
    const completions: number[] = []
    const child = new ChildZiProcess({
      name: "agent-send",
      command: [process.execPath, mockChild],
      cwd: root,
      processTreeTracker: createProcessTreeTracker(),
      env: { ...process.env, MOCK_RPC_REPLY: "queued-then-continued", MOCK_RPC_DELAY_MS: "20" },
      onCompletion(completion) {
        completions.push(completion.workCycle)
      }
    })

    await child.start()
    await child.sendFollowUp("queue this")
    expect(child.state.type).toBe("idle")
    expect(completions).toEqual([])

    await child.continueWith("wake now")
    expect(child.state.type).toBe("running")
    await waitFor(() => child.state.type === "idle", 5_000)
    expect(completions).toEqual([1])
    expect(child.snapshot().completion).toMatchObject({
      status: "completed",
      text: "queued-then-continued",
      workCycle: 1
    })

    await child.close()
  } finally {
    await rm(root, { recursive: true, force: true })
  }
}, 15_000)

test("ChildZiProcess continue extends a running work cycle", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-child-continue-running-"))
  try {
    const completions: number[] = []
    const child = new ChildZiProcess({
      name: "agent-running",
      command: [process.execPath, mockChild],
      cwd: root,
      processTreeTracker: createProcessTreeTracker(),
      env: { ...process.env, MOCK_RPC_REPLY: "continued-while-running", MOCK_RPC_DELAY_MS: "300" },
      onCompletion(completion) {
        completions.push(completion.workCycle)
      }
    })

    await child.start()
    await child.spawnAdmit("first")
    await child.continueWith("follow-up")
    expect(child.state.type).toBe("running")

    await waitFor(() => child.state.type === "idle", 5_000)
    expect(completions).toEqual([1])
    expect(child.snapshot().completion).toMatchObject({
      status: "completed",
      text: "continued-while-running",
      workCycle: 1
    })

    await child.close()
  } finally {
    await rm(root, { recursive: true, force: true })
  }
}, 15_000)

test("running follow-ups reuse one idle watch and cannot exhaust RPC capacity", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-child-idle-watch-reuse-"))
  const logPath = join(root, "methods.log")
  try {
    const child = new ChildZiProcess({
      name: "agent-idle-watch-reuse",
      command: [process.execPath, mockChild],
      cwd: root,
      processTreeTracker: createProcessTreeTracker(),
      workTimeoutMs: 2_000,
      env: { ...process.env, MOCK_RPC_DELAY_MS: "500", MOCK_RPC_LOG: logPath }
    })

    await child.start()
    await child.spawnAdmit("first")
    for (let index = 0; index < 40; index++) {
      // oxlint-disable-next-line no-await-in-loop -- sequential delivery is the production supervisor contract
      await child.continueWith(`follow-up ${index}`)
    }
    await waitFor(() => child.state.type === "idle", 5_000)

    const methods = (await Bun.file(logPath).text()).trim().split("\n")
    expect(methods.filter(method => method === "session.await_idle")).toHaveLength(1)
    expect(child.snapshot().completion).toMatchObject({ workCycle: 1, status: "completed" })
    await child.close()
  } finally {
    await rm(root, { recursive: true, force: true })
  }
}, 15_000)

test("a follow-up while idle completion is in flight invalidates stale evidence", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-child-stale-idle-"))
  const logPath = join(root, "methods.log")
  try {
    const completions: number[] = []
    const child = new ChildZiProcess({
      name: "agent-stale-idle",
      command: [process.execPath, mockChild],
      cwd: root,
      processTreeTracker: createProcessTreeTracker(),
      workTimeoutMs: 1_000,
      env: { ...process.env, MOCK_RPC_DELAY_MS: "20", MOCK_RPC_COMPLETION_DELAY_MS: "150", MOCK_RPC_LOG: logPath },
      onCompletion(completion) {
        completions.push(completion.workCycle)
      }
    })

    await child.start()
    await child.spawnAdmit("first")
    await waitFor(() => readFileSync(logPath, "utf8").includes("session.await_idle:completion"), 5_000)
    await child.continueWith("__second_evidence__")
    await Bun.sleep(30)
    expect(child.state.type).toBe("running")
    expect(completions).toEqual([])

    await waitFor(() => child.state.type === "idle", 5_000)
    expect(completions).toEqual([1])
    expect(child.snapshot().completion).toMatchObject({
      workCycle: 1,
      status: "completed",
      text: "second-cycle-evidence"
    })
    const methods = readFileSync(logPath, "utf8").trim().split("\n")
    expect(methods.filter(method => method === "session.await_idle")).toHaveLength(2)
    await child.close()
  } finally {
    await rm(root, { recursive: true, force: true })
  }
}, 15_000)

test("a queue-only follow-up racing idle completion does not erase settled evidence", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-child-queued-idle-race-"))
  const logPath = join(root, "methods.log")
  try {
    const child = new ChildZiProcess({
      name: "agent-queued-idle-race",
      command: [process.execPath, mockChild],
      cwd: root,
      processTreeTracker: createProcessTreeTracker(),
      env: {
        ...process.env,
        MOCK_RPC_REPLY: "settled-before-queue",
        MOCK_RPC_DELAY_MS: "20",
        MOCK_RPC_COMPLETION_DELAY_MS: "150",
        MOCK_RPC_LOG: logPath
      }
    })

    await child.start()
    await child.spawnAdmit("first")
    await waitFor(() => readFileSync(logPath, "utf8").includes("session.await_idle:completion"), 5_000)
    await child.sendFollowUp("queue after semantic idle")
    await waitFor(() => child.state.type === "idle", 5_000)

    expect(child.snapshot().completion).toMatchObject({
      workCycle: 1,
      status: "completed",
      text: "settled-before-queue"
    })
    const methods = readFileSync(logPath, "utf8").trim().split("\n")
    expect(methods.filter(method => method === "session.await_idle")).toHaveLength(1)
    await child.close()
  } finally {
    await rm(root, { recursive: true, force: true })
  }
}, 15_000)

test("a follow-up while idle completion is in flight rearms the remaining cycle deadline", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-child-stale-idle-deadline-"))
  const logPath = join(root, "methods.log")
  try {
    const child = new ChildZiProcess({
      name: "agent-stale-idle-deadline",
      command: [process.execPath, mockChild],
      cwd: root,
      processTreeTracker: createProcessTreeTracker(),
      workTimeoutMs: 200,
      workTimeoutSettlementMs: 500,
      env: { ...process.env, MOCK_RPC_DELAY_MS: "20", MOCK_RPC_COMPLETION_DELAY_MS: "100", MOCK_RPC_LOG: logPath }
    })

    await child.start()
    await child.spawnAdmit("first")
    await waitFor(() => readFileSync(logPath, "utf8").includes("session.await_idle:completion"), 5_000)
    await child.continueWith("__long_work__")
    await waitFor(() => child.state.type === "idle", 5_000)

    expect(child.snapshot().completion).toMatchObject({ workCycle: 1, status: "failed", reason: "work_cycle_timeout" })
    await child.close()
  } finally {
    await rm(root, { recursive: true, force: true })
  }
}, 15_000)

test("a running follow-up does not reset the current work deadline", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-child-nonreset-work-deadline-"))
  try {
    const child = new ChildZiProcess({
      name: "agent-nonreset-work-deadline",
      command: [process.execPath, mockChild],
      cwd: root,
      processTreeTracker: createProcessTreeTracker(),
      workTimeoutMs: 100,
      workTimeoutSettlementMs: 500,
      env: { ...process.env, MOCK_RPC_DELAY_MS: "30000" }
    })

    await child.start()
    await child.spawnAdmit("first")
    await Bun.sleep(60)
    await child.continueWith("must keep the original deadline")
    await waitFor(() => child.state.type === "idle", 5_000)

    expect(child.snapshot().completion).toMatchObject({ workCycle: 1, status: "failed", reason: "work_cycle_timeout" })
    expect(child.snapshot().completion?.durationMs).toBeLessThan(160)
    await child.close()
  } finally {
    await rm(root, { recursive: true, force: true })
  }
}, 15_000)

test("ChildZiProcess explicit close terminates a long-lived descendant", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-child-descendant-close-"))
  const marker = join(root, "descendant.pid")
  let descendantPid: number | undefined
  try {
    const child = new ChildZiProcess({
      name: "agent-descendant-close",
      command: [process.execPath, mockChild],
      cwd: root,
      processTreeTracker: createProcessTreeTracker(),
      env: { ...process.env, MOCK_RPC_DESCENDANT_PID: marker }
    })
    await child.start()
    descendantPid = await readPid(marker)
    expect(processAlive(descendantPid)).toBe(true)

    await child.close("test")
    await waitFor(() => !processAlive(descendantPid!), 5_000)
    expect(child.state.type).toBe("exited")
  } finally {
    if (descendantPid && processAlive(descendantPid)) {
      try {
        process.kill(descendantPid, "SIGKILL")
      } catch {
        // already dead
      }
    }
    await rm(root, { recursive: true, force: true })
  }
}, 15_000)

test("ChildZiProcess protocol failure terminates a long-lived descendant", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-child-descendant-crash-"))
  const marker = join(root, "descendant.pid")
  let descendantPid: number | undefined
  try {
    let reentrantClose: Promise<void> | undefined
    let child!: ChildZiProcess
    child = new ChildZiProcess({
      name: "agent-descendant-crash",
      command: [process.execPath, mockChild],
      cwd: root,
      processTreeTracker: createProcessTreeTracker(),
      env: { ...process.env, MOCK_RPC_DESCENDANT_PID: marker, MOCK_RPC_PROTOCOL_CRASH: "1" },
      onFatal() {
        reentrantClose = child.close()
      }
    })
    await child.start()
    descendantPid = await readPid(marker)
    await waitFor(() => child.state.type === "exited", 5_000)
    await reentrantClose
    await waitFor(() => !processAlive(descendantPid!), 5_000)
    expect(child.snapshot().lifecycle).toBe("exited")
  } finally {
    if (descendantPid && processAlive(descendantPid)) {
      try {
        process.kill(descendantPid, "SIGKILL")
      } catch {
        // already dead
      }
    }
    await rm(root, { recursive: true, force: true })
  }
}, 15_000)

test("ChildZiProcess contains stdin errors when a child exits with queued requests", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-child-stdin-exit-race-"))
  try {
    const failures: string[] = []
    const child = new ChildZiProcess({
      name: "agent-stdin-exit-race",
      command: [process.execPath, mockChild],
      cwd: root,
      processTreeTracker: createProcessTreeTracker(),
      env: { ...process.env, MOCK_RPC_EXIT_ON_PROMPT: "1" },
      onFatal(error) {
        failures.push(error.message)
      }
    })
    await child.start()

    const text = "x".repeat(512 * 1024)
    const requests = Array.from({ length: 8 }, () => child.sendFollowUp(text))
    const results = await Promise.allSettled(requests)
    await waitFor(() => child.state.type === "exited", 5_000)

    expect(results.every(result => result.status === "rejected")).toBe(true)
    expect(failures).toHaveLength(1)
  } finally {
    await rm(root, { recursive: true, force: true })
  }
}, 15_000)

test("ChildZiProcess interruption during spawn admission cannot return to running", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-child-interrupt-admission-"))
  try {
    const lifecycles: string[] = []
    const completions: number[] = []
    let child!: ChildZiProcess
    child = new ChildZiProcess({
      name: "agent-interrupt-admission",
      command: [process.execPath, mockChild],
      cwd: root,
      processTreeTracker: createProcessTreeTracker(),
      env: { ...process.env, MOCK_RPC_DELAY_MS: "30000", MOCK_RPC_PROMPT_RESPONSE_DELAY_MS: "150" },
      onStateChange() {
        lifecycles.push(child.state.type)
      },
      onCompletion(completion) {
        completions.push(completion.workCycle)
      }
    })

    await child.start()
    const admission = child.spawnAdmit("interrupt admission")
    await waitFor(() => child.state.type === "spawn_admitting", 5_000)
    expect(await child.interrupt()).toBe("interrupted")
    await admission
    await waitFor(() => child.state.type === "idle", 5_000)

    const interruptIndex = lifecycles.indexOf("interrupting")
    expect(interruptIndex).toBeGreaterThanOrEqual(0)
    expect(lifecycles.slice(interruptIndex + 1)).not.toContain("running")
    expect(completions).toEqual([1])
    expect(child.snapshot().completion).toMatchObject({ status: "cancelled", workCycle: 1 })
    await child.close()
  } finally {
    await rm(root, { recursive: true, force: true })
  }
}, 15_000)

test("ChildZiProcess bounds requested interruption settlement and records terminal evidence", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-child-interrupt-settlement-"))
  try {
    const child = new ChildZiProcess({
      name: "agent-interrupt-settlement",
      command: [process.execPath, mockChild],
      cwd: root,
      processTreeTracker: createProcessTreeTracker(),
      interruptSettlementMs: 50,
      env: { ...process.env, MOCK_RPC_DELAY_MS: "30000", MOCK_RPC_IGNORE_INTERRUPT: "1" }
    })

    await child.start()
    await child.spawnAdmit("ignore requested interruption")
    expect(await child.interrupt()).toBe("interrupted")
    await waitFor(() => child.state.type === "exited", 5_000)

    expect(child.snapshot().completion).toMatchObject({
      workCycle: 1,
      status: "failed",
      reason: "interrupt_settlement_timeout"
    })
  } finally {
    await rm(root, { recursive: true, force: true })
  }
}, 15_000)

test("ChildZiProcess settlement deadline bounds an unacknowledged interrupt request", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-child-interrupt-unacknowledged-"))
  try {
    const child = new ChildZiProcess({
      name: "agent-interrupt-unacknowledged",
      command: [process.execPath, mockChild],
      cwd: root,
      processTreeTracker: createProcessTreeTracker(),
      interruptSettlementMs: 50,
      env: { ...process.env, MOCK_RPC_DELAY_MS: "30000", MOCK_RPC_DROP_INTERRUPT: "1" }
    })

    await child.start()
    await child.spawnAdmit("drop requested interruption")
    const interruptionError = await child.interrupt().then(
      () => undefined,
      cause => cause
    )
    expect(interruptionError).toBeInstanceOf(Error)
    if (!(interruptionError instanceof Error)) throw new Error("Expected interruption failure")
    expect(interruptionError.message).toContain("interruption did not settle within 50ms")
    await waitFor(() => child.state.type === "exited", 5_000)

    expect(child.snapshot().completion).toMatchObject({
      workCycle: 1,
      status: "failed",
      reason: "interrupt_settlement_timeout"
    })
  } finally {
    await rm(root, { recursive: true, force: true })
  }
}, 15_000)

test("ChildZiProcess interrupt leaves the process reusable", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-child-interrupt-"))
  try {
    const child = new ChildZiProcess({
      name: "agent-3",
      command: [process.execPath, mockChild],
      cwd: root,
      processTreeTracker: createProcessTreeTracker(),
      env: {
        ...process.env,
        MOCK_RPC_REPLY: "after-interrupt",
        // Keep the first await_idle open long enough for interrupt to win the race.
        MOCK_RPC_DELAY_MS: "800"
      }
    })

    await child.start()
    await child.spawnAdmit("long work")
    expect(child.state.type).toBe("running")
    const interruption = child.interrupt()
    expect(child.continueWith("forbidden during interruption")).rejects.toThrow("cannot continue while interrupting")
    expect(child.sendFollowUp("also forbidden")).rejects.toThrow("cannot accept send while interrupting")
    expect(await interruption).toBe("interrupted")
    await waitFor(() => child.state.type === "idle" || child.state.type === "exited", 5_000)
    expect(child.state.type).toBe("idle")
    expect(child.snapshot().completion?.status).toBe("cancelled")

    await child.continueWith("again")
    await waitFor(() => child.state.type === "idle", 5_000)
    expect(child.snapshot().completion).toMatchObject({ status: "completed", text: "after-interrupt" })
    await child.close()
  } finally {
    await rm(root, { recursive: true, force: true })
  }
}, 15_000)

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
    // oxlint-disable-next-line no-await-in-loop -- bounded poll
    await Bun.sleep(15)
  }
  throw new Error("condition not met before deadline")
}
