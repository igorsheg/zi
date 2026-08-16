import { expect, test } from "bun:test"

import {
  maxTrackedProcessScopes,
  PosixProcessTreeTracker,
  type PosixProcessRow,
  type ProcessTableReader
} from "../src/processes/process-tree.js"

test("live process containment has no synchronous OS scans or per-scope intervals", async () => {
  const sources = await Promise.all(
    ["../src/processes/process-tree.ts", "../src/extensions/host.ts"].map(path =>
      Bun.file(new URL(path, import.meta.url)).text()
    )
  )
  for (const source of sources) {
    expect(source).not.toMatch(/\b(?:spawnSync|readFileSync|readdirSync|sleepSync)\b/)
  }
  expect(sources[1]).not.toContain("setInterval(")
})

test("one POSIX process-table scan refreshes every registered scope", async () => {
  const first = deferred<readonly PosixProcessRow[]>()
  let scans = 0
  const read: ProcessTableReader = () => {
    scans++
    return scans === 1 ? first.promise : Promise.resolve([])
  }
  const tracker = new PosixProcessTreeTracker(
    read,
    60_000,
    () => true,
    () => Promise.resolve()
  )
  const firstScope = tracker.track(101)
  const secondScope = tracker.track(202)

  expect(scans).toBe(1)
  first.resolve([
    { pid: 101, ppid: 1, pgid: 101, startIdentity: "first" },
    { pid: 202, ppid: 1, pgid: 202, startIdentity: "second" }
  ])
  await Promise.all([firstScope.refresh(), secondScope.refresh()])

  expect(scans).toBe(1)
  expect(firstScope.snapshot().identities).toEqual([{ pid: 101, pgid: 101, startIdentity: "first" }])
  expect(secondScope.snapshot().identities).toEqual([{ pid: 202, pgid: 202, startIdentity: "second" }])
  await tracker.dispose()
})

test("concurrent POSIX process-table refreshes never overlap", async () => {
  const scans: Array<ReturnType<typeof deferred<readonly PosixProcessRow[]>>> = []
  let active = 0
  let maxActive = 0
  const tracker = new PosixProcessTreeTracker(
    () => {
      active++
      maxActive = Math.max(maxActive, active)
      if (scans.length >= 2) {
        active--
        return Promise.resolve([])
      }
      const scan = deferred<readonly PosixProcessRow[]>()
      scans.push(scan)
      return scan.promise.finally(() => {
        active--
      })
    },
    60_000,
    () => true,
    () => Promise.resolve()
  )
  const scope = tracker.track(101)
  const first = scope.refresh()
  const coalesced = scope.refresh()

  expect(scans).toHaveLength(1)
  scans[0]!.resolve([{ pid: 101, ppid: 1, pgid: 101, startIdentity: "first" }])
  await Promise.all([first, coalesced])

  const second = scope.refresh()
  const secondCoalesced = scope.refresh()
  expect(scans).toHaveLength(2)
  expect(maxActive).toBe(1)
  scans[1]!.resolve([{ pid: 101, ppid: 1, pgid: 101, startIdentity: "first" }])
  await Promise.all([second, secondCoalesced])
  await tracker.dispose()
})

test("a POSIX process-table scan failure fails scopes closed and signals retained groups", async () => {
  let scans = 0
  const failures: Error[] = []
  const signals: number[] = []
  const rows = [
    { pid: 101, ppid: 1, pgid: 101, startIdentity: "first" },
    { pid: 202, ppid: 101, pgid: 202, startIdentity: "detached" }
  ]
  const tracker = new PosixProcessTreeTracker(
    () => {
      scans++
      return scans <= 2 ? Promise.resolve(rows) : Promise.reject(new Error("scan unavailable"))
    },
    60_000,
    pgid => {
      signals.push(pgid)
      return true
    },
    () => Promise.resolve()
  )
  const scope = tracker.track(101, error => failures.push(error))
  await scope.admitted
  await Promise.resolve()
  await scope.refresh()

  await tracker.refresh().catch(error => {
    expect(error).toEqual(new Error("scan unavailable"))
    return []
  })
  expect(failures.map(error => error.message)).toEqual(["scan unavailable"])
  expect(signals).toEqual([101, 202])
  await tracker.refresh().catch(error => {
    expect(error).toEqual(new Error("scan unavailable"))
    return []
  })
  expect(failures.map(error => error.message)).toEqual(["scan unavailable"])
  expect(scope.snapshot().identities).toEqual([])
  expect(await scope.terminate()).toEqual({ type: "closed" })
  await tracker.dispose()
})

