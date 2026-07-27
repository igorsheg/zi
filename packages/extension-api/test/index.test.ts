import { expect, test } from "bun:test"

import { Schema, type ExtensionToolDefinition, type Static } from "../src/index.js"

function invalidSchemas(): void {
  // @ts-expect-error tool parameters require an object schema
  const nonObject: ExtensionToolDefinition = { name: "bad", description: "bad", parameters: Schema.string() }
  // @ts-expect-error literal values must cross JSON IPC
  const bigint = Schema.literal(1n)
  // @ts-expect-error patterns are JSON strings, not RegExp objects
  const pattern = Schema.string({ pattern: /x/ })
  void [nonObject, bigint, pattern]
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

test("public types reject values outside the worker schema contract", () => {
  expect(typeof invalidSchemas).toBe("function")
})
