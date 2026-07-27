import { expect, test } from "bun:test"

import { Schema, type ExtensionToolDefinition } from "../src/index.js"

test("the public extension API exposes only runtime schema construction", async () => {
  const api = await import("../src/index.js")
  expect(Object.keys(api)).toEqual(["Schema"])
  expect(Schema.object({ message: Schema.string() })).toMatchObject({
    type: "object",
    properties: { message: { type: "string" } }
  })
})

test("tool schemas infer execution parameters", () => {
  const parameters = Schema.object({ message: Schema.string() })
  const tool: ExtensionToolDefinition<typeof parameters> = {
    name: "echo_message",
    description: "Echo one message",
    parameters,
    execute: async ({ message }, { signal }) => (signal.aborted ? "cancelled" : message)
  }

  expect(tool.name).toBe("echo_message")
})
