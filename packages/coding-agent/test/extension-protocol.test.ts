import { expect, test } from "bun:test"
import { resolve } from "node:path"
import { Writable } from "node:stream"

import { maxExtensionSources, type ExtensionLoadPlan, type ExtensionSource } from "../src/extensions/discovery.js"
import {
  boundedExtensionDiagnostic,
  encodeExtensionProtocolFrame,
  ExtensionProtocolDecoder,
  ExtensionProtocolWriter,
  extensionProtocolVersion,
  maxExtensionDiagnosticMessageBytes,
  maxExtensionIdBytes,
  maxExtensionProtocolFrameBytes,
  maxExtensionQueuedWrites,
  maxExtensionSubagentDescriptionBytes,
  maxExtensionSubagentInstructionsBytes,
  maxExtensionSubagentModelBytes,
  maxExtensionSubagentNameBytes,
  maxExtensionSubagentProfiles,
  maxExtensionToolArgumentsBytes,
  maxExtensionToolCatalogBytes,
  maxExtensionToolDescriptionBytes,
  maxExtensionToolResultBytes,
  maxExtensionToolSchemaBytes,
  maxExtensionTools,
  type HostMessage,
  validateHostMessage,
  validateWorkerMessage
} from "../src/extensions/protocol.js"
import { maxCustomStateEntries } from "../src/session-manager.js"

const source: ExtensionSource = Object.freeze({
  id: "extension-fixture",
  declaredPath: resolve("extension-fixture.ts"),
  entryPath: resolve("extension-fixture.ts"),
  scope: "temporary",
  origin: "cli"
})
const plan: ExtensionLoadPlan = Object.freeze({ cwd: resolve("project"), sources: Object.freeze([source]) })

test("protocol decoding accepts partial frames and multiple messages per read", () => {
  const decoder = new ExtensionProtocolDecoder(validateHostMessage)
  const initialize: HostMessage = { type: "initialize", protocolVersion: extensionProtocolVersion, generation: 1, plan }
  const start: HostMessage = { type: "session_start", generation: 1, requestId: 3, reason: "startup" }
  const bytes = Buffer.concat([encodeExtensionProtocolFrame(initialize), encodeExtensionProtocolFrame(start)])
  const messages = []

  for (let offset = 0; offset < bytes.byteLength;) {
    const length = Math.min((offset % 7) + 1, bytes.byteLength - offset)
    messages.push(...decoder.push(bytes.subarray(offset, offset + length)))
    offset += length
  }
  decoder.end()

  expect(messages).toEqual([initialize, start])
  if (messages[0]?.type !== "initialize") throw new Error("Initialize frame was not decoded first")
  expect(Object.isFrozen(messages[0].plan.sources)).toBe(true)
})

test("protocol decoding rejects malformed framing, UTF-8, JSON, and closed messages", () => {
  expect(() => new ExtensionProtocolDecoder(validateHostMessage).push(frameWithLength(0))).toThrow("cannot be empty")
  expect(() =>
    new ExtensionProtocolDecoder(validateHostMessage).push(frameWithLength(maxExtensionProtocolFrameBytes + 1))
  ).toThrow(`${maxExtensionProtocolFrameBytes} bytes`)
  expect(() => new ExtensionProtocolDecoder(validateHostMessage).push(rawFrame(Buffer.from([0xff])))).toThrow(
    "not valid UTF-8"
  )
  expect(() => new ExtensionProtocolDecoder(validateHostMessage).push(rawFrame(Buffer.from("{")))).toThrow(
    "not valid JSON"
  )
  expect(() =>
    new ExtensionProtocolDecoder(validateHostMessage).push(encodeExtensionProtocolFrame({ type: "future" }))
  ).toThrow("Unknown host protocol message")

  const partial = new ExtensionProtocolDecoder(validateHostMessage)
  partial.push(encodeExtensionProtocolFrame({ type: "stop", generation: 1, requestId: 1 }).subarray(0, 5))
  expect(() => partial.end()).toThrow("partial frame")
  expect(() => partial.push(Buffer.from([0]))).toThrow("partial frame")
})

