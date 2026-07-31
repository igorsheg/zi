import { readdirSync, readFileSync } from "node:fs"

import type { WindowsHandle, WindowsJobNative } from "./process-scope-windows.js"

/**
 * Host-owned killable process scope for one extension-worker generation.
 *
 * POSIX keeps a live registry of PID/start-identity/PGID rows because SessionShell
 * children create detached process groups that survive worker-PGID signals alone.
 * Windows uses a Job Object with kill-on-close so descendant containment is OS-owned.
 */
export const maxTrackedProcessIdentities = 256

export type ProcessIdentity = { readonly pid: number; readonly startIdentity: string; readonly pgid: number }

export type ProcessScopeSnapshot = { readonly workerPid: number; readonly identities: readonly ProcessIdentity[] }

export type ProcessScopeTerminateResult =
  | { readonly type: "terminated"; readonly signaledGroups: number }
  | { readonly type: "overflow"; readonly signaledGroups: number }
  | { readonly type: "closed" }

export interface ProcessScope {
  readonly platform: "posix" | "windows"
  readonly workerPid: number
  snapshot(): ProcessScopeSnapshot
  refresh(): { readonly type: "ok" } | { readonly type: "overflow" }
  /** Signal every retained group (POSIX) or close the job (Windows). Idempotent. */
  terminate(): ProcessScopeTerminateResult
  dispose(): void
}

export class ProcessScopeOverflowError extends Error {
  constructor(message = `Process scope exceeded ${maxTrackedProcessIdentities} tracked identities`) {
    super(message)
    this.name = "ProcessScopeOverflowError"
  }
}

export function createProcessScope(workerPid: number): ProcessScope {
  if (process.platform === "win32") return new WindowsProcessScope(workerPid)
  return new PosixProcessScope(workerPid)
}

type PosixScopeState =
  | {
      readonly type: "tracking"
      readonly workerPid: number
      readonly workerPgid: number
      readonly workerStart: string
      readonly identities: Map<string, ProcessIdentity>
    }
  | { readonly type: "closed" }

export class PosixProcessScope implements ProcessScope {
  readonly platform = "posix" as const
  readonly workerPid: number
  #state: PosixScopeState

  constructor(workerPid: number, workerStartIdentity?: string) {
    if (!Number.isInteger(workerPid) || workerPid <= 0) {
      throw new Error("Process scope requires a positive worker pid")
    }
    const table = listPosixProcesses()
    const worker = table.find(row => row.pid === workerPid)
    const startIdentity = workerStartIdentity ?? worker?.startIdentity
    if (!startIdentity) throw new Error(`Could not resolve start identity for worker pid ${workerPid}`)
    const pgid = worker?.pgid ?? workerPid
    const identities = new Map<string, ProcessIdentity>()
    const self: ProcessIdentity = { pid: workerPid, startIdentity, pgid }
    identities.set(identityKey(self), self)
    this.workerPid = workerPid
    this.#state = { type: "tracking", workerPid, workerPgid: pgid, workerStart: startIdentity, identities }
    // Overflow is a refresh result the host must act on; do not throw away a partial registry.
    this.refresh()
  }

  snapshot(): ProcessScopeSnapshot {
    const state = this.#state
    if (state.type === "closed") return { workerPid: this.workerPid, identities: Object.freeze([]) }
    return { workerPid: state.workerPid, identities: Object.freeze([...state.identities.values()]) }
  }

