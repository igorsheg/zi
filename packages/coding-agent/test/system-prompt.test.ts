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

const sendPeerMessage = { ...spawnSubagent, name: "send_peer_message", label: "send_peer_message" } satisfies AgentTool

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
  expect(prompt).toContain(`${docs}/code-mode.md`)
  expect(prompt).toContain(`${docs}/skills.md`)
  expect(prompt).toContain(`${docs}/subagents.md`)
})

test("a custom system prompt owns its product documentation policy", () => {
  const prompt = buildSystemPrompt("/work", createSessionResources({ systemPrompt: "Custom prompt" }), [])

  expect(prompt).not.toContain("Zi documentation")
})

test("Code Mode adds programmatic-runtime doctrine to the default prompt", () => {
  const prompt = buildSystemPrompt("/work", createSessionResources(), [], true)

  expect(prompt).toContain("# Programmatic runtime")
  expect(prompt).toContain("Use direct tools for one ordinary read, edit, write, or command")
  expect(prompt).toContain("The runtime coordinates work")
  expect(prompt).toContain("Tool and ambient process effects are not rolled back")
})

test("Code Mode doctrine remains active with a custom system prompt", () => {
  const prompt = buildSystemPrompt("/work", createSessionResources({ systemPrompt: "Custom prompt" }), [], true)

  expect(prompt).toContain("Custom prompt")
  expect(prompt).toContain("# Programmatic runtime")
  expect(prompt).not.toContain("Zi documentation")
})

test("peer messaging tools add child-team doctrine", () => {
  const prompt = buildSystemPrompt("/work", createSessionResources({ systemPrompt: "Child prompt" }), [sendPeerMessage])

  expect(prompt).toContain("# Peer subagents")
  expect(prompt).toContain("do not start an idle sibling turn")
  expect(prompt).toContain("final response is still delivered to your parent")
})

test("tool names do not activate native subagent prompt policy", () => {
  const prompt = buildSystemPrompt("/work", createSessionResources(), [spawnSubagent])

  expect(prompt).not.toContain("Subagents:")
  expect(prompt).not.toContain("wait_subagents")
})
