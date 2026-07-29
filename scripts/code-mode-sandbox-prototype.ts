#!/usr/bin/env bun

// PROTOTYPE: delete after the code-mode sandbox spike selects or rejects a production mechanism.

import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process"
import { closeSync, writeFileSync } from "node:fs"
import { chmod, mkdtemp, rm, stat } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { Readable } from "node:stream"
import { fileURLToPath } from "node:url"

import quickJsVariant from "@jitl/quickjs-singlefile-mjs-release-sync"
import { newQuickJSWASMModuleFromVariant, type QuickJSDeferredPromise } from "quickjs-emscripten-core"

import { defaultCliArgv, main } from "../packages/cli/src/main.js"
import { compileStandalone } from "./compile-zi.js"

const parentArgument = "--prototype-code-mode-parent"
const workerArgument = "--prototype-code-mode-worker"
const standaloneBuild = process.env.ZI_CODE_MODE_PROTOTYPE_STANDALONE === "1"

if (!standaloneBuild) {
  await runProbe()
} else if (process.argv.includes(workerArgument)) {
  await runWorker()
} else if (process.argv.includes(parentArgument)) {
  await runParent(requiredArgument(parentArgument))
} else {
  process.exitCode = await main(defaultCliArgv())
}

type Scenario = "success" | "isolation" | "cpu-limit" | "memory-limit" | "cancellation" | "hard-kill"

type ParentFrame =
  | { readonly type: "start"; readonly code: string; readonly timeoutMs: number; readonly memoryLimitBytes: number }
  | { readonly type: "result"; readonly id: number; readonly result: unknown }
  | { readonly type: "error"; readonly id: number; readonly error: string }
  | { readonly type: "cancel" }

type WorkerFrame =
  | { readonly type: "call"; readonly id: number; readonly name: string; readonly arguments: unknown }
  | { readonly type: "completed"; readonly result: unknown; readonly logs: readonly string[] }
  | { readonly type: "failed"; readonly error: string; readonly logs: readonly string[] }

interface ScenarioReport {
  readonly scenario: Scenario
  readonly workerExitCode: number
  readonly stdout: string
  readonly stderr: string
  readonly calls: readonly Extract<WorkerFrame, { type: "call" }>[]
  readonly final: Exclude<WorkerFrame, { type: "call" }> | undefined
  readonly killed: boolean
  readonly elapsedMs: number
}

interface SpawnedWorker {
  readonly stdin: { write(value: string): Promise<void>; close(): Promise<void> }
  readonly stdout: AsyncIterable<Uint8Array | string>
  readonly stderr: AsyncIterable<Uint8Array | string>
  readonly protocol: AsyncIterable<Uint8Array | string>
  readonly exited: Promise<number>
  kill(): boolean
}

