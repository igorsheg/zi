import { expect, test } from "bun:test"
import { readFileSync } from "node:fs"
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join, resolve } from "node:path"
import { fileURLToPath } from "node:url"

import type { AgentTool } from "@earendil-works/pi-agent-core"
import { Type } from "@earendil-works/pi-ai"

import { CodeMode, isCodeModeDetails } from "../src/code-mode/code-mode.js"
import { ZiPaths } from "../src/paths.js"
import { createProcessTreeTracker } from "../src/processes/process-tree.js"
import { SessionManager } from "../src/session-manager.js"
import { clipUtf8 } from "../src/subagents/child-process.js"
import { durablePreviewBytes, maxRetainedSubagents, SubagentSupervisor } from "../src/subagents/supervisor.js"
import { createSubagentTools } from "../src/subagents/tools.js"

const mockChild = resolve(import.meta.dir, "fixtures/mock-rpc-child.ts")
const codeModeWorkerCommand = Object.freeze([
  process.execPath,
  fileURLToPath(new URL("../src/code-mode/worker-entry.ts", import.meta.url))
])

test("UTF-8 clipping handles maximum admitted task text without splitting code points", () => {
  const clipped = clipUtf8(`${"a".repeat(8 * 1024 * 1024 - 3)}界`, 256)
  expect(Buffer.byteLength(clipped.text)).toBe(256)
  expect(clipped.omittedBytes).toBe(clipped.originalBytes - 256)
  expect(clipped.text).not.toContain("�")
  expect(clipUtf8(`${"a".repeat(255)}界`, 256).text).toBe("a".repeat(255))
})

test("SubagentSupervisor spawns, durably publishes completion, waits, and closes", async () => {
  const harness = await createHarness("vertical-slice", { reply: "supervisor-ok", delayMs: 20 })
  try {
    const name = await harness.supervisor.spawn("project-inspector", "inspect the project")
    expect(name).toBe("project-inspector")
    expect(harness.supervisor.snapshots()).toHaveLength(1)
    expect(harness.supervisor.snapshots()[0]).toMatchObject({
      name,
      lifecycle: "running",
      workCycle: 1,
      sessionId: "mock-child-session"
    })
    expect(harness.supervisor.status()).toEqual({ workingNames: [name], readyNames: [] })

    await waitFor(() => harness.supervisor.status().readyNames.length > 0, 5_000)
    expect(harness.supervisor.status()).toEqual({ workingNames: [], readyNames: [name] })
    expect(harness.sessionManager.subagentEntries().at(-1)).toMatchObject({
      event: "work_cycle_finished",
      name,
      workCycle: 1,
      status: "completed",
      preview: "supervisor-ok"
    })

    const deliveryEvents: string[] = []
    const unsubscribe = harness.supervisor.subscribe(event => {
      if (event.type === "changed") deliveryEvents.push(event.name)
    })
    const waited = await harness.supervisor.wait([name], 5_000)
    unsubscribe()
    expect(waited).toHaveLength(1)
    expect(deliveryEvents).toContain(name)
    expect(waited[0]).toMatchObject({
      name,
      lifecycle: "idle",
      completionDelivery: "durable",
      completion: { status: "completed", text: "supervisor-ok", workCycle: 1 }
    })
    expect(harness.supervisor.snapshots()[0]).toMatchObject({ completionDelivery: "delivered" })
    expect(harness.supervisor.status()).toEqual({ workingNames: [], readyNames: [] })
    expect(harness.supervisor.transcript(name)?.messages.map(message => message.role)).toEqual(["user", "assistant"])

    await harness.supervisor.close(name)
    expect(harness.supervisor.snapshots()[0]).toMatchObject({ name, lifecycle: "exited", workCycle: 1 })
    expect(harness.supervisor.transcript(name)?.messages.at(-1)).toMatchObject({ role: "assistant" })
    expect(harness.sessionManager.subagentEntries().at(-1)).toMatchObject({ event: "exited", name })
  } finally {
    await harness.dispose()
  }
}, 15_000)

test("exited transcript retention drops older payloads without losing child records", async () => {
  const harness = await createHarness("exited-transcript-bound", { reply: "bounded", delayMs: 20 })
  const names: string[] = []
  try {
    for (let index = 0; index < 3; index++) {
      // oxlint-disable-next-line no-await-in-loop -- each close must release the live-child slot.
      const name = await harness.supervisor.spawn(`bounded-${index}`, "__large_messages__")
      names.push(name)
      // oxlint-disable-next-line no-await-in-loop -- each close must release the live-child slot.
      await waitFor(() => harness.supervisor.transcript(name)?.omittedBytes !== 0, 10_000)
      // oxlint-disable-next-line no-await-in-loop -- retention is admitted in close order.
      await harness.supervisor.close(name)
    }

    expect(harness.supervisor.transcript(names[0]!)).toBeUndefined()
    expect(harness.supervisor.transcript(names.at(-1)!)).toBeDefined()
    for (const name of names) {
      expect(harness.supervisor.snapshots()).toContainEqual(expect.objectContaining({ name, lifecycle: "exited" }))
      expect(harness.supervisor.sessionEvents(name)).toBeDefined()
    }
  } finally {
    await harness.dispose()
  }
}, 45_000)

test("durable completions can be delivered to parent context exactly once", async () => {
  const harness = await createHarness("context-delivery", { reply: "context-ok", delayMs: 20 })
  try {
    const name = await harness.supervisor.spawn("context-worker", "inspect")
    await waitFor(() => harness.supervisor.status().readyNames.includes(name), 5_000)

    const delivered: string[] = []
    harness.supervisor.deliverCompletions(completion => delivered.push(`${completion.workCycle}:${completion.text}`))
    harness.supervisor.deliverCompletions(completion => delivered.push(`${completion.workCycle}:${completion.text}`))

    await harness.supervisor.continue(name, "second cycle")
    await waitFor(() => harness.supervisor.status().readyNames.includes(name), 5_000)
    harness.supervisor.deliverCompletions(completion => delivered.push(`${completion.workCycle}:${completion.text}`))

    expect(delivered).toEqual(["1:context-ok", "2:context-ok"])
    expect(harness.supervisor.status()).toEqual({ workingNames: [], readyNames: [] })
    expect(harness.supervisor.snapshots()[0]).toMatchObject({ workCycle: 2, completionDelivery: "delivered" })

    await harness.supervisor.close(name)
    expect(harness.supervisor.snapshots()[0]).toMatchObject({ lifecycle: "exited", workCycle: 2 })
  } finally {
    await harness.dispose()
  }
}, 15_000)

test("parent evidence remains delivered when its redundant delivery marker cannot persist", async () => {
  const harness = await createHarness("delivery-marker-failure", { reply: "durable-parent-evidence", delayMs: 20 })
  try {
    const name = await harness.supervisor.spawn("context-worker", "inspect")
    await waitFor(() => harness.supervisor.status().readyNames.includes(name), 5_000)
    const append = harness.sessionManager.appendSubagent.bind(harness.sessionManager)
    Object.defineProperty(harness.sessionManager, "appendSubagent", {
      configurable: true,
      value(data: Parameters<SessionManager["appendSubagent"]>[0]) {
        if (data.event === "work_cycle_delivered") throw new Error("journal unavailable")
        return append(data)
      }
    })

    const delivered: string[] = []
    harness.supervisor.deliverCompletions(completion => delivered.push(completion.text))
    harness.supervisor.deliverCompletions(completion => delivered.push(completion.text))

    expect(delivered).toEqual(["durable-parent-evidence"])
    expect(harness.supervisor.status().readyNames).toEqual([])
  } finally {
    await harness.dispose()
  }
}, 15_000)

test("wait holds until every requested subagent has completed", async () => {
  const harness = await createHarness("wait-all", { delayMs: 120 })
  try {
    const first = await harness.supervisor.spawn("first-worker", "first")
    await harness.supervisor.wait([first], 5_000)
    const second = await harness.supervisor.spawn("second-worker", "second")

    const waited = await harness.supervisor.wait([first, second], 5_000)

    expect(waited).toEqual([
      expect.objectContaining({ name: first, completion: expect.objectContaining({ status: "completed" }) }),
      expect.objectContaining({ name: second, completion: expect.objectContaining({ status: "completed" }) })
    ])
  } finally {
    await harness.dispose()
  }
}, 15_000)

