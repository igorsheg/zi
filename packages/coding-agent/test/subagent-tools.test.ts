import { expect, test } from "bun:test"

import { generalSubagentType, type SubagentTypeDefinition } from "../src/subagents/definitions.js"
import { subagentTypeParameterDescription } from "../src/subagents/tools.js"

test("subagent type parameter describes names without child instructions", () => {
  const reviewer: SubagentTypeDefinition = {
    name: "reviewer",
    description: "Review\n\tchanges\u0001carefully\u200b before reporting",
    instructions: "SECRET CHILD INSTRUCTIONS"
  }

  expect(subagentTypeParameterDescription([generalSubagentType, reviewer])).toBe(
    "Named subagent type. Defaults to general.\n\n" +
      "Available types:\n" +
      "- general — General coding, research, and repository work with normal Zi tools\n" +
      "- reviewer — Review changes carefully before reporting"
  )
  expect(subagentTypeParameterDescription([reviewer])).not.toContain(reviewer.instructions)
})

test("subagent type parameter keeps every bounded name while clipping UTF-8 descriptions", () => {
  const definitions: SubagentTypeDefinition[] = Array.from({ length: 33 }, (_, index) => ({
    name: `a${index.toString().padStart(2, "0")}${"x".repeat(61)}`,
    description: "🧪".repeat(1_024),
    instructions: "not model-facing"
  }))

  const description = subagentTypeParameterDescription(definitions)

  expect(Buffer.byteLength(description)).toBeLessThanOrEqual(8 * 1024)
  expect(description).not.toContain("�")
  expect(description).toContain("…")
  for (const definition of definitions) expect(description).toContain(`- ${definition.name} — `)
})