test("host protocol validation bounds and freezes the complete load plan", () => {
  const initialize = validateHostMessage({
    type: "initialize",
    protocolVersion: extensionProtocolVersion,
    generation: 7,
    plan
  })
  expect(initialize).toEqual({ type: "initialize", protocolVersion: extensionProtocolVersion, generation: 7, plan })
  expect(Object.isFrozen(initialize)).toBe(true)

  expect(() => validateHostMessage({ type: "initialize", protocolVersion: 1, generation: 1, plan })).toThrow(
    "Unsupported"
  )
  expect(() =>
    validateHostMessage({
      type: "initialize",
      protocolVersion: extensionProtocolVersion,
      generation: 1,
      plan: { ...plan, cwd: "relative" }
    })
  ).toThrow("cwd must be absolute")
  expect(() =>
    validateHostMessage({
      type: "initialize",
      protocolVersion: extensionProtocolVersion,
      generation: 1,
      plan: { ...plan, sources: [{ ...source, entryPath: "relative" }] }
    })
  ).toThrow("paths must be absolute")
  expect(() =>
    validateHostMessage({
      type: "initialize",
      protocolVersion: extensionProtocolVersion,
      generation: 1,
      plan: { ...plan, sources: [{ ...source, id: "x".repeat(maxExtensionIdBytes + 1) }] }
    })
  ).toThrow("extension id")
  expect(() => validateHostMessage({ type: "stop", generation: 0, requestId: 1 })).toThrow("generation")
  expect(() => validateHostMessage({ type: "session_start", generation: 1, requestId: 1, reason: "later" })).toThrow(
    "start reason"
  )
})

test("worker protocol validation keeps source-attributed load and lifecycle results closed", () => {
  const diagnostic = {
    extensionId: source.id,
    path: source.entryPath,
    phase: "factory",
    severity: "error",
    message: "factory failed"
  }
  expect(
    validateWorkerMessage({
      type: "ready",
      protocolVersion: extensionProtocolVersion,
      generation: 1,
      extensions: [
        { source, status: "loaded" },
        { source: { ...source, id: "failed" }, status: "failed", diagnostic }
      ],
      tools: []
    })
  ).toMatchObject({ type: "ready", extensions: [{ status: "loaded" }, { status: "failed", diagnostic }] })
  expect(() =>
    validateWorkerMessage({
      type: "ready",
      protocolVersion: extensionProtocolVersion,
      generation: 1,
      extensions: [{ source, status: "failed" }],
      tools: []
    })
  ).toThrow("require a diagnostic")
  expect(() =>
    validateWorkerMessage({
      type: "diagnostic",
      generation: 1,
      diagnostic: { ...diagnostic, message: "x".repeat(maxExtensionDiagnosticMessageBytes + 1) }
    })
  ).toThrow(`${maxExtensionDiagnosticMessageBytes} bytes`)
  expect(() => validateWorkerMessage({ type: "settled", generation: 1, requestId: -1 })).toThrow("requestId")
})

