import { expect, test } from "bun:test"

import type { SubagentEntry } from "../src/session-manager.js"
import type { SubagentCompletion } from "../src/subagents/child-process.js"
import { CompletionLedger } from "../src/subagents/completion-ledger.js"

test("CompletionLedger preserves claim and acknowledgement state across persistence", () => {
  const ledger = new CompletionLedger(4)
  const claimed = completion("claimed-worker", 1)
  ledger.reserve(claimed.name, claimed.workCycle)
  expect(ledger.admit(claimed)).toBe("accepted")
  expect(ledger.delivery(claimed.name, claimed.workCycle)).toEqual({ type: "pending", completion: claimed })

  expect(ledger.claim(claimed.name, claimed.workCycle, "tool:claim")).toBe(true)
  expect(ledger.delivery(claimed.name, claimed.workCycle)).toEqual({
    type: "claimed",
    completion: claimed,
    claimId: "tool:claim"
  })
  expect(ledger.pendingPersistence()).toEqual([{ completion: claimed }])
  ledger.commitPersistence(claimed.name, claimed.workCycle, "entry-claimed")
  expect(ledger.delivery(claimed.name, claimed.workCycle)).toEqual({
    type: "claimed",
    completion: claimed,
    entryId: "entry-claimed",
    claimId: "tool:claim"
  })
  expect(ledger.releaseClaims("other:")).toEqual([])
  expect(ledger.releaseClaims("tool:")).toEqual([claimed.name])
  expect(ledger.delivery(claimed.name, claimed.workCycle)).toEqual({
    type: "durable",
    completion: claimed,
    entryId: "entry-claimed"
  })
  expect(ledger.claim(claimed.name, claimed.workCycle, "tool:final")).toBe(true)
  expect(ledger.acknowledge(claimed.name, claimed.workCycle)).toBe(true)
  expect(ledger.delivery(claimed.name, claimed.workCycle)).toEqual({
    type: "delivered",
    completion: claimed,
    entryId: "entry-claimed"
  })

  const acknowledged = completion("acknowledged-worker", 1)
  ledger.reserve(acknowledged.name, acknowledged.workCycle)
  expect(ledger.admit(acknowledged)).toBe("accepted")
  expect(ledger.claim(acknowledged.name, acknowledged.workCycle, "tool:acknowledged")).toBe(true)
  expect(ledger.acknowledge(acknowledged.name, acknowledged.workCycle)).toBe(true)
  expect(ledger.delivery(acknowledged.name, acknowledged.workCycle)).toEqual({
    type: "delivered",
    completion: acknowledged
  })
  expect(ledger.pendingPersistence()).toEqual([{ completion: acknowledged }])
  ledger.commitPersistence(acknowledged.name, acknowledged.workCycle, "entry-acknowledged")
  expect(ledger.delivery(acknowledged.name, acknowledged.workCycle)).toEqual({
    type: "delivered",
    completion: acknowledged,
    entryId: "entry-acknowledged"
  })
  ledger.assertInvariants()
})

test("CompletionLedger releases pending and durable claims to their exact prior durability", () => {
  const ledger = new CompletionLedger(4)
  const pending = completion("pending-worker", 1)
  const durable = completion("durable-worker", 1)
  for (const value of [pending, durable]) {
    ledger.reserve(value.name, value.workCycle)
    expect(ledger.admit(value)).toBe("accepted")
  }
  ledger.commitPersistence(durable.name, durable.workCycle, "entry-durable")
  expect(ledger.claim(pending.name, pending.workCycle, "nested:pending")).toBe(true)
  expect(ledger.claim(durable.name, durable.workCycle, "nested:durable")).toBe(true)

  expect(ledger.releaseClaims("nested:")).toEqual([pending.name, durable.name])
  expect(ledger.delivery(pending.name, pending.workCycle)).toEqual({ type: "pending", completion: pending })
  expect(ledger.delivery(durable.name, durable.workCycle)).toEqual({
    type: "durable",
    completion: durable,
    entryId: "entry-durable"
  })
})