async function runProbe(): Promise<void> {
  const temporary = await mkdtemp(join(tmpdir(), "zi-code-mode-sandbox-prototype-"))
  const executable = join(
    temporary,
    process.platform === "win32" ? "zi-code-mode-prototype.exe" : "zi-code-mode-prototype"
  )
  try {
    await compileStandalone(fileURLToPath(import.meta.url), executable, {
      "process.env.ZI_CODE_MODE_PROTOTYPE_STANDALONE": JSON.stringify("1")
    })
    if (process.platform !== "win32") await chmod(executable, 0o755)

    const cliSmoke = await runProcess(executable, ["-V"])
    const [success, isolationReport, cpuLimit, memoryLimit, cancellation, hardKill] = await Promise.all([
      runCompiledScenario(executable, "success"),
      runCompiledScenario(executable, "isolation"),
      runCompiledScenario(executable, "cpu-limit"),
      runCompiledScenario(executable, "memory-limit"),
      runCompiledScenario(executable, "cancellation"),
      runCompiledScenario(executable, "hard-kill")
    ])
    const reports: Record<Scenario, ScenarioReport> = {
      success,
      isolation: isolationReport,
      "cpu-limit": cpuLimit,
      "memory-limit": memoryLimit,
      cancellation,
      "hard-kill": hardKill
    }

    const isolation = completedResult(reports.isolation)
    const checks = {
      releaseShapedCompilation: cliSmoke.exitCode === 0 && cliSmoke.stdout.startsWith("zi ") && cliSmoke.stderr === "",
      embeddedQuickJs: success.workerExitCode === 0,
      asyncToolDispatch:
        JSON.stringify(completedResult(success)) === JSON.stringify({ upper: "ZI", sum: 42 }) &&
        success.calls.map(call => call.name).join(",") === "upper,add",
      consoleCapture:
        success.final?.type === "completed" &&
        success.final.logs.length === 1 &&
        success.final.logs[0] === "ZI 42" &&
        success.stdout === "" &&
        success.stderr === "",
      ambientAuthorityBlocked:
        isRecord(isolation) &&
        isolation.process === "undefined" &&
        isolation.Bun === "undefined" &&
        isolation.require === "undefined" &&
        isolation.fetch === "undefined" &&
        isolation.hostCall === "undefined" &&
        isolation.hostLog === "undefined",
      cpuLimit:
        reports["cpu-limit"].final?.type === "failed" &&
        reports["cpu-limit"].final.error.toLowerCase().includes("interrupted") &&
        reports["cpu-limit"].elapsedMs < 2_000,
      memoryLimit:
        reports["memory-limit"].final?.type === "failed" &&
        reports["memory-limit"].final.error.toLowerCase().includes("memory"),
      cancellation:
        reports.cancellation.final?.type === "failed" &&
        reports.cancellation.final.error === "Execution cancelled" &&
        reports.cancellation.calls.map(call => call.name).join(",") === "hang",
      hardTermination:
        reports["hard-kill"].killed &&
        reports["hard-kill"].workerExitCode !== 0 &&
        reports["hard-kill"].elapsedMs < 2_000
    }

    console.log(
      JSON.stringify(
        {
          prototype: "compiled Zi child with an embedded QuickJS code sandbox",
          question:
            "Can a standalone Zi executable run bounded JavaScript, dispatch async host tools, and contain cancellation or hangs without ambient OS APIs?",
          platform: `${process.platform}-${process.arch}`,
          bun: Bun.version,
          executableBytes: (await stat(executable)).size,
          checks,
          reports
        },
        null,
        2
      )
    )
    if (Object.values(checks).some(passed => !passed)) process.exitCode = 1
  } finally {
    await rm(temporary, { recursive: true, force: true })
  }
}

async function runCompiledScenario(executable: string, scenario: Scenario): Promise<ScenarioReport> {
  const process = Bun.spawn([executable, parentArgument, scenario], {
    stdin: "ignore",
    stdout: "pipe",
    stderr: "pipe",
    windowsHide: true
  })
  const [exitCode, stdout, stderr] = await Promise.all([
    process.exited,
    new Response(process.stdout).text(),
    new Response(process.stderr).text()
  ])
  if (exitCode !== 0) {
    throw new Error(`Compiled probe parent failed for ${scenario}: ${stderr || stdout}`)
  }
  const value: unknown = JSON.parse(stdout)
  if (!isScenarioReport(value) || value.scenario !== scenario) {
    throw new Error(`Compiled probe parent returned an invalid ${scenario} report`)
  }
  return value
}

