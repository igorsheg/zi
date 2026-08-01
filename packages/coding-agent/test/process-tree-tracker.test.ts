import { expect, test } from "bun:test"

import {
  PosixProcessTreeTracker,
  type PosixProcessRow,
  type ProcessTableReader
} from "../src/processes/process-tree.js"

test("live process containment has no synchronous OS scans or per-scope intervals", async () => {
  const sources = await Promise.all(
    ["../src/processes/process-tree.ts", "../src/extensions/host.ts", "../src/subagents/child-process.ts"].map(path =>
      Bun.file(new URL(path, import.meta.url)).text()
    )
  )
  for (const source of sources) {
    expect(source).not.toMatch(/\b(?:spawnSync|readFileSync|readdirSync|sleepSync)\b/)
  }
  expect(sources[1]).not.toContain("setInterval(")
  expect(sources[2]).not.toContain("setInterval(")
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

test("a POSIX process-table scan failure fails every tracked scope closed", async () => {
  let scans = 0
  const failures: Error[] = []
  const tracker = new PosixProcessTreeTracker(
    () => {
      scans++
      return scans === 1
        ? Promise.resolve([{ pid: 101, ppid: 1, pgid: 101, startIdentity: "first" }])
        : Promise.reject(new Error("scan unavailable"))
    },
    60_000,
    () => true,
    () => Promise.resolve()
  )
  const scope = tracker.track(101, error => failures.push(error))
  await scope.admitted
  await Promise.resolve()

  await tracker.refresh().catch(error => {
    expect(error).toEqual(new Error("scan unavailable"))
    return []
  })
  expect(failures.map(error => error.message)).toEqual(["scan unavailable"])
  await tracker.refresh().catch(error => {
    expect(error).toEqual(new Error("scan unavailable"))
    return []
  })
  expect(failures.map(error => error.message)).toEqual(["scan unavailable"])
  expect(scope.snapshot().identities).toEqual([])
  expect(await scope.terminate()).toEqual({ type: "closed" })
  await tracker.dispose()
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
