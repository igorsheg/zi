import { expect, test } from "bun:test"
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { createProcessScope, maxTrackedProcessIdentities, PosixProcessScope } from "../src/extensions/process-scope.js"

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
  try {
    const scope = new PosixProcessScope(requirePid(worker))
    expect(scope.snapshot().identities.some(identity => identity.pid === worker.pid)).toBe(true)
    expect(scope.refresh()).toEqual({ type: "ok" })

    const result = scope.terminate()
    expect(result.type).toBe("terminated")
    await worker.exited
    expect(processAlive(requirePid(worker))).toBe(false)
  } finally {
    try {
      process.kill(-requirePid(worker), "SIGKILL")
    } catch {
      // already dead
    }
  }
})

test("POSIX process scope retains detached descendant PGIDs across worker SIGKILL", async () => {
  if (!isPosix) return

  const root = mkdtempSync(join(tmpdir(), "zi-process-scope-"))
  const marker = join(root, "info.json")
  const script = join(root, "worker.mjs")
  writeFileSync(
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

  try {
    const info = asInfo(await waitForJson(marker))
    const scope = new PosixProcessScope(requirePid(worker))
    // Detached sleep is a child; refresh must capture its PGID before the worker dies.
    await waitFor(() => {
      scope.refresh()
      return scope.snapshot().identities.some(identity => identity.pid === info.childPid)
    })
    expect(scope.snapshot().identities.some(identity => identity.pid === info.childPid)).toBe(true)

    process.kill(requirePid(worker), "SIGKILL")
    await worker.exited
    // Detached child is reparented and would otherwise survive a worker-only kill.
    expect(processAlive(info.childPid)).toBe(true)

    const result = scope.terminate()
    expect(result.type === "terminated" || result.type === "overflow").toBe(true)
    await waitFor(() => !processAlive(info.childPid))
    expect(processAlive(info.childPid)).toBe(false)
  } finally {
    try {
      process.kill(-requirePid(worker), "SIGKILL")
    } catch {
      // already dead
    }
    try {
      const info = asInfo(JSON.parse(await Bun.file(marker).text()))
      if (info.childPid > 0) process.kill(-info.childPid, "SIGKILL")
    } catch {
      // already dead
    }
    rmSync(root, { recursive: true, force: true })
  }
})

test("POSIX process scope overflow fails closed without dropping already tracked identities", async () => {
  if (!isPosix) return

  const root = mkdtempSync(join(tmpdir(), "zi-process-scope-overflow-"))
  const marker = join(root, "ready")
  const script = join(root, "worker.mjs")
  // Spawn many detached children so refresh exceeds the hard bound.
  writeFileSync(
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

  try {
    const info = asInfo(await waitForJson(marker))
    const scope = new PosixProcessScope(requirePid(worker))
    // Constructor refresh may already overflow; keep polling until the bound is observed.
    let overflow = scope.refresh().type === "overflow"
    for (let attempt = 0; attempt < 40 && !overflow; attempt++) {
      // oxlint-disable-next-line no-await-in-loop -- bounded overflow poll
      await Bun.sleep(50)
      overflow = scope.refresh().type === "overflow"
    }
    expect(overflow).toBe(true)
    expect(scope.snapshot().identities.length).toBeGreaterThan(0)
    expect(scope.snapshot().identities.length).toBeLessThanOrEqual(maxTrackedProcessIdentities)

    const terminated = scope.terminate()
    expect(terminated.type).toBe("overflow")
    await worker.exited

    // Best-effort cleanup of any children that raced past the bound.
    for (const pid of info.children) {
      try {
        process.kill(-pid, "SIGKILL")
      } catch {
        // already dead
      }
    }
  } finally {
    try {
      process.kill(-requirePid(worker), "SIGKILL")
    } catch {
      // already dead
    }
    rmSync(root, { recursive: true, force: true })
  }
})

test("process scope terminate does not signal the parent Zi process", async () => {
  if (!isPosix) return
  const parentPid = process.pid
  const worker = Bun.spawn({
    cmd: ["sleep", "60"],
    stdin: "ignore",
    stdout: "ignore",
    stderr: "ignore",
    detached: true
  })
  try {
    const scope = createProcessScope(requirePid(worker))
    scope.terminate()
    await worker.exited
    expect(process.pid).toBe(parentPid)
    expect(processAlive(parentPid)).toBe(true)
  } finally {
    try {
      process.kill(-requirePid(worker), "SIGKILL")
    } catch {
      // already dead
    }
  }
})

test("createProcessScope selects the platform owner", () => {
  // Smoke construction against a short-lived child of this process.
  const child = Bun.spawn({
    cmd: process.platform === "win32" ? ["cmd.exe", "/c", "ping -n 20 127.0.0.1 >nul"] : ["sleep", "20"],
    stdin: "ignore",
    stdout: "ignore",
    stderr: "ignore",
    ...(process.platform === "win32" ? {} : { detached: true })
  })
  try {
    const scope = createProcessScope(requirePid(child))
    expect(scope.platform).toBe(process.platform === "win32" ? "windows" : "posix")
    expect(scope.workerPid).toBe(child.pid)
    scope.dispose()
  } finally {
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

async function waitFor(predicate: () => boolean, timeoutMs = 3_000): Promise<void> {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    if (predicate()) return
    // oxlint-disable-next-line no-await-in-loop -- bounded poll
    await Bun.sleep(25)
  }
  throw new Error("Condition was not met before the deadline")
}

async function waitForJson(path: string, timeoutMs = 5_000): Promise<unknown> {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    try {
      // oxlint-disable-next-line no-await-in-loop -- bounded poll
      const text = await Bun.file(path).text()
      return JSON.parse(text)
    } catch {
      // oxlint-disable-next-line no-await-in-loop -- bounded poll
      await Bun.sleep(25)
    }
  }
  throw new Error(`Timed out waiting for ${path}`)
}

function asInfo(value: unknown): { workerPid: number; childPid: number; children: number[] } {
  if (!value || typeof value !== "object") throw new Error("invalid process-scope fixture info")
  const workerPid = Reflect.get(value, "workerPid")
  const childPid = Reflect.get(value, "childPid")
  const childrenValue = Reflect.get(value, "children")
  if (typeof workerPid !== "number" || (typeof childPid !== "number" && childrenValue === undefined)) {
    throw new Error("invalid process-scope fixture info")
  }
  const children = Array.isArray(childrenValue)
    ? childrenValue.filter((entry): entry is number => typeof entry === "number")
    : []
  return { workerPid, childPid: typeof childPid === "number" ? childPid : 0, children }
}

void mkdirSync