  refresh(): { readonly type: "ok" } | { readonly type: "overflow" } {
    const state = this.#state
    if (state.type === "closed") return { type: "ok" }

    const table = listPosixProcesses()
    const byPid = new Map(table.map(row => [row.pid, row]))
    const worker = byPid.get(state.workerPid)
    // Worker already gone: keep the last pre-exit snapshot; never rediscover from a dead PID.
    if (!worker || worker.startIdentity !== state.workerStart) return { type: "ok" }

    const known = new Map(state.identities)
    for (const [key, identity] of known) {
      const live = byPid.get(identity.pid)
      if (!live || live.startIdentity !== identity.startIdentity) known.delete(key)
    }
    known.set(identityKey(worker), { pid: worker.pid, startIdentity: worker.startIdentity, pgid: worker.pgid })

    let grew = true
    while (grew) {
      grew = false
      for (const row of table) {
        const parentKnown = [...known.values()].some(identity => identity.pid === row.ppid)
        if (!parentKnown) continue
        const key = identityKey(row)
        if (known.has(key)) continue
        if (known.size >= maxTrackedProcessIdentities) {
          this.#state = {
            type: "tracking",
            workerPid: state.workerPid,
            workerPgid: worker.pgid,
            workerStart: state.workerStart,
            identities: known
          }
          return { type: "overflow" }
        }
        known.set(key, { pid: row.pid, startIdentity: row.startIdentity, pgid: row.pgid })
        grew = true
      }
    }

    this.#state = {
      type: "tracking",
      workerPid: state.workerPid,
      workerPgid: worker.pgid,
      workerStart: state.workerStart,
      identities: known
    }
    return { type: "ok" }
  }

  terminate(): ProcessScopeTerminateResult {
    const state = this.#state
    if (state.type === "closed") return { type: "closed" }

    const refresh = this.refresh()
    const current = this.#state
    if (current.type === "closed") return { type: "closed" }

    const groups = new Set<number>([current.workerPgid])
    for (const identity of current.identities.values()) groups.add(identity.pgid)

    let signaledGroups = 0
    for (const pgid of groups) {
      if (pgid <= 1) continue
      if (signalProcessGroup(pgid, "SIGKILL")) signaledGroups++
    }

    const deadline = Date.now() + 1_000
    while (Date.now() < deadline) {
      const live = listPosixProcesses()
      const remaining = [...current.identities.values()].filter(identity => {
        const row = live.find(candidate => candidate.pid === identity.pid)
        return row !== undefined && row.startIdentity === identity.startIdentity
      })
      if (remaining.length === 0) break
      for (const identity of remaining) signalProcessGroup(identity.pgid, "SIGKILL")
      Bun.sleepSync(20)
    }

    this.#state = { type: "closed" }
    return refresh.type === "overflow" ? { type: "overflow", signaledGroups } : { type: "terminated", signaledGroups }
  }

  dispose(): void {
    if (this.#state.type !== "closed") this.terminate()
  }
}

type WindowsScopeState = { readonly type: "tracking"; readonly job: WindowsJobHandle } | { readonly type: "closed" }

export class WindowsProcessScope implements ProcessScope {
  readonly platform = "windows" as const
  readonly workerPid: number
  #state: WindowsScopeState

  constructor(workerPid: number) {
    if (!Number.isInteger(workerPid) || workerPid <= 0) {
      throw new Error("Process scope requires a positive worker pid")
    }
    const job = WindowsJobHandle.create()
    try {
      job.assign(workerPid)
    } catch (cause) {
      job.dispose()
      throw cause
    }
    this.workerPid = workerPid
    this.#state = { type: "tracking", job }
  }

  snapshot(): ProcessScopeSnapshot {
    return {
      workerPid: this.workerPid,
      identities: Object.freeze([
        { pid: this.workerPid, startIdentity: `windows:${this.workerPid}`, pgid: this.workerPid }
      ])
    }
  }

  refresh(): { readonly type: "ok" } | { readonly type: "overflow" } {
    return { type: "ok" }
  }

  terminate(): ProcessScopeTerminateResult {
    const state = this.#state
    if (state.type === "closed") return { type: "closed" }
    // Closing the job handle kills every member when KILL_ON_JOB_CLOSE is set.
    state.job.dispose()
    this.#state = { type: "closed" }
    return { type: "terminated", signaledGroups: 1 }
  }