test("a failed scan closes current scopes but later admissions recover", async () => {
  const first = { pid: 101, ppid: 1, pgid: 101, startIdentity: "first" }
  const second = { pid: 202, ppid: 1, pgid: 202, startIdentity: "second" }
  const failure = new Error("scan unavailable")
  const failures: Error[] = []
  let recoveryAdmissionFailure: unknown
  let scans = 0
  const tracker = new PosixProcessTreeTracker(
    () => {
      scans++
      if (scans === 1) return Promise.resolve([first])
      if (scans === 2) return Promise.reject(failure)
      if (scans === 3) return Promise.resolve([second])
      return Promise.resolve([])
    },
    60_000,
    () => true,
    () => Promise.resolve()
  )
  const failedScope = tracker.track(first.pid, error => {
    failures.push(error)
    try {
      tracker.track(second.pid)
    } catch (cause) {
      recoveryAdmissionFailure = cause
    }
  })
  await failedScope.admitted
  await Promise.resolve()

  expect(await tracker.refresh().catch(cause => cause)).toBe(failure)
  expect(failures).toEqual([failure])
  expect(recoveryAdmissionFailure).toBeInstanceOf(Error)
  expect(recoveryAdmissionFailure).toHaveProperty(
    "message",
    "Process-tree tracker is recovering after: scan unavailable"
  )
  expect(recoveryAdmissionFailure).toHaveProperty("cause", failure)
  expect(await failedScope.terminate()).toEqual({ type: "closed" })

  const recoveredScope = tracker.track(second.pid)
  await recoveredScope.admitted
  expect(recoveredScope.snapshot().identities).toEqual([
    { pid: second.pid, pgid: second.pgid, startIdentity: second.startIdentity }
  ])
  expect(scans).toBe(3)
  await tracker.dispose()
})

test("a timed-out scan aborts its owned operation and preserves the admission cause", async () => {
  const second = { pid: 202, ppid: 1, pgid: 202, startIdentity: "second" }
  const signals: AbortSignal[] = []
  const failures: Error[] = []
  const tracker = new PosixProcessTreeTracker(
    signal => {
      signals.push(signal)
      if (signals.length === 2) return Promise.resolve([second])
      if (signals.length > 2) return Promise.resolve([])
      return new Promise((_, reject) => {
        signal.addEventListener("abort", () => reject(signal.reason), { once: true })
      })
    },
    60_000,
    () => true,
    () => Promise.resolve(),
    5
  )
  const failedScope = tracker.track(101, error => failures.push(error))
  const failure = await tracker.refresh().catch(cause => cause)

  expect(failure).toBeInstanceOf(Error)
  if (!(failure instanceof Error)) throw new Error("expected scan failure")
  expect(failure.message).toBe("Process-table scan timed out")
  expect(signals[0]?.aborted).toBe(true)
  expect(await failedScope.admitted.catch(cause => cause)).toBe(failure)
  expect(failures).toEqual([failure])

  const recoveredScope = tracker.track(second.pid)
  await recoveredScope.admitted
  expect(signals[1]).not.toBe(signals[0])
  expect(signals[1]?.aborted).toBe(false)
  await tracker.dispose()
})

test("a scan cannot succeed with stale rows after its timeout abort", async () => {
  const stale = { pid: 101, ppid: 1, pgid: 101, startIdentity: "stale" }
  const fresh = { pid: 202, ppid: 1, pgid: 202, startIdentity: "fresh" }
  let scans = 0
  const tracker = new PosixProcessTreeTracker(
    signal => {
      scans++
      if (scans === 2) return Promise.resolve([fresh])
      if (scans > 2) return Promise.resolve([])
      return new Promise(resolve => {
        signal.addEventListener("abort", () => resolve([stale]), { once: true })
      })
    },
    60_000,
    () => true,
    () => Promise.resolve(),
    5,
    10
  )
  const staleScope = tracker.track(stale.pid)
  const failure = await tracker.refresh().catch(cause => cause)

  expect(failure).toBeInstanceOf(Error)
  expect(failure).toHaveProperty("message", "Process-table scan timed out")
  expect(await staleScope.admitted.catch(cause => cause)).toBe(failure)

  const freshScope = tracker.track(fresh.pid)
  await freshScope.admitted
  expect(freshScope.snapshot().identities).toEqual([
    { pid: fresh.pid, pgid: fresh.pgid, startIdentity: fresh.startIdentity }
  ])
  await tracker.dispose()
})

