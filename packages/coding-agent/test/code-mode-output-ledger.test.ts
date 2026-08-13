import { expect, test } from "bun:test"

import { boundCodeModeOutput } from "../src/code-mode/output-ledger.js"
import { CodeModeProtocolError } from "../src/code-mode/protocol.js"

test("code-mode output accounts logs and one result under the same JSON-byte cap", () => {
  const exact = boundCodeModeOutput(11, ["abc"], { type: "result", result: "xy" })
  const limited = boundCodeModeOutput(10, ["abc"], { type: "result", result: "xy" })

  expect(exact).toEqual({ type: "result", logs: ["abc"], result: "xy" })
  expect(limited.type).toBe("output-limit")
  if (limited.type !== "output-limit") throw new Error("expected output limit")
  expect(
    Buffer.byteLength(JSON.stringify(limited.logs)) + Buffer.byteLength(JSON.stringify(limited.error))
  ).toBeLessThanOrEqual(10)
})

test("code-mode output accounts failure text instead of a result", () => {
  expect(boundCodeModeOutput(11, ["abc"], { type: "error", error: "xy" })).toEqual({
    type: "error",
    logs: ["abc"],
    error: "xy"
  })
  expect(boundCodeModeOutput(10, ["abc"], { type: "error", error: "xy" }).type).toBe("output-limit")
})

test("code-mode output limits retain a fitting escaped Unicode log prefix", () => {
  const maxBytes = 64
  const text = `start-${'😀"\\\n'.repeat(100)}`
  const output = boundCodeModeOutput(maxBytes, [text, "later"], { type: "result", result: null })

  expect(output.type).toBe("output-limit")
  if (output.type !== "output-limit") throw new Error("expected output limit")
  expect(output.logs).toHaveLength(1)
  expect(output.logs[0]?.startsWith("start-😀")).toBe(true)
  const lastCodeUnit = output.logs[0]?.charCodeAt((output.logs[0]?.length ?? 0) - 1) ?? 0
  expect(lastCodeUnit < 0xd800 || lastCodeUnit > 0xdbff).toBe(true)
  expect(
    Buffer.byteLength(JSON.stringify(output.logs)) + Buffer.byteLength(JSON.stringify(output.error))
  ).toBeLessThanOrEqual(maxBytes)
})

test("code-mode output preserves exact escaped UTF-8 boundaries", () => {
  const result = { text: '"\\\b\t\n\f\r\u0000😀\ud800€' }
  const maxBytes = Buffer.byteLength(JSON.stringify([])) + Buffer.byteLength(JSON.stringify(result))

  expect(boundCodeModeOutput(maxBytes, [], { type: "result", result })).toEqual({ type: "result", logs: [], result })
  expect(boundCodeModeOutput(maxBytes - 1, [], { type: "result", result }).type).toBe("output-limit")
})

test("code-mode output supports its minimum representable aggregate cap", () => {
  expect(boundCodeModeOutput(4, [], { type: "result", result: "" })).toEqual({ type: "result", logs: [], result: "" })
  expect(boundCodeModeOutput(4, [], { type: "result", result: null })).toEqual({
    type: "output-limit",
    logs: [],
    error: ""
  })
  expect(() => boundCodeModeOutput(3, [], { type: "result", result: null })).toThrow(CodeModeProtocolError)
})

test("code-mode output accounting keeps working after guest-visible intrinsics are replaced", () => {
  const logs = ['log-"-€']
  const result = { payload: ["😀", 42] }
  const maxBytes = Buffer.byteLength(JSON.stringify(logs)) + Buffer.byteLength(JSON.stringify(result))
  const defineProperty = Object.defineProperty
  const arrayIsArray = Object.getOwnPropertyDescriptor(Array, "isArray")!
  const arrayPop = Object.getOwnPropertyDescriptor(Array.prototype, "pop")!
  const arrayPush = Object.getOwnPropertyDescriptor(Array.prototype, "push")!
  const bufferByteLength = Object.getOwnPropertyDescriptor(Buffer, "byteLength")!
  const objectDefineProperty = Object.getOwnPropertyDescriptor(Object, "defineProperty")!
  const objectKeys = Object.getOwnPropertyDescriptor(Object, "keys")!
  const reflectApply = Object.getOwnPropertyDescriptor(Reflect, "apply")!
  const charCodeAt = Object.getOwnPropertyDescriptor(String.prototype, "charCodeAt")!
  const codePointAt = Object.getOwnPropertyDescriptor(String.prototype, "codePointAt")!
  const slice = Object.getOwnPropertyDescriptor(String.prototype, "slice")!
  let output: unknown

  try {
    defineProperty(Array, "isArray", { configurable: true, value: () => false, writable: true })
    defineProperty(Array.prototype, "pop", {
      configurable: true,
      value: () => {
        throw new Error("mutated pop")
      },
      writable: true
    })
    defineProperty(Array.prototype, "push", {
      configurable: true,
      value: () => {
        throw new Error("mutated push")
      },
      writable: true
    })
    defineProperty(Buffer, "byteLength", { configurable: true, value: () => 0, writable: true })
    defineProperty(Object, "defineProperty", {
      configurable: true,
      value: () => {
        throw new Error("mutated defineProperty")
      },
      writable: true
    })
    defineProperty(Object, "keys", { configurable: true, value: () => [], writable: true })
    defineProperty(Reflect, "apply", {
      configurable: true,
      value: () => {
        throw new Error("mutated apply")
      },
      writable: true
    })
    defineProperty(String.prototype, "charCodeAt", {
      configurable: true,
      value: () => {
        throw new Error("mutated charCodeAt")
      },
      writable: true
    })
    defineProperty(String.prototype, "codePointAt", {
      configurable: true,
      value: () => {
        throw new Error("mutated codePointAt")
      },
      writable: true
    })
    defineProperty(String.prototype, "slice", {
      configurable: true,
      value: () => {
        throw new Error("mutated slice")
      },
      writable: true
    })
    output = boundCodeModeOutput(maxBytes, logs, { type: "result", result })
  } finally {
    defineProperty(Array, "isArray", arrayIsArray)
    defineProperty(Array.prototype, "pop", arrayPop)
    defineProperty(Array.prototype, "push", arrayPush)
    defineProperty(Buffer, "byteLength", bufferByteLength)
    defineProperty(Object, "defineProperty", objectDefineProperty)
    defineProperty(Object, "keys", objectKeys)
    defineProperty(Reflect, "apply", reflectApply)
    defineProperty(String.prototype, "charCodeAt", charCodeAt)
    defineProperty(String.prototype, "codePointAt", codePointAt)
    defineProperty(String.prototype, "slice", slice)
  }

  expect(output).toEqual({ type: "result", logs, result })
})
