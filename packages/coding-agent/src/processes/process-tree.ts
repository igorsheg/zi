import { readdir, readFile } from "node:fs/promises"

import { loadWindowsJobNative, type WindowsHandle, type WindowsJobNative } from "./process-tree-windows.js"

export const maxTrackedProcessIdentities = 256
export const maxTrackedProcessScopes = 8

const processTreeRefreshMs = 250
const processTreeScanTimeoutMs = 2_000
const processTreeSettleMs = 1_000
const processTreeSettlePollMs = 20
const maxProcessTableEntries = 32_768
const maxProcessTableBytes = 8 * 1024 * 1024
const maxAdmissionMisses = 4

export interface PosixProcessRow {
  readonly pid: number
  readonly ppid: number
  readonly pgid: number
  readonly startIdentity: string
}

export type ProcessTableReader = (signal: AbortSignal) => Promise<readonly PosixProcessRow[]>

export type ProcessIdentity = { readonly pid: number; readonly startIdentity: string; readonly pgid: number }

export type ProcessScopeSnapshot = { readonly workerPid: number; readonly identities: readonly ProcessIdentity[] }

export type ProcessScopeRefreshResult = { readonly type: "ok" } | { readonly type: "overflow" }

export type ProcessScopeTerminateResult =
  | { readonly type: "terminated"; readonly signaledGroups: number }
  | { readonly type: "overflow"; readonly signaledGroups: number }
  | { readonly type: "closed" }

export interface ProcessScope {
  readonly platform: "posix" | "windows"
  readonly workerPid: number
  readonly admitted: Promise<void>
  snapshot(): ProcessScopeSnapshot
  refresh(): Promise<ProcessScopeRefreshResult>
  terminate(): Promise<ProcessScopeTerminateResult>
  dispose(): Promise<void>
}

export interface ProcessTreeTracker {
  track(workerPid: number, onFailure?: (error: Error) => void): ProcessScope
  dispose(): Promise<void>
}

type TrackerState =
  | { readonly type: "open" }
  | { readonly type: "recovering"; readonly error: Error; readonly settled: Promise<void> }
  | { readonly type: "failed"; readonly error: Error }
  | { readonly type: "disposing"; readonly settled: Promise<void> }
  | { readonly type: "disposed" }

class ProcessTableScanStalledError extends Error {}

type PosixTrackingState = {
  readonly type: "tracking"
  readonly workerPgid: number
  readonly workerStart: string
  readonly identities: Map<string, ProcessIdentity>
  readonly overflow: boolean
}

type PosixScopeState =
  | { readonly type: "admitting" }
  | PosixTrackingState
  | {
      readonly type: "closed"
      readonly overflow: boolean
      readonly workerPgid: number
      readonly identities: readonly ProcessIdentity[]
    }

interface TrackedScope {
  readonly scope: PosixProcessScope
  readonly onFailure: ((error: Error) => void) | undefined
  admissionMisses: number
}

export function createProcessTreeTracker(): ProcessTreeTracker {
  return process.platform === "win32"
    ? new WindowsProcessTreeTracker()
    : new PosixProcessTreeTracker(readPosixProcessTable, processTreeRefreshMs)
}

export class PosixProcessTreeTracker implements ProcessTreeTracker {
  readonly #read: ProcessTableReader
  readonly #refreshMs: number
  readonly #signalGroup: (pgid: number, signal: NodeJS.Signals) => boolean
  readonly #sleep: (ms: number) => Promise<void>
  readonly #scanTimeoutMs: number
  readonly #scanCancellationMs: number
  readonly #scopes = new Map<PosixProcessScope, TrackedScope>()
  readonly #terminations = new Map<PosixProcessScope, Promise<ProcessScopeTerminateResult>>()
  #state: TrackerState = { type: "open" }
  #refresh: Promise<readonly PosixProcessRow[]> | undefined
  #rawScan: { readonly promise: Promise<readonly PosixProcessRow[]>; readonly controller: AbortController } | undefined
  #timer: ReturnType<typeof setTimeout> | undefined

