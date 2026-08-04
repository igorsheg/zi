import { expect, test } from "bun:test"

import {
  Schema,
  type ExtensionAPI,
  type ExtensionCommandDefinition,
  type ExtensionContext,
  type ExtensionMode,
  type ExtensionToolDefinition,
  type Static
} from "../src/index.js"

const context: ExtensionContext = Object.freeze({
  mode: "embedded",
  cwd: "/tmp/extension-api-test",
  session: Object.freeze({ type: "memory", id: "test" })
})

async function sessionOperations(api: ExtensionAPI): Promise<void> {
  const entries = await api.getSessionEntries("example.counter")
  const appended = await api.appendEntry("example.counter", { count: entries.length })
  await api.sendMessage(
    { customType: appended.customType, content: "updated", display: true, details: appended.data ?? null },
    "follow_up"
  )
  const activeTools = await api.getActiveTools()
  await api.setActiveTools(activeTools)
  // @ts-expect-error active tool names must be strings
  await api.setActiveTools([1])
  // @ts-expect-error session values must be JSON
  await api.appendEntry("example.counter", { count: 1n })
  // @ts-expect-error delivery is a closed contract
  await api.sendMessage({ customType: "example.counter", content: "updated", display: true }, "later")
}

function registerActivity(api: ExtensionAPI): void {
  api.on("session_start", (event, session) => void [event.reason, session.mode])
  api.on("agent_start", (event, session) => void [event.type, session.cwd])
  api.on("agent_settled", (event, session) => void [event.type, session.session.id])
  api.on("session_shutdown", (event, session) => void [event.reason, session.session.type])
  // @ts-expect-error agent_end is not an authoritative idle notification
  api.on("agent_end", () => {})
}

function registerCommand(api: ExtensionAPI): void {
  api.registerCommand({
    name: "counter",
    description: "Manage the counter",
    argumentHint: "[show|increment|reset]",
    execute: async (arguments_, { signal }) => (signal.aborted ? undefined : `Counter command: ${arguments_}`)
  })
}

function registerStructuredTool(api: ExtensionAPI): void {
  api.registerTool({
    name: "double_value",
    description: "Double one value",
    active: false,
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

test("extension context has five closed modes and memory or journal identity", () => {
  const modes: ExtensionMode[] = ["interactive", "text", "json", "rpc", "embedded"]
  const journal: ExtensionContext = {
    mode: "interactive",
    cwd: "/tmp/project",
    session: { type: "journal", id: "session", file: "/tmp/session.jsonl" }
  }

  expect(modes).toHaveLength(5)
  expect(journal.session.type === "journal" ? journal.session.file : undefined).toBe("/tmp/session.jsonl")
})

test("commands expose bounded raw arguments, cancellation, and optional local feedback", async () => {
  const command: ExtensionCommandDefinition = {
    name: "counter",
    description: "Manage the counter",
    argumentHint: "[show|increment|reset]",
    execute: (arguments_, { signal }) => (signal.aborted ? undefined : `Counter: ${arguments_}`)
  }

  expect(await command.execute("show", { ...context, signal: new AbortController().signal })).toBe("Counter: show")
})

test("tool schemas infer parameters and expose invocation-scoped progress", async () => {
  const parameters = Schema.object({ message: Schema.string(), suffix: Schema.optional(Schema.string()) })
  const tool: ExtensionToolDefinition<typeof parameters> = {
    name: "echo_message",
    description: "Echo one message",
    timeoutMs: 5 * 60_000,
    parameters,
    execute: async ({ message, suffix }, toolContext) => {
      toolContext.reportProgress(`Echoing ${message}`)
      return toolContext.signal.aborted ? "cancelled" : message + (suffix ?? "")
    }
  }
  const value: Static<typeof parameters> = { message: "hello" }
  const progress: string[] = []

  expect(
    await tool.execute(value, {
      ...context,
      signal: new AbortController().signal,
      reportProgress: message => progress.push(message)
    })
  ).toBe("hello")
  expect(progress).toEqual(["Echoing hello"])
  expect(tool.timeoutMs).toBe(5 * 60_000)
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

  expect(
    await tool.execute({ value: 3 }, { ...context, signal: new AbortController().signal, reportProgress: () => {} })
  ).toEqual({ doubled: 6, label: "3" })
})

test("public types reject values outside the worker schema contract", () => {
  expect(typeof invalidSchemas).toBe("function")
  expect(typeof sessionOperations).toBe("function")
  expect(typeof registerActivity).toBe("function")
  expect(typeof registerCommand).toBe("function")
  expect(typeof registerStructuredTool).toBe("function")
})
