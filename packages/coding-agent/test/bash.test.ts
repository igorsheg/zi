import { expect, test } from "bun:test"
import { existsSync, rmSync } from "node:fs"
import { mkdtemp, readFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { defaultShellLimits, SessionShell, type ShellLimits } from "../src/session-shell.js"
import { createBashTool } from "../src/tools/bash.js"
import { createKillTaskTool, createTaskOutputTool } from "../src/tools/shell-tasks.js"
import { DEFAULT_MAX_BYTES } from "../src/tools/truncate.js"

test("bash bounds model output and preserves the full stream for the session lifetime", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "openzi-bash-"))
  const shell = createShell(cwd)
  const tool = createBashTool(shell)

  try {
    const result = await tool.execute("bash-1", {
      command: `node -e "process.stdout.write('x'.repeat(${DEFAULT_MAX_BYTES + 4096}))"`
    })

    const output = result.content[0]
    expect(output?.type).toBe("text")
    if (output?.type !== "text") throw new Error("Expected text output")
    expect(Buffer.byteLength(output.text)).toBeLessThan(DEFAULT_MAX_BYTES + 512)
    expect(result.details.truncation?.truncated).toBe(true)
    expect(result.details.fullOutputPath && existsSync(result.details.fullOutputPath)).toBe(true)
  } finally {
    await shell.dispose()
    rmSync(cwd, { recursive: true, force: true })
  }
})

test("bash cancellation terminates the process group and settles with bounded output", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "openzi-bash-abort-"))
  const shell = createShell(cwd)
  const tool = createBashTool(shell)
  const controller = new AbortController()
  const started = deferred<void>()
  const execution = tool.execute(
    "bash-abort",
    { command: `node -e "process.stdout.write('started\\n'); setInterval(() => {}, 1000)"` },
    controller.signal,
    update => {
      const output = update.content[0]
      if (output?.type === "text" && output.text.includes("started")) started.resolve()
    }
  )

  try {
    await started.promise
    controller.abort()
    const error = await rejection(execution)
    expect(error.message).toContain("started")
    expect(error.message).toContain("Command aborted")
  } finally {
    await shell.dispose()
    rmSync(cwd, { recursive: true, force: true })
  }
})

test("bash cancellation kills a SIGTERM-resistant descendant before settling", async () => {
  if (process.platform === "win32") return
  const cwd = await mkdtemp(join(tmpdir(), "openzi-bash-group-abort-"))
  const pidPath = join(cwd, "child.pid")
  const script = `const fs=require('fs');fs.writeFileSync(${JSON.stringify(
    pidPath
  )},String(process.pid));process.on('SIGTERM',()=>{});setInterval(()=>{},1000)`
  const shell = createShell(cwd)
  const tool = createBashTool(shell)
  const controller = new AbortController()
  const execution = tool.execute(
    "bash-group-abort",
    { command: `node -e ${JSON.stringify(script)} & wait` },
    controller.signal
  )
  let pid: number | undefined

  try {
    await waitUntil(() => existsSync(pidPath))
    pid = Number(await readFile(pidPath, "utf8"))
    controller.abort()
    expect((await rejection(execution)).message).toContain("Command aborted")
    expect(processRunning(pid)).toBe(false)
  } finally {
    if (pid && processRunning(pid)) process.kill(pid, "SIGKILL")
    await shell.dispose()
    rmSync(cwd, { recursive: true, force: true })
  }
})

test("foreground execution can be demoted without tying the process to turn cancellation", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "openzi-bash-demote-"))
  const shell = createShell(cwd)
  const controller = new AbortController()
  const started = deferred<void>()
  const running = shell.run(
    "bash-demote",
    {
      command: `node -e "console.log('started'); setTimeout(() => console.log('done'), 150)"`,
      timeoutMs: 2_000,
      background: false
    },
    controller.signal,
    task => {
      if (task.output.text.includes("started")) started.resolve()
    }
  )

  try {
    await started.promise
    const demoted = shell.demoteForeground()
    expect(demoted.type).toBe("backgrounded")
    const execution = await running
    expect(execution.type).toBe("backgrounded")
    controller.abort()
    if (execution.type !== "backgrounded") throw new Error("Expected background task")
    const completed = await shell.wait(execution.task.taskId, 2_000)
    expect(completed?.type).toBe("completed")
    expect(completed?.output.text).toContain("done")
  } finally {
    await shell.dispose()
    rmSync(cwd, { recursive: true, force: true })
  }
})

