import { expect, test } from "bun:test"
import { mkdir, mkdtemp, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { InvariantRegistry } from "@with-zi/invariants"

import { ZiPaths } from "../src/paths.js"
import { SessionManager } from "../src/session-manager.js"
import type { SubagentChildSessionRequest } from "../src/subagents/child.js"
import {
  maxLiveChildren,
  maxRetainedSubagents,
  maxRunningChildren,
  SubagentSupervisor
} from "../src/subagents/supervisor.js"
import { clipUtf8 } from "../src/subagents/text.js"
import { createInProcessSubagentHarness, waitFor } from "./subagent-harness.js"

test("UTF-8 clipping does not split code points", () => {
  const clipped = clipUtf8(`${"a".repeat(255)}界`, 256)
  expect(clipped.text).toBe("a".repeat(255))
  expect(clipped.omittedBytes).toBe(3)
})

test("SubagentSupervisor runs an in-process child, persists completion, and closes it", async () => {
  const harness = await createInProcessSubagentHarness("vertical", { reply: "supervisor-ok", delayMs: 20 })
  try {
    const name = await harness.supervisor.spawn("project-inspector", "inspect the project")
    expect(harness.supervisor.snapshots()[0]).toMatchObject({ name, lifecycle: "running", workCycle: 1 })

    await waitFor(() => harness.supervisor.status().readyNames.includes(name))
    expect(harness.sessionManager.subagentWorkResults().at(-1)).toMatchObject({
      result: "succeeded",
      name,
      workCycle: 1,
      preview: "supervisor-ok"
    })
    expect(await harness.supervisor.wait([name], 1_000)).toEqual([
      expect.objectContaining({
        name,
        lifecycle: "idle",
        completion: expect.objectContaining({ status: "completed", text: "supervisor-ok" })
      })
    ])
    const transcript = harness.supervisor.transcript(name)?.messages
    expect(transcript?.map(message => message.role)).toEqual(["user", "assistant"])

    await harness.supervisor.close(name)
    expect(harness.supervisor.snapshots()[0]).toMatchObject({ name, lifecycle: "exited", workCycle: 1 })
    expect(harness.supervisor.transcript(name)?.messages).toBe(transcript)
  } finally {
    await harness.dispose()
  }
})

test("idle continuation starts a new cycle and running continuation joins the current cycle", async () => {
  const harness = await createInProcessSubagentHarness("continue", {
    reply: (_request, prompt) => `reply:${prompt}`,
    delayMs: 30
  })
  try {
    const name = await harness.supervisor.spawn("worker", "first")
    expect(await harness.supervisor.continue(name, "joined")).toBe("follow_up")
    await waitFor(() => harness.supervisor.status().readyNames.includes(name))
    harness.supervisor.deliverCompletions(() => {})

    expect(await harness.supervisor.continue(name, "second")).toBe("started_turn")
    await waitFor(() => harness.supervisor.status().readyNames.includes(name))
    expect(harness.supervisor.snapshots()[0]).toMatchObject({ workCycle: 2, lifecycle: "idle" })
    expect(harness.supervisor.transcript(name)?.messages.filter(message => message.role === "user")).toHaveLength(3)
  } finally {
    await harness.dispose()
  }
})

test("send queues context without waking an idle child", async () => {
  const harness = await createInProcessSubagentHarness("send", { reply: "done", delayMs: 10 })
  try {
    const name = await harness.supervisor.spawn("worker", "first")
    await waitFor(() => harness.supervisor.snapshots()[0]?.lifecycle === "idle")
    await harness.supervisor.send(name, "queued context")
    expect(harness.supervisor.snapshots()[0]).toMatchObject({ lifecycle: "idle", workCycle: 1 })

    await harness.supervisor.continue(name, "wake")
    await waitFor(
      () =>
        harness.supervisor.snapshots()[0]?.workCycle === 2 && harness.supervisor.snapshots()[0]?.lifecycle === "idle"
    )
    expect(harness.supervisor.transcript(name)?.messages.some(message => message.role === "user")).toBe(true)
  } finally {
    await harness.dispose()
  }
})

test("direct interruption settles cancelled evidence and leaves the child reusable", async () => {
  const harness = await createInProcessSubagentHarness("interrupt", { reply: "late", delayMs: 300 })
  try {
    const name = await harness.supervisor.spawn("worker", "long work")
    expect(await harness.supervisor.interrupt(name)).toBe("interrupted")
    await waitFor(() => harness.supervisor.snapshots()[0]?.lifecycle === "idle")
    expect((await harness.supervisor.wait([name], 1_000))[0]?.completion).toMatchObject({ status: "cancelled" })

    expect(await harness.supervisor.continue(name, "retry")).toBe("started_turn")
    await waitFor(
      () =>
        harness.supervisor.snapshots()[0]?.workCycle === 2 && harness.supervisor.snapshots()[0]?.lifecycle === "idle"
    )
  } finally {
    await harness.dispose()
  }
})

test("selection is resolved at spawn and passed independently to the child factory", async () => {
  const seen: SubagentChildSessionRequest[] = []
  const harness = await createInProcessSubagentHarness("selection", { onCreate: request => seen.push(request) })
  try {
    await harness.supervisor.spawn("worker", "inspect", undefined, { model: "other/model", thinkingLevel: "high" })
    expect(seen[0]).toMatchObject({ name: "worker", model: "other/model", thinkingLevel: "high" })
    expect(seen[0]?.apiKey).toBeUndefined()
  } finally {
    await harness.dispose()
  }
})

test("failed unpublished child creation unwinds the reservation and retains terminal evidence", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-subagent-create-failure-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "agent"))
  await mkdir(paths.cwd, { recursive: true })
  const sessionManager = SessionManager.create(paths, { persist: false })
  const supervisor = new SubagentSupervisor({
    createChildSession: async () => {
      throw new Error("startup failed")
    },
    selection: () => ({ model: "faux/faux-1", thinkingLevel: "off" }),
    sessionManager,
    invariantRegistry: new InvariantRegistry()
  })
  try {
    expect(supervisor.spawn("worker", "inspect")).rejects.toThrow("startup failed")
    expect(supervisor.capacity()).toEqual({ live: 0, maximum: maxLiveChildren })
    expect(supervisor.snapshots()).toEqual([expect.objectContaining({ name: "worker", lifecycle: "exited" })])
  } finally {
    await supervisor.shutdown()
    await rm(root, { recursive: true, force: true })
  }
})