test("CompletionLedger evicts delivered pending and durable evidence before refusing new work", () => {
  const pendingLedger = new CompletionLedger(1)
  const first = completion("first-worker", 1)
  pendingLedger.reserve(first.name, first.workCycle)
  pendingLedger.admit(first)
  pendingLedger.acknowledge(first.name, first.workCycle)
  pendingLedger.reserve("second-worker", 1)
  expect(pendingLedger.delivery(first.name, first.workCycle)).toBeUndefined()
  expect(pendingLedger.identities()).toEqual([{ name: "second-worker", workCycle: 1 }])

  const durableLedger = new CompletionLedger(1)
  durableLedger.reserve(first.name, first.workCycle)
  durableLedger.admit(first)
  durableLedger.commitPersistence(first.name, first.workCycle, "entry-first")
  durableLedger.markDelivered(first.name, first.workCycle)
  durableLedger.reserve("second-worker", 1)
  expect(durableLedger.delivery(first.name, first.workCycle)).toBeUndefined()

  const full = new CompletionLedger(1)
  full.reserve(first.name, first.workCycle)
  expect(() => full.reserve("blocked-worker", 1)).toThrow("undelivered completions fill the mailbox")
})

test("CompletionLedger rejects stale and duplicate admission without disturbing ordering", () => {
  const ledger = new CompletionLedger(4)
  const first = completion("worker", 1)
  const second = completion("worker", 2)
  expect(ledger.admit(first)).toBe("stale")
  ledger.reserve(first.name, first.workCycle)
  ledger.reserve(second.name, second.workCycle)
  expect(() => ledger.reserve(first.name, first.workCycle)).toThrow("already exists")
  expect(ledger.admit(second)).toBe("accepted")
  expect(ledger.admit(first)).toBe("accepted")
  expect(ledger.admit(first)).toBe("duplicate")
  expect(ledger.oldestReady("worker")?.completion.workCycle).toBe(1)
  ledger.commitPersistence(second.name, second.workCycle, "entry-second")
  expect(ledger.oldestReady("worker")?.completion.workCycle).toBe(1)
  ledger.commitPersistence(first.name, first.workCycle, "entry-first")
  expect(ledger.claim(first.name, first.workCycle, "mailbox:first")).toBe(true)
  expect(ledger.oldestReady("worker")?.completion.workCycle).toBe(2)
  expect(ledger.releaseClaims("mailbox:")).toEqual(["worker"])

  expect(ledger.deliveries().map(delivery => delivery.completion.workCycle)).toEqual([2, 1])
  expect(ledger.oldestDurable("worker")?.completion.workCycle).toBe(1)
  expect(ledger.latest("worker")?.completion.workCycle).toBe(2)
  expect(ledger.readyNames()).toEqual(["worker"])
})

test("CompletionLedger replay preserves markers, first finished evidence, bounds, and ordering", () => {
  const entries = [
    delivered("evicted-worker", 1),
    finished("evicted-worker", 1, "first-result"),
    finished("kept-b", 1, "result-b"),
    finished("kept-c", 1, "result-c"),
    finished("evicted-worker", 1, "duplicate-result")
  ]
  const ledger = CompletionLedger.restore(entries, 2)

  expect(ledger.deliveries().map(delivery => delivery.completion.name)).toEqual(["kept-b", "kept-c"])
  expect(ledger.readyNames()).toEqual(["kept-b", "kept-c"])

  const duplicate = CompletionLedger.restore(
    [finished("duplicate-worker", 1, "first-result"), finished("duplicate-worker", 1, "later-result")],
    2
  )
  expect(duplicate.delivery("duplicate-worker", 1)?.completion.text).toBe("first-result")

  expect(() =>
    CompletionLedger.restore(
      [finished("worker-a", 1, "a"), finished("worker-b", 1, "b"), finished("worker-c", 1, "c")],
      2
    )
  ).toThrow("more than 2 undelivered subagent completions")
})

function completion(name: string, workCycle: number, text = `${name}-result`): SubagentCompletion {
  return Object.freeze({
    name,
    workCycle,
    status: "completed",
    text,
    originalBytes: Buffer.byteLength(text),
    omittedBytes: 0,
    truncated: false,
    durationMs: workCycle
  })
}

let entrySequence = 0

function finished(name: string, workCycle: number, preview: string): SubagentEntry {
  return {
    id: `entry-${++entrySequence}`,
    parentId: null,
    timestamp: "2026-08-09T00:00:00.000Z",
    type: "subagent",
    event: "work_cycle_finished",
    name,
    workCycle,
    status: "completed",
    preview,
    originalBytes: Buffer.byteLength(preview),
    omittedBytes: 0,
    truncated: false,
    durationMs: workCycle
  }
}

function delivered(name: string, workCycle: number): SubagentEntry {
  return {
    id: `entry-${++entrySequence}`,
    parentId: null,
    timestamp: "2026-08-09T00:00:00.000Z",
    type: "subagent",
    event: "work_cycle_delivered",
    name,
    workCycle
  }
}