test("tool protocol validation closes registration, arguments, results, and correlation", () => {
  const registration = {
    source,
    name: "echo_message",
    label: "Echo message",
    description: "Echo one message",
    parameters: { type: "object", required: ["message"], properties: { message: { type: "string" } } },
    outputSchema: { type: "object", required: ["echoed"], properties: { echoed: { type: "string" } } }
  }
  const ready = validateWorkerMessage({
    type: "ready",
    protocolVersion: extensionProtocolVersion,
    generation: 1,
    extensions: [{ source, status: "loaded" }],
    tools: [registration]
  })
  expect(ready).toMatchObject({ type: "ready", tools: [{ name: "echo_message" }] })
  expect(Object.isFrozen(ready.type === "ready" ? ready.tools[0]?.parameters.properties : undefined)).toBe(true)

  const invoke = validateHostMessage({
    type: "tool_invoke",
    generation: 1,
    requestId: 2,
    name: "echo_message",
    arguments: { message: "hello" }
  })
  expect(invoke).toEqual({
    type: "tool_invoke",
    generation: 1,
    requestId: 2,
    name: "echo_message",
    arguments: { message: "hello" }
  })
  expect(() =>
    validateHostMessage({ ...invoke, arguments: { value: "x".repeat(maxExtensionToolArgumentsBytes) } })
  ).toThrow(`${maxExtensionToolArgumentsBytes} bytes`)
  expect(() =>
    validateWorkerMessage({
      type: "ready",
      protocolVersion: extensionProtocolVersion,
      generation: 1,
      extensions: [{ source, status: "loaded" }],
      tools: [{ ...registration, name: "Invalid-name" }]
    })
  ).toThrow("tool names")
  expect(() =>
    validateWorkerMessage({
      type: "ready",
      protocolVersion: extensionProtocolVersion,
      generation: 1,
      extensions: [{ source, status: "loaded" }],
      tools: [{ ...registration, outputSchema: undefined }]
    })
  ).toThrow("output schema")
  expect(() =>
    validateWorkerMessage({
      type: "ready",
      protocolVersion: extensionProtocolVersion,
      generation: 1,
      extensions: [{ source, status: "loaded" }],
      tools: [{ ...registration, parameters: { type: "object", properties: { value: { type: "future" } } } }]
    })
  ).toThrow("unsupported type")
  expect(() =>
    validateWorkerMessage({
      type: "ready",
      protocolVersion: extensionProtocolVersion,
      generation: 1,
      extensions: [{ source, status: "loaded" }],
      tools: [registration, registration]
    })
  ).toThrow("unique")
  expect(() =>
    validateWorkerMessage({
      type: "tool_result",
      generation: 1,
      requestId: 2,
      value: "x".repeat(maxExtensionToolResultBytes + 1)
    })
  ).toThrow(`${maxExtensionToolResultBytes} bytes`)
  expect(
    validateWorkerMessage({ type: "tool_result", generation: 1, requestId: 2, value: { echoed: "hello" } })
  ).toEqual({ type: "tool_result", generation: 1, requestId: 2, value: { echoed: "hello" } })
})

test("session-operation protocol validates source, values, delivery, and bounded results", () => {
  const append = validateWorkerMessage({
    type: "custom_entry_append",
    generation: 1,
    requestId: 7,
    extensionId: source.id,
    customType: "example.counter",
    data: { count: 1 }
  })
  expect(append).toEqual({
    type: "custom_entry_append",
    generation: 1,
    requestId: 7,
    extensionId: source.id,
    customType: "example.counter",
    data: { count: 1 }
  })
  expect(Object.isFrozen(append.type === "custom_entry_append" ? append.data : undefined)).toBe(true)

  expect(
    validateWorkerMessage({
      type: "custom_message_send",
      generation: 1,
      requestId: 8,
      extensionId: source.id,
      message: { customType: "example.notice", content: "hello", display: false, details: { count: 1 } },
      delivery: "follow_up"
    })
  ).toMatchObject({ type: "custom_message_send", delivery: "follow_up", message: { display: false } })
  expect(() => validateWorkerMessage({ ...append, customType: "Invalid Type" })).toThrow("custom type")
  expect(() =>
    validateWorkerMessage({
      type: "custom_message_send",
      generation: 1,
      requestId: 8,
      extensionId: source.id,
      message: { customType: "example.notice", content: "hello", display: true },
      delivery: "later"
    })
  ).toThrow("delivery")

  const entry = { id: "entry", timestamp: new Date(0).toISOString(), customType: "example.counter", data: null }
  expect(validateHostMessage({ type: "custom_entries_result", generation: 1, requestId: 7, entries: [entry] })).toEqual(
    { type: "custom_entries_result", generation: 1, requestId: 7, entries: [entry] }
  )
  expect(() =>
    validateHostMessage({
      type: "custom_entries_result",
      generation: 1,
      requestId: 7,
      entries: Array.from({ length: maxCustomStateEntries + 1 }, () => entry)
    })
  ).toThrow(`${maxCustomStateEntries}`)
  expect(() =>
    validateHostMessage({ type: "session_operation_error", generation: 1, requestId: 7, message: "" })
  ).toThrow("session operation error")
})