test("shutdown aborts unpublished creation and closes without factory release", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-subagent-shutdown-create-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "agent"))
  await mkdir(paths.cwd, { recursive: true })
  let factorySignal: AbortSignal | undefined
  const supervisor = new SubagentSupervisor({
    createChildSession: request => {
      factorySignal = request.signal
      return new Promise<never>((_, reject) => {
        const abort = (): void => reject(request.signal?.reason ?? new Error("creation aborted"))
        if (request.signal?.aborted) abort()
        else request.signal?.addEventListener("abort", abort, { once: true })
      })
    },
    selection: () => ({ model: "faux/faux-1", thinkingLevel: "off" }),
    sessionManager: SessionManager.create(paths, { persist: false }),
    invariantRegistry: new InvariantRegistry()
  })
  const spawn = supervisor.spawn("worker", "inspect")
  const shutdown = supervisor.shutdown()
  try {
    expect(spawn).rejects.toThrow("spawn was cancelled")
    await shutdown
    expect(factorySignal?.aborted).toBe(true)
    expect(supervisor.capacity()).toEqual({ live: 0, maximum: maxLiveChildren })
    expect(supervisor.state).toEqual({ type: "closed" })
  } finally {
    await shutdown.catch(() => {})
    await rm(root, { recursive: true, force: true })
  }
})

