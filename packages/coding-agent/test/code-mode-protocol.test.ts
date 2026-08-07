import { expect, test } from "bun:test"
import { Writable } from "node:stream"

import {
  CodeModeProtocolDecoder,
  CodeModeProtocolError,
  CodeModeProtocolWriter,
  codeModeProtocolVersion,
  encodeCodeModeFrame,
  maxCodeModeFrameBytes,
  validateCodeModeJson,
  validateHostMessage,
  validateWorkerMessage
} from "../src/code-mode/protocol.js"

test("code-mode protocol decodes fragmented and coalesced frames", () => {
  const decoder = new CodeModeProtocolDecoder(validateWorkerMessage)
  const first = encodeCodeModeFrame({ version: codeModeProtocolVersion, type: "ready", generation: 2 })
  const second = encodeCodeModeFrame({
    version: codeModeProtocolVersion,
    type: "completed",
    generation: 2,
    executionId: 7,
    result: { ok: true },
    state: { count: 1 },
    logs: []
  })
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
  const writer = new CodeModeProtocolWriter(sink)
  const pending: Promise<void>[] = []
  for (let index = 0; index < 128; index++) {
    pending.push(writer.send({ version: codeModeProtocolVersion, type: "initialize", generation: 1 }))
  }
  const overflow = writer.send({ version: codeModeProtocolVersion, type: "initialize", generation: 1 })

  expect(overflow).rejects.toThrow("queue exceeded")
  writer.dispose()
  await Promise.allSettled(pending)
  sink.destroy()
})

test("code-mode protocol fails closed on partial, oversized, and structurally unbounded input", () => {
  const partial = new CodeModeProtocolDecoder(validateWorkerMessage)
  partial.push(encodeCodeModeFrame({ version: codeModeProtocolVersion, type: "ready", generation: 1 }).subarray(0, 6))
  expect(() => partial.end()).toThrow("partial frame")

  const oversized = new CodeModeProtocolDecoder(validateWorkerMessage)
  const header = Buffer.alloc(4)
  header.writeUInt32BE(maxCodeModeFrameBytes + 1)
  expect(() => oversized.push(header)).toThrow(CodeModeProtocolError)

  let value: unknown = null
  for (let index = 0; index < 40; index++) value = [value]
  expect(() => validateCodeModeJson(value)).toThrow("structural bound")
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