test("explicit background execution survives its tool signal and can be awaited", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "openzi-bash-background-"))
  const shell = createShell(cwd)
  const controller = new AbortController()

  try {
    const result = await shell.run(
      "bash-background",
      { command: `node -e "setTimeout(() => console.log('complete'), 100)"`, timeoutMs: 2_000, background: true },
      controller.signal
    )
    expect(result.type).toBe("backgrounded")
    controller.abort()
    if (result.type !== "backgrounded") throw new Error("Expected background task")
    const completed = await shell.wait(result.task.taskId, 2_000)
    expect(completed).toMatchObject({ type: "completed", outcome: { type: "exited", exitCode: 0 } })
    expect(completed?.output.text).toContain("complete")
  } finally {
    await shell.dispose()
    rmSync(cwd, { recursive: true, force: true })
  }
})

test("bash, task_output, and kill_task adapt one session task owner", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "openzi-bash-tools-"))
  const shell = createShell(cwd)
  const bash = createBashTool(shell)
  const output = createTaskOutputTool(shell)
  const kill = createKillTaskTool(shell)

  try {
    const started = await bash.execute("bash-tool-background", {
      command: `node -e "setTimeout(() => console.log('complete'), 100)"`,
      background: true
    })
    expect(started.details.status).toBe("backgrounded")
    const completed = await output.execute("task-output", { taskId: started.details.taskId, timeout: 2 })
    expect(completed.details).toMatchObject({ type: "completed", outcome: { type: "exited", exitCode: 0 } })
    expect(completed.content[0]).toMatchObject({ type: "text", text: expect.stringContaining("complete") })

    const longRunning = await bash.execute("bash-tool-kill", {
      command: `node -e "setInterval(() => {}, 1000)"`,
      background: true
    })
    const killed = await kill.execute("kill-task", { taskId: longRunning.details.taskId })
    expect(killed.details).toMatchObject({ type: "stopping", reason: "killed" })
  } finally {
    await shell.dispose()
    rmSync(cwd, { recursive: true, force: true })
  }
})

test("output limits stop runaway writers and completed tombstones stay bounded", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "openzi-bash-limits-"))
  const shell = createShell(cwd, { maxOutputFileBytes: 1_024, maxRetainedOutputBytes: 2_048, maxCompletedTasks: 2 })

  try {
    const limited = await shell.run("bash-limit", {
      command: `node -e "process.stdout.write('x'.repeat(8192)); setInterval(() => {}, 1000)"`,
      timeoutMs: 2_000,
      background: false
    })
    expect(limited).toMatchObject({ type: "completed", task: { outcome: { type: "output_limit" } } })

    await shell.run("bash-two", { command: "printf two", timeoutMs: 2_000, background: false })
    await shell.run("bash-three", { command: "printf three", timeoutMs: 2_000, background: false })
    expect(shell.snapshots()).toHaveLength(2)
  } finally {
    await shell.dispose()
    rmSync(cwd, { recursive: true, force: true })
  }
})

test("aggregate output retention evicts the oldest completed spill before admitting new output", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "openzi-bash-retention-"))
  const shell = createShell(cwd, { maxOutputFileBytes: 1_024, maxRetainedOutputBytes: 1_024 })

  try {
    const first = await shell.run("bash-first-output", {
      command: `node -e "process.stdout.write('a'.repeat(800))"`,
      timeoutMs: 2_000,
      background: false
    })
    if (first.type !== "completed") throw new Error("Expected completed task")
    const firstOutput = first.task.output.fullOutput
    if (firstOutput.type !== "available") throw new Error("Expected retained first output")

    const second = await shell.run("bash-second-output", {
      command: `node -e "process.stdout.write('b'.repeat(800))"`,
      timeoutMs: 2_000,
      background: false
    })
    if (second.type !== "completed") throw new Error("Expected completed task")

    expect(shell.snapshot(first.task.taskId)?.output.fullOutput.type).toBe("evicted")
    expect(existsSync(firstOutput.path)).toBe(false)
    expect(second.task.output.fullOutput).toMatchObject({ type: "available", bytes: 800 })
  } finally {
    await shell.dispose()
    rmSync(cwd, { recursive: true, force: true })
  }
})