async function runParent(rawScenario: string): Promise<void> {
  const scenario = parseScenario(rawScenario)
  const worker = spawnWorker()
  const startedAt = Date.now()
  const calls: Extract<WorkerFrame, { type: "call" }>[] = []
  let final: Exclude<WorkerFrame, { type: "call" }> | undefined
  let killed = false
  let writeChain = Promise.resolve()

  const send = (frame: ParentFrame): Promise<void> => {
    writeChain = writeChain.then(() => worker.stdin.write(`${JSON.stringify(frame)}\n`))
    return writeChain
  }

  const stdoutPromise = readAll(worker.stdout)
  const stderrPromise = readAll(worker.stderr)
  await send({
    type: "start",
    code: scenarioCode(scenario),
    timeoutMs: scenario === "cpu-limit" ? 100 : 2_000,
    memoryLimitBytes: scenario === "memory-limit" ? 4 * 1024 * 1024 : 16 * 1024 * 1024
  })

  let cancellationScheduled = false
  const protocolPromise = (async () => {
    for await (const line of readLines(worker.protocol)) {
      const frame = parseWorkerFrame(line)
      if (frame.type !== "call") {
        final = frame
        await worker.stdin.close()
        return
      }
      calls.push(frame)
      switch (frame.name) {
        case "upper": {
          const input =
            isRecord(frame.arguments) && typeof frame.arguments.value === "string" ? frame.arguments.value : ""
          await send({ type: "result", id: frame.id, result: input.toUpperCase() })
          break
        }
        case "add": {
          const left = isRecord(frame.arguments) && typeof frame.arguments.left === "number" ? frame.arguments.left : 0
          const right =
            isRecord(frame.arguments) && typeof frame.arguments.right === "number" ? frame.arguments.right : 0
          await send({ type: "result", id: frame.id, result: left + right })
          break
        }
        case "hang":
          if (scenario === "cancellation" && !cancellationScheduled) {
            cancellationScheduled = true
            setTimeout(() => void send({ type: "cancel" }), 50)
          }
          break
        default:
          await send({ type: "error", id: frame.id, error: `Unknown prototype tool: ${frame.name}` })
      }
    }
  })()

  const hardDeadline = setTimeout(
    () => {
      killed = worker.kill()
    },
    scenario === "hard-kill" ? 300 : 3_000
  )
  const workerExitCode = await worker.exited
  clearTimeout(hardDeadline)
  await Promise.all([protocolPromise, writeChain.catch(() => {}), stdoutPromise, stderrPromise])
  const report: ScenarioReport = {
    scenario,
    workerExitCode,
    stdout: await stdoutPromise,
    stderr: await stderrPromise,
    calls,
    final,
    killed,
    elapsedMs: Date.now() - startedAt
  }
  console.log(JSON.stringify(report))
}

function spawnWorker(): SpawnedWorker {
  if (process.platform === "win32") {
    const child = spawn(process.execPath, [workerArgument], {
      stdio: ["pipe", "pipe", "pipe", "pipe"],
      windowsHide: true
    })
    const protocol = child.stdio[3]
    if (!child.stdin || !child.stdout || !child.stderr || !(protocol instanceof Readable)) {
      child.kill("SIGKILL")
      throw new Error("Prototype worker did not expose all required Windows pipes")
    }
    return nodeWorker(child, protocol)
  }

  const child = Bun.spawn([process.execPath, workerArgument], {
    stdin: "pipe",
    stdout: "pipe",
    stderr: "pipe",
    stdio: ["pipe", "pipe", "pipe", "pipe"],
    windowsHide: true
  })
  const protocolDescriptor = child.stdio[3]
  if (typeof protocolDescriptor !== "number") {
    child.kill("SIGKILL")
    throw new Error("Prototype worker did not expose its protocol pipe")
  }
  return {
    stdin: {
      async write(value) {
        await child.stdin.write(value)
        await child.stdin.flush()
      },
      async close() {
        await child.stdin.end()
      }
    },
    stdout: child.stdout,
    stderr: child.stderr,
    protocol: Bun.file(protocolDescriptor).stream(),
    exited: child.exited,
    kill: () => {
      child.kill("SIGKILL")
      return true
    }
  }
}