test("extension wait keeps its current-cycle barrier when older completion persistence is pending", async () => {
  const harness = await createHarness("extension-wait-pending", { reply: "cycle-ok", delayMs: 100 })
  const append = harness.sessionManager.appendSubagent.bind(harness.sessionManager)
  Object.defineProperty(harness.sessionManager, "appendSubagent", {
    configurable: true,
    value(data: Parameters<SessionManager["appendSubagent"]>[0]) {
      if (data.event === "work_cycle_finished" && data.workCycle === 1) throw new Error("journal unavailable")
      return append(data)
    }
  })

  try {
    const name = await harness.supervisor.spawn("cycle-worker", "first cycle")
    await waitFor(() => harness.supervisor.snapshots()[0]?.lifecycle === "idle", 5_000)
    await harness.supervisor.continue(name, "second cycle")

    const waited = await harness.supervisor.wait([name], 5_000)
    expect(waited).toEqual([
      expect.objectContaining({
        name,
        capturedWorkCycle: 2,
        completion: expect.objectContaining({ workCycle: 2, status: "completed" })
      })
    ])

    const received = await harness.supervisor.waitForTool([name], 0, undefined, "mailbox-pending")
    expect(received).toEqual([
      expect.objectContaining({
        name,
        capturedWorkCycle: 1,
        completion: expect.objectContaining({ workCycle: 1, status: "completed" })
      })
    ])
  } finally {
    Object.defineProperty(harness.sessionManager, "appendSubagent", { configurable: true, value: append })
    await harness.dispose()
  }
}, 15_000)

test("model wait receives the first completion while other captured work keeps running", async () => {
  const harness = await createHarness("wait-mailbox", { reply: "mailbox-ok", delayMs: 300 })
  try {
    const first = await harness.supervisor.spawn("first-worker", "first")
    await Bun.sleep(100)
    const second = await harness.supervisor.spawn("second-worker", "second")

    const received = await harness.supervisor.waitForTool([first, second], 5_000, undefined, "first-receive")
    expect(received).toEqual([
      expect.objectContaining({ name: first, completion: expect.objectContaining({ status: "completed" }) })
    ])
    expect(harness.supervisor.status()).toEqual({ workingNames: [second], readyNames: [] })

    const remaining = await harness.supervisor.waitForTool([first, second], 5_000, undefined, "second-receive")
    expect(remaining).toEqual([
      expect.objectContaining({ name: second, completion: expect.objectContaining({ status: "completed" }) })
    ])
  } finally {
    await harness.dispose()
  }
}, 15_000)

test("cancelling a model mailbox receive preserves later completion delivery", async () => {
  const harness = await createHarness("mailbox-cancel", { reply: "receive-later", delayMs: 300 })
  try {
    const name = await harness.supervisor.spawn("slow-worker", "keep working")
    const controller = new AbortController()
    const outcome = harness.supervisor.waitForTool([name], 5_000, controller.signal, "cancelled-receive").then(
      () => ({ type: "resolved" as const }),
      (cause: unknown) => ({ type: "rejected" as const, cause })
    )
    controller.abort()

    expect(await outcome).toEqual({
      type: "rejected",
      cause: expect.objectContaining({ name: "AbortError", message: "Subagent wait was cancelled" })
    })
    await waitFor(() => harness.supervisor.status().readyNames.includes(name), 5_000)
    expect(await harness.supervisor.waitForTool([name], 0, undefined, "later-receive")).toEqual([
      expect.objectContaining({ name, completion: expect.objectContaining({ text: "receive-later" }) })
    ])
  } finally {
    await harness.dispose()
  }
}, 15_000)

test("observer failure cannot interrupt a wait delivery commit", async () => {
  const harness = await createHarness("wait-observer-failure", { reply: "observer-ok", delayMs: 100 })
  try {
    const first = await harness.supervisor.spawn("first-worker", "first")
    const second = await harness.supervisor.spawn("second-worker", "second")
    await waitFor(() => harness.supervisor.status().readyNames.length === 2, 5_000)
    const unsubscribe = harness.supervisor.subscribe(() => {
      throw new Error("observer failed")
    })

    const waited = await harness.supervisor.wait([first, second], 5_000)
    unsubscribe()

    expect(waited).toEqual([
      expect.objectContaining({ name: first, completion: expect.objectContaining({ status: "completed" }) }),
      expect.objectContaining({ name: second, completion: expect.objectContaining({ status: "completed" }) })
    ])
    expect(harness.supervisor.status()).toEqual({ workingNames: [], readyNames: [] })
  } finally {
    await harness.dispose()
  }
}, 15_000)

test("cancelling wait rejects only the waiter and preserves uncollected results", async () => {
  const harness = await createHarness("wait-cancel", { reply: "wait-ok", delayMs: 300 })
  try {
    const completed = await harness.supervisor.spawn("completed-worker", "finish first")
    await waitFor(() => harness.supervisor.status().readyNames.includes(completed), 5_000)
    const running = await harness.supervisor.spawn("running-worker", "keep working")
    const controller = new AbortController()

    const outcome = harness.supervisor.wait([completed, running], 5_000, controller.signal).then(
      () => ({ type: "resolved" as const }),
      (cause: unknown) => ({ type: "rejected" as const, cause })
    )
    controller.abort()

    expect(await outcome).toEqual({
      type: "rejected",
      cause: expect.objectContaining({ name: "AbortError", message: "Subagent wait was cancelled" })
    })
    expect(harness.supervisor.status()).toEqual({ workingNames: [running], readyNames: [completed] })

    const collected = await harness.supervisor.wait([completed, running], 5_000)
    expect(collected).toEqual([
      expect.objectContaining({ name: completed, completionDelivery: "durable" }),
      expect.objectContaining({ name: running, completionDelivery: "durable" })
    ])
  } finally {
    await harness.dispose()
  }
}, 15_000)

test("wait observation timeout leaves the independent work cycle running", async () => {
  const harness = await createHarness("wait-timeout-independent", { reply: "later", delayMs: 250 })
  try {
    const name = await harness.supervisor.spawn("slow-worker", "keep working")

    const observed = await harness.supervisor.wait([name], 20)
    expect(observed).toEqual([expect.objectContaining({ name, lifecycle: "running", capturedWorkCycle: 1 })])
    expect(observed[0]?.completion).toBeUndefined()
    expect(harness.supervisor.status()).toEqual({ workingNames: [name], readyNames: [] })

    const completed = await harness.supervisor.wait([name], 5_000)
    expect(completed).toEqual([
      expect.objectContaining({ name, completion: expect.objectContaining({ workCycle: 1, status: "completed" }) })
    ])
  } finally {
    await harness.dispose()
  }
}, 15_000)

test("shutdown wins the spawn admission race without appending late ready work", async () => {
  const harness = await createHarness("shutdown-spawn-admission", { delayMs: 300 })
  let shutdown: Promise<void> | undefined
  const unsubscribe = harness.supervisor.subscribe(event => {
    if (
      event.type === "changed" &&
      harness.supervisor.snapshots().some(snapshot => snapshot.name === "racing-child" && snapshot.lifecycle === "idle")
    ) {
      shutdown = harness.supervisor.shutdown()
    }
  })

  try {
    expect(harness.supervisor.spawn("racing-child", "race shutdown")).rejects.toThrow("Subagent supervisor is stopping")
    await shutdown
    expect(harness.supervisor.state).toEqual({ type: "closed" })
    expect(harness.sessionManager.subagentEntries().map(entry => entry.event)).not.toContain("ready")
    expect(harness.sessionManager.subagentEntries().map(entry => entry.event)).not.toContain("work_cycle_started")
  } finally {
    unsubscribe()
    await harness.dispose()
  }
}, 15_000)

