import { expect, test } from "bun:test"

import { decodeRpcRequest, maxRpcFrameBytes, RpcLineDecoder, RpcRequestError } from "../src/rpc/protocol.js"

test("RPC request decoding admits only the versioned closed command catalog", () => {
  expect(
    decodeRpcRequest({
      version: 1,
      id: "prompt-1",
      method: "session.prompt",
      params: { delivery: "steer", text: "next" }
    })
  ).toEqual({ version: 1, id: "prompt-1", method: "session.prompt", params: { delivery: "steer", text: "next" } })
  expect(
    decodeRpcRequest({ version: 1, id: "thinking-1", method: "thinking.select", params: { level: "high" } })
  ).toEqual({ version: 1, id: "thinking-1", method: "thinking.select", params: { level: "high", scope: "global" } })
  expect(decodeRpcRequest({ version: 1, id: "messages-default", method: "session.get_messages" })).toEqual({
    version: 1,
    id: "messages-default",
    method: "session.get_messages",
    params: { start: 0, limit: 100 }
  })
  expect(
    decodeRpcRequest({ version: 1, id: "messages-1", method: "session.get_messages", params: { start: 2 } })
  ).toEqual({ version: 1, id: "messages-1", method: "session.get_messages", params: { start: 2, limit: 100 } })

  expectRequestError({ version: 2, id: "x", method: "session.get_state" }, "unsupported_version")
  expectRequestError({ version: 1, id: "", method: "session.get_state" }, "invalid_request")
  expectRequestError({ version: 1, id: "x", method: "session.get_state", extra: true }, "invalid_request")
  expectRequestError({ version: 1, id: "x", method: "unknown" }, "unknown_method")
  expect(
    decodeRpcRequest({
      version: 1,
      id: "continue-1",
      method: "session.prompt",
      params: { delivery: "continue", text: "wake" }
    })
  ).toEqual({ version: 1, id: "continue-1", method: "session.prompt", params: { delivery: "continue", text: "wake" } })
  expect(
    decodeRpcRequest({ version: 1, id: "events-1", method: "connection.set_events", params: { mode: "none" } })
  ).toEqual({ version: 1, id: "events-1", method: "connection.set_events", params: { mode: "none" } })

  expectRequestError(
    { version: 1, id: "x", method: "session.prompt", params: { delivery: "later", text: "hello" } },
    "invalid_request"
  )
  expectRequestError(
    { version: 1, id: "x", method: "connection.set_events", params: { mode: "sometimes" } },
    "invalid_request"
  )
  expectRequestError(
    { version: 1, id: "x", method: "connection.set_events", params: { mode: "none", extra: true } },
    "invalid_request"
  )
  expectRequestError(
    { version: 1, id: "x", method: "session.get_messages", params: { start: -1, limit: 101 } },
    "invalid_request"
  )
})

test("RPC line decoding preserves split UTF-8 and rejects malformed or oversized framing", () => {
  const decoder = new RpcLineDecoder()
  const encoded = new TextEncoder().encode('{"text":"héllo"}\r\n{}\n')

  expect(decoder.push(encoded.subarray(0, 10))).toEqual([])
  expect(decoder.push(encoded.subarray(10))).toEqual(['{"text":"héllo"}', "{}"])
  expect(decoder.finish()).toEqual([])

  const unterminated = new RpcLineDecoder()
  expect(unterminated.push(new TextEncoder().encode("{}"))).toEqual([])
  expect(unterminated.finish()).toEqual(["{}"])

  const malformed = new RpcLineDecoder()
  expect(() => malformed.push(Uint8Array.from([0xff]))).toThrow("valid UTF-8")

  const oversized = new RpcLineDecoder()
  expect(() => oversized.push(new Uint8Array(maxRpcFrameBytes + 1).fill(0x61))).toThrow(
    `RPC input records cannot exceed ${maxRpcFrameBytes} bytes`
  )
})

function expectRequestError(value: unknown, code: RpcRequestError["code"]): void {
  try {
    decodeRpcRequest(value)
    throw new Error("Expected request rejection")
  } catch (cause) {
    if (!(cause instanceof RpcRequestError)) throw cause
    expect(cause.code).toBe(code)
  }
}
