import { expect, test } from "bun:test"
import { existsSync, readFileSync, rmSync } from "node:fs"
import { mkdtemp, readFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type { ShellBackgroundTaskOperationOutcomeInput } from "../src/session-shell.js"
import { defaultShellLimits, SessionShell, ShellRunAdmissionError, type ShellLimits } from "../src/session-shell.js"
import { createBashTool, isBashToolDetails } from "../src/tools/bash.js"
import { projectToolPresentation } from "../src/tools/presentation/project.js"
import {
  createKillTaskTool,
  createListTasksTool,
  createTaskOutputTool,
  isTaskListToolDetails,
  isTaskOutputToolDetails
} from "../src/tools/shell-tasks.js"
import { DEFAULT_MAX_BYTES } from "../src/tools/truncate.js"

test("bash bounds model output and preserves the full stream for the session lifetime", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-bash-"))
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
    if (result.details.state === "rejected") throw new Error("Expected admitted Bash execution")
    expect(result.details.output.truncation.truncated).toBe(true)
    const fullOutput = result.details.output.fullOutput
    expect(fullOutput.type === "available" && existsSync(fullOutput.path)).toBe(true)

    const incremental = await createTaskOutputTool(shell).execute("bash-1-output", {
      taskId: result.details.taskId,
      cursor: 0
    })
    if (incremental.details.outcome === "error") throw new Error("Expected incremental output")
    expect(incremental.details.output).toMatchObject({ cursor: 0, nextCursor: DEFAULT_MAX_BYTES + 4096 })
    expect(incremental.details.output.omittedBytes).toBeGreaterThan(0)
  } finally {
    await shell.dispose()
    rmSync(cwd, { recursive: true, force: true })
  }
})

test("bash keeps a UTF-8 aligned fixed tail after output exceeds its preview buffer", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-bash-ring-tail-"))
  const shell = createShell(cwd)
  const tool = createBashTool(shell)

  try {
    const result = await tool.execute("bash-ring-tail", {
      command: `node -e "process.stdout.write('🙂'.repeat(${DEFAULT_MAX_BYTES}) + 'TAIL')"`
    })
    const output = result.content[0]
    if (output?.type !== "text") throw new Error("Expected text output")
    expect(output.text).toContain("TAIL\n\n[Output truncated")
    expect(output.text).not.toContain("�")
    expect(Buffer.byteLength(output.text)).toBeLessThan(DEFAULT_MAX_BYTES + 512)
  } finally {
    await shell.dispose()
    rmSync(cwd, { recursive: true, force: true })
  }
})

test("newline-terminated shell output keeps its semantic presentation", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-bash-presentation-"))
  const shell = createShell(cwd)
  const bash = createBashTool(shell)
  const output = createTaskOutputTool(shell)

  try {
    const command = `printf "alpha\\nbeta\\n"`
    const result = await bash.execute("bash-newlines", { command, description: "Print rows" })
    expect(isBashToolDetails(result.details)).toBe(true)
    expect(result.details).toMatchObject({ output: { truncation: { totalLines: 2, outputLines: 2 } } })
    expect(
      projectToolPresentation({ status: "done", name: "bash", args: { command, description: "Print rows" }, result })
        .header.label
    ).toBe("Run")

    const started = await bash.execute("bash-newlines-background", { command, background: true })
    if (started.details.state === "rejected") throw new Error("Expected background task")
    const completed = await output.execute("task-newlines", { taskId: started.details.taskId, timeout: 2 })
    expect(isTaskOutputToolDetails(completed.details)).toBe(true)
    expect(
      projectToolPresentation({
        status: "done",
        name: "task_output",
        args: { taskId: started.details.taskId, timeout: 2 },
        result: completed
      }).header.label
    ).toBe("Output")
  } finally {
    await shell.dispose()
    rmSync(cwd, { recursive: true, force: true })
  }
})