test("shutdown after initial cycle admission publishes terminal evidence", async () => {
  const harness = await createHarness("spawn-shutdown-admission", { delayMs: 300 })
  let shutdown: Promise<void> | undefined
  const unsubscribe = harness.supervisor.subscribe(event => {
    if (
      event.type === "entry_appended" &&
      event.entry.type === "subagent" &&
      event.entry.event === "work_cycle_started" &&
      event.entry.workCycle === 1
    ) {
      shutdown = harness.supervisor.shutdown()
    }
  })

  try {
    const outcome = harness.supervisor.spawn("cycle-worker", "initial work").then(
      () => "fulfilled" as const,
      () => "rejected" as const
    )

    expect(await outcome).toBe("rejected")
    expect(shutdown).toBeDefined()
    await shutdown
    expect(harness.sessionManager.subagentEntries()).toContainEqual(
      expect.objectContaining({
        event: "work_cycle_finished",
        name: "cycle-worker",
        workCycle: 1,
        status: "failed",
        reason: "child_exited"
      })
    )
    expect(harness.supervisor.snapshots()[0]).toMatchObject({
      name: "cycle-worker",
      lifecycle: "exited",
      completion: { workCycle: 1, status: "failed", reason: "child_exited" }
    })
  } finally {
    unsubscribe()
    await harness.dispose()
  }
}, 15_000)

test("shutdown before spawn ownership transfer rejects the admitted child", async () => {
  const harness = await createHarness("shutdown-spawn-transfer", { delayMs: 300 })
  let shutdown: Promise<void> | undefined
  const unsubscribe = harness.supervisor.subscribe(event => {
    if (
      event.type === "changed" &&
      harness.supervisor
        .snapshots()
        .some(snapshot => snapshot.name === "racing-child" && snapshot.lifecycle === "running")
    ) {
      shutdown = harness.supervisor.shutdown()
    }
  })

  try {
    expect(harness.supervisor.spawn("racing-child", "race shutdown")).rejects.toThrow("Subagent supervisor is stopping")
    await shutdown
    expect(harness.supervisor.state).toEqual({ type: "closed" })
    expect(harness.supervisor.capacity()).toEqual({ live: 0, maximum: 4 })
    expect(harness.supervisor.snapshots()[0]).toMatchObject({ name: "racing-child", lifecycle: "exited" })
  } finally {
    unsubscribe()
    await harness.dispose()
  }
}, 15_000)

test("synchronous child construction failure retains an addressable exited snapshot", async () => {
  const harness = await createHarness("construction-failure")
  try {
    await rm(harness.cwd, { recursive: true, force: true })

    const outcome = harness.supervisor.spawn("broken-worker", "cannot start").then(
      () => ({ type: "resolved" as const }),
      (cause: unknown) => ({ type: "rejected" as const, cause })
    )

    expect(await outcome).toEqual({ type: "rejected", cause: expect.any(Error) })
    expect(harness.supervisor.capacity()).toEqual({ live: 0, maximum: 4 })
    expect(harness.supervisor.status()).toEqual({ workingNames: [], readyNames: [] })
    expect(harness.supervisor.snapshots()).toEqual([
      expect.objectContaining({ name: "broken-worker", lifecycle: "exited" })
    ])
    expect(await harness.supervisor.wait(["broken-worker"], 5_000)).toEqual([
      expect.objectContaining({ name: "broken-worker", lifecycle: "exited" })
    ])
    expect(await harness.supervisor.close("broken-worker")).toMatchObject({
      name: "broken-worker",
      lifecycle: "exited"
    })
    expect(harness.supervisor.spawn("broken-worker", "retry reserved name")).rejects.toThrow(
      "Subagent name already in use"
    )
    expect(harness.sessionManager.subagentEntries()).toEqual([
      expect.objectContaining({ event: "starting", name: "broken-worker" }),
      expect.objectContaining({ event: "exited", name: "broken-worker", outcome: expect.any(String) })
    ])

    const failures = await Promise.all(
      Array.from({ length: maxRetainedSubagents }, (_, index) =>
        harness.supervisor.spawn(`broken-${index}`, "cannot start").then(
          () => "resolved" as const,
          () => "rejected" as const
        )
      )
    )
    expect(failures.every(result => result === "rejected")).toBe(true)
    expect(harness.supervisor.snapshots()).toHaveLength(maxRetainedSubagents)
    expect(harness.supervisor.snapshots().some(snapshot => snapshot.name === "broken-worker")).toBe(false)
    expect(harness.supervisor.spawn("broken-worker", "still reserved")).rejects.toThrow("Subagent name already in use")
  } finally {
    await harness.dispose()
  }
}, 15_000)

test("an admitted wait retains a terminal target through snapshot eviction", async () => {
  const harness = await createHarness("wait-target-eviction", { reply: "working-done", delayMs: 600 })
  try {
    const working = await harness.supervisor.spawn("working-child", "finish later")
    await rm(harness.cwd, { recursive: true, force: true })
    await harness.supervisor.spawn("evicted-child", "cannot start").catch(() => {})

    const waiting = harness.supervisor.wait(["evicted-child", working], 5_000)
    await Promise.all(
      Array.from({ length: maxRetainedSubagents }, (_, index) =>
        harness.supervisor.spawn(`later-failure-${index}`, "cannot start").catch(() => undefined)
      )
    )
    expect(harness.supervisor.snapshots().some(snapshot => snapshot.name === "evicted-child")).toBe(false)

    expect(await waiting).toEqual([
      expect.objectContaining({ name: "evicted-child", lifecycle: "exited" }),
      expect.objectContaining({ name: working, completion: expect.objectContaining({ status: "completed" }) })
    ])
  } finally {
    await harness.dispose()
  }
}, 15_000)

test("spawn cancellation before admission closes the starting child", async () => {
  const harness = await createHarness("startup-cancel", { delayMs: 300 })
  try {
    const controller = new AbortController()
    controller.abort()
    expect(harness.supervisor.spawn("cancelled-child", "cancel", controller.signal)).rejects.toThrow("was cancelled")
    await waitFor(() => harness.supervisor.snapshots()[0]?.lifecycle === "exited", 5_000)
  } finally {
    await harness.dispose()
  }
}, 15_000)

test("spawn cancellation ends at background ownership transfer", async () => {
  const harness = await createHarness("ownership-transfer", { delayMs: 300 })
  try {
    const controller = new AbortController()
    const name = await harness.supervisor.spawn("background-worker", "background work", controller.signal)
    controller.abort()
    expect(harness.supervisor.snapshots()[0]).toMatchObject({ name, lifecycle: "running" })
    const waited = await harness.supervisor.wait([name], 5_000)
    expect(waited[0]).toMatchObject({ lifecycle: "idle", completion: { status: "completed" } })
  } finally {
    await harness.dispose()
  }
}, 15_000)

test("SubagentSupervisor keeps queue-only send idle and continue extends the current cycle", async () => {
  const harness = await createHarness("delivery", { reply: "delivery-ok", delayMs: 250 })
  try {
    const name = await harness.supervisor.spawn("cycle-worker", "first cycle")
    await harness.supervisor.wait([name], 5_000)
    expect(harness.supervisor.snapshots()[0]).toMatchObject({ lifecycle: "idle", workCycle: 1 })

    await harness.supervisor.send(name, "queue without waking")
    expect(harness.supervisor.snapshots()[0]).toMatchObject({ lifecycle: "idle", workCycle: 1 })

    await harness.supervisor.continue(name, "wake second cycle")
    expect(harness.supervisor.snapshots()[0]).toMatchObject({ lifecycle: "running", workCycle: 2 })
    await harness.supervisor.continue(name, "extend second cycle")

    const waited = await harness.supervisor.wait([name], 5_000)
    expect(waited[0]).toMatchObject({
      lifecycle: "idle",
      workCycle: 2,
      completion: { status: "completed", text: "delivery-ok", workCycle: 2 }
    })
    expect(
      harness.sessionManager
        .subagentEntries()
        .filter(entry => entry.event === "work_cycle_started")
        .map(entry => entry.workCycle)
    ).toEqual([1, 2])
  } finally {
    await harness.dispose()
  }
}, 15_000)

