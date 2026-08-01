import { expect, test } from "bun:test"

import type { AgentTool } from "@earendil-works/pi-agent-core"
import { Type } from "@earendil-works/pi-ai"

import { createSessionResources } from "../src/resource-loader.js"
import { buildSystemPrompt } from "../src/system-prompt.js"

const spawnSubagent = {
  name: "spawn_subagent",
  label: "spawn_subagent",
  description: "test subagent tool",
  parameters: Type.Object({}),
  execute: () => Promise.resolve({ content: [], details: undefined })
} satisfies AgentTool

test("native subagent prompt defines bounded delegation and parent interruption policy", () => {
  const prompt = buildSystemPrompt("/work", createSessionResources(), [spawnSubagent])

  expect(prompt).toContain("concrete, self-contained task")
  expect(prompt).toContain("explicit scope or file boundaries")
  expect(prompt).toContain("bounded time or scope budget")
  expect(prompt).toContain("Parallel assignments must not overlap")
  expect(prompt).toContain("continue non-overlapping local work")
  expect(prompt).toContain("wait for delegated work and synthesize the results")
  expect(prompt).toContain("Close children when their work is done")
  expect(prompt).toContain("Interrupting the parent does not interrupt admitted children")
})

test("subagent policy is omitted when native delegation is unavailable", () => {
  const prompt = buildSystemPrompt("/work", createSessionResources(), [])

  expect(prompt).not.toContain("Subagents:")
})