function nodeWorker(child: ChildProcessWithoutNullStreams, protocol: Readable): SpawnedWorker {
  return {
    stdin: {
      write: value =>
        new Promise<void>((resolve, reject) => {
          child.stdin.write(value, cause => {
            if (cause) {
              reject(cause)
              return
            }
            resolve()
          })
        }),
      close: () =>
        new Promise<void>(resolve => {
          child.stdin.end(resolve)
        })
    },
    stdout: child.stdout,
    stderr: child.stderr,
    protocol,
    exited: new Promise<number>((resolve, reject) => {
      child.once("error", reject)
      child.once("close", (code, signal) => resolve(code ?? (signal ? 1 : 0)))
    }),
    kill: () => child.kill("SIGKILL")
  }
}

interface QuickJsRun {
  readonly settled: Promise<void>
  settle(frame: Extract<ParentFrame, { type: "result" | "error" }>): void
  cancel(): void
}

async function runWorker(): Promise<void> {
  let active: QuickJsRun | undefined
  for await (const line of readLines(process.stdin)) {
    const frame = parseParentFrame(line)
    if (frame.type === "start") {
      if (active) throw new Error("Prototype worker accepts one execution")
      active = await startQuickJsRun(frame)
    } else if (frame.type === "cancel") {
      active?.cancel()
    } else {
      active?.settle(frame)
    }
  }
  await active?.settled
  closeSync(3)
}

async function startQuickJsRun(frame: Extract<ParentFrame, { type: "start" }>): Promise<QuickJsRun> {
  const QuickJS = await newQuickJSWASMModuleFromVariant(quickJsVariant)
  const runtime = QuickJS.newRuntime()
  runtime.setMemoryLimit(frame.memoryLimitBytes)
  runtime.setMaxStackSize(512 * 1024)
  const deadline = Date.now() + frame.timeoutMs
  runtime.setInterruptHandler(() => Date.now() >= deadline)
  const context = runtime.newContext()
  const pending = new Map<number, QuickJSDeferredPromise>()
  const logs: string[] = []
  let nextCallId = 0
  let ended = false
  let resolveSettled!: () => void
  const settled = new Promise<void>(resolve => {
    resolveSettled = resolve
  })

  const finish = (final: Exclude<WorkerFrame, { type: "call" }>): void => {
    if (ended) return
    ended = true
    writeWorkerFrame(final)
    for (const deferred of pending.values()) deferred.dispose()
    pending.clear()
    context.dispose()
    runtime.dispose()
    resolveSettled()
  }

  const hostCall = context.newFunction("__hostCall", (nameHandle, argumentsHandle) => {
    const name = context.getString(nameHandle)
    const argumentsJson = context.getString(argumentsHandle)
    if (ended) return context.newString(JSON.stringify({ error: "Execution ended" }))
    if (nextCallId >= 16) return context.newString(JSON.stringify({ error: "Prototype tool-call limit exceeded" }))
    const id = nextCallId++
    const deferred = context.newPromise()
    pending.set(id, deferred)
    writeWorkerFrame({ type: "call", id, name, arguments: JSON.parse(argumentsJson) })
    return deferred.handle
  })
  hostCall.consume(handle => context.setProp(context.global, "__hostCall", handle))

  const hostLog = context.newFunction("__hostLog", valueHandle => {
    if (logs.length < 32) logs.push(context.getString(valueHandle).slice(0, 4_096))
  })
  hostLog.consume(handle => context.setProp(context.global, "__hostLog", handle))

  try {
    context
      .unwrapResult(
        context.evalCode(`
(() => {
  const callHost = globalThis.__hostCall;
  const writeLog = globalThis.__hostLog;
  globalThis.zi = new Proxy(Object.create(null), {
    get: (_target, name) => async (arguments_) => {
      const response = JSON.parse(await callHost(String(name), JSON.stringify(arguments_)));
      if (response.error) throw new Error(response.error);
      return response.result;
    }
  });
  globalThis.console = Object.freeze({
    log: (...values) => writeLog(values.map(String).join(" ")),
    warn: (...values) => writeLog("[warn] " + values.map(String).join(" ")),
    error: (...values) => writeLog("[error] " + values.map(String).join(" "))
  });
  delete globalThis.__hostCall;
  delete globalThis.__hostLog;
})();
`)
      )
      .dispose()

    const evaluation = context.evalCode(`(${frame.code})()`)
    if (evaluation.error) {
      const message = quickJsError(context.dump(evaluation.error))
      evaluation.error.dispose()
      finish({ type: "failed", error: message, logs })
      return { settled, settle: () => {}, cancel: () => {} }
    }

    const promiseHandle = evaluation.value
    const resultPromise = context.resolvePromise(promiseHandle)
    promiseHandle.dispose()
    const initialJobs = runtime.executePendingJobs()
    if (initialJobs.error) {
      const message = quickJsError(context.dump(initialJobs.error))
      initialJobs.error.dispose()
      finish({ type: "failed", error: message, logs })
      return { settled, settle: () => {}, cancel: () => {} }
    }
    void resultPromise.then(result => {
      if (ended) {
        if ("value" in result) result.value.dispose()
        else result.error.dispose()
        return undefined
      }
      if (result.error) {
        const message = quickJsError(context.dump(result.error))
        result.error.dispose()
        finish({ type: "failed", error: message, logs })
        return undefined
      }
      const value = context.dump(result.value)
      result.value.dispose()
      finish({ type: "completed", result: value, logs })
      return undefined
    })
  } catch (cause) {
    finish({ type: "failed", error: errorMessage(cause), logs })
  }

  return {
    settled,
    settle(response) {
      if (ended) return
      const deferred = pending.get(response.id)
      if (!deferred) return
      pending.delete(response.id)
      const envelope = response.type === "result" ? { result: response.result } : { error: response.error }
      const value = context.newString(JSON.stringify(envelope))
      deferred.resolve(value)
      value.dispose()
      const jobs = runtime.executePendingJobs()
      if (jobs.error) {
        const message = quickJsError(context.dump(jobs.error))
        jobs.error.dispose()
        finish({ type: "failed", error: message, logs })
      }
    },
    cancel() {
      finish({ type: "failed", error: "Execution cancelled", logs })
    }
  }
}