test("a reader that ignores cancellation fails terminally without accumulating scans", async () => {
  const staleScan = deferred<readonly PosixProcessRow[]>()
  let scans = 0
  const tracker = new PosixProcessTreeTracker(
    () => {
      scans++
      return staleScan.promise
    },
    60_000,
    () => true,
    () => Promise.resolve(),
    5,
    10
  )
  const staleScope = tracker.track(101)
  const failure = await tracker.refresh().catch(cause => cause)
  expect(failure).toHaveProperty("message", "Process-table scan timed out and did not settle within 10ms")
  expect(await staleScope.admitted.catch(cause => cause)).toBe(failure)
  expect(() => tracker.track(202)).toThrow("Process-tree tracker failed")
  expect(scans).toBe(1)

  staleScan.resolve([{ pid: 101, ppid: 1, pgid: 101, startIdentity: "late" }])
  await Promise.resolve()
  expect(scans).toBe(1)
  await tracker.dispose()
})

test("disposal during a pending admission preserves the scan cause and is idempotent", async () => {
  const failures: Error[] = []
  const tracker = new PosixProcessTreeTracker(
    signal =>
      new Promise((_, reject) => {
        signal.addEventListener("abort", () => reject(signal.reason), { once: true })
      }),
    60_000,
    () => true,
    () => Promise.resolve(),
    5,
    10
  )
  const scope = tracker.track(101, error => failures.push(error))
  const first = tracker.dispose()
  const second = tracker.dispose()

  expect(second).toBe(first)
  await first
  const admissionFailure = await scope.admitted.catch(cause => cause)
  expect(admissionFailure).toBeInstanceOf(Error)
  expect(admissionFailure).toHaveProperty("message", "Process-table scan timed out")
  expect(failures).toEqual([admissionFailure])
  expect(() => tracker.track(202)).toThrow("Process-tree tracker is disposed")
})

test("disposal force-bounds an uncancellable final scan and signals retained groups", async () => {
  const row = { pid: 101, ppid: 1, pgid: 101, startIdentity: "worker" }
  const never = deferred<readonly PosixProcessRow[]>()
  const signals: number[] = []
  const failures: Error[] = []
  let scans = 0
  const tracker = new PosixProcessTreeTracker(
    () => (++scans === 1 ? Promise.resolve([row]) : never.promise),
    60_000,
    pgid => {
      signals.push(pgid)
      return true
    },
    () => Promise.resolve(),
    5,
    10
  )
  const scope = tracker.track(row.pid, error => failures.push(error))
  await scope.admitted
  await Bun.sleep(0)

  const startedAt = Date.now()
  await tracker.dispose()

  expect(Date.now() - startedAt).toBeLessThan(100)
  expect(signals).toEqual([row.pgid])
  expect(failures).toHaveLength(1)
  expect(failures[0]?.message).toBe("Process-table scan timed out and did not settle within 10ms")
})

test("scan failure fans one cause across capacity and reclaims every scope", async () => {
  const failure = new Error("scan unavailable")
  const failures: Error[] = []
  const rows = Array.from({ length: maxTrackedProcessScopes }, (_, index) => ({
    pid: 100 + index,
    ppid: 1,
    pgid: 100 + index,
    startIdentity: `worker-${index}`
  }))
  let scans = 0
  const tracker = new PosixProcessTreeTracker(
    () => {
      scans++
      if (scans === 1) return Promise.reject(failure)
      if (scans === 2) return Promise.resolve(rows)
      return Promise.resolve([])
    },
    60_000,
    () => true,
    () => Promise.resolve()
  )
  const scopes = rows.map(row => tracker.track(row.pid, error => failures.push(error)))

  expect(await tracker.refresh().catch(cause => cause)).toBe(failure)
  const repeatedFailure = rows.map(() => failure)
  expect(await Promise.all(scopes.map(scope => scope.admitted.catch(cause => cause)))).toEqual(repeatedFailure)
  expect(failures).toEqual(repeatedFailure)

  const recovered = rows.map(row => tracker.track(row.pid))
  await Promise.all(recovered.map(scope => scope.admitted))
  expect(recovered).toHaveLength(maxTrackedProcessScopes)
  await tracker.dispose()
})