test("background capacity rejects new and demoted work until a task starts stopping", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "openzi-bash-capacity-"))
  const shell = createShell(cwd, { maxBackgroundTasks: 1 })

  try {
    const first = await shell.run("bash-background-one", {
      command: `node -e "setInterval(() => {}, 1000)"`,
      timeoutMs: 10_000,
      background: true
    })
    if (first.type !== "backgrounded") throw new Error("Expected background task")
    expect(() =>
      shell.run("bash-background-two", { command: "printf two", timeoutMs: 2_000, background: true })
    ).toThrow("Background task capacity exceeded")

    const foreground = shell.run("bash-foreground", {
      command: `node -e "setTimeout(() => {}, 500)"`,
      timeoutMs: 2_000,
      background: false
    })
    expect(shell.demoteForeground()).toEqual({ type: "capacity_exceeded" })
    expect((await shell.kill(first.task.taskId)).type).toBe("stopping")
    expect(shell.demoteForeground().type).toBe("backgrounded")
    expect((await foreground).type).toBe("backgrounded")
  } finally {
    await shell.dispose()
    rmSync(cwd, { recursive: true, force: true })
  }
})

test("session shell disposal kills background work and removes retained output", async () => {
  if (process.platform === "win32") return
  const cwd = await mkdtemp(join(tmpdir(), "openzi-bash-dispose-"))
  const pidPath = join(cwd, "background.pid")
  const shell = createShell(cwd)
  const script = `const fs=require('fs');fs.writeFileSync(${JSON.stringify(
    pidPath
  )},String(process.pid));setInterval(()=>{},1000)`
  const result = await shell.run("bash-dispose", {
    command: `node -e ${JSON.stringify(script)}`,
    timeoutMs: 10_000,
    background: true
  })
  if (result.type !== "backgrounded") throw new Error("Expected background task")
  await waitUntil(() => existsSync(pidPath))
  const pid = Number(await readFile(pidPath, "utf8"))
  const output = result.task.output.fullOutput
  if (output.type !== "available") throw new Error("Expected retained output")

  await shell.dispose()
  expect(processRunning(pid)).toBe(false)
  expect(existsSync(output.path)).toBe(false)
  rmSync(cwd, { recursive: true, force: true })
})

function createShell(cwd: string, overrides: Partial<ShellLimits> = {}): SessionShell {
  return new SessionShell({ cwd, sessionId: crypto.randomUUID(), limits: { ...defaultShellLimits, ...overrides } })
}

async function rejection(promise: Promise<unknown>): Promise<Error> {
  try {
    await promise
  } catch (cause) {
    if (cause instanceof Error) return cause
    throw new Error(`Promise rejected with a non-Error value: ${String(cause)}`, { cause })
  }
  throw new Error("Expected promise to reject")
}

async function waitUntil(condition: () => boolean): Promise<void> {
  for (let attempt = 0; attempt < 100; attempt++) {
    if (condition()) return
    // Polling delays are sequential by definition.
    // oxlint-disable-next-line no-await-in-loop
    await Bun.sleep(10)
  }
  throw new Error("Condition was not reached")
}

function processRunning(pid: number): boolean {
  try {
    process.kill(pid, 0)
    return true
  } catch {
    return false
  }
}

function deferred<T>() {
  let resolve!: (value: T | PromiseLike<T>) => void
  const promise = new Promise<T>(resolvePromise => {
    resolve = resolvePromise
  })
  return { promise, resolve }
}