test("concurrent unresolved creations reserve all four admission slots", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-subagent-concurrent-create-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "agent"))
  await mkdir(paths.cwd, { recursive: true })
  let factoryCalls = 0
  const supervisor = new SubagentSupervisor({
    createChildSession: request => {
      factoryCalls++
      return new Promise<never>((_, reject) => {
        const abort = (): void => reject(request.signal?.reason ?? new Error("creation aborted"))
        if (request.signal?.aborted) abort()
        else request.signal?.addEventListener("abort", abort, { once: true })
      })
    },
    selection: () => ({ model: "faux/faux-1", thinkingLevel: "off" }),
    sessionManager: SessionManager.create(paths, { persist: false }),
    invariantRegistry: new InvariantRegistry()
  })
  const admitted = Array.from({ length: maxLiveChildren }, (_, index) =>
    supervisor.spawn(`worker-${index}`, `task ${index}`)
  )
  try {
    expect(supervisor.spawn("extra", "too many")).rejects.toThrow("Subagent capacity exceeded")
    expect(factoryCalls).toBe(maxLiveChildren)
    expect(supervisor.capacity()).toEqual({ live: maxLiveChildren, maximum: maxLiveChildren })

    const shutdown = supervisor.shutdown()
    const failures = await Promise.all(admitted.map(spawn => spawn.catch(cause => cause)))
    expect(failures).toHaveLength(maxLiveChildren)
    expect(failures.every(cause => cause instanceof Error && cause.message.includes("spawn was cancelled"))).toBe(true)
    await shutdown
  } finally {
    await supervisor.shutdown().catch(() => {})
    await rm(root, { recursive: true, force: true })
  }
})

test("SubagentSupervisor admits four live children and rejects a fifth", async () => {
  const harness = await createInProcessSubagentHarness("capacity", { delayMs: 100 })
  try {
    for (let index = 0; index < maxLiveChildren; index++) {
      // oxlint-disable-next-line no-await-in-loop -- admission order is part of this capacity contract.
      await harness.supervisor.spawn(`worker-${index}`, `task ${index}`)
    }
    expect(harness.supervisor.capacity()).toEqual({ live: maxLiveChildren, maximum: maxLiveChildren })
    expect(harness.supervisor.spawn("extra", "too many")).rejects.toThrow("Subagent capacity exceeded")
  } finally {
    await harness.dispose()
  }
})

test("four live children run two provider cycles at a time in FIFO order", async () => {
  let active = 0
  let maximumActive = 0
  const starts: string[] = []
  const harness = await createInProcessSubagentHarness("running-admission", {
    delayMs: request => ({ "worker-0": 50, "worker-1": 100, "worker-2": 20, "worker-3": 20 })[request.name] ?? 0,
    onRunStart: request => {
      starts.push(request.name)
      active++
      maximumActive = Math.max(maximumActive, active)
    },
    onRunEnd: () => {
      active--
    }
  })
  try {
    for (let index = 0; index < maxLiveChildren; index++) {
      // oxlint-disable-next-line no-await-in-loop -- FIFO admission order is under test.
      await harness.supervisor.spawn(`worker-${index}`, `task ${index}`)
    }
    await waitFor(() => starts.length === 2)
    expect(harness.supervisor.capacity()).toEqual({ live: maxLiveChildren, maximum: maxLiveChildren })
    expect(harness.supervisor.runningCount()).toBe(maxRunningChildren)
    expect(harness.supervisor.status().workingNames).toEqual(["worker-0", "worker-1", "worker-2", "worker-3"])

    await waitFor(() => harness.supervisor.status().readyNames.length === maxLiveChildren)
    expect(starts).toEqual(["worker-0", "worker-1", "worker-2", "worker-3"])
    expect(maximumActive).toBe(maxRunningChildren)
  } finally {
    await harness.dispose()
  }
})