test("subagent protocol bounds profiles, operations, snapshots, and cancellation", () => {
  const profile = {
    source,
    name: "finder",
    description: "Find evidence",
    instructions: "Find only requested evidence",
    thinking: "high"
  }
  const ready = validateWorkerMessage({
    type: "ready",
    protocolVersion: extensionProtocolVersion,
    generation: 1,
    extensions: [{ source, status: "loaded" }],
    tools: [],
    subagents: [profile]
  })
  expect(ready).toMatchObject({ subagents: [{ name: "finder", thinking: "high" }] })
  expect(Object.isFrozen(ready.type === "ready" ? ready.subagents?.[0] : undefined)).toBe(true)
  expect(() =>
    validateWorkerMessage({
      type: "ready",
      protocolVersion: extensionProtocolVersion,
      generation: 1,
      extensions: [{ source, status: "loaded" }],
      tools: [],
      subagents: [profile, profile]
    })
  ).toThrow("unique")
  expect(() =>
    validateWorkerMessage({
      type: "ready",
      protocolVersion: extensionProtocolVersion,
      generation: 1,
      extensions: [{ source, status: "loaded" }],
      tools: [],
      subagents: [{ ...profile, instructions: "x".repeat(maxExtensionSubagentInstructionsBytes + 1) }]
    })
  ).toThrow(`${maxExtensionSubagentInstructionsBytes}`)
  expect(() =>
    validateWorkerMessage({
      type: "ready",
      protocolVersion: extensionProtocolVersion,
      generation: 1,
      extensions: [{ source, status: "loaded" }],
      tools: [],
      subagents: [{ ...profile, description: " \n ", instructions: " \t " }]
    })
  ).toThrow("blank")
  expect(() =>
    validateWorkerMessage({
      type: "ready",
      protocolVersion: extensionProtocolVersion,
      generation: 1,
      extensions: [{ source, status: "loaded" }],
      tools: [],
      subagents: [{ ...profile, model: "   " }]
    })
  ).toThrow("blank")
  expect(
    validateWorkerMessage({
      type: "ready",
      protocolVersion: extensionProtocolVersion,
      generation: 1,
      extensions: [{ source, status: "loaded" }],
      tools: [],
      subagents: [
        {
          ...profile,
          description: "d".repeat(maxExtensionSubagentDescriptionBytes),
          instructions: "i".repeat(maxExtensionSubagentInstructionsBytes),
          model: "m".repeat(maxExtensionSubagentModelBytes)
        }
      ]
    })
  ).toMatchObject({ subagents: [{ name: "finder" }] })
  expect(() =>
    validateWorkerMessage({
      type: "subagent_spawn",
      generation: 1,
      requestId: 2,
      extensionId: source.id,
      profile: "finder",
      name: "x".repeat(maxExtensionSubagentNameBytes + 1),
      prompt: "inspect"
    })
  ).toThrow(`${maxExtensionSubagentNameBytes}`)
  expect(
    validateWorkerMessage({
      type: "subagent_operation_cancel",
      generation: 1,
      requestId: 2,
      extensionId: source.id,
      targetRequestId: 2
    })
  ).toMatchObject({ type: "subagent_operation_cancel", targetRequestId: 2 })
  expect(
    validateHostMessage({
      type: "subagent_wait_result",
      generation: 1,
      requestId: 2,
      snapshots: [{ name: "finder-1", lifecycle: "idle", resultReady: false }]
    })
  ).toMatchObject({ type: "subagent_wait_result", snapshots: [{ name: "finder-1", lifecycle: "idle" }] })
})

