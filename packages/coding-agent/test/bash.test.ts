import { expect, test } from "bun:test"
import { existsSync, rmSync } from "node:fs"
import { mkdtemp, readFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"

import { createBashTool } from "../src/tools/bash.js"
import { DEFAULT_MAX_BYTES } from "../src/tools/truncate.js"

test("bash bounds model output and preserves the full stream", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "openzi-bash-"))
  const tool = createBashTool(cwd)
  const result = await tool.execute("bash-1", {
    command: `node -e "process.stdout.write('x'.repeat(${DEFAULT_MAX_BYTES + 4096}))"`
  })

  const output = result.content[0]
  expect(output?.type).toBe("text")
  if (output?.type !== "text") throw new Error("Expected text output")
  expect(Buffer.byteLength(output.text)).toBeLessThan(DEFAULT_MAX_BYTES + 512)
  expect(result.details?.truncation?.truncated).toBe(true)
  expect(result.details?.fullOutputPath && existsSync(result.details.fullOutputPath)).toBe(true)

  if (result.details?.fullOutputPath) rmSync(dirname(result.details.fullOutputPath), { recursive: true, force: true })
})

test("bash cancellation terminates the process group and settles with bounded output", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "openzi-bash-abort-"))
  const tool = createBashTool(cwd)
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

  await started.promise
  controller.abort()
  const error = await rejection(execution)

  expect(error.message).toContain("started")
  expect(error.message).toContain("Command aborted")
})

test("bash cancellation kills a SIGTERM-resistant descendant before settling", async () => {
  if (process.platform === "win32") return
  const cwd = await mkdtemp(join(tmpdir(), "openzi-bash-group-abort-"))
  const pidPath = join(cwd, "child.pid")
  const script = `const fs=require('fs');fs.writeFileSync(${JSON.stringify(
    pidPath
  )},String(process.pid));process.on('SIGTERM',()=>{});setInterval(()=>{},1000)`
  const tool = createBashTool(cwd)
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
    rmSync(cwd, { recursive: true, force: true })
  }
})

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