test("queued send and assignment join the exact admitted cycle", async () => {
  const harness = await createInProcessSubagentHarness("queued-follow-up", {
    reply: (_request, prompt) => `done:${prompt}`,
    delayMs: request => (request.name === "queued-worker" ? 0 : 300)
  })
  try {
    await harness.supervisor.spawn("blocker-a", "block")
    await harness.supervisor.spawn("blocker-b", "block")
    const name = await harness.supervisor.spawn("queued-worker", "initial")
    expect(harness.supervisor.runningCount()).toBe(2)
    expect(harness.supervisor.status().workingNames).toContain(name)

    await harness.supervisor.send(name, "queued context")
    expect(await harness.supervisor.continue(name, "queued assignment")).toBe("follow_up")
    expect(harness.supervisor.runningCount()).toBe(2)

    await harness.supervisor.interrupt("blocker-a")
    await waitFor(() => harness.supervisor.status().readyNames.includes(name))
    const result = (await harness.supervisor.wait([name], 0))[0]
    expect(result?.completion).toMatchObject({ workCycle: 1, status: "completed" })
    expect(harness.supervisor.transcript(name)?.messages.filter(message => message.role === "user")).toHaveLength(3)
    expect(harness.sessionManager.subagentWorkResults().filter(entry => entry.name === name)).toHaveLength(1)
  } finally {
    await harness.dispose()
  }
})

test("queued interruption removes FIFO work and admits a reusable next cycle", async () => {
  const starts: string[] = []
  const harness = await createInProcessSubagentHarness("queued-interrupt", {
    delayMs: request => (request.name === "worker" ? 0 : 300),
    onRunStart: request => starts.push(request.name)
  })
  try {
    await harness.supervisor.spawn("blocker-a", "block")
    await harness.supervisor.spawn("blocker-b", "block")
    const name = await harness.supervisor.spawn("worker", "cancel")
    expect(harness.supervisor.snapshots().find(snapshot => snapshot.name === name)).toMatchObject({
      lifecycle: "queued",
      workCycle: 1
    })

    expect(await harness.supervisor.interrupt(name)).toBe("interrupted")
    expect((await harness.supervisor.wait([name], 0))[0]?.completion).toMatchObject({
      workCycle: 1,
      status: "cancelled",
      text: ""
    })
    expect(starts).not.toContain(name)

    expect(await harness.supervisor.continue(name, "reuse")).toBe("started_turn")
    await harness.supervisor.interrupt("blocker-a")
    await waitFor(() => harness.supervisor.status().readyNames.includes(name))
    expect(starts.filter(started => started === name)).toHaveLength(1)
    expect((await harness.supervisor.wait([name], 0))[0]?.completion).toMatchObject({
      workCycle: 2,
      status: "completed"
    })
  } finally {
    await harness.dispose()
  }
})

test("closing queued and running children releases the next permit exactly once", async () => {
  const starts: string[] = []
  const harness = await createInProcessSubagentHarness("close-admission", {
    delayMs: 300,
    onRunStart: request => starts.push(request.name)
  })
  try {
    for (const name of ["first", "second", "third", "fourth"]) {
      // oxlint-disable-next-line no-await-in-loop -- FIFO admission order is under test.
      await harness.supervisor.spawn(name, "work")
    }
    await waitFor(() => starts.length === 2)

    await harness.supervisor.close("fourth")
    expect(starts).toEqual(["first", "second"])
    await harness.supervisor.close("first")
    await waitFor(() => starts.includes("third"))
    await Bun.sleep(30)
    expect(starts).toEqual(["first", "second", "third"])
    expect(starts.filter(name => name === "third")).toHaveLength(1)
    expect(starts).not.toContain("fourth")
  } finally {
    await harness.dispose()
  }
})

test("shutdown cancels queued work without starting it", async () => {
  const starts: string[] = []
  const harness = await createInProcessSubagentHarness("shutdown-queued", {
    delayMs: 300,
    onRunStart: request => starts.push(request.name)
  })
  try {
    for (const name of ["first", "second", "third", "fourth"]) {
      // oxlint-disable-next-line no-await-in-loop -- FIFO admission order is under test.
      await harness.supervisor.spawn(name, "work")
    }
    await waitFor(() => starts.length === maxRunningChildren)
    await harness.supervisor.shutdown()

    expect(starts).toEqual(["first", "second"])
    for (const name of ["third", "fourth"]) {
      expect(harness.sessionManager.subagentWorkResults().find(entry => entry.name === name)).toMatchObject({
        workCycle: 1,
        result: "cancelled",
        preview: ""
      })
    }
  } finally {
    await harness.dispose()
  }
})