test("newline-terminated Bash output retains all 2,000 usable lines", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-bash-line-limit-"))
  const shell = createShell(cwd)
  const bash = createBashTool(shell)

  try {
    const result = await bash.execute("bash-line-limit", {
      command: `node -e "let s='';for(let i=1;i<=2000;i++)s+='line-'+i+'\\n';process.stdout.write(s)"`
    })
    if (result.details.state === "rejected") throw new Error("Expected admitted Bash execution")
    expect(result.details.output.truncation).toMatchObject({ truncated: false, totalLines: 2_000, outputLines: 2_000 })
    const content = result.content[0]
    if (content?.type !== "text") throw new Error("Expected Bash text output")
    expect(content.text).toStartWith("line-1\n")
    expect(content.text).toEndWith("line-2000\n")
    expect(content.text.split("\n").slice(0, -1)).toHaveLength(2_000)
  } finally {
    await shell.dispose()
    rmSync(cwd, { recursive: true, force: true })
  }
})

test("bash returns typed errors for reachable admission failures", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-bash-admission-"))
  const shell = createShell(cwd, { maxBackgroundTasks: 1, maxRuntimeMs: 1_000 })
  const tool = createBashTool(shell)

  try {
    const timeout = await tool.execute("bash-timeout-rejected", { command: "printf no", timeout: 2 })
    expect(timeout.details).toMatchObject({
      outcome: "error",
      state: "rejected",
      timeoutSeconds: 2,
      error: expect.stringContaining("session limit")
    })

    const first = await tool.execute("bash-capacity-one", {
      command: `node -e "setInterval(() => {}, 1000)"`,
      background: true
    })
    if (first.details.state === "rejected") throw new Error("Expected first background task")
    const capacity = await tool.execute("bash-capacity-two", { command: "printf no", background: true })
    expect(capacity.details).toMatchObject({
      outcome: "error",
      state: "rejected",
      error: expect.stringContaining("capacity exceeded")
    })
  } finally {
    await shell.dispose()
    rmSync(cwd, { recursive: true, force: true })
  }
})

test("bash cancellation terminates the process group and settles with bounded output", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-bash-abort-"))
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
    const result = await execution
    const content = result.content[0]
    expect(content?.type).toBe("text")
    if (content?.type !== "text") throw new Error("Expected Bash text output")
    expect(content.text).toContain("started")
    expect(content.text).toContain("Command aborted")
    expect(result.details).toMatchObject({
      outcome: "error",
      state: "completed",
      finalOutcome: { type: "aborted" },
      error: "Command aborted"
    })
  } finally {
    await shell.dispose()
    rmSync(cwd, { recursive: true, force: true })
  }
})

test("bash cancellation kills a SIGTERM-resistant descendant before settling", async () => {
  if (process.platform === "win32") return
  const cwd = await mkdtemp(join(tmpdir(), "zi-bash-group-abort-"))
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
    const childPid = Number(await readFile(pidPath, "utf8"))
    pid = childPid
    controller.abort()
    const result = await execution
    expect(result.content[0]).toMatchObject({ type: "text", text: expect.stringContaining("Command aborted") })
    expect(result.details).toMatchObject({ outcome: "error", finalOutcome: { type: "aborted" } })
    await waitUntil(() => !processRunning(childPid))
  } finally {
    if (pid && processRunning(pid)) process.kill(pid, "SIGKILL")
    await shell.dispose()
    rmSync(cwd, { recursive: true, force: true })
  }
})

test("foreground execution can be demoted without tying the process to turn cancellation", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-bash-demote-"))
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
  const cwd = await mkdtemp(join(tmpdir(), "zi-bash-background-"))
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

test("background task settlement emits one closed operation outcome", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-bash-outcomes-"))
  const shell = createShell(cwd)
  const outcomes: ShellBackgroundTaskOperationOutcomeInput[] = []
  shell.bindOperationOutcomeSink(outcome => outcomes.push(outcome))

  try {
    await shell.run("foreground", { command: "printf foreground", timeoutMs: 2_000, background: false })
    expect(outcomes).toEqual([])

    const started = await shell.run("background", {
      command: "printf background; exit 7",
      timeoutMs: 2_000,
      background: true
    })
    if (started.type !== "backgrounded") throw new Error("Expected background task")
    const completed = await shell.wait(started.task.taskId, 2_000)
    expect(completed).toMatchObject({ type: "completed", outcome: { type: "exited", exitCode: 7 } })
    expect(outcomes).toEqual([
      expect.objectContaining({
        capability: "shell",
        operation: "background_task",
        result: "failed",
        evidence: expect.objectContaining({
          taskId: started.task.taskId,
          origin: "requested",
          errorCode: "exit_nonzero",
          exitCode: 7,
          outputBytes: 10
        })
      })
    ])
    expect(JSON.stringify(outcomes)).not.toContain("printf background")

    await shell.wait(started.task.taskId, 0)
    await shell.kill(started.task.taskId)
    expect(outcomes).toHaveLength(1)
  } finally {
    await shell.dispose()
    rmSync(cwd, { recursive: true, force: true })
  }
})