function scenarioCode(scenario: Scenario): string {
  switch (scenario) {
    case "success":
      return `async () => {
  const upper = await zi.upper({ value: "zi" });
  const sum = await zi.add({ left: 20, right: 22 });
  console.log(upper, sum);
  return { upper, sum };
}`
    case "isolation":
      return `async () => ({
  process: typeof process,
  Bun: typeof Bun,
  require: typeof require,
  fetch: typeof fetch,
  hostCall: typeof __hostCall,
  hostLog: typeof __hostLog
})`
    case "cpu-limit":
      return `async () => { while (true) {} }`
    case "memory-limit":
      return `async () => {
  const values = [];
  for (let index = 0; index < 1_000_000; index++) values.push("value-" + index);
  return values.length;
}`
    case "cancellation":
      return `async () => {
  try { await zi.hang({}); } catch {}
  await zi.upper({ value: "should-not-run" });
  return "continued";
}`
    case "hard-kill":
      return `async () => await zi.hang({})`
    default:
      return assertNever(scenario)
  }
}

function writeWorkerFrame(frame: WorkerFrame): void {
  writeFileSync(3, `${JSON.stringify(frame)}\n`)
}

async function* readLines(stream: AsyncIterable<Uint8Array | string>): AsyncGenerator<string> {
  const decoder = new TextDecoder()
  let buffered = ""
  for await (const chunk of stream) {
    buffered += typeof chunk === "string" ? chunk : decoder.decode(chunk, { stream: true })
    let newline = buffered.indexOf("\n")
    while (newline >= 0) {
      const line = buffered.slice(0, newline)
      buffered = buffered.slice(newline + 1)
      if (line) yield line
      newline = buffered.indexOf("\n")
    }
  }
  buffered += decoder.decode()
  if (buffered) yield buffered
}