test("wait claims one exact completion and release restores canonical delivery", async () => {
  const harness = await createInProcessSubagentHarness("claim-delivery", { reply: "claimed" })
  try {
    const name = await harness.supervisor.spawn("worker", "finish")
    await waitFor(() => harness.supervisor.status().readyNames.includes(name))

    const claimed = await harness.supervisor.waitForTool([name], 1_000, undefined, "tool:claim")
    expect(claimed).toEqual([
      expect.objectContaining({
        capturedWorkCycle: 1,
        completionDelivery: "claimed",
        completion: expect.objectContaining({ text: "claimed" })
      })
    ])
    expect(await harness.supervisor.waitForTool([name], 0, undefined, "other:claim")).toEqual([])

    harness.supervisor.releaseCompletionClaims("tool:")
    expect(await harness.supervisor.wait([name], 0)).toEqual([
      expect.objectContaining({ capturedWorkCycle: 1, completion: expect.objectContaining({ text: "claimed" }) })
    ])
    expect((await harness.supervisor.wait([name], 0))[0]).not.toHaveProperty("completion")
  } finally {
    await harness.dispose()
  }
})

test("multi-agent wait keeps every captured cycle as an exact barrier", async () => {
  const harness = await createInProcessSubagentHarness("wait-barrier", {
    reply: (_request, prompt) => `done:${prompt}`,
    delayMs: (_request, prompt) => (prompt === "slow" ? 100 : 10)
  })
  try {
    const slow = await harness.supervisor.spawn("slow-worker", "slow")
    const fast = await harness.supervisor.spawn("fast-worker", "fast")
    let settled = false
    const waiting = harness.supervisor.wait([slow, fast], 1_000).then(result => {
      settled = true
      return result
    })
    await waitFor(() => harness.supervisor.status().readyNames.includes(fast))
    expect(settled).toBe(false)

    const result = await waiting
    expect(result.map(snapshot => snapshot.name)).toEqual([slow, fast])
    expect(result.map(snapshot => snapshot.completion?.text)).toEqual(["done:slow", "done:fast"])
  } finally {
    await harness.dispose()
  }
})

test("concurrent idle continuations admit one new cycle and join the rest", async () => {
  const harness = await createInProcessSubagentHarness("concurrent-continue", {
    reply: (_request, prompt) => `reply:${prompt}`,
    delayMs: 20
  })
  try {
    const name = await harness.supervisor.spawn("worker", "first")
    await waitFor(() => harness.supervisor.status().readyNames.includes(name))
    await harness.supervisor.wait([name], 0)

    const admissions = await Promise.all([
      harness.supervisor.continue(name, "second-a"),
      harness.supervisor.continue(name, "second-b")
    ])
    expect(admissions.toSorted()).toEqual(["follow_up", "started_turn"])
    await waitFor(() => harness.supervisor.snapshots()[0]?.completion?.workCycle === 2)
    expect(harness.supervisor.snapshots()[0]).toMatchObject({ lifecycle: "idle", workCycle: 2 })
    expect(harness.sessionManager.subagentWorkResults().filter(result => result.name === name)).toHaveLength(2)
  } finally {
    await harness.dispose()
  }
})

test("provider failure settles once and leaves the child reusable", async () => {
  const harness = await createInProcessSubagentHarness("failure-recovery", {
    reply: (_request, prompt) => {
      if (prompt === "fail") throw new Error("provider unavailable")
      return "recovered"
    }
  })
  try {
    const name = await harness.supervisor.spawn("worker", "fail")
    await waitFor(() => harness.supervisor.status().readyNames.includes(name))
    expect((await harness.supervisor.wait([name], 0))[0]?.completion).toMatchObject({
      workCycle: 1,
      status: "failed",
      reason: "provider_error"
    })

    expect(await harness.supervisor.continue(name, "recover")).toBe("started_turn")
    await waitFor(() => harness.supervisor.status().readyNames.includes(name))
    expect((await harness.supervisor.wait([name], 0))[0]?.completion).toMatchObject({
      workCycle: 2,
      status: "completed",
      text: "recovered"
    })
    expect(harness.sessionManager.subagentWorkResults().filter(result => result.name === name)).toHaveLength(2)
  } finally {
    await harness.dispose()
  }
})