test("concurrent continues serialize work-cycle admission", async () => {
  const harness = await createHarness("concurrent-continue", { reply: "concurrent-ok", delayMs: 250 })
  try {
    const name = await harness.supervisor.spawn("cycle-worker", "first cycle")
    await harness.supervisor.wait([name], 5_000)

    const outcomes = await Promise.all([
      harness.supervisor.continue(name, "start second cycle"),
      harness.supervisor.continue(name, "extend second cycle")
    ])

    expect(outcomes.toSorted()).toEqual(["follow_up", "started_turn"])
    expect(
      harness.sessionManager
        .subagentEntries()
        .filter(entry => entry.event === "work_cycle_started")
        .map(entry => entry.workCycle)
    ).toEqual([1, 2])

    const waited = await harness.supervisor.wait([name], 5_000)
    expect(waited[0]).toMatchObject({
      lifecycle: "idle",
      workCycle: 2,
      completion: { status: "completed", workCycle: 2 }
    })
  } finally {
    await harness.dispose()
  }
}, 15_000)

test("a rejected idle assignment publishes terminal evidence and keeps the child reusable", async () => {
  const harness = await createHarness("rejected-assignment", { reply: "reused-ok", delayMs: 20 })
  try {
    const name = await harness.supervisor.spawn("cycle-worker", "first cycle")
    await harness.supervisor.wait([name], 5_000)

    expect(harness.supervisor.continue(name, "__reject_prompt__")).rejects.toThrow("prompt rejected")
    const rejected = await harness.supervisor.wait([name], 0)
    expect(rejected[0]).toMatchObject({
      capturedWorkCycle: 2,
      completion: { workCycle: 2, status: "failed", reason: "assignment_failed", error: "prompt rejected" }
    })

    expect(await harness.supervisor.continue(name, "third cycle")).toBe("started_turn")
    const reused = await harness.supervisor.wait([name], 5_000)
    expect(reused[0]).toMatchObject({ completion: { workCycle: 3, status: "completed", text: "reused-ok" } })
  } finally {
    await harness.dispose()
  }
}, 15_000)

test("shutdown after work-cycle admission publishes terminal evidence", async () => {
  const harness = await createHarness("continue-shutdown-admission", { delayMs: 250 })
  let shutdown: Promise<void> | undefined
  try {
    const name = await harness.supervisor.spawn("cycle-worker", "first cycle")
    await harness.supervisor.wait([name], 5_000)
    const unsubscribe = harness.supervisor.subscribe(event => {
      if (
        event.type === "entry_appended" &&
        event.entry.type === "subagent" &&
        event.entry.event === "work_cycle_started" &&
        event.entry.workCycle === 2
      ) {
        shutdown = harness.supervisor.shutdown()
      }
    })

    const outcome = harness.supervisor.continue(name, "start second cycle").then(
      () => "fulfilled" as const,
      () => "rejected" as const
    )

    expect(await outcome).toBe("rejected")
    expect(shutdown).toBeDefined()
    await shutdown
    unsubscribe()

    expect(harness.sessionManager.subagentEntries()).toContainEqual(
      expect.objectContaining({
        event: "work_cycle_finished",
        name,
        workCycle: 2,
        status: "failed",
        reason: "child_exited"
      })
    )
    expect(harness.supervisor.snapshots()[0]).toMatchObject({
      name,
      lifecycle: "exited",
      completion: { workCycle: 2, status: "failed", reason: "child_exited" }
    })
  } finally {
    await harness.dispose()
  }
}, 15_000)

test("wait returns an older pending result before a newer active cycle", async () => {
  const harness = await createHarness("ready-while-working", { reply: "cycle-ok", delayMs: 200 })
  try {
    const name = await harness.supervisor.spawn("cycle-worker", "first cycle")
    await waitFor(() => harness.supervisor.status().readyNames.length === 1, 5_000)

    await harness.supervisor.continue(name, "second cycle")
    expect(harness.supervisor.status()).toEqual({ workingNames: [name], readyNames: [name] })

    const older = await harness.supervisor.wait([name], 0)
    expect(older[0]).toMatchObject({
      lifecycle: "running",
      capturedWorkCycle: 1,
      completion: { workCycle: 1, text: "cycle-ok" }
    })
    expect(harness.supervisor.status()).toEqual({ workingNames: [name], readyNames: [] })

    const newer = await harness.supervisor.wait([name], 5_000)
    expect(newer[0]).toMatchObject({ capturedWorkCycle: 2, completion: { workCycle: 2, text: "cycle-ok" } })
    expect(harness.supervisor.status()).toEqual({ workingNames: [], readyNames: [] })
  } finally {
    await harness.dispose()
  }
}, 15_000)

test("concurrent model waits claim once and nested Code Mode release restores canonical delivery", async () => {
  const harness = await createHarness("concurrent-wait-claims", { reply: "claimed-once", delayMs: 20 })
  try {
    const name = await harness.supervisor.spawn("cycle-worker", "first cycle")
    await waitFor(() => harness.supervisor.status().readyNames.includes(name), 5_000)

    const waits = await Promise.all([
      harness.supervisor.waitForTool([name], 0, undefined, "parent:code:0"),
      harness.supervisor.waitForTool([name], 0, undefined, "direct-tool")
    ])
    expect(waits.flat().filter(snapshot => snapshot.completion)).toHaveLength(1)
    expect(harness.supervisor.status().readyNames).toEqual([])

    harness.supervisor.releaseCompletionClaims("parent:code:")
    expect(harness.supervisor.status().readyNames).toEqual([name])
    const delivered: string[] = []
    harness.supervisor.deliverCompletions(completion => delivered.push(completion.text))
    expect(delivered).toEqual(["claimed-once"])
  } finally {
    await harness.dispose()
  }
}, 15_000)

test("completion durability commits before entry observers can claim it", async () => {
  const harness = await createHarness("completion-commit-order", { reply: "claimed-after-commit", delayMs: 20 })
  let claimed: ReturnType<SubagentSupervisor["waitForTool"]> | undefined
  const unsubscribe = harness.supervisor.subscribe(event => {
    if (
      event.type === "entry_appended" &&
      event.entry.type === "subagent" &&
      event.entry.event === "work_cycle_finished"
    ) {
      claimed ??= harness.supervisor.waitForTool(["cycle-worker"], 0, undefined, "entry-observer")
    }
  })
  try {
    await harness.supervisor.spawn("cycle-worker", "first cycle")
    await waitFor(() => claimed !== undefined, 5_000)
    if (!claimed) throw new Error("Expected the completion entry observer to claim the result")

    expect(await claimed).toEqual([
      expect.objectContaining({
        name: "cycle-worker",
        completionDelivery: "claimed",
        completion: expect.objectContaining({ text: "claimed-after-commit" })
      })
    ])
    expect(harness.supervisor.status().readyNames).toEqual([])
    harness.supervisor.releaseCompletionClaims("entry-observer")
    expect(harness.supervisor.status().readyNames).toEqual(["cycle-worker"])
  } finally {
    unsubscribe()
    await harness.dispose()
  }
}, 15_000)

test("a multi-agent wait drains each oldest pending cycle independently", async () => {
  const harness = await createHarness("later-cycle-timeout", { reply: "cycle-ok", delayMs: 300 })
  try {
    const running = await harness.supervisor.spawn("cycle-worker", "first cycle")
    const completed = await harness.supervisor.spawn("completed-worker", "only cycle")
    await waitFor(() => harness.supervisor.status().readyNames.length === 2, 5_000)

    await harness.supervisor.continue(running, "second cycle")
    const pending = await harness.supervisor.wait([running, completed], 0)

    expect(pending[0]).toMatchObject({
      name: running,
      lifecycle: "running",
      capturedWorkCycle: 1,
      completion: { workCycle: 1, status: "completed" }
    })
    expect(pending[1]).toMatchObject({
      name: completed,
      lifecycle: "idle",
      capturedWorkCycle: 1,
      completion: { workCycle: 1, status: "completed" }
    })
    expect(harness.supervisor.status()).toEqual({ workingNames: [running], readyNames: [] })

    const current = await harness.supervisor.wait([running], 5_000)
    expect(current[0]).toMatchObject({ capturedWorkCycle: 2, completion: { workCycle: 2 } })
    expect(harness.supervisor.status()).toEqual({ workingNames: [], readyNames: [] })
  } finally {
    await harness.dispose()
  }
}, 15_000)

