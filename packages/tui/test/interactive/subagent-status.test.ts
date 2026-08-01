import { expect, test } from "bun:test"

import type { SubagentSnapshot, SubagentStatus } from "@with-zi/coding-agent"

import { subagentStatusTitles } from "../../src/interactive/prompt/subagent-status.js"

const snapshots: readonly SubagentSnapshot[] = [
  { name: "shutdown-reviewer", lifecycle: "running" },
  { name: "test-runner", lifecycle: "idle", completion: completion("test-runner", "completed") },
  { name: "failure-reviewer", lifecycle: "idle", completion: completion("failure-reviewer", "failed") },
  { name: "cancelled-reviewer", lifecycle: "idle", completion: completion("cancelled-reviewer", "cancelled") }
]

test("subagent status uses human agent names for singular activity", () => {
  const status: SubagentStatus = { workingNames: ["shutdown-reviewer"], readyNames: ["test-runner"] }
  expect(subagentStatusTitles(status, snapshots)).toEqual(["Shutdown reviewer working", "Test runner ready"])
})

test("subagent status combines an earlier result with the same agent's current work", () => {
  const status: SubagentStatus = { workingNames: ["shutdown-reviewer"], readyNames: ["shutdown-reviewer"] }
  expect(subagentStatusTitles(status, snapshots)).toEqual(["Shutdown reviewer working · result ready"])
})

test("subagent status distinguishes ready failures and cancellations from successful results", () => {
  expect(subagentStatusTitles({ workingNames: [], readyNames: ["failure-reviewer"] }, snapshots)).toEqual([
    "Failure reviewer failed"
  ])
  expect(subagentStatusTitles({ workingNames: [], readyNames: ["cancelled-reviewer"] }, snapshots)).toEqual([
    "Cancelled reviewer cancelled"
  ])
})

test("subagent status uses quiet aggregate labels for multiple children", () => {
  const status: SubagentStatus = {
    workingNames: ["shutdown-reviewer", "test-runner"],
    readyNames: ["shutdown-reviewer", "test-runner"]
  }
  expect(subagentStatusTitles(status, snapshots)).toEqual(["2 agents working", "2 results ready"])
})

test("subagent status separates mixed aggregate completion outcomes", () => {
  const status: SubagentStatus = {
    workingNames: [],
    readyNames: ["test-runner", "failure-reviewer", "cancelled-reviewer"]
  }
  expect(subagentStatusTitles(status, snapshots)).toEqual(["1 result ready", "1 agent failed", "1 agent cancelled"])
})

test("subagent status remains useful when a retained snapshot is unavailable", () => {
  expect(subagentStatusTitles({ workingNames: [], readyNames: ["missing"] }, snapshots)).toEqual(["Missing ready"])
  expect(subagentStatusTitles({ workingNames: [], readyNames: [] }, snapshots)).toEqual([])
})

function completion(name: string, status: "completed" | "failed" | "cancelled") {
  return { name, workCycle: 1, status, text: "", originalBytes: 0, omittedBytes: 0, truncated: false, durationMs: 100 }
}