test("closing during a cycle publishes one exact terminal result", async () => {
  const harness = await createInProcessSubagentHarness("close-cycle", { reply: "late", delayMs: 250 })
  try {
    const name = await harness.supervisor.spawn("worker", "active")
    const closed = await harness.supervisor.closeAndDeliver(name)
    expect(closed).toMatchObject({
      lifecycle: "exited",
      capturedWorkCycle: 1,
      completion: { workCycle: 1, status: "failed", reason: "child_exited" }
    })
    expect(harness.sessionManager.subagentWorkResults().filter(result => result.name === name)).toHaveLength(1)
    await Bun.sleep(300)
    expect(harness.sessionManager.subagentWorkResults().filter(result => result.name === name)).toHaveLength(1)
  } finally {
    await harness.dispose()
  }
})

test("close preserves terminal evidence when lifecycle journaling fails", async () => {
  const harness = await createInProcessSubagentHarness("close-journal-failure", { reply: "late", delayMs: 250 })
  try {
    const name = await harness.supervisor.spawn("worker", "active")
    const append = harness.sessionManager.appendSubagent.bind(harness.sessionManager)
    Object.defineProperty(harness.sessionManager, "appendSubagent", {
      configurable: true,
      value(data: Parameters<SessionManager["appendSubagent"]>[0]) {
        if (data.event === "closing" || data.event === "exited") throw new Error("journal unavailable")
        return append(data)
      }
    })

    expect(await harness.supervisor.closeAndDeliver(name)).toMatchObject({
      lifecycle: "exited",
      capturedWorkCycle: 1,
      completion: { workCycle: 1, status: "failed", reason: "child_exited" }
    })
    expect(harness.supervisor.capacity()).toEqual({ live: 0, maximum: maxLiveChildren })
  } finally {
    await harness.dispose()
  }
})

test("work timeout publishes once and the interrupted child can run another cycle", async () => {
  const harness = await createInProcessSubagentHarness("work-timeout", {
    reply: "done",
    delayMs: (_request, prompt) => (prompt === "slow" ? 200 : 0),
    workTimeoutMs: 20
  })
  try {
    const name = await harness.supervisor.spawn("worker", "slow")
    await waitFor(() => harness.supervisor.status().readyNames.includes(name))
    expect((await harness.supervisor.wait([name], 0))[0]?.completion).toMatchObject({
      workCycle: 1,
      status: "failed",
      reason: "work_cycle_timeout"
    })

    expect(await harness.supervisor.continue(name, "retry")).toBe("started_turn")
    await waitFor(() => harness.supervisor.status().readyNames.includes(name))
    expect((await harness.supervisor.wait([name], 0))[0]?.completion).toMatchObject({
      workCycle: 2,
      status: "completed",
      text: "done"
    })
    expect(harness.sessionManager.subagentWorkResults().filter(result => result.name === name)).toHaveLength(2)
  } finally {
    await harness.dispose()
  }
})

test("cancelling interrupt observation preserves cancellation evidence and reuse", async () => {
  const harness = await createInProcessSubagentHarness("interrupt-cancel", { reply: "late", delayMs: 250 })
  try {
    const name = await harness.supervisor.spawn("worker", "active")
    const controller = new AbortController()
    const observation = harness.supervisor.interruptAndWait(name, controller.signal)
    controller.abort()
    expect(observation).rejects.toThrow("Subagent wait was cancelled")

    await waitFor(() => harness.supervisor.status().readyNames.includes(name))
    expect((await harness.supervisor.wait([name], 0))[0]?.completion).toMatchObject({
      workCycle: 1,
      status: "cancelled"
    })
    expect(await harness.supervisor.continue(name, "retry")).toBe("started_turn")
  } finally {
    await harness.dispose()
  }
})

test("shutdown after cycle admission retains exactly one durable terminal result", async () => {
  const harness = await createInProcessSubagentHarness("shutdown-cycle", { reply: "late", delayMs: 250 })
  try {
    const name = await harness.supervisor.spawn("worker", "active")
    await harness.supervisor.shutdown()
    expect(harness.supervisor.state).toEqual({ type: "closed" })
    expect(harness.supervisor.snapshots()[0]).toMatchObject({ name, lifecycle: "exited" })
    expect(harness.sessionManager.subagentWorkResults().filter(result => result.name === name)).toHaveLength(1)
  } finally {
    await harness.dispose()
  }
})

