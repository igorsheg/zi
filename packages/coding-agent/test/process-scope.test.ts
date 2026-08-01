import { expect, test } from "bun:test"
import { mkdtemp, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { createProcessTreeTracker, maxTrackedProcessIdentities } from "../src/processes/process-tree.js"

const isPosix = process.platform !== "win32"

test("POSIX process scope tracks the worker group and kills non-detached members", async () => {
  if (!isPosix) return

  const worker = Bun.spawn({
    cmd: ["bash", "-lc", "sleep 120"],
    stdin: "ignore",
    stdout: "ignore",
    stderr: "ignore",
    detached: true
  })
  const tracker = createProcessTreeTracker()
  try {
    const scope = tracker.track(requirePid(worker))
    await scope.admitted
    expect(scope.snapshot().identities.some(identity => identity.pid === worker.pid)).toBe(true)
    expect(await scope.refresh()).toEqual({ type: "ok" })

    const result = await scope.terminate()
    expect(result.type).toBe("terminated")
    await worker.exited
    expect(processAlive(requirePid(worker))).toBe(false)
  } finally {
    await tracker.dispose()
    killGroup(requirePid(worker))
  }
})

test("POSIX process scope retains detached descendant PGIDs across worker SIGKILL", async () => {
  if (!isPosix) return

  const root = await mkdtemp(join(tmpdir(), "zi-process-scope-"))
  const marker = join(root, "info.json")
  const script = join(root, "worker.mjs")
  await writeFile(
    script,
    [
      'import { spawn } from "node:child_process"',
      'import { writeFileSync } from "node:fs"',
      'const child = spawn("sleep", ["120"], { detached: true, stdio: "ignore" })',
      `writeFileSync(${JSON.stringify(marker)}, JSON.stringify({ workerPid: process.pid, childPid: child.pid }))`,
      "child.unref()",
      "setInterval(() => {}, 1 << 30)"
    ].join("\n")
  )

  const worker = Bun.spawn({
    cmd: [process.execPath, script],
    stdin: "ignore",
    stdout: "ignore",
    stderr: "ignore",
    detached: true
  })
  const tracker = createProcessTreeTracker()
  let childPid: number | undefined

  try {
    const info = asInfo(await waitForJson(marker))
    childPid = info.childPid
    const scope = tracker.track(requirePid(worker))
    await scope.admitted
    await waitFor(async () => {
      await scope.refresh()
      return scope.snapshot().identities.some(identity => identity.pid === info.childPid)
    })

    process.kill(requirePid(worker), "SIGKILL")
    await worker.exited
    expect(processAlive(info.childPid)).toBe(true)

    const result = await scope.terminate()
    expect(result.type === "terminated" || result.type === "overflow").toBe(true)
    await waitFor(() => !processAlive(info.childPid))
  } finally {
    await tracker.dispose()
    killGroup(requirePid(worker))
    if (childPid) killGroup(childPid)
    await rm(root, { recursive: true, force: true })
  }
})

test("POSIX process scope overflow fails closed without dropping its bound", async () => {
  if (!isPosix) return

  const root = await mkdtemp(join(tmpdir(), "zi-process-scope-overflow-"))
  const marker = join(root, "ready")
  const script = join(root, "worker.mjs")
  await writeFile(
    script,
    [
      'import { spawn } from "node:child_process"',
      'import { writeFileSync } from "node:fs"',
      `const count = ${maxTrackedProcessIdentities + 8}`,
      "const children = []",
      "for (let i = 0; i < count; i++) {",
      '  const child = spawn("sleep", ["120"], { detached: true, stdio: "ignore" })',
      "  children.push(child.pid)",
      "  child.unref()",
      "}",
      `writeFileSync(${JSON.stringify(marker)}, JSON.stringify({ workerPid: process.pid, children }))`,
      "setInterval(() => {}, 1 << 30)"
    ].join("\n")
  )

  const worker = Bun.spawn({
    cmd: [process.execPath, script],
    stdin: "ignore",
    stdout: "ignore",
    stderr: "ignore",
    detached: true
  })
  const tracker = createProcessTreeTracker()
  let children: readonly number[] = []

  try {
    const info = asInfo(await waitForJson(marker))
    children = info.children
    const scope = tracker.track(requirePid(worker))
    await scope.admitted
    let overflow = false
    for (let attempt = 0; attempt < 40 && !overflow; attempt++) {
      // oxlint-disable-next-line no-await-in-loop -- bounded overflow poll
      overflow = (await scope.refresh()).type === "overflow"
      if (!overflow) {
        // oxlint-disable-next-line no-await-in-loop -- bounded overflow poll
        await Bun.sleep(50)
      }
    }
    expect(overflow).toBe(true)
    expect(scope.snapshot().identities.length).toBeLessThanOrEqual(maxTrackedProcessIdentities)

    const terminated = await scope.terminate()
    expect(terminated.type === "overflow" || terminated.type === "closed").toBe(true)
    await worker.exited
  } finally {
    await tracker.dispose()
    killGroup(requirePid(worker))
    for (const pid of children) killGroup(pid)
    await rm(root, { recursive: true, force: true })
  }
}, 30_000)

test("process scope termination does not signal the parent Zi process", async () => {
  if (!isPosix) return
  const parentPid = process.pid
  const worker = Bun.spawn({
    cmd: ["sleep", "60"],
    stdin: "ignore",
    stdout: "ignore",
    stderr: "ignore",
    detached: true
  })
  const tracker = createProcessTreeTracker()
  try {
    const scope = tracker.track(requirePid(worker))
    await scope.admitted
    await scope.terminate()
    await worker.exited
    expect(process.pid).toBe(parentPid)
    expect(processAlive(parentPid)).toBe(true)
  } finally {
    await tracker.dispose()
    killGroup(requirePid(worker))
  }
})

test("process-tree tracker selects the platform owner", async () => {
  const child = Bun.spawn({
    cmd: process.platform === "win32" ? ["cmd.exe", "/c", "ping -n 20 127.0.0.1 >nul"] : ["sleep", "20"],
    stdin: "ignore",
    stdout: "ignore",
    stderr: "ignore",
    ...(process.platform === "win32" ? {} : { detached: true })
  })
  const tracker = createProcessTreeTracker()
  try {
    const scope = tracker.track(requirePid(child))
    await scope.admitted
    expect(scope.platform).toBe(process.platform === "win32" ? "windows" : "posix")
    expect(scope.workerPid).toBe(child.pid)
    await scope.dispose()
  } finally {
    await tracker.dispose()
    try {
      if (process.platform === "win32") child.kill()
      else process.kill(-requirePid(child), "SIGKILL")
    } catch {
      // already dead
    }
  }
})

function requirePid(child: { readonly pid?: number | null }): number {
  if (typeof child.pid !== "number" || child.pid <= 0) throw new Error("expected child pid")
  return child.pid
}

function processAlive(pid: number): boolean {
  try {
    process.kill(pid, 0)
    return true
  } catch {
    return false
  }
}

function killGroup(pid: number): void {
  try {
    process.kill(-pid, "SIGKILL")
  } catch {
    // already dead
  }
}

async function waitFor(predicate: () => boolean | Promise<boolean>, timeoutMs = 3_000): Promise<void> {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    // oxlint-disable-next-line no-await-in-loop -- bounded process settlement poll
    if (await predicate()) return
    // oxlint-disable-next-line no-await-in-loop -- bounded process settlement poll
    await Bun.sleep(25)
  }
  throw new Error("Condition was not met before the deadline")
}

async function waitForJson(path: string, timeoutMs = 5_000): Promise<unknown> {
  let value: unknown
  await waitFor(async () => {
    try {
      value = JSON.parse(await Bun.file(path).text())
      return true
    } catch {
      return false
    }
  }, timeoutMs)
  return value
}

function asInfo(value: unknown): {
  readonly workerPid: number
  readonly childPid: number
  readonly children: number[]
} {
  if (!value || typeof value !== "object") throw new Error("invalid process marker")
  const workerPid = Reflect.get(value, "workerPid")
  const childPid = Reflect.get(value, "childPid")
  const children = Reflect.get(value, "children")
  if (typeof workerPid !== "number") throw new Error("invalid process marker")
  return {
    workerPid,
    childPid: typeof childPid === "number" ? childPid : 0,
    children: Array.isArray(children) ? children.filter((pid): pid is number => typeof pid === "number") : []
  }
}
