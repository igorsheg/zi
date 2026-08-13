import { expect, test } from "bun:test"
import { Writable } from "node:stream"

import {
  codeModeFramingLabel,
  codeModeFramingLimits,
  codeModeProtocolVersion,
  maxCodeModeFrameBytes,
  validateCodeModeJson,
  validateHostMessage,
  validateWorkerMessage
} from "../src/code-mode/protocol.js"
import { encodeFramedJson, FramedJsonDecoder, FramedJsonError, FramedJsonWriter } from "../src/processes/framed-json.js"

test("code-mode protocol decodes fragmented and coalesced frames", () => {
  const decoder = new FramedJsonDecoder(validateWorkerMessage, codeModeFramingLimits, codeModeFramingLabel)
  const first = encodeFramedJson(
    { version: codeModeProtocolVersion, type: "ready", generation: 2 },
    codeModeFramingLimits,
    codeModeFramingLabel
  )
  const second = encodeFramedJson(
    {
      version: codeModeProtocolVersion,
      type: "completed",
      generation: 2,
      executionId: 7,
      result: { ok: true },
      state: { count: 1 },
      logs: []
    },
    codeModeFramingLimits,
    codeModeFramingLabel
  )
  const input = Buffer.concat([first, second])

  expect(decoder.push(input.subarray(0, 3))).toEqual([])
  expect(decoder.push(input.subarray(3, first.byteLength + 2))).toEqual([
    { version: codeModeProtocolVersion, type: "ready", generation: 2 }
  ])
  expect(decoder.push(input.subarray(first.byteLength + 2))).toEqual([
    {
      version: codeModeProtocolVersion,
      type: "completed",
      generation: 2,
      executionId: 7,
      result: { ok: true },
      state: { count: 1 },
      logs: []
    }
  ])
  decoder.end()
})

test("code-mode protocol bounds queued host output", async () => {
  const sink = new Writable({ write() {} })
  const writer = new FramedJsonWriter(sink, codeModeFramingLimits, codeModeFramingLabel)
  const pending: Promise<void>[] = []
  for (let index = 0; index < 128; index++) {
    pending.push(writer.send({ version: codeModeProtocolVersion, type: "initialize", generation: 1 }))
  }
  const overflow = writer.send({ version: codeModeProtocolVersion, type: "initialize", generation: 1 })

  expect(overflow).rejects.toThrow("queue cannot exceed")
  writer.dispose()
  await Promise.allSettled(pending)
  sink.destroy()
})

test("code-mode protocol fails closed on partial, oversized, and structurally unbounded input", () => {
  const partial = new FramedJsonDecoder(validateWorkerMessage, codeModeFramingLimits, codeModeFramingLabel)
  partial.push(
    encodeFramedJson(
      { version: codeModeProtocolVersion, type: "ready", generation: 1 },
      codeModeFramingLimits,
      codeModeFramingLabel
    ).subarray(0, 6)
  )
  expect(() => partial.end()).toThrow("partial frame")

  const oversized = new FramedJsonDecoder(validateWorkerMessage, codeModeFramingLimits, codeModeFramingLabel)
  const header = Buffer.alloc(4)
  header.writeUInt32BE(maxCodeModeFrameBytes + 1)
  expect(() => oversized.push(header)).toThrow(FramedJsonError)

  let value: unknown = null
  for (let index = 0; index < 40; index++) value = [value]
  expect(() => validateCodeModeJson(value)).toThrow("structural bound")
})

test("code-mode worker failures carry bounded nested-tool provenance", () => {
  const message = validateWorkerMessage({
    version: codeModeProtocolVersion,
    type: "failed",
    generation: 2,
    executionId: 7,
    error: "nested failure",
    logs: [],
    toolCallId: 3
  })

  expect(message).toEqual({
    version: codeModeProtocolVersion,
    type: "failed",
    generation: 2,
    executionId: 7,
    error: "nested failure",
    logs: [],
    toolCallId: 3
  })
  expect(() =>
    validateWorkerMessage({
      version: codeModeProtocolVersion,
      type: "failed",
      generation: 2,
      executionId: 7,
      error: "nested failure",
      logs: [],
      toolCallId: 64
    })
  ).toThrow("call ID")
})

test("code-mode host results carry native values without presentation details", () => {
  const message = validateHostMessage({
    version: codeModeProtocolVersion,
    type: "tool_result",
    generation: 2,
    executionId: 7,
    id: 3,
    value: { files: 3, lines: 12 },
    terminate: true
  })

  expect(message).toEqual({
    version: codeModeProtocolVersion,
    type: "tool_result",
    generation: 2,
    executionId: 7,
    id: 3,
    value: { files: 3, lines: 12 },
    terminate: true
  })
  expect(() =>
    validateHostMessage({
      version: codeModeProtocolVersion,
      type: "tool_result",
      generation: 2,
      executionId: 7,
      id: 3,
      result: { text: "legacy", details: {} }
    })
  ).toThrow("value")
})