test("maximum admitted load results fit in one protocol frame", () => {
  const path = resolve("root", '"'.repeat(3_500))
  const largestSource: ExtensionSource = {
    id: "x".repeat(maxExtensionIdBytes),
    declaredPath: path,
    entryPath: path,
    scope: "temporary",
    origin: "cli"
  }
  const result = {
    source: largestSource,
    status: "failed",
    diagnostic: { extensionId: largestSource.id, path, phase: "import", severity: "error", message: '"'.repeat(2_048) }
  }
  const message = validateWorkerMessage({
    type: "ready",
    protocolVersion: extensionProtocolVersion,
    generation: 1,
    extensions: Array.from({ length: maxExtensionSources }, () => result),
    tools: []
  })

  expect(encodeExtensionProtocolFrame(message).byteLength).toBeLessThanOrEqual(maxExtensionProtocolFrameBytes + 4)
})

test("tool catalogs have one aggregate ready-frame budget", () => {
  const toolSource: ExtensionSource = { ...source }
  const tools = Array.from({ length: maxExtensionTools }, (_, index) => ({
    source: toolSource,
    name: `tool_${index}`,
    label: `Tool ${index}`,
    description: "d".repeat(maxExtensionToolDescriptionBytes),
    parameters: { type: "object", description: "s".repeat(maxExtensionToolSchemaBytes - 64), properties: {} },
    outputSchema: { type: "string" }
  }))

  expect(() =>
    validateWorkerMessage({
      type: "ready",
      protocolVersion: extensionProtocolVersion,
      generation: 1,
      extensions: [{ source: toolSource, status: "loaded" }],
      tools
    })
  ).toThrow(`catalog cannot exceed ${maxExtensionToolCatalogBytes} bytes`)
})

test("ready-frame validation bounds combined source, tool, and subagent catalogs", () => {
  const path = resolve("root", '"'.repeat(3_500))
  const largestSource: ExtensionSource = {
    id: "x".repeat(maxExtensionIdBytes),
    declaredPath: path,
    entryPath: path,
    scope: "temporary",
    origin: "cli"
  }
  const failed = {
    source: largestSource,
    status: "failed",
    diagnostic: { extensionId: largestSource.id, path, phase: "import", severity: "error", message: '"'.repeat(2_048) }
  }
  const tools = Array.from({ length: maxExtensionTools }, (_, index) => ({
    source,
    name: `tool_${index}`,
    label: `Tool ${index}`,
    description: '"'.repeat(3_000),
    parameters: { type: "object", properties: {} },
    outputSchema: { type: "string" }
  }))
  const subagents = Array.from({ length: maxExtensionSubagentProfiles }, (_, index) => ({
    source,
    name: `profile-${index}`,
    description: "d".repeat(maxExtensionSubagentDescriptionBytes),
    instructions: "i".repeat(maxExtensionSubagentInstructionsBytes),
    model: "m".repeat(maxExtensionSubagentModelBytes)
  }))
  expect(() =>
    validateWorkerMessage({
      type: "ready",
      protocolVersion: extensionProtocolVersion,
      generation: 1,
      extensions: [...Array.from({ length: maxExtensionSources - 1 }, () => failed), { source, status: "loaded" }],
      tools,
      subagents
    })
  ).toThrow(`ready frame cannot exceed ${maxExtensionProtocolFrameBytes} bytes`)

  const maximumProfiles = validateWorkerMessage({
    type: "ready",
    protocolVersion: extensionProtocolVersion,
    generation: 1,
    extensions: [{ source, status: "loaded" }],
    tools: [],
    subagents
  })
  expect(encodeExtensionProtocolFrame(maximumProfiles).byteLength).toBeLessThanOrEqual(
    maxExtensionProtocolFrameBytes + 4
  )
})