async function readAll(stream: AsyncIterable<Uint8Array | string>): Promise<string> {
  const chunks: Uint8Array[] = []
  for await (const chunk of stream) chunks.push(typeof chunk === "string" ? Buffer.from(chunk) : chunk)
  return Buffer.concat(chunks).toString("utf8")
}

async function runProcess(executable: string, arguments_: readonly string[]) {
  const child = Bun.spawn([executable, ...arguments_], { stdin: "ignore", stdout: "pipe", stderr: "pipe" })
  const [exitCode, stdout, stderr] = await Promise.all([
    child.exited,
    new Response(child.stdout).text(),
    new Response(child.stderr).text()
  ])
  return { exitCode, stdout, stderr }
}

function parseParentFrame(line: string): ParentFrame {
  const value: unknown = JSON.parse(line)
  if (!isRecord(value) || typeof value.type !== "string") throw new Error("Invalid parent frame")
  if (
    value.type === "start" &&
    typeof value.code === "string" &&
    typeof value.timeoutMs === "number" &&
    typeof value.memoryLimitBytes === "number"
  ) {
    return { type: "start", code: value.code, timeoutMs: value.timeoutMs, memoryLimitBytes: value.memoryLimitBytes }
  }
  if (value.type === "result" && typeof value.id === "number")
    return { type: "result", id: value.id, result: value.result }
  if (value.type === "error" && typeof value.id === "number" && typeof value.error === "string") {
    return { type: "error", id: value.id, error: value.error }
  }
  if (value.type === "cancel") return { type: "cancel" }
  throw new Error("Invalid parent frame")
}

function parseWorkerFrame(line: string): WorkerFrame {
  const value: unknown = JSON.parse(line)
  if (!isRecord(value) || typeof value.type !== "string") throw new Error("Invalid worker frame")
  if (value.type === "call" && typeof value.id === "number" && typeof value.name === "string" && "arguments" in value) {
    return { type: "call", id: value.id, name: value.name, arguments: value.arguments }
  }
  const logs = Array.isArray(value.logs) && value.logs.every(log => typeof log === "string") ? value.logs : undefined
  if (value.type === "completed" && logs) return { type: "completed", result: value.result, logs }
  if (value.type === "failed" && typeof value.error === "string" && logs) {
    return { type: "failed", error: value.error, logs }
  }
  throw new Error("Invalid worker frame")
}

function parseScenario(value: string): Scenario {
  if (
    value === "success" ||
    value === "isolation" ||
    value === "cpu-limit" ||
    value === "memory-limit" ||
    value === "cancellation" ||
    value === "hard-kill"
  ) {
    return value
  }
  throw new Error(`Unknown prototype scenario: ${value}`)
}

function requiredArgument(name: string): string {
  const index = process.argv.indexOf(name)
  const value = process.argv[index + 1]
  if (!value) throw new Error(`${name} requires a value`)
  return value
}

function completedResult(report: ScenarioReport): unknown {
  return report.final?.type === "completed" ? report.final.result : undefined
}

function quickJsError(value: unknown): string {
  if (isRecord(value) && typeof value.message === "string") return value.message
  return typeof value === "string" ? value : JSON.stringify(value)
}

function errorMessage(cause: unknown): string {
  return cause instanceof Error ? cause.message : String(cause)
}

function isScenarioReport(value: unknown): value is ScenarioReport {
  return (
    isRecord(value) &&
    typeof value.scenario === "string" &&
    typeof value.workerExitCode === "number" &&
    typeof value.stdout === "string" &&
    typeof value.stderr === "string" &&
    Array.isArray(value.calls) &&
    typeof value.killed === "boolean" &&
    typeof value.elapsedMs === "number"
  )
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}

function assertNever(value: never): never {
  throw new Error(`Unknown prototype scenario: ${String(value)}`)
}