test("closing new work returns exact terminal evidence while preserving the older result", async () => {
  const harness = await createHarness("close-new-cycle", { reply: "cycle-ok", delayMs: 300 })
  try {
    const name = await harness.supervisor.spawn("cycle-worker", "first cycle")
    await waitFor(() => harness.supervisor.status().readyNames.length === 1, 5_000)

    await harness.supervisor.continue(name, "second cycle")
    const closed = await harness.supervisor.closeAndDeliver(name)
    expect(closed).toMatchObject({
      capturedWorkCycle: 2,
      completionDelivery: "delivered",
      completion: { workCycle: 2, status: "failed", reason: "child_exited" }
    })

    expect(harness.supervisor.snapshots()[0]).toMatchObject({
      lifecycle: "exited",
      completionDelivery: "durable",
      completion: { workCycle: 1, status: "completed" }
    })
    const first = await harness.supervisor.wait([name], 0)
    expect(first[0]).toMatchObject({ completion: { workCycle: 1, status: "completed" } })
    const second = await harness.supervisor.wait([name], 0)
    expect(second[0]).toMatchObject({ completion: { workCycle: 2, status: "failed", reason: "child_exited" } })
  } finally {
    await harness.dispose()
  }
}, 15_000)

test("provider failure metadata is bounded before durable completion admission", async () => {
  const harness = await createHarness("bounded-provider-error", {
    reply: "failed-output",
    error: "x".repeat(64 * 1024),
    delayMs: 20
  })
  try {
    const name = await harness.supervisor.spawn("failed-worker", "fail with a large provider error")
    await waitFor(() => harness.supervisor.status().readyNames.includes(name), 5_000)
    const [snapshot] = await harness.supervisor.wait([name], 0)
    expect(snapshot?.completion).toMatchObject({ workCycle: 1, status: "failed", text: "failed-output" })
    expect(Buffer.byteLength(snapshot?.completion?.error ?? "")).toBe(durablePreviewBytes)
    expect(
      harness.sessionManager
        .subagentEntries()
        .find(entry => entry.event === "work_cycle_finished" && entry.name === name)
    ).toMatchObject({ error: "x".repeat(durablePreviewBytes) })
  } finally {
    await harness.dispose()
  }
}, 15_000)

test("SubagentSupervisor publishes bounded actionable diagnostics when a child protocol fails", async () => {
  const harness = await createHarness("protocol-failure", { delayMs: 1_000, protocolCrash: true })
  try {
    const name = await harness.supervisor.spawn("protocol-worker", "start work")
    const waited = await harness.supervisor.wait([name], 5_000)
    expect(waited[0]).toMatchObject({
      lifecycle: "exited",
      completion: { status: "failed", reason: "child_failed", error: "Subagent RPC emitted invalid JSONL" }
    })
    expect(
      harness.sessionManager.subagentEntries().findLast(entry => entry.event === "work_cycle_finished")
    ).toMatchObject({
      event: "work_cycle_finished",
      status: "failed",
      reason: "child_failed",
      error: "Subagent RPC emitted invalid JSONL"
    })
  } finally {
    await harness.dispose()
  }
}, 15_000)

test("SubagentSupervisor interrupts a child and reuses it for another cycle", async () => {
  const harness = await createHarness("interrupt", { reply: "reused-ok", delayMs: 250 })
  try {
    const name = await harness.supervisor.spawn("reusable-worker", "long first cycle")
    const interrupted = await harness.supervisor.interruptAndWait(name)
    expect(interrupted).toMatchObject({
      result: "interrupted",
      snapshot: { lifecycle: "idle", workCycle: 1, completion: { status: "cancelled", workCycle: 1 } }
    })

    await harness.supervisor.continue(name, "reuse child")
    const reused = await harness.supervisor.wait([name], 5_000)
    expect(reused[0]).toMatchObject({
      lifecycle: "idle",
      workCycle: 2,
      completion: { status: "completed", text: "reused-ok", workCycle: 2 }
    })
  } finally {
    await harness.dispose()
  }
}, 15_000)

test("cancelling interrupt settlement preserves exact cycle evidence", async () => {
  const harness = await createHarness("interrupt-cancel", { reply: "cancelled", delayMs: 250 })
  try {
    const name = await harness.supervisor.spawn("reusable-worker", "long first cycle")
    const controller = new AbortController()
    controller.abort()
    expect(harness.supervisor.interruptAndWaitForTool(name, controller.signal)).rejects.toMatchObject({
      name: "AbortError"
    })

    const retained = await harness.supervisor.wait([name], 5_000)
    expect(retained[0]).toMatchObject({ capturedWorkCycle: 1, completion: { workCycle: 1, status: "cancelled" } })
  } finally {
    await harness.dispose()
  }
}, 15_000)

test("interrupt observation cancels while the admitted RPC command settles independently", async () => {
  const harness = await createHarness("interrupt-observation-cancel", {
    reply: "cancelled",
    delayMs: 30_000,
    interruptBarrier: true
  })
  try {
    const name = await harness.supervisor.spawn("reusable-worker", "long first cycle")
    const controller = new AbortController()
    let outcome: { readonly type: "resolved" } | { readonly type: "rejected"; readonly cause: unknown } | undefined
    void harness.supervisor.interruptAndWaitForTool(name, controller.signal).then(
      () => {
        outcome = { type: "resolved" }
        return undefined
      },
      cause => {
        outcome = { type: "rejected", cause }
        return undefined
      }
    )
    await waitFor(() => harness.supervisor.snapshots()[0]?.lifecycle === "interrupting", 5_000)

    controller.abort()
    await Bun.sleep(0)
    expect(outcome).toEqual({ type: "rejected", cause: expect.objectContaining({ name: "AbortError" }) })

    await writeFile(harness.interruptReleasePath!, "release")
    const retained = await harness.supervisor.wait([name], 5_000)
    expect(retained[0]).toMatchObject({ capturedWorkCycle: 1, completion: { workCycle: 1, status: "cancelled" } })
  } finally {
    await harness.dispose()
  }
}, 15_000)

test("Code Mode cancels sibling subagent observation after a nested failure", async () => {
  const harness = await createHarness("code-mode-interrupt-cancel", {
    reply: "cancelled",
    delayMs: 30_000,
    interruptBarrier: true
  })
  const codeMode = new CodeMode(harness.cwd, codeModeWorkerCommand)
  try {
    const name = await harness.supervisor.spawn("reusable-worker", "long first cycle")
    const subagentTools = createSubagentTools(
      [{ name: "pathfinder", description: "Find paths", instructions: "Return evidence." }],
      harness.supervisor,
      (_profile, runtimeName, prompt, signal) => harness.supervisor.spawn(runtimeName, prompt, signal)
    )
    const interrupt = subagentTools.find(tool => tool.name === "interrupt_subagent")
    if (!interrupt) throw new Error("Expected interrupt_subagent tool")
    const fail: AgentTool = {
      name: "fail",
      label: "fail",
      description: "Fail immediately",
      parameters: Type.Object({}),
      execute: async () => {
        throw new Error("first nested failure")
      }
    }
    const tool = codeMode.createTool([fail, interrupt])
    const result = await tool.execute(
      "outer",
      {
        code: `async () => Promise.all([
  zi.fail({}),
  zi.interrupt_subagent({ name: "${name}" })
])`
      },
      undefined
    )

    expect(isCodeModeDetails(result.details)).toBe(true)
    if (!isCodeModeDetails(result.details) || result.details.outcome !== "error") {
      throw new Error("Expected nested tool failure")
    }
    expect(result.content[0]).toEqual({ type: "text", text: expect.stringContaining("Nested Zi tool fail failed") })
    expect(result.details.calls).toEqual([
      expect.objectContaining({ name: "fail", state: "failed" }),
      expect.objectContaining({ name: "interrupt_subagent", state: "aborted" })
    ])

    const recovered = await tool.execute("recovered", { code: `async () => "ready"` }, undefined)
    expect(recovered.content).toEqual([{ type: "text", text: "ready" }])

    await writeFile(harness.interruptReleasePath!, "release")
    const retained = await harness.supervisor.wait([name], 5_000)
    expect(retained[0]).toMatchObject({ capturedWorkCycle: 1, completion: { workCycle: 1, status: "cancelled" } })

    await harness.supervisor.continue(name, "__short_work__")
    const reused = await harness.supervisor.wait([name], 5_000)
    expect(reused[0]).toMatchObject({ capturedWorkCycle: 2, completion: { workCycle: 2, status: "completed" } })
  } finally {
    await codeMode.dispose()
    await harness.dispose()
  }
}, 15_000)