  dispose(): void {
    if (this.#state.type !== "closed") this.terminate()
  }
}

type PosixProcessRow = {
  readonly pid: number
  readonly ppid: number
  readonly pgid: number
  readonly startIdentity: string
}

function identityKey(identity: { readonly pid: number; readonly startIdentity: string }): string {
  return `${identity.pid}:${identity.startIdentity}`
}

function signalProcessGroup(pgid: number, signal: NodeJS.Signals): boolean {
  try {
    process.kill(-pgid, signal)
    return true
  } catch {
    return false
  }
}

function listPosixProcesses(): PosixProcessRow[] {
  if (process.platform === "linux") return listLinuxProcesses()
  return listPsProcesses()
}

function listLinuxProcesses(): PosixProcessRow[] {
  const rows: PosixProcessRow[] = []
  let entries: string[]
  try {
    entries = readdirSync("/proc")
  } catch {
    return listPsProcesses()
  }
  for (const entry of entries) {
    if (!/^\d+$/.test(entry)) continue
    try {
      const stat = readFileSync(`/proc/${entry}/stat`, "utf8")
      const open = stat.indexOf("(")
      const close = stat.lastIndexOf(")")
      if (open <= 0 || close <= open) continue
      const pid = Number(stat.slice(0, open - 1))
      const rest = stat.slice(close + 2).split(" ")
      // fields after comm: state ppid pgrp ... starttime at index 19
      const ppid = Number(rest[1])
      const pgid = Number(rest[2])
      const startIdentity = rest[19] ?? ""
      if (!Number.isInteger(pid) || !Number.isInteger(ppid) || !Number.isInteger(pgid) || startIdentity.length === 0) {
        continue
      }
      rows.push({ pid, ppid, pgid, startIdentity })
    } catch {
      // raced with exit
    }
  }
  return rows
}

function listPsProcesses(): PosixProcessRow[] {
  const result = Bun.spawnSync(["ps", "-axo", "pid=,ppid=,pgid=,lstart="], { stdout: "pipe", stderr: "pipe" })
  if (result.exitCode !== 0) return []
  const rows: PosixProcessRow[] = []
  for (const line of result.stdout.toString().split("\n")) {
    const trimmed = line.trim()
    if (trimmed.length === 0) continue
    const match = /^(\d+)\s+(\d+)\s+(\d+)\s+(.+)$/.exec(trimmed)
    if (!match) continue
    const startIdentity = match[4]
    if (startIdentity === undefined) continue
    rows.push({
      pid: Number(match[1]),
      ppid: Number(match[2]),
      pgid: Number(match[3]),
      startIdentity: startIdentity.trim()
    })
  }
  return rows
}

/** Win32 Job Object with JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE. */
class WindowsJobHandle {
  #handle: WindowsHandle | undefined
  readonly #native: WindowsJobNative

  private constructor(native: WindowsJobNative, handle: WindowsHandle) {
    this.#native = native
    this.#handle = handle
  }

  static create(): WindowsJobHandle {
    // Lazy require keeps kernel32/bun:ffi out of POSIX module evaluation.
    const windows = loadWindowsModule()
    const native = windows.loadWindowsJobNative()
    const handle = native.createJob()
    try {
      native.configureKillOnClose(handle)
    } catch (cause) {
      native.close(handle)
      throw cause
    }
    return new WindowsJobHandle(native, handle)
  }

  assign(pid: number): void {
    const handle = this.#handle
    if (handle === undefined) throw new Error("Windows job is closed")
    this.#native.assignPid(handle, pid)
  }

  dispose(): void {
    const handle = this.#handle
    if (handle === undefined) return
    this.#handle = undefined
    this.#native.close(handle)
  }
}

function loadWindowsModule(): { loadWindowsJobNative: () => WindowsJobNative } {
  // Windows module is required only when create() runs on win32.
  // oxlint-disable-next-line typescript/no-unsafe-type-assertion
  return require("./process-scope-windows.js") as { loadWindowsJobNative: () => WindowsJobNative }
}