  constructor(
    read: ProcessTableReader,
    refreshMs = processTreeRefreshMs,
    signalGroup = signalProcessGroup,
    sleep = (ms: number) => Bun.sleep(ms),
    scanTimeoutMs = processTreeScanTimeoutMs,
    scanCancellationMs = processTreeSettleMs
  ) {
    if (!Number.isFinite(refreshMs) || refreshMs <= 0) throw new Error("Process-tree refresh interval must be positive")
    if (!Number.isFinite(scanTimeoutMs) || scanTimeoutMs <= 0) {
      throw new Error("Process-tree scan timeout must be positive")
    }
    if (!Number.isFinite(scanCancellationMs) || scanCancellationMs <= 0) {
      throw new Error("Process-tree scan cancellation bound must be positive")
    }
    this.#read = read
    this.#refreshMs = refreshMs
    this.#signalGroup = signalGroup
    this.#sleep = sleep
    this.#scanTimeoutMs = scanTimeoutMs
    this.#scanCancellationMs = scanCancellationMs
  }

  track(workerPid: number, onFailure?: (error: Error) => void): ProcessScope {
    const state = this.#state
    if (state.type === "recovering") {
      throw new Error(`Process-tree tracker is recovering after: ${state.error.message}`, { cause: state.error })
    }
    if (state.type === "failed") {
      throw new Error(`Process-tree tracker failed after: ${state.error.message}`, { cause: state.error })
    }
    if (state.type !== "open") throw new Error("Process-tree tracker is disposed")
    if (this.#scopes.size >= maxTrackedProcessScopes) {
      throw new Error(`Process-tree scope capacity exceeded (maximum ${maxTrackedProcessScopes})`)
    }
    const scope = new PosixProcessScope(this, workerPid)
    this.#scopes.set(scope, { scope, onFailure, admissionMisses: 0 })
    void this.refresh().catch(() => {})
    return scope
  }

  refresh(): Promise<readonly PosixProcessRow[]> {
    return this.#refreshScopes(false)
  }