test("SubagentSupervisor admits four live children and rejects a fifth", async () => {
  const harness = await createHarness("capacity", { delayMs: 20 })
  try {
    expect(harness.supervisor.capacity()).toEqual({ live: 0, maximum: 4 })
    const names: string[] = []
    for (let index = 0; index < 4; index++) {
      // oxlint-disable-next-line no-await-in-loop -- capacity is admitted one child at a time
      names.push(await harness.supervisor.spawn(`worker-${index}`, `task ${index}`))
    }

    expect(new Set(names).size).toBe(4)
    expect(harness.supervisor.snapshots()).toHaveLength(4)
    expect(harness.supervisor.capacity()).toEqual({ live: 4, maximum: 4 })
    expect(harness.supervisor.spawn("extra-worker", "one too many")).rejects.toThrow(
      "Subagent capacity exceeded: at most 4 live children. Close a child you no longer need before spawning another."
    )
    await harness.supervisor.close(names[0]!)
    expect(harness.supervisor.capacity()).toEqual({ live: 3, maximum: 4 })
  } finally {
    await harness.dispose()
  }
}, 15_000)

test("SubagentSupervisor validates names and keeps them unique for the parent session", async () => {
  const harness = await createHarness("names", { delayMs: 20 })
  try {
    for (const name of ["", "Uppercase", "two words", "1worker", "worker/path", "éclair", `a${"x".repeat(64)}`]) {
      expect(harness.supervisor.spawn(name, "invalid name")).rejects.toThrow("Subagent name")
    }
    expect(harness.sessionManager.subagentEntries()).toEqual([])

    const name = await harness.supervisor.spawn("unique-worker", "first task")
    await harness.supervisor.close(name)
    expect(harness.supervisor.spawn("unique-worker", "second task")).rejects.toThrow(
      "Subagent name already in use: unique-worker"
    )
    expect(harness.sessionManager.subagentEntries().filter(entry => entry.event === "starting")).toHaveLength(1)
  } finally {
    await harness.dispose()
  }
}, 15_000)

test("SubagentSupervisor recovers journal evidence without recreating a process", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-subagent-recovery-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "agent"))
  await mkdir(paths.cwd, { recursive: true })
  const sessionManager = SessionManager.create(paths, { persist: false })
  sessionManager.appendSubagent({ event: "starting", name: "orphaned-worker" })

  const supervisor = new SubagentSupervisor({
    command: [join(root, "must-not-be-executed")],
    cwd: paths.cwd,
    env: {},
    selection: () => ({ model: "faux/faux-1", thinkingLevel: "off" }),
    sessionManager,
    processTreeTracker: createProcessTreeTracker()
  })
  try {
    expect(supervisor.runningCount()).toBe(0)
    expect(supervisor.snapshots()).toEqual([expect.objectContaining({ name: "orphaned-worker", lifecycle: "exited" })])
    expect(supervisor.transcript("orphaned-worker")).toBeUndefined()
    expect(sessionManager.subagentEntries().map(entry => entry.event)).toEqual(["starting", "lost"])
    expect(sessionManager.subagentEntries().at(-1)).toMatchObject({
      event: "lost",
      name: "orphaned-worker",
      reason: "session_restored"
    })
  } finally {
    await supervisor.shutdown()
    await rm(root, { recursive: true, force: true })
  }
})

test("work-cycle timeout evidence survives supervisor restoration", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-subagent-timeout-recovery-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "agent"))
  await mkdir(paths.cwd, { recursive: true })
  const sessionManager = SessionManager.create(paths, { persist: false })
  sessionManager.appendSubagent({ event: "starting", name: "timed-out-worker" })
  sessionManager.appendSubagent({
    event: "work_cycle_started",
    name: "timed-out-worker",
    workCycle: 1,
    task: "bounded work"
  })
  sessionManager.appendSubagent({
    event: "work_cycle_finished",
    name: "timed-out-worker",
    workCycle: 1,
    status: "failed",
    preview: "",
    originalBytes: 0,
    omittedBytes: 0,
    truncated: false,
    durationMs: 900_000,
    reason: "work_cycle_timeout",
    error: "Subagent work cycle exceeded 900000ms"
  })

  const supervisor = new SubagentSupervisor({
    command: [join(root, "unused")],
    cwd: paths.cwd,
    env: {},
    selection: () => ({ model: "faux/faux-1", thinkingLevel: "off" }),
    sessionManager,
    processTreeTracker: createProcessTreeTracker()
  })
  try {
    expect(await supervisor.wait(["timed-out-worker"], 0)).toEqual([
      expect.objectContaining({
        name: "timed-out-worker",
        workCycle: 1,
        completionDelivery: "durable",
        completion: expect.objectContaining({
          status: "failed",
          reason: "work_cycle_timeout",
          error: "Subagent work cycle exceeded 900000ms"
        })
      })
    ])
    expect(supervisor.status().readyNames).toEqual([])
  } finally {
    await supervisor.shutdown()
    await rm(root, { recursive: true, force: true })
  }
})

test("recovered completion and exited projections stay bounded", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-subagent-recovery-bounds-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "agent"))
  await mkdir(paths.cwd, { recursive: true })
  const sessionManager = SessionManager.create(paths, { persist: false })
  for (let index = 0; index < 40; index++) {
    const workerName = `worker-${index}`
    sessionManager.appendSubagent({ event: "starting", name: workerName })
    sessionManager.appendSubagent({
      event: "work_cycle_started",
      name: workerName,
      workCycle: 1,
      task: `task-${index}`
    })
    sessionManager.appendSubagent({
      event: "work_cycle_finished",
      name: workerName,
      workCycle: 1,
      status: "completed",
      preview: `result-${index}`,
      originalBytes: 9,
      omittedBytes: 0,
      truncated: false,
      durationMs: 1
    })
    if (index < 8) sessionManager.appendSubagent({ event: "work_cycle_delivered", name: workerName, workCycle: 1 })
  }
  const supervisor = new SubagentSupervisor({
    command: [join(root, "unused")],
    cwd: paths.cwd,
    env: {},
    selection: () => ({ model: "faux/faux-1", thinkingLevel: "off" }),
    sessionManager,
    processTreeTracker: createProcessTreeTracker()
  })
  try {
    expect(supervisor.snapshots()).toHaveLength(32)
    expect(supervisor.snapshots()[0]).toMatchObject({ name: "worker-8", workCycle: 1, task: "task-8", elapsedMs: 1 })
    expect(supervisor.spawn("worker-0", "duplicate evicted child")).rejects.toThrow(
      "Subagent name already in use: worker-0"
    )
    expect(supervisor.spawn("no-capacity", "no capacity")).rejects.toThrow("Subagent completion capacity exceeded")
    expect(await supervisor.wait(["worker-39"], 0)).toMatchObject([
      { completion: { text: "result-39" }, completionDelivery: "durable" }
    ])
  } finally {
    await supervisor.shutdown()
    await rm(root, { recursive: true, force: true })
  }
})