test("diagnostic construction truncates UTF-8 on a complete code point", () => {
  const message = `prefix-${"🦊".repeat(maxExtensionDiagnosticMessageBytes)}`
  const diagnostic = boundedExtensionDiagnostic({ phase: "factory", severity: "error", message })

  expect(Buffer.byteLength(diagnostic.message)).toBeLessThanOrEqual(maxExtensionDiagnosticMessageBytes)
  expect(diagnostic.message).not.toContain("�")
  expect(Object.isFrozen(diagnostic)).toBe(true)
})

test("protocol writer serializes writes and releases its owned listener", async () => {
  const chunks: Buffer[] = []
  const callbacks: Array<(error?: Error | null) => void> = []
  const sink = new Writable({
    write(chunk: Buffer, _encoding, callback) {
      chunks.push(Buffer.from(chunk))
      callbacks.push(callback)
    }
  })
  const writer = new ExtensionProtocolWriter(sink)
  const first = writer.send({ sequence: 1 })
  const second = writer.send({ sequence: 2 })

  expect(chunks).toHaveLength(1)
  callbacks.shift()!()
  await first
  expect(chunks).toHaveLength(2)
  callbacks.shift()!()
  await second

  writer.dispose()
  expect(sink.listenerCount("error")).toBe(0)
  expect(writer.send({ sequence: 3 })).rejects.toThrow("disposed")
})

test("protocol writer bounds queued frames and bytes and rejects all work on failure", async () => {
  const sink = new Writable({ write(_chunk, _encoding, _callback) {} })
  const writer = new ExtensionProtocolWriter(sink)
  const writes = Array.from({ length: maxExtensionQueuedWrites }, (_, index) => writer.send({ index }))
  expect(writer.send({ overflow: true })).rejects.toThrow(`${maxExtensionQueuedWrites} frames`)
  writer.fail(new Error("pipe failed"))
  const outcomes = await Promise.allSettled(writes)
  expect(outcomes.every(outcome => outcome.status === "rejected")).toBe(true)
  expect(writer.send({ late: true })).rejects.toThrow("pipe failed")
  writer.dispose()

  const byteSink = new Writable({ write(_chunk, _encoding, _callback) {} })
  const byteWriter = new ExtensionProtocolWriter(byteSink)
  const payload = "x".repeat(900_000)
  const byteWrites: Promise<void>[] = []
  let overflow: Promise<void> | undefined
  for (let index = 0; index < 10; index++) {
    const write = byteWriter.send({ index, payload })
    if (index === 9) overflow = write
    else byteWrites.push(write)
  }
  expect(overflow!).rejects.toThrow("queue more than")
  byteWriter.dispose()
  await Promise.allSettled(byteWrites)
})

test("protocol encoding rejects non-JSON and oversized values", () => {
  const circular: Record<string, unknown> = {}
  circular.self = circular
  expect(() => encodeExtensionProtocolFrame(circular)).toThrow("could not be serialized")
  expect(() => encodeExtensionProtocolFrame(undefined)).toThrow("must be JSON values")
  expect(() => encodeExtensionProtocolFrame("x".repeat(maxExtensionProtocolFrameBytes))).toThrow(
    `${maxExtensionProtocolFrameBytes}`
  )
})

function rawFrame(payload: Buffer): Buffer {
  const frame = Buffer.alloc(4 + payload.byteLength)
  frame.writeUInt32BE(payload.byteLength)
  payload.copy(frame, 4)
  return frame
}

function frameWithLength(length: number): Buffer {
  const frame = Buffer.alloc(4)
  frame.writeUInt32BE(length)
  return frame
}