test("demotion and task control preserve one background operation identity", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-bash-demoted-outcome-"))
  const shell = createShell(cwd)
  const outcomes: ShellBackgroundTaskOperationOutcomeInput[] = []
  shell.bindOperationOutcomeSink(outcome => outcomes.push(outcome))
  const started = deferred<void>()
  const running = shell.run(
    "demoted",
    { command: `node -e "console.log('ready'); setInterval(() => {}, 1000)"`, timeoutMs: 2_000, background: false },
    undefined,
    task => {
      if (task.output.text.includes("ready")) started.resolve()
    }
  )

  try {
    await started.promise
    const demoted = shell.demoteForeground()
    if (demoted.type !== "backgrounded") throw new Error("Expected demoted task")
    await running
    await shell.kill(demoted.task.taskId)
    await shell.wait(demoted.task.taskId, 2_000)

    expect(outcomes).toEqual([
      expect.objectContaining({
        result: "cancelled",
        evidence: expect.objectContaining({
          taskId: demoted.task.taskId,
          origin: "demoted",
          cancellationCode: "killed"
        })
      })
    ])
  } finally {
    await shell.dispose()
    rmSync(cwd, { recursive: true, force: true })
  }
})

test("background timeout, output limit, and disposal retain distinct outcomes", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-bash-terminal-outcomes-"))
  const shell = createShell(cwd, { maxOutputFileBytes: 1_024 })
  const outcomes: ShellBackgroundTaskOperationOutcomeInput[] = []
  shell.bindOperationOutcomeSink(outcome => outcomes.push(outcome))

  const timed = await shell.run("timed", {
    command: `node -e "setInterval(() => {}, 1000)"`,
    timeoutMs: 20,
    background: true
  })
  if (timed.type !== "backgrounded") throw new Error("Expected timed background task")
  await shell.wait(timed.task.taskId, 2_000)

  const limited = await shell.run("limited", {
    command: `node -e "process.stdout.write('x'.repeat(8192)); setInterval(() => {}, 1000)"`,
    timeoutMs: 2_000,
    background: true
  })
  if (limited.type !== "backgrounded") throw new Error("Expected limited background task")
  await shell.wait(limited.task.taskId, 2_000)

  const disposed = await shell.run("disposed", {
    command: `node -e "setInterval(() => {}, 1000)"`,
    timeoutMs: 2_000,
    background: true
  })
  if (disposed.type !== "backgrounded") throw new Error("Expected disposable background task")
  await shell.dispose()

  expect(outcomes).toEqual(
    expect.arrayContaining([
      expect.objectContaining({
        result: "failed",
        evidence: expect.objectContaining({ taskId: timed.task.taskId, errorCode: "timed_out" })
      }),
      expect.objectContaining({
        result: "failed",
        evidence: expect.objectContaining({ taskId: limited.task.taskId, errorCode: "output_limit" })
      }),
      expect.objectContaining({
        result: "cancelled",
        evidence: expect.objectContaining({ taskId: disposed.task.taskId, cancellationCode: "disposed" })
      })
    ])
  )
  rmSync(cwd, { recursive: true, force: true })
})

test("operation outcome binding rejects background work admitted before session ownership", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-bash-late-outcome-binding-"))
  const shell = createShell(cwd)

  try {
    const started = await shell.run("background", { command: "printf done", timeoutMs: 2_000, background: true })
    if (started.type !== "backgrounded") throw new Error("Expected background task")
    expect(() => shell.bindOperationOutcomeSink(() => {})).toThrow(
      "Shell operation outcome sink must be bound before background work"
    )
  } finally {
    await shell.dispose()
    rmSync(cwd, { recursive: true, force: true })
  }
})