test("recovery rejects an impossible journal instead of evicting undelivered evidence", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-subagent-recovery-overflow-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "agent"))
  await mkdir(paths.cwd, { recursive: true })
  const sessionManager = SessionManager.create(paths, { persist: false })
  for (let index = 0; index <= maxRetainedSubagents; index++) {
    const name = `worker-${index}`
    sessionManager.appendSubagent({ event: "starting", name })
    sessionManager.appendSubagent({ event: "work_cycle_started", name, workCycle: 1 })
    sessionManager.appendSubagent({
      event: "work_cycle_finished",
      name,
      workCycle: 1,
      status: "completed",
      preview: `result-${index}`,
      originalBytes: 9,
      omittedBytes: 0,
      truncated: false,
      durationMs: 1
    })
  }
  try {
    expect(
      () =>
        new SubagentSupervisor({
          command: [join(root, "unused")],
          cwd: paths.cwd,
          env: {},
          selection: () => ({ model: "faux/faux-1", thinkingLevel: "off" }),
          sessionManager,
          processTreeTracker: createProcessTreeTracker()
        })
    ).toThrow(`more than ${maxRetainedSubagents} undelivered subagent completions`)
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test("restored parent-context evidence suppresses duplicate completion delivery", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-subagent-delivery-recovery-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "agent"))
  await mkdir(paths.cwd, { recursive: true })
  const sessionManager = SessionManager.create(paths, { persist: false })
  sessionManager.appendSubagent({ event: "starting", name: "restored-worker" })
  sessionManager.appendSubagent({ event: "work_cycle_started", name: "restored-worker", workCycle: 1 })
  sessionManager.appendSubagent({
    event: "work_cycle_finished",
    name: "restored-worker",
    workCycle: 1,
    status: "completed",
    preview: "restored-result",
    originalBytes: 15,
    omittedBytes: 0,
    truncated: false,
    durationMs: 1
  })
  sessionManager.appendSubagent({
    event: "work_cycle_finished",
    name: "restored-worker",
    workCycle: 1,
    status: "completed",
    preview: "duplicate-result",
    originalBytes: 16,
    omittedBytes: 0,
    truncated: false,
    durationMs: 2
  })
  sessionManager.appendSubagent({ event: "work_cycle_delivered", name: "restored-worker", workCycle: 1 })
  const supervisor = new SubagentSupervisor({
    command: [join(root, "unused")],
    cwd: paths.cwd,
    env: {},
    selection: () => ({ model: "faux/faux-1", thinkingLevel: "off" }),
    sessionManager,
    processTreeTracker: createProcessTreeTracker()
  })
  try {
    const delivered: string[] = []
    supervisor.deliverCompletions(completion => delivered.push(completion.text))
    expect(delivered).toEqual([])
    expect(supervisor.status().readyNames).toEqual([])
    expect(supervisor.snapshots()[0]).toMatchObject({
      completionDelivery: "delivered",
      completion: { text: "restored-result", durationMs: 1 }
    })
  } finally {
    await supervisor.shutdown()
    await rm(root, { recursive: true, force: true })
  }
})

test("SubagentSupervisor resolves the parent's current model selection without exposing its credential in argv", async () => {
  const argvPath = join(tmpdir(), `zi-subagent-selection-${crypto.randomUUID()}.json`)
  const apiKeyPath = join(tmpdir(), `zi-subagent-api-key-${crypto.randomUUID()}.txt`)
  let model = "faux/current"
  let thinkingLevel: "off" | "high" = "off"
  const harness = await createHarness("selection", {
    argvPath,
    apiKeyPath,
    selection: () => ({ model, thinkingLevel, apiKey: "ephemeral-key" })
  })
  try {
    model = "faux/changed"
    thinkingLevel = "high"
    const name = await harness.supervisor.spawn("selection-inspector", "inspect selection")
    const argv: unknown = JSON.parse(readFileSync(argvPath, "utf8"))
    expect(argv).toEqual(expect.arrayContaining(["--model", "faux/changed", "--thinking", "high"]))
    expect(argv).not.toContain("--api-key")
    expect(argv).not.toContain("ephemeral-key")
    expect(readFileSync(apiKeyPath, "utf8")).toBe("ephemeral-key")
    await harness.supervisor.close(name)
  } finally {
    await harness.dispose()
    await Promise.all([rm(argvPath, { force: true }), rm(apiKeyPath, { force: true })])
  }
}, 15_000)

test("SubagentSupervisor propagates the code-only tool surface to child sessions", async () => {
  const argvPath = join(tmpdir(), `zi-subagent-code-only-${crypto.randomUUID()}.json`)
  const harness = await createHarness("code-only", { argvPath, toolSurface: "code-only" })
  try {
    const name = await harness.supervisor.spawn("programmatic-worker", "inspect programmatically")
    const argv: unknown = JSON.parse(readFileSync(argvPath, "utf8"))
    expect(argv).toEqual(expect.arrayContaining(["--mode", "rpc", "--code-only"]))
    await harness.supervisor.close(name)
  } finally {
    await harness.dispose()
    await rm(argvPath, { force: true })
  }
}, 15_000)

test("close cleans up and returns terminal evidence when lifecycle journaling fails", async () => {
  const harness = await createHarness("close-journal-failure", { delayMs: 300 })
  try {
    const name = await harness.supervisor.spawn("journal-worker", "active cycle")
    const append = harness.sessionManager.appendSubagent.bind(harness.sessionManager)
    Object.defineProperty(harness.sessionManager, "appendSubagent", {
      configurable: true,
      value(data: Parameters<SessionManager["appendSubagent"]>[0]) {
        if (data.event === "closing" || data.event === "exited") throw new Error("journal unavailable")
        return append(data)
      }
    })

    const closed = await harness.supervisor.closeAndDeliver(name)
    expect(closed).toMatchObject({
      lifecycle: "exited",
      capturedWorkCycle: 1,
      completion: { workCycle: 1, status: "failed", reason: "child_exited" }
    })
    expect(harness.supervisor.capacity()).toEqual({ live: 0, maximum: 4 })
  } finally {
    await harness.dispose()
  }
}, 15_000)

test("SubagentSupervisor shutdown preempts a blocked serialized child command", async () => {
  const harness = await createHarness("shutdown-blocked-command", { delayMs: 1_000 })
  try {
    const name = await harness.supervisor.spawn("blocked-worker", "start")
    const blocked = harness.supervisor.send(name, "__block_prompt__").then(
      () => "fulfilled" as const,
      () => "rejected" as const
    )
    await Bun.sleep(50)

    await harness.supervisor.shutdown()

    expect(harness.supervisor.state).toEqual({ type: "closed" })
    expect(await blocked).toBe("rejected")
    expect(harness.supervisor.snapshots()[0]).toMatchObject({ name, lifecycle: "exited" })
  } finally {
    await harness.dispose()
  }
}, 15_000)

test("SubagentSupervisor durably reports work-cycle timeout and keeps the child reusable", async () => {
  const harness = await createHarness("work-timeout", { delayMs: 30_000, workTimeoutMs: 40 })
  try {
    const name = await harness.supervisor.spawn("timeout-worker", "take too long")
    await waitFor(() => harness.supervisor.snapshots()[0]?.lifecycle === "idle", 5_000)

    expect(harness.supervisor.snapshots()[0]).toMatchObject({
      name,
      lifecycle: "idle",
      completion: { workCycle: 1, status: "failed", reason: "work_cycle_timeout" }
    })
    expect(
      harness.sessionManager
        .subagentEntries()
        .find(entry => entry.event === "work_cycle_finished" && entry.name === name && entry.workCycle === 1)
    ).toMatchObject({ status: "failed", reason: "work_cycle_timeout" })
    await harness.supervisor.wait([name], 0)

    await harness.supervisor.continue(name, "another bounded cycle")
    await waitFor(() => harness.supervisor.snapshots()[0]?.completion?.workCycle === 2, 5_000)
    expect(harness.supervisor.snapshots()[0]).toMatchObject({
      lifecycle: "idle",
      completion: { workCycle: 2, status: "failed", reason: "work_cycle_timeout" }
    })
    await harness.supervisor.close(name)
  } finally {
    await harness.dispose()
  }
}, 15_000)

