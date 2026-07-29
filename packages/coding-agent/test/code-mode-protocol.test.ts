import { expect, test } from "bun:test"
import { Writable } from "node:stream"

import {
  CodeModeProtocolDecoder,
  CodeModeProtocolError,
  CodeModeProtocolWriter,
  encodeCodeModeFrame,
  maxCodeModeFrameBytes,
  validateCodeModeJson,
  validateWorkerMessage
} from "../src/code-mode/protocol.js"

test("code-mode protocol decodes fragmented and coalesced frames", () => {
  const decoder = new CodeModeProtocolDecoder(validateWorkerMessage)
  const first = encodeCodeModeFrame({ version: 1, type: "ready" })
  const second = encodeCodeModeFrame({ version: 1, type: "completed", result: { ok: true }, logs: [] })
  const input = Buffer.concat([first, second])

  expect(decoder.push(input.subarray(0, 3))).toEqual([])
  expect(decoder.push(input.subarray(3, first.byteLength + 2))).toEqual([{ version: 1, type: "ready" }])
  expect(decoder.push(input.subarray(first.byteLength + 2))).toEqual([
    { version: 1, type: "completed", result: { ok: true }, logs: [] }
  ])
  decoder.end()
})

test("code-mode protocol bounds queued host output", async () => {
  const sink = new Writable({ write() {} })
  const writer = new CodeModeProtocolWriter(sink)
  const pending: Promise<void>[] = []
  for (let index = 0; index < 128; index++) {
    pending.push(writer.send({ version: 1, type: "start", code: "async () => {}", tools: [] }))
  }
  const overflow = writer.send({ version: 1, type: "start", code: "async () => {}", tools: [] })

  expect(overflow).rejects.toThrow("queue exceeded")
  writer.dispose()
  await Promise.allSettled(pending)
  sink.destroy()
})

test("code-mode protocol fails closed on partial, oversized, and structurally unbounded input", () => {
  const partial = new CodeModeProtocolDecoder(validateWorkerMessage)
  partial.push(encodeCodeModeFrame({ version: 1, type: "ready" }).subarray(0, 6))
  expect(() => partial.end()).toThrow("partial frame")

  const oversized = new CodeModeProtocolDecoder(validateWorkerMessage)
  const header = Buffer.alloc(4)
  header.writeUInt32BE(maxCodeModeFrameBytes + 1)
  expect(() => oversized.push(header)).toThrow(CodeModeProtocolError)

  let value: unknown = null
  for (let index = 0; index < 40; index++) value = [value]
  expect(() => validateCodeModeJson(value)).toThrow("structural bound")
})