test("background outcome persistence retries at the next delivery boundary", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-bash-outcome-retry-"))
  const shell = createShell(cwd)
  const outcomes: ShellBackgroundTaskOperationOutcomeInput[] = []
  let attempts = 0
  shell.bindOperationOutcomeSink(outcome => {
    attempts++
    if (attempts === 1) throw new Error("journal unavailable")
    outcomes.push(outcome)
  })

  try {
    const first = await shell.run("first", { command: "printf first", timeoutMs: 2_000, background: true })
    if (first.type !== "backgrounded") throw new Error("Expected first background task")
    await shell.wait(first.task.taskId, 2_000)
    expect(outcomes).toEqual([])

    shell.retryPendingOutcomes()
    expect(outcomes.map(outcome => outcome.evidence.taskId)).toEqual([first.task.taskId])

    const second = await shell.run("second", { command: "printf second", timeoutMs: 2_000, background: true })
    if (second.type !== "backgrounded") throw new Error("Expected second background task")
    await shell.wait(second.task.taskId, 2_000)

    expect(outcomes.map(outcome => outcome.evidence.taskId)).toEqual([first.task.taskId, second.task.taskId])
  } finally {
    await shell.dispose()
    rmSync(cwd, { recursive: true, force: true })
  }
})

test("an unpersisted background outcome bounds later admission and preserves cleanup", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-bash-outcome-backlog-"))
  const outputRoot = join(cwd, "output")
  const shell = new SessionShell({
    cwd,
    sessionId: crypto.randomUUID(),
    outputRoot,
    limits: { ...defaultShellLimits, maxBackgroundTasks: 2, maxCompletedTasks: 1 }
  })
  shell.bindOperationOutcomeSink(() => {
    throw new Error("journal unavailable")
  })

  const first = await shell.run("first", {
    command: `node -e "setInterval(() => {}, 1000)"`,
    timeoutMs: 2_000,
    background: true
  })
  if (first.type !== "backgrounded") throw new Error("Expected first background task")
  const output = first.task.output.fullOutput
  if (output.type !== "available") throw new Error("Expected retained output")

  expect(() => shell.run("second", { command: "printf second", timeoutMs: 2_000, background: true })).toThrow(
    ShellRunAdmissionError
  )
  await shell.kill(first.task.taskId)
  await shell.wait(first.task.taskId, 2_000)
  expect(() => shell.run("third", { command: "printf third", timeoutMs: 2_000, background: true })).toThrow(
    ShellRunAdmissionError
  )
  expect(
    await shell.dispose().then(
      () => "",
      cause => (cause instanceof Error ? cause.message : String(cause))
    )
  ).toBe("Could not persist shell operation outcomes")
  expect(shell.snapshots()).toEqual([])
  expect(existsSync(output.path)).toBe(false)
  rmSync(cwd, { recursive: true, force: true })
})

