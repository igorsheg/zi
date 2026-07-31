import { expect, test } from "bun:test"

import {
  Schema,
  type ExtensionAPI,
  type ExtensionToolDefinition,
  type Static,
  type SubagentTypeDefinition
} from "../src/index.js"

async function sessionOperations(api: ExtensionAPI): Promise<void> {
  const entries = await api.getSessionEntries("example.counter")
  const appended = await api.appendEntry("example.counter", { count: entries.length })
  await api.sendMessage(
    { customType: appended.customType, content: "updated", display: true, details: appended.data ?? null },
    "follow_up"
  )
  // @ts-expect-error session values must be JSON
  await api.appendEntry("example.counter", { count: 1n })
  // @ts-expect-error delivery is a closed contract
  await api.sendMessage({ customType: "example.counter", content: "updated", display: true }, "later")
}

function registerStructuredTool(api: ExtensionAPI): void {
  api.registerSubagentType({
    name: "reviewer",
    description: "Review changes",
    instructions: "Inspect the requested change and report findings."
  })
  api.registerTool({
    name: "double_value",
    description: "Double one value",
    parameters: Schema.object({ value: Schema.integer() }),
    outputSchema: Schema.object({ doubled: Schema.integer() }),
    execute: ({ value }) => ({ doubled: value * 2 })
  })
}

function invalidSchemas(): void {
  // @ts-expect-error tool parameters require an object schema
  const nonObject: ExtensionToolDefinition = { name: "bad", description: "bad", parameters: Schema.string() }
  // @ts-expect-error literal values must cross JSON IPC
  const bigint = Schema.literal(1n)
  // @ts-expect-error patterns are JSON strings, not RegExp objects
  const pattern = Schema.string({ pattern: /x/ })
  const parameters = Schema.object({})
  const outputSchema = Schema.object({ count: Schema.integer() })
  const invalidOutput: ExtensionToolDefinition<typeof parameters, typeof outputSchema> = {
    name: "bad_output",
    description: "bad output",
    parameters,
    outputSchema,
    // @ts-expect-error execute must return the declared output
    execute: () => ({ count: "one" })
  }
  void [nonObject, bigint, pattern, invalidOutput]
}

test("the public extension API exposes one frozen JSON-schema runtime", async () => {
  const api = await import("../src/index.js")
  expect(Object.keys(api)).toEqual(["Schema"])
  const schema = Schema.object(
    {
      message: Schema.string({ description: "Message", pattern: "^[a-z]+$" }),
      mode: Schema.literal("loud", { description: "Mode" }),
      tags: Schema.optional(Schema.array(Schema.string(), { maxItems: 4 }))
    },
    { additionalProperties: false }
  )
  expect(schema as unknown).toEqual({
    type: "object",
    properties: {
      message: { type: "string", description: "Message", pattern: "^[a-z]+$" },
      mode: { type: "string", const: "loud", description: "Mode" },
      tags: { type: "array", items: { type: "string" }, maxItems: 4 }
    },
    required: ["message", "mode"],
    additionalProperties: false
  })
  expect(Object.isFrozen(schema)).toBe(true)
  expect(Object.isFrozen(schema.properties)).toBe(true)
})

test("tool schemas infer required and optional execution parameters", () => {
  const parameters = Schema.object({ message: Schema.string(), suffix: Schema.optional(Schema.string()) })
  const tool: ExtensionToolDefinition<typeof parameters> = {
    name: "echo_message",
    description: "Echo one message",
    parameters,
    execute: async ({ message, suffix }, { signal }) => (signal.aborted ? "cancelled" : message + (suffix ?? ""))
  }
  const value: Static<typeof parameters> = { message: "hello" }

  expect(tool.name).toBe("echo_message")
  expect(value).toEqual({ message: "hello" })
})

test("tool output schemas infer structured execution results", async () => {
  const parameters = Schema.object({ value: Schema.integer() })
  const outputSchema = Schema.object({ doubled: Schema.integer(), label: Schema.string() })
  const tool: ExtensionToolDefinition<typeof parameters, typeof outputSchema> = {
    name: "double_value",
    description: "Double one value",
    parameters,
    outputSchema,
    execute: ({ value }) => ({ doubled: value * 2, label: String(value) })
  }

  expect(await tool.execute({ value: 3 }, { signal: new AbortController().signal })).toEqual({ doubled: 6, label: "3" })
})

test("subagent definitions expose only declarative policy", () => {
  const definition: SubagentTypeDefinition = {
    name: "reviewer",
    description: "Review changes",
    instructions: "Inspect the requested change and report findings."
  }
  expect(definition.name).toBe("reviewer")
})

test("public types reject values outside the worker schema contract", () => {
  expect(typeof invalidSchemas).toBe("function")
  expect(typeof sessionOperations).toBe("function")
  expect(typeof registerStructuredTool).toBe("function")
})
