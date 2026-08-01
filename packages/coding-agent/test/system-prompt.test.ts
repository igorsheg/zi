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

test("tool names do not activate native subagent prompt policy", () => {
  const prompt = buildSystemPrompt("/work", createSessionResources(), [spawnSubagent])

  expect(prompt).not.toContain("Subagents:")
  expect(prompt).not.toContain("wait_subagents")
})