test("task_output cursors return only newly observed output", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-bash-cursor-"))
  const shell = createShell(cwd)
  const bash = createBashTool(shell)
  const output = createTaskOutputTool(shell)

  try {
    const started = await bash.execute("bash-cursor", {
      command: `node -e "process.stdout.write('alpha\\n'); setTimeout(() => process.stdout.write('beta\\n'), 500)"`,
      background: true
    })
    if (started.details.state === "rejected") throw new Error("Expected background task")
    const taskId = started.details.taskId

    await waitUntil(() => shell.snapshot(taskId)?.output.text.includes("alpha") === true)
    const first = await output.execute("task-cursor-first", { taskId })
    if (first.details.outcome === "error") throw new Error("Expected task output")
    const cursor = first.details.output.nextCursor
    if (cursor === undefined) throw new Error("Expected task output cursor")

    const second = await output.execute("task-cursor-second", { taskId, timeout: 2, cursor })
    expect(second.content[0]).toMatchObject({ type: "text", text: expect.stringContaining("beta") })
    expect(second.content[0]).not.toMatchObject({ type: "text", text: expect.stringContaining("alpha") })
    expect(second.details).toMatchObject({
      outcome: "success",
      state: "completed",
      output: { cursor, omittedBytes: 0 }
    })
    expect(isTaskOutputToolDetails(second.details)).toBe(true)

    if (second.details.outcome === "error") throw new Error("Expected completed task output")
    const settledCursor = second.details.output.nextCursor
    if (settledCursor === undefined) throw new Error("Expected settled task output cursor")
    const empty = await output.execute("task-cursor-empty", { taskId, cursor: settledCursor })
    expect(empty.content[0]).toMatchObject({ type: "text", text: expect.stringContaining("(no new output)") })
    expect(empty.details).toMatchObject({ output: { cursor: settledCursor, nextCursor: settledCursor } })

    const invalid = await output.execute("task-cursor-invalid", { taskId, cursor: settledCursor + 1 })
    expect(invalid.details).toMatchObject({ outcome: "error", error: expect.stringContaining("cursor") })
  } finally {
    await shell.dispose()
    rmSync(cwd, { recursive: true, force: true })
  }
})

test("cursor-aware waits retain settlement output when the completed task is evicted", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-bash-cursor-eviction-"))
  const shell = createShell(cwd, { maxCompletedTasks: 2 })
  shell.bindOperationOutcomeSink(() => {})
  const now = Date.now
  Date.now = () => 1_000

  try {
    const delayed = await shell.run("delayed", {
      command: `node -e "setTimeout(() => process.stdout.write('late'), 100)"`,
      timeoutMs: 2_000,
      background: true
    })
    if (delayed.type !== "backgrounded") throw new Error("Expected delayed background task")
    const waiting = shell.wait(delayed.task.taskId, 2_000, undefined, 0)

    const quick = await shell.run("quick", { command: "printf quick", timeoutMs: 2_000, background: true })
    if (quick.type !== "backgrounded") throw new Error("Expected quick background task")
    await shell.wait(quick.task.taskId, 2_000)
    await shell.run("foreground", { command: "printf foreground", timeoutMs: 2_000, background: false })

    const completed = await waiting
    expect(completed).toMatchObject({
      type: "completed",
      output: { text: "late", cursor: 0, nextCursor: 4, fullOutput: { type: "evicted" } }
    })
    expect(shell.snapshot(delayed.task.taskId)).toBeUndefined()
  } finally {
    Date.now = now
    await shell.dispose()
    rmSync(cwd, { recursive: true, force: true })
  }
})

test("list_tasks returns bounded recent task summaries without output", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-bash-list-"))
  const shell = createShell(cwd)
  const bash = createBashTool(shell)
  const list = createListTasksTool(shell)

  try {
    await bash.execute("bash-list-first", { command: "printf first-output" })
    await bash.execute("bash-list-second", { command: "printf second-output" })
    const result = await list.execute("list-tasks", { limit: 1 })

    expect(result.content[0]).toMatchObject({ type: "text", text: expect.stringContaining("printf second-output") })
    expect(result.details).toMatchObject({
      outcome: "success",
      tasks: [{ state: "completed", command: "printf second-output", finalOutcome: { type: "exited", exitCode: 0 } }],
      omitted: 1
    })
    expect(isTaskListToolDetails(result.details)).toBe(true)
  } finally {
    await shell.dispose()
    rmSync(cwd, { recursive: true, force: true })
  }
})

test("bash, task_output, and kill_task adapt one session task owner", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-bash-tools-"))
  const shell = createShell(cwd)
  const bash = createBashTool(shell)
  const output = createTaskOutputTool(shell)
  const kill = createKillTaskTool(shell)

  try {
    const started = await bash.execute("bash-tool-background", {
      command: `node -e "setTimeout(() => console.log('complete'), 100)"`,
      background: true
    })
    expect(started.details).toMatchObject({ outcome: "success", state: "background" })
    if (started.details.state === "rejected") throw new Error("Expected background task")
    const completed = await output.execute("task-output", { taskId: started.details.taskId, timeout: 2 })
    expect(completed.details).toMatchObject({
      outcome: "success",
      state: "completed",
      finalOutcome: { type: "exited", exitCode: 0 }
    })
    expect(completed.content[0]).toMatchObject({ type: "text", text: expect.stringContaining("complete") })

    const longRunning = await bash.execute("bash-tool-kill", {
      command: `node -e "setInterval(() => {}, 1000)"`,
      background: true
    })
    if (longRunning.details.state === "rejected") throw new Error("Expected background task")
    const killed = await kill.execute("kill-task", { taskId: longRunning.details.taskId })
    expect(killed.details).toMatchObject({ outcome: "success", stop: "stopping" })
  } finally {
    await shell.dispose()
    rmSync(cwd, { recursive: true, force: true })
  }
})