test("shutdown retains one forced-settlement failure when child disposal never settles", async () => {
  const harness = await createInProcessSubagentHarness("shutdown-forced-settlement", {
    reply: "late",
    delayMs: 100,
    closeSettlementMs: 20,
    childDisposeNeverSettles: true
  })
  try {
    const name = await harness.supervisor.spawn("worker", "active")
    const shutdown = await Promise.race([
      harness.supervisor.shutdown().then(() => "settled" as const),
      Bun.sleep(500).then(() => "timed_out" as const)
    ])

    expect(shutdown).toBe("settled")
    expect(harness.supervisor.state).toEqual({ type: "closed" })
    expect(harness.supervisor.capacity()).toEqual({ live: 0, maximum: maxLiveChildren })
    expect(harness.supervisor.snapshots()).toEqual([
      expect.objectContaining({
        name,
        lifecycle: "exited",
        completion: expect.objectContaining({ status: "failed", reason: "child_forced_settlement" })
      })
    ])
    expect(harness.sessionManager.subagentWorkResults().filter(result => result.name === name)).toEqual([
      expect.objectContaining({ result: "failed", errorCode: "child_forced_settlement" })
    ])

    await Bun.sleep(150)
    expect(harness.supervisor.snapshots()).toHaveLength(1)
    expect(harness.sessionManager.subagentWorkResults().filter(result => result.name === name)).toHaveLength(1)
  } finally {
    await harness.dispose()
  }
})

test("exited child retention stays bounded without reusing evicted names", async () => {
  const harness = await createInProcessSubagentHarness("retention")
  try {
    for (let index = 0; index < maxRetainedSubagents + 2; index++) {
      const name = `worker-${index}`
      // oxlint-disable-next-line no-await-in-loop -- each close must release the live-child slot.
      await harness.supervisor.spawn(name, "finish")
      // oxlint-disable-next-line no-await-in-loop -- each retained child must settle before delivery.
      await waitFor(() => harness.supervisor.status().readyNames.includes(name))
      // oxlint-disable-next-line no-await-in-loop -- delivery precedes this child's retention.
      await harness.supervisor.wait([name], 0)
      // oxlint-disable-next-line no-await-in-loop -- retention order is part of the eviction contract.
      await harness.supervisor.close(name)
    }
    const snapshots = harness.supervisor.snapshots()
    expect(snapshots).toHaveLength(maxRetainedSubagents)
    expect(snapshots.some(snapshot => snapshot.name === "worker-0")).toBe(false)
    expect(harness.supervisor.spawn("worker-0", "again")).rejects.toThrow("already in use")
  } finally {
    await harness.dispose()
  }
})

test("shutdown rejects settled work that could not become durable", async () => {
  const harness = await createInProcessSubagentHarness("durability-invariant", { failResultPersistence: true })
  try {
    await harness.supervisor.spawn("worker", "finish")
    await waitFor(() => harness.supervisor.snapshots()[0]?.lifecycle === "idle")
    expect(harness.supervisor.shutdown()).rejects.toThrow("Could not persist subagent work results")
  } finally {
    await harness.dispose()
  }
})

test("completion text is clipped once to 50 KiB before durable persistence", async () => {
  const harness = await createInProcessSubagentHarness("evidence-bound", { reply: "界".repeat(30_000) })
  try {
    const name = await harness.supervisor.spawn("worker", "large")
    await waitFor(() => harness.supervisor.status().readyNames.includes(name))
    const snapshot = harness.supervisor.snapshots()[0]
    expect(Buffer.byteLength(snapshot?.completion?.text ?? "")).toBeLessThanOrEqual(50 * 1024)
    expect(snapshot?.completion).toMatchObject({ truncated: true })
    expect(snapshot?.completion?.omittedBytes).toBeGreaterThan(0)
  } finally {
    await harness.dispose()
  }
})
