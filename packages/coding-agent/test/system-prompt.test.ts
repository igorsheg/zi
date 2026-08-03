import { expect, test } from "bun:test"

import type { AgentTool } from "@earendil-works/pi-agent-core"
import { Type } from "@earendil-works/pi-ai"

import { getProductDocumentationPaths } from "../src/product-documentation.js"
import { createSessionResources } from "../src/resource-loader.js"
import { buildSystemPrompt } from "../src/system-prompt.js"

const spawnSubagent = {
  name: "spawn_subagent",
  label: "spawn_subagent",
  description: "test subagent tool",
  parameters: Type.Object({}),
  execute: () => Promise.resolve({ content: [], details: undefined })
} satisfies AgentTool

test("the default prompt routes Zi customization work to shipped documentation", () => {
  const paths = getProductDocumentationPaths()
  const readme = paths.readme.replaceAll("\\", "/")
  const docs = paths.docs.replaceAll("\\", "/")
  const examples = paths.examples.replaceAll("\\", "/")
  const prompt = buildSystemPrompt("/work", createSessionResources(), [])

  expect(prompt).toContain(`- Documentation index: ${docs}/index.md`)
  expect(prompt).toContain(`- Product README: ${readme}`)
  expect(prompt).toContain(`- Documentation directory: ${docs}`)
  expect(prompt).toContain(`- Examples: ${examples}`)
  expect(prompt).toContain(`${docs}/cli.md`)
  expect(prompt).toContain(`${docs}/prompts.md`)
  expect(prompt).toContain(`${docs}/notifications.md`)
  expect(prompt).toContain(`${docs}/json-events.md`)
  expect(prompt).toContain(`${docs}/rpc.md`)
  expect(prompt).toContain(`${docs}/extensions.md`)
  expect(prompt).toContain(`${docs}/skills.md`)
  expect(prompt).toContain(`${docs}/subagents.md`)
})

test("a custom system prompt owns its product documentation policy", () => {
  const prompt = buildSystemPrompt("/work", createSessionResources({ systemPrompt: "Custom prompt" }), [])

  expect(prompt).not.toContain("Zi documentation")
})

test("tool names do not activate native subagent prompt policy", () => {
  const prompt = buildSystemPrompt("/work", createSessionResources(), [spawnSubagent])

  expect(prompt).not.toContain("Subagents:")
  expect(prompt).not.toContain("wait_subagents")
})