test("output limits stop runaway writers and completed tombstones stay bounded", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-bash-limits-"))
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
  const cwd = await mkdtemp(join(tmpdir(), "zi-bash-retention-"))
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

test("starting foreground admission rejects a reentrant foreground run", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-bash-reentrant-"))
  const shell = createShell(cwd)
  let attempted = false
  let rejection: unknown
  const unsubscribe = shell.subscribe(taskId => {
    const task = shell.snapshot(taskId)
    if (attempted || task?.type !== "starting" || task.placement !== "foreground") return
    attempted = true
    try {
      void shell.run("bash-reentrant-second", { command: "printf second", timeoutMs: 2_000, background: false })
    } catch (cause) {
      rejection = cause
    }
  })

  try {
    const first = await shell.run("bash-reentrant-first", {
      command: "printf first",
      timeoutMs: 2_000,
      background: false
    })
    expect(first).toMatchObject({ type: "completed", task: { output: { text: "first" } } })
    expect(rejection).toBeInstanceOf(ShellRunAdmissionError)
    expect(rejection).toMatchObject({ reason: "foreground-busy" })
    expect(shell.snapshots()).toHaveLength(1)
  } finally {
    unsubscribe()
    await shell.dispose()
    rmSync(cwd, { recursive: true, force: true })
  }
})

test("completed eviction forgets scheduled updates and retained output", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-bash-forget-"))
  const shell = createShell(cwd, { maxCompletedTasks: 1 })
  const updates: string[] = []
  const unsubscribe = shell.subscribe(taskId => updates.push(taskId))

  try {
    const first = await shell.run("bash-forget-first", {
      command: `node -e "process.stdout.write('first');setTimeout(()=>process.stdout.write('second'),10)"`,
      timeoutMs: 2_000,
      background: false
    })
    if (first.type !== "completed") throw new Error("Expected completed first task")
    const firstOutput = first.task.output.fullOutput
    if (firstOutput.type !== "available") throw new Error("Expected retained first output")

    await shell.run("bash-forget-second", { command: "printf replacement", timeoutMs: 2_000, background: false })
    expect(shell.snapshot(first.task.taskId)).toBeUndefined()
    expect(existsSync(firstOutput.path)).toBe(false)
    expect(shell.snapshots()).toHaveLength(1)

    const updateCount = updates.filter(taskId => taskId === first.task.taskId).length
    await Bun.sleep(150)
    expect(updates.filter(taskId => taskId === first.task.taskId)).toHaveLength(updateCount)
  } finally {
    unsubscribe()
    await shell.dispose()
    rmSync(cwd, { recursive: true, force: true })
  }
})

test("background capacity rejects new and demoted work until a task starts stopping", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-bash-capacity-"))
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
  const cwd = await mkdtemp(join(tmpdir(), "zi-bash-dispose-"))
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
  await waitUntil(() => !processRunning(pid))
  expect(existsSync(output.path)).toBe(false)
  rmSync(cwd, { recursive: true, force: true })
})

function createShell(cwd: string, overrides: Partial<ShellLimits> = {}): SessionShell {
  return new SessionShell({ cwd, sessionId: crypto.randomUUID(), limits: { ...defaultShellLimits, ...overrides } })
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
  if (process.platform === "linux") {
    try {
      const stat = readFileSync(`/proc/${pid}/stat`, "utf8")
      const stateOffset = stat.lastIndexOf(")") + 2
      return stat[stateOffset] !== "Z"
    } catch {}
  }

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