test("SubagentSupervisor relays authenticated queue-only messages between sibling children", async () => {
  const harness = await createHarness("peer-relay", { delayMs: 20, peerRelay: true })
  try {
    await harness.supervisor.spawn("worker-b", "wait for peer context")
    await waitFor(() => harness.supervisor.snapshots()[0]?.lifecycle === "idle", 5_000)
    await harness.supervisor.spawn("worker-a", "__peer_send__")
    await waitFor(() => Bun.file(harness.peerResponsePath!).size > 0, 5_000)
    await waitFor(() => {
      try {
        return readFileSync(harness.promptsLogPath!, "utf8").includes("[Peer message from worker-a]\\npeer evidence")
      } catch {
        return false
      }
    }, 5_000)

    expect(JSON.parse(await Bun.file(harness.peerResponsePath!).text())).toMatchObject({
      type: "peer_response",
      id: "mock-peer-1",
      operation: "send",
      ok: true,
      result: { delivered: true }
    })
    expect(harness.supervisor.snapshots().find(snapshot => snapshot.name === "worker-b")?.lifecycle).toBe("idle")
  } finally {
    await harness.dispose()
  }
}, 15_000)

test("SubagentSupervisor lists live siblings without exposing the authenticated sender", async () => {
  const harness = await createHarness("peer-list", { delayMs: 20, peerRelay: true, peerOperation: "list" })
  try {
    await harness.supervisor.spawn("worker-b", "wait")
    await waitFor(() => harness.supervisor.snapshots()[0]?.lifecycle === "idle", 5_000)
    await harness.supervisor.spawn("worker-a", "__peer_send__")
    await waitFor(() => Bun.file(harness.peerResponsePath!).size > 0, 5_000)

    expect(JSON.parse(await Bun.file(harness.peerResponsePath!).text())).toEqual({
      version: 1,
      type: "peer_response",
      id: "mock-peer-1",
      operation: "list",
      ok: true,
      result: { peers: [{ name: "worker-b", lifecycle: "idle" }] }
    })
  } finally {
    await harness.dispose()
  }
}, 15_000)

test("SubagentSupervisor rejects self-addressed peer messages", async () => {
  const harness = await createHarness("peer-self", {
    delayMs: 20,
    peerRelay: true,
    peerOperation: "send",
    peerTarget: "worker-a"
  })
  try {
    await harness.supervisor.spawn("worker-a", "__peer_send__")
    await waitFor(() => Bun.file(harness.peerResponsePath!).size > 0, 5_000)

    expect(JSON.parse(await Bun.file(harness.peerResponsePath!).text())).toMatchObject({
      type: "peer_response",
      id: "mock-peer-1",
      operation: "send",
      ok: false,
      error: expect.stringContaining("cannot send a peer message to itself")
    })
  } finally {
    await harness.dispose()
  }
}, 15_000)

test("SubagentSupervisor shutdown disposes its live children and descendants and closes admission", async () => {
  const harness = await createHarness("shutdown", { delayMs: 400, descendant: true })
  try {
    const name = await harness.supervisor.spawn("shutdown-worker", "keep working")
    expect(harness.supervisor.snapshots()[0]).toMatchObject({ name, lifecycle: "running" })
    const descendantPid = await readPid(harness.descendantMarker!)
    expect(processAlive(descendantPid)).toBe(true)

    await harness.supervisor.shutdown()
    await waitFor(() => !processAlive(descendantPid), 5_000)

    expect(harness.supervisor.state).toEqual({ type: "closed" })
    expect(harness.supervisor.snapshots()[0]).toMatchObject({ name, lifecycle: "exited" })
    expect(harness.sessionManager.subagentEntries().some(entry => entry.event === "closing")).toBe(true)
    expect(harness.sessionManager.subagentEntries().at(-1)).toMatchObject({ event: "exited", name })
    expect(harness.supervisor.spawn("late-worker", "too late")).rejects.toThrow("Subagent supervisor is closed")
  } finally {
    await harness.dispose()
  }
}, 15_000)

async function createHarness(
  name: string,
  options: {
    readonly reply?: string
    readonly error?: string
    readonly delayMs?: number
    readonly workTimeoutMs?: number
    readonly descendant?: boolean
    readonly argvPath?: string
    readonly apiKeyPath?: string
    readonly protocolCrash?: boolean
    readonly peerRelay?: boolean
    readonly peerOperation?: "list" | "send"
    readonly peerTarget?: string
    readonly interruptBarrier?: boolean
    readonly toolSurface?: "code-only"
    readonly selection?: () => {
      readonly model: string
      readonly thinkingLevel: "off" | "high"
      readonly apiKey?: string
    }
  } = {}
): Promise<{
  readonly supervisor: SubagentSupervisor
  readonly sessionManager: SessionManager
  readonly cwd: string
  readonly descendantMarker?: string
  readonly peerResponsePath?: string
  readonly promptsLogPath?: string
  readonly interruptReleasePath?: string
  dispose(): Promise<void>
}> {
  const root = await mkdtemp(join(tmpdir(), `zi-subagent-${name}-`))
  const paths = new ZiPaths(join(root, "project"), join(root, "agent"))
  await mkdir(paths.cwd, { recursive: true })
  const sessionManager = SessionManager.create(paths, { persist: false })
  const descendantMarker = options.descendant ? join(root, "descendant.pid") : undefined
  const peerResponsePath = options.peerRelay ? join(root, "peer-response.json") : undefined
  const promptsLogPath = options.peerRelay ? join(root, "prompts.log") : undefined
  const interruptReleasePath = options.interruptBarrier ? join(root, "interrupt.release") : undefined
  const supervisor = new SubagentSupervisor({
    command: [process.execPath, mockChild],
    cwd: paths.cwd,
    env: {
      ...process.env,
      MOCK_RPC_REPLY: options.reply ?? "child-done",
      MOCK_RPC_DELAY_MS: String(options.delayMs ?? 30),
      ...(options.error ? { MOCK_RPC_ERROR: options.error } : {}),
      ...(descendantMarker ? { MOCK_RPC_DESCENDANT_PID: descendantMarker } : {}),
      ...(options.argvPath ? { MOCK_RPC_ARGV: options.argvPath } : {}),
      ...(options.apiKeyPath ? { MOCK_RPC_INTERNAL_API_KEY: options.apiKeyPath } : {}),
      ...(options.protocolCrash ? { MOCK_RPC_PROTOCOL_CRASH: "1" } : {}),
      ...(peerResponsePath ? { MOCK_RPC_PEER_RESPONSE: peerResponsePath } : {}),
      ...(promptsLogPath ? { MOCK_RPC_PROMPTS_LOG: promptsLogPath } : {}),
      ...(options.peerOperation ? { MOCK_RPC_PEER_OPERATION: options.peerOperation } : {}),
      ...(options.peerTarget ? { MOCK_RPC_PEER_TARGET: options.peerTarget } : {}),
      ...(interruptReleasePath ? { MOCK_RPC_INTERRUPT_RELEASE: interruptReleasePath } : {})
    },
    selection: options.selection ?? (() => ({ model: "faux/faux-1", thinkingLevel: "off" })),
    sessionManager,
    processTreeTracker: createProcessTreeTracker(),
    ...(options.workTimeoutMs ? { workTimeoutMs: options.workTimeoutMs } : {}),
    ...(options.toolSurface ? { toolSurface: options.toolSurface } : {})
  })
  return {
    supervisor,
    sessionManager,
    cwd: paths.cwd,
    ...(descendantMarker ? { descendantMarker } : {}),
    ...(peerResponsePath ? { peerResponsePath } : {}),
    ...(promptsLogPath ? { promptsLogPath } : {}),
    ...(interruptReleasePath ? { interruptReleasePath } : {}),
    async dispose() {
      await supervisor.shutdown()
      await rm(root, { recursive: true, force: true })
    }
  }
}

async function readPid(path: string): Promise<number> {
  let value = 0
  await waitFor(() => {
    try {
      value = Number(readFileSync(path, "utf8"))
      return Number.isInteger(value) && value > 0
    } catch {
      return false
    }
  }, 5_000)
  return value
}

function processAlive(pid: number): boolean {
  try {
    process.kill(pid, 0)
    return true
  } catch {
    return false
  }
}

async function waitFor(predicate: () => boolean, timeoutMs: number): Promise<void> {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    if (predicate()) return
    // oxlint-disable-next-line no-await-in-loop -- bounded poll of public supervisor state
    await Bun.sleep(15)
  }
  throw new Error("condition not met before deadline")
}