  async #refreshScopes(duringDisposal: boolean): Promise<readonly PosixProcessRow[]> {
    const state = this.#state
    if (state.type === "recovering" || state.type === "failed") throw state.error
    if (state.type === "disposed" || (state.type === "disposing" && !duringDisposal)) {
      throw new Error("Process-tree tracker is disposed")
    }
    if (this.#refresh) return this.#refresh

    const refresh = this.#readRows().then(
      rows => {
        if (this.#state.type !== "open" && this.#state.type !== "disposing") return rows
        for (const record of this.#scopes.values()) {
          const result = record.scope.apply(rows)
          if (result === "missing") {
            record.admissionMisses++
            if (record.admissionMisses >= maxAdmissionMisses) {
              this.#failScope(
                record,
                new Error(`Could not resolve start identity for worker pid ${record.scope.workerPid}`)
              )
            }
          } else {
            record.admissionMisses = 0
          }
          if (result === "overflow") {
            this.#failScope(
              record,
              new Error(`Process scope exceeded ${maxTrackedProcessIdentities} tracked identities`)
            )
          }
        }
        this.#schedule()
        return rows
      },
      cause => {
        const error = cause instanceof Error ? cause : new Error(String(cause))
        if (this.#state.type === "disposing") this.#failTrackedScopes(error)
        else if (error instanceof ProcessTableScanStalledError) this.#fail(error)
        else this.#recover(error)
        throw error
      }
    )
    this.#refresh = refresh
    void refresh.then(
      () => {
        if (this.#refresh === refresh) this.#refresh = undefined
        return undefined
      },
      () => {
        if (this.#refresh === refresh) this.#refresh = undefined
        return undefined
      }
    )
    return refresh
  }

  terminate(scope: PosixProcessScope): Promise<ProcessScopeTerminateResult> {
    const current = this.#terminations.get(scope)
    if (current) return current
    const termination = this.#terminate(scope)
    this.#terminations.set(scope, termination)
    const release = (): void => {
      if (this.#terminations.get(scope) === termination) this.#terminations.delete(scope)
    }
    void termination.then(release, release)
    return termination
  }

  async #terminate(scope: PosixProcessScope): Promise<ProcessScopeTerminateResult> {
    if (!this.#scopes.has(scope)) return scope.closedResult()
    try {
      await this.refresh()
    } catch {
      return scope.closedResult()
    }
    if (!this.#scopes.delete(scope)) return scope.closedResult()
    const result = scope.close(this.#signalGroup)
    await this.#settle(scope)
    return result
  }

  dispose(): Promise<void> {
    const state = this.#state
    if (state.type === "disposed") return Promise.resolve()
    if (state.type === "disposing") return state.settled

    let resolve!: () => void
    let reject!: (cause: unknown) => void
    const settled = new Promise<void>((complete, fail) => {
      resolve = complete
      reject = fail
    })
    const recovery = state.type === "recovering" ? state.settled : Promise.resolve()
    this.#state = { type: "disposing", settled }
    if (this.#timer) clearTimeout(this.#timer)
    this.#timer = undefined
    void this.#dispose(recovery).then(
      () => {
        this.#state = { type: "disposed" }
        resolve()
        return undefined
      },
      cause => {
        this.#state = { type: "disposed" }
        reject(cause)
        return undefined
      }
    )
    return settled
  }

  async #dispose(recovery: Promise<void>): Promise<void> {
    if (this.#scopes.size > 0) {
      try {
        await this.#refreshScopes(true)
      } catch {
        // Known process groups are still terminated below when the final scan fails.
      }
    } else if (this.#refresh) {
      await this.#refresh.catch(() => undefined)
    }
    const scopes = [...this.#scopes.keys()]
    this.#scopes.clear()
    for (const scope of scopes) scope.close(this.#signalGroup)
    await Promise.all(scopes.map(scope => this.#settle(scope)))
    await Promise.allSettled([recovery, ...this.#terminations.values()])
  }

  async #readRows(): Promise<readonly PosixProcessRow[]> {
    if (this.#rawScan) return this.#rawScan.promise
    const controller = new AbortController()
    let abortTimer: ReturnType<typeof setTimeout> | undefined
    let forceTimer: ReturnType<typeof setTimeout> | undefined
    // Give cancellable readers a bounded cleanup window, then reject even if a backend violates cancellation.
    const deadline = new Promise<never>((_, reject) => {
      abortTimer = setTimeout(() => {
        const error = new Error("Process-table scan timed out")
        controller.abort(error)
        forceTimer = setTimeout(
          () =>
            reject(
              new ProcessTableScanStalledError(
                `Process-table scan timed out and did not settle within ${this.#scanCancellationMs}ms`
              )
            ),
          this.#scanCancellationMs
        )
        forceTimer.unref?.()
      }, this.#scanTimeoutMs)
      abortTimer.unref?.()
    })
    let operation: Promise<readonly PosixProcessRow[]>
    try {
      operation = this.#read(controller.signal)
    } catch (cause) {
      operation = Promise.reject(cause)
    }
    const cancellable = operation.then(
      rows => {
        throwIfAborted(controller.signal)
        return rows
      },
      cause => {
        throwIfAborted(controller.signal)
        throw cause
      }
    )
    const scan = Promise.race([cancellable, deadline]).finally(() => {
      if (abortTimer) clearTimeout(abortTimer)
      if (forceTimer) clearTimeout(forceTimer)
    })
    const active = { promise: scan, controller }
    this.#rawScan = active
    void scan.then(
      () => {
        if (this.#rawScan === active) this.#rawScan = undefined
        return undefined
      },
      () => {
        if (this.#rawScan === active) this.#rawScan = undefined
        return undefined
      }
    )
    return scan
  }

  async #settle(scope: PosixProcessScope): Promise<void> {
    const deadline = Date.now() + processTreeSettleMs
    while (scope.hasRetainedProcesses() && Date.now() < deadline) {
      // oxlint-disable-next-line no-await-in-loop -- bounded sequential settlement poll
      await this.#sleep(processTreeSettlePollMs)
      let rows: readonly PosixProcessRow[]
      try {
        // oxlint-disable-next-line no-await-in-loop -- bounded sequential settlement poll
        rows = await this.#readRows()
      } catch {
        return
      }
      if (!scope.retainsLiveIdentity(rows)) return
      scope.signalRetainedGroups(this.#signalGroup)
    }
  }

  #fail(error: Error): void {
    if (this.#state.type !== "open") return
    this.#state = { type: "failed", error }
    if (this.#timer) clearTimeout(this.#timer)
    this.#timer = undefined
    this.#failTrackedScopes(error)
  }

  #recover(error: Error): void {
    if (this.#state.type !== "open") return
    // Lost visibility fails current scopes closed, but it is not terminal owner disposal.
    let complete!: () => void
    const settled = new Promise<void>(resolve => {
      complete = resolve
    })
    const recovery = { type: "recovering" as const, error, settled }
    this.#state = recovery
    if (this.#timer) clearTimeout(this.#timer)
    this.#timer = undefined
    this.#failTrackedScopes(error)
    queueMicrotask(() => {
      if (this.#state === recovery) this.#state = { type: "open" }
      complete()
    })
  }

  #failTrackedScopes(error: Error): void {
    const records = [...this.#scopes.values()]
    this.#scopes.clear()
    for (const record of records) this.#closeFailedScope(record, error)
  }

  #failScope(record: TrackedScope, error: Error): void {
    if (!this.#scopes.delete(record.scope)) return
    this.#closeFailedScope(record, error)
  }

  #closeFailedScope(record: TrackedScope, error: Error): void {
    record.scope.close(this.#signalGroup, error)
    try {
      record.onFailure?.(error)
    } catch {
      // Process ownership cannot cross into an observer.
    }
  }

  #schedule(): void {
    if (this.#state.type !== "open" || this.#timer || this.#scopes.size === 0) return
    this.#timer = setTimeout(() => {
      this.#timer = undefined
      void this.refresh().catch(() => {})
    }, this.#refreshMs)
    this.#timer.unref?.()
  }
}

class PosixProcessScope implements ProcessScope {
  readonly platform = "posix" as const
  readonly workerPid: number
  readonly admitted: Promise<void>
  readonly #owner: PosixProcessTreeTracker
  #state: PosixScopeState = { type: "admitting" }
  #resolveAdmission!: () => void
  #rejectAdmission!: (error: Error) => void

  constructor(owner: PosixProcessTreeTracker, workerPid: number) {
    if (!Number.isInteger(workerPid) || workerPid <= 0) throw new Error("Process scope requires a positive worker pid")
    this.#owner = owner
    this.workerPid = workerPid
    this.admitted = new Promise<void>((resolve, reject) => {
      this.#resolveAdmission = resolve
      this.#rejectAdmission = reject
    })
    void this.admitted.catch(() => {})
  }

  snapshot(): ProcessScopeSnapshot {
    return {
      workerPid: this.workerPid,
      identities:
        this.#state.type === "tracking" ? Object.freeze([...this.#state.identities.values()]) : Object.freeze([])
    }
  }

  async refresh(): Promise<ProcessScopeRefreshResult> {
    await this.#owner.refresh()
    const state = this.#state
    return state.type !== "admitting" && state.overflow ? { type: "overflow" } : { type: "ok" }
  }

  terminate(): Promise<ProcessScopeTerminateResult> {
    return this.#owner.terminate(this)
  }

  async dispose(): Promise<void> {
    await this.terminate()
  }

  apply(rows: readonly PosixProcessRow[]): "ok" | "missing" | "overflow" {
    const state = this.#state
    if (state.type === "closed") return "ok"
    const byPid = new Map(rows.map(row => [row.pid, row]))
    if (state.type === "admitting") {
      const worker = byPid.get(this.workerPid)
      if (!worker) return "missing"
      const identity = processIdentity(worker)
      this.#state = {
        type: "tracking",
        workerPgid: worker.pgid,
        workerStart: worker.startIdentity,
        identities: new Map([[identityKey(identity), identity]]),
        overflow: false
      }
      this.#resolveAdmission()
      return "ok"
    }

    const worker = byPid.get(this.workerPid)
    if (!worker || worker.startIdentity !== state.workerStart) return "ok"
    const identities = discoverIdentities(rows, byPid, state, worker)
    this.#state = {
      type: "tracking",
      workerPgid: worker.pgid,
      workerStart: state.workerStart,
      identities: identities.values,
      overflow: identities.overflow
    }
    return identities.overflow ? "overflow" : "ok"
  }

  close(
    signalGroup: (pgid: number, signal: NodeJS.Signals) => boolean,
    admissionFailure?: Error
  ): ProcessScopeTerminateResult {
    const state = this.#state
    if (state.type === "closed") return { type: "closed" }
    if (state.type === "admitting") {
      this.#rejectAdmission(admissionFailure ?? new Error(`Could not admit process scope ${this.workerPid}`))
    }
    const workerPgid = state.type === "tracking" ? state.workerPgid : this.workerPid
    const identities = state.type === "tracking" ? [...state.identities.values()] : []
    const overflow = state.type === "tracking" && state.overflow
    this.#state = { type: "closed", overflow, workerPgid, identities }
    const signaledGroups = this.signalRetainedGroups(signalGroup)
    return { type: overflow ? "overflow" : "terminated", signaledGroups }
  }

  closedResult(): ProcessScopeTerminateResult {
    return { type: "closed" }
  }

  hasRetainedProcesses(): boolean {
    return this.#state.type === "closed" && this.#state.identities.length > 0
  }

  retainsLiveIdentity(rows: readonly PosixProcessRow[]): boolean {
    const state = this.#state
    if (state.type !== "closed") return false
    const byPid = new Map(rows.map(row => [row.pid, row]))
    return state.identities.some(identity => byPid.get(identity.pid)?.startIdentity === identity.startIdentity)
  }

  signalRetainedGroups(signalGroup: (pgid: number, signal: NodeJS.Signals) => boolean): number {
    const state = this.#state
    if (state.type !== "closed") return 0
    const groups = new Set<number>([state.workerPgid, ...state.identities.map(identity => identity.pgid)])
    let signaled = 0
    for (const pgid of groups) {
      if (pgid > 1 && signalGroup(pgid, "SIGKILL")) signaled++
    }
    return signaled
  }
}

class WindowsProcessTreeTracker implements ProcessTreeTracker {
  readonly #scopes = new Set<WindowsProcessScope>()
  #disposed = false

  track(workerPid: number): ProcessScope {
    if (this.#disposed) throw new Error("Process-tree tracker is not open")
    if (this.#scopes.size >= maxTrackedProcessScopes) {
      throw new Error(`Process-tree scope capacity exceeded (maximum ${maxTrackedProcessScopes})`)
    }
    const scope = new WindowsProcessScope(workerPid, () => this.#scopes.delete(scope))
    this.#scopes.add(scope)
    return scope
  }

  async dispose(): Promise<void> {
    if (this.#disposed) return
    this.#disposed = true
    const scopes = [...this.#scopes]
    this.#scopes.clear()
    await Promise.all(scopes.map(scope => scope.dispose()))
  }
}

type WindowsScopeState = { readonly type: "tracking"; readonly job: WindowsJobHandle } | { readonly type: "closed" }

class WindowsProcessScope implements ProcessScope {
  readonly platform = "windows" as const
  readonly workerPid: number
  readonly admitted = Promise.resolve()
  readonly #onClose: () => void
  #state: WindowsScopeState

  constructor(workerPid: number, onClose: () => void) {
    if (!Number.isInteger(workerPid) || workerPid <= 0) throw new Error("Process scope requires a positive worker pid")
    const job = WindowsJobHandle.create()
    try {
      job.assign(workerPid)
    } catch (cause) {
      job.dispose()
      throw cause
    }
    this.workerPid = workerPid
    this.#onClose = onClose
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

  async refresh(): Promise<ProcessScopeRefreshResult> {
    return { type: "ok" }
  }

  async terminate(): Promise<ProcessScopeTerminateResult> {
    const state = this.#state
    if (state.type === "closed") return { type: "closed" }
    state.job.dispose()
    this.#state = { type: "closed" }
    this.#onClose()
    return { type: "terminated", signaledGroups: 1 }
  }

  async dispose(): Promise<void> {
    await this.terminate()
  }
}

function discoverIdentities(
  rows: readonly PosixProcessRow[],
  byPid: ReadonlyMap<number, PosixProcessRow>,
  state: PosixTrackingState,
  worker: PosixProcessRow
): { readonly values: Map<string, ProcessIdentity>; readonly overflow: boolean } {
  const values = new Map(state.identities)
  for (const [key, identity] of values) {
    const live = byPid.get(identity.pid)
    if (!live || live.startIdentity !== identity.startIdentity) values.delete(key)
  }
  const workerIdentity = processIdentity(worker)
  values.set(identityKey(workerIdentity), workerIdentity)

  const knownPids = new Set([...values.values()].map(identity => identity.pid))
  let grew = true
  while (grew) {
    grew = false
    for (const row of rows) {
      if (!knownPids.has(row.ppid)) continue
      const identity = processIdentity(row)
      const key = identityKey(identity)
      if (values.has(key)) continue
      if (values.size >= maxTrackedProcessIdentities) return { values, overflow: true }
      values.set(key, identity)
      knownPids.add(row.pid)
      grew = true
    }
  }
  return { values, overflow: false }
}

async function readPosixProcessTable(signal: AbortSignal): Promise<readonly PosixProcessRow[]> {
  return process.platform === "linux" ? readLinuxProcessTable(signal) : readPsProcessTable(signal)
}

async function readLinuxProcessTable(signal: AbortSignal): Promise<readonly PosixProcessRow[]> {
  throwIfAborted(signal)
  let entries: string[]
  try {
    entries = await readdir("/proc")
  } catch {
    if (signal.aborted) throw abortReason(signal)
    return readPsProcessTable(signal)
  }
  const pids = entries.filter(entry => /^\d+$/.test(entry))
  if (pids.length > maxProcessTableEntries) throw new Error("Process table exceeded entry capacity")

  const rows: PosixProcessRow[] = []
  const concurrency = 64
  for (let offset = 0; offset < pids.length; offset += concurrency) {
    throwIfAborted(signal)
    const chunk = pids.slice(offset, offset + concurrency)
    // oxlint-disable-next-line no-await-in-loop -- bounded batches cap open procfs files
    const parsed = await Promise.all(
      chunk.map(async entry => {
        try {
          return parseLinuxProcessStat(await readFile(`/proc/${entry}/stat`, { encoding: "utf8", signal }))
        } catch {
          if (signal.aborted) throw abortReason(signal)
          return undefined
        }
      })
    )
    for (const row of parsed) if (row) rows.push(row)
  }
  return rows
}

function parseLinuxProcessStat(stat: string): PosixProcessRow | undefined {
  const open = stat.indexOf("(")
  const close = stat.lastIndexOf(")")
  if (open <= 0 || close <= open) return undefined
  const pid = Number(stat.slice(0, open - 1))
  const rest = stat.slice(close + 2).split(" ")
  const ppid = Number(rest[1])
  const pgid = Number(rest[2])
  const startIdentity = rest[19] ?? ""
  return Number.isInteger(pid) && Number.isInteger(ppid) && Number.isInteger(pgid) && startIdentity.length > 0
    ? { pid, ppid, pgid, startIdentity }
    : undefined
}

async function readPsProcessTable(signal: AbortSignal): Promise<readonly PosixProcessRow[]> {
  throwIfAborted(signal)
  const child = Bun.spawn(["ps", "-axo", "pid=,ppid=,pgid=,lstart="], {
    stdin: "ignore",
    stdout: "pipe",
    stderr: "ignore"
  })
  // Capture before cancellation can release the subprocess handles behind Bun's accessor.
  const exited = child.exited
  const abort = (): void => {
    try {
      child.kill()
    } catch {
      // The process exited as the scan was cancelled.
    }
  }
  signal.addEventListener("abort", abort, { once: true })
  try {
    const output = await readBoundedText(child.stdout, maxProcessTableBytes)
    const exitCode = await exited
    if (signal.aborted) throw abortReason(signal)
    if (exitCode !== 0) throw new Error(`Process-table scan exited with code ${exitCode}`)
    return parsePsProcessTable(output)
  } catch (cause) {
    abort()
    await settleValueWithin(exited, processTreeSettleMs, "Process-table process cleanup timed out").catch(
      () => undefined
    )
    if (signal.aborted) throw abortReason(signal)
    throw cause
  } finally {
    signal.removeEventListener("abort", abort)
  }
}

function parsePsProcessTable(output: string): readonly PosixProcessRow[] {
  const rows: PosixProcessRow[] = []
  for (const line of output.split("\n")) {
    const match = /^(\d+)\s+(\d+)\s+(\d+)\s+(.+)$/.exec(line.trim())
    if (!match || match[4] === undefined) continue
    rows.push({ pid: Number(match[1]), ppid: Number(match[2]), pgid: Number(match[3]), startIdentity: match[4].trim() })
    if (rows.length > maxProcessTableEntries) throw new Error("Process table exceeded entry capacity")
  }
  return rows
}

async function readBoundedText(stream: ReadableStream<Uint8Array>, maxBytes: number): Promise<string> {
  const reader = stream.getReader()
  const decoder = new TextDecoder()
  let bytes = 0
  let text = ""
  try {
    while (true) {
      // oxlint-disable-next-line no-await-in-loop -- stream chunks are inherently sequential
      const next = await reader.read()
      if (next.done) break
      bytes += next.value.byteLength
      if (bytes > maxBytes) throw new Error(`Process table exceeded ${maxBytes} bytes`)
      text += decoder.decode(next.value, { stream: true })
    }
    return text + decoder.decode()
  } finally {
    reader.releaseLock()
  }
}

function processIdentity(row: PosixProcessRow): ProcessIdentity {
  return { pid: row.pid, startIdentity: row.startIdentity, pgid: row.pgid }
}

function identityKey(identity: { readonly pid: number; readonly startIdentity: string }): string {
  return `${identity.pid}:${identity.startIdentity}`
}

function throwIfAborted(signal: AbortSignal): void {
  if (signal.aborted) throw abortReason(signal)
}

function abortReason(signal: AbortSignal): Error {
  return signal.reason instanceof Error ? signal.reason : new Error("Process-table scan cancelled")
}

function signalProcessGroup(pgid: number, signal: NodeJS.Signals): boolean {
  try {
    process.kill(-pgid, signal)
    return true
  } catch {
    return false
  }
}

async function settleValueWithin<T>(operation: Promise<T>, timeoutMs: number, message: string): Promise<T> {
  let timeout: ReturnType<typeof setTimeout> | undefined
  return Promise.race([
    operation,
    new Promise<T>((_, reject) => {
      timeout = setTimeout(() => reject(new Error(message)), timeoutMs)
      timeout.unref?.()
    })
  ]).finally(() => {
    if (timeout) clearTimeout(timeout)
  })
}

class WindowsJobHandle {
  #handle: WindowsHandle | undefined
  readonly #native: WindowsJobNative

  private constructor(native: WindowsJobNative, handle: WindowsHandle) {
    this.#native = native
    this.#handle = handle
  }

  static create(): WindowsJobHandle {
    const native = loadWindowsJobNative()
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
