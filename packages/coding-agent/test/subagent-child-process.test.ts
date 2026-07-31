import { expect, test } from "bun:test"
import { readFileSync } from "node:fs"
import { mkdtemp, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join, resolve } from "node:path"

import { ChildZiProcess } from "../src/subagents/child-process.js"

const mockChild = resolve(import.meta.dir, "fixtures/mock-rpc-child.ts")

test("ChildZiProcess spawn/wait/close vertical slice against a mock RPC child", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-child-zi-process-"))
  const logPath = join(root, "methods.log")
  try {
    const completions: Array<{ status: string; text: string }> = []
    const child = new ChildZiProcess({
      agentId: "agent-1",
      command: [process.execPath, mockChild],
      cwd: root,
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
    expect(methods).toContain("session.get_messages")
  } finally {
    await rm(root, { recursive: true, force: true })
  }
}, 15_000)

test("ChildZiProcess continue wakes an idle child for a second work cycle", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-child-continue-"))
  try {
    const completions: number[] = []
    const child = new ChildZiProcess({
      agentId: "agent-2",
      command: [process.execPath, mockChild],
      cwd: root,
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
      agentId: "agent-send",
      command: [process.execPath, mockChild],
      cwd: root,
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
      agentId: "agent-running",
      command: [process.execPath, mockChild],
      cwd: root,
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

test("ChildZiProcess explicit close terminates a long-lived descendant", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-child-descendant-close-"))
  const marker = join(root, "descendant.pid")
  let descendantPid: number | undefined
  try {
    const child = new ChildZiProcess({
      agentId: "agent-descendant-close",
      command: [process.execPath, mockChild],
      cwd: root,
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
    const child = new ChildZiProcess({
      agentId: "agent-descendant-crash",
      command: [process.execPath, mockChild],
      cwd: root,
      env: { ...process.env, MOCK_RPC_DESCENDANT_PID: marker, MOCK_RPC_PROTOCOL_CRASH: "1" }
    })
    await child.start()
    descendantPid = await readPid(marker)
    await waitFor(() => child.state.type === "exited", 5_000)
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

test("ChildZiProcess interrupt leaves the process reusable", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-child-interrupt-"))
  try {
    const child = new ChildZiProcess({
      agentId: "agent-3",
      command: [process.execPath, mockChild],
      cwd: root,
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
    const result = await child.interrupt()
    expect(result).toBe("interrupted")
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
