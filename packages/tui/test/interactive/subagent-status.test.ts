import { expect, test } from "bun:test"

import type { SubagentSnapshot, SubagentStatus } from "@with-zi/coding-agent"

import { subagentStatusTitles } from "../../src/interactive/prompt/subagent-status.js"

const snapshots: readonly SubagentSnapshot[] = [
  {
    agentId: "reviewer-1",
    lifecycle: "running",
    definition: { name: "code-reviewer", description: "Review code", instructions: "Review." }
  },
  {
    agentId: "tester-1",
    lifecycle: "idle",
    definition: { name: "tester", description: "Test code", instructions: "Test." }
  }
]

test("subagent status uses human type labels for singular activity", () => {
  const status: SubagentStatus = { workingAgentIds: ["reviewer-1"], readyAgentIds: ["tester-1"] }
  expect(subagentStatusTitles(status, snapshots)).toEqual(["Code reviewer working", "Tester ready"])
})

test("subagent status combines an earlier result with the same agent's current work", () => {
  const status: SubagentStatus = { workingAgentIds: ["reviewer-1"], readyAgentIds: ["reviewer-1"] }
  expect(subagentStatusTitles(status, snapshots)).toEqual(["Code reviewer working · result ready"])
})

test("subagent status uses quiet aggregate labels for multiple children", () => {
  const status: SubagentStatus = {
    workingAgentIds: ["reviewer-1", "tester-1"],
    readyAgentIds: ["reviewer-1", "tester-1"]
  }
  expect(subagentStatusTitles(status, snapshots)).toEqual(["2 agents working", "2 results ready"])
})

test("subagent status remains useful when a retained snapshot is unavailable", () => {
  expect(subagentStatusTitles({ workingAgentIds: [], readyAgentIds: ["missing"] }, snapshots)).toEqual(["Agent ready"])
  expect(subagentStatusTitles({ workingAgentIds: [], readyAgentIds: [] }, snapshots)).toEqual([])
})