test("disposal during scan recovery cannot reopen the tracker", async () => {
  const failure = new Error("scan unavailable")
  let disposal: Promise<void> | undefined
  let tracker!: PosixProcessTreeTracker
  tracker = new PosixProcessTreeTracker(
    () => Promise.reject(failure),
    60_000,
    () => true,
    () => Promise.resolve()
  )
  tracker.track(101, () => {
    disposal = tracker.dispose()
  })

  expect(await tracker.refresh().catch(cause => cause)).toBe(failure)
  await disposal
  expect(() => tracker.track(202)).toThrow("Process-tree tracker is disposed")
  const refreshFailure = await tracker.refresh().catch(cause => cause)
  expect(refreshFailure).toBeInstanceOf(Error)
  expect(refreshFailure).toHaveProperty("message", "Process-tree tracker is disposed")
})

test("termination yields while its asynchronous process-table scan is pending", async () => {
  const root = { pid: 101, ppid: 1, pgid: 101, startIdentity: "root" }
  const pending = deferred<readonly PosixProcessRow[]>()
  let scans = 0
  const tracker = new PosixProcessTreeTracker(
    () => (++scans === 1 ? Promise.resolve([root]) : pending.promise),
    60_000,
    () => true,
    () => Promise.resolve()
  )
  const scope = tracker.track(root.pid)
  await scope.admitted
  await Promise.resolve()
  let terminated = false

  const termination = scope.terminate().then(() => {
    terminated = true
    return undefined
  })
  let timerRan = false
  setTimeout(() => {
    timerRan = true
  }, 0)
  await Bun.sleep(1)

  expect(timerRan).toBe(true)
  expect(terminated).toBe(false)
  pending.resolve([])
  await termination
  await tracker.dispose()
})

test("scan completion cannot repopulate a terminated scope", async () => {
  const root = { pid: 101, ppid: 1, pgid: 101, startIdentity: "root" }
  const descendant = { pid: 303, ppid: 101, pgid: 303, startIdentity: "descendant" }
  let rows: readonly PosixProcessRow[] = [root]
  const signals: number[] = []
  const tracker = new PosixProcessTreeTracker(
    () => Promise.resolve(rows),
    60_000,
    pgid => {
      signals.push(pgid)
      return true
    },
    () => Promise.resolve()
  )
  const scope = tracker.track(root.pid)
  await scope.admitted
  await Promise.resolve()
  rows = []
  await scope.terminate()
  const signalsAfterTermination = signals.length

  rows = [root, descendant]
  await tracker.refresh()

  expect(scope.snapshot().identities).toEqual([])
  expect(signals).toHaveLength(signalsAfterTermination)
  await tracker.dispose()
})

test("termination kills a retained detached descendant after its worker disappears", async () => {
  const root = { pid: 101, ppid: 1, pgid: 101, startIdentity: "root" }
  const descendant = { pid: 303, ppid: 101, pgid: 303, startIdentity: "descendant" }
  const tables: Array<readonly PosixProcessRow[]> = [[root, descendant], [root, descendant], [descendant], []]
  const signals: number[] = []
  const tracker = new PosixProcessTreeTracker(
    () => Promise.resolve(tables.shift() ?? []),
    60_000,
    pgid => {
      signals.push(pgid)
      return true
    },
    () => Promise.resolve()
  )
  const scope = tracker.track(root.pid)
  await scope.admitted
  await Promise.resolve()

  const result = await scope.terminate()

  expect(result).toEqual({ type: "terminated", signaledGroups: 2 })
  expect(signals).toContain(101)
  expect(signals).toContain(303)
  expect(scope.snapshot().identities).toEqual([])
  await tracker.dispose()
})

function deferred<T>(): { readonly promise: Promise<T>; resolve(value: T): void } {
  let resolve!: (value: T) => void
  const promise = new Promise<T>(complete => {
    resolve = complete
  })
  return { promise, resolve }
}
