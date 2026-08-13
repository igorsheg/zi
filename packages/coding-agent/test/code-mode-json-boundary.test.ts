import { expect, test } from "bun:test"
import { runInNewContext } from "node:vm"

import { snapshotCodeModeJson } from "../src/code-mode/json-boundary.js"
import { CodeModeProtocolError, maxCodeModeJsonDepth, maxCodeModeJsonNodes } from "../src/code-mode/protocol.js"

test("code-mode JSON snapshots detach plain containers without losing special keys", () => {
  const shared = { count: 1 }
  const nullPrototype: Record<string, unknown> = {}
  Object.setPrototypeOf(nullPrototype, null)
  Object.defineProperty(nullPrototype, "__proto__", {
    configurable: true,
    enumerable: true,
    value: shared,
    writable: true
  })
  const source = { items: [nullPrototype, shared], alias: shared }

  const snapshot = snapshotCodeModeJson(source)
  shared.count = 2

  expect(snapshot).toEqual({ items: [{ ["__proto__"]: { count: 1 } }, { count: 1 }], alias: { count: 1 } })
  expect(snapshot).not.toBe(source)
  if (typeof snapshot !== "object" || snapshot === null || Array.isArray(snapshot)) {
    throw new Error("expected object snapshot")
  }
  expect(Reflect.get(snapshot, "alias")).not.toBe(shared)
  const items: unknown = Reflect.get(snapshot, "items")
  if (!Array.isArray(items)) throw new Error("expected snapshot items")
  const first = items[0]
  expect(typeof first === "object" && first !== null && Object.hasOwn(first, "__proto__")).toBe(true)
})

test("code-mode JSON snapshots accept plain containers from another realm", () => {
  const foreign = runInNewContext("({ nested: [{ ok: true }] })")

  expect(snapshotCodeModeJson(foreign)).toEqual({ nested: [{ ok: true }] })
})

test("code-mode JSON snapshots reject values whose JSON serialization would be lossy or executable", () => {
  class RecordLike {
    value = 1
  }
  const cycle: Record<string, unknown> = {}
  cycle.self = cycle
  const sparse: undefined[] = []
  sparse.length = 1
  const decorated = [1]
  Object.defineProperty(decorated, "extra", { enumerable: true, value: 2 })
  const hidden = Object.defineProperty({}, "hidden", { value: 1 })
  const symbolObject = { [Symbol("value")]: 1 }
  let accessorReads = 0
  const accessor = Object.defineProperty({}, "value", {
    enumerable: true,
    get() {
      accessorReads += 1
      return 1
    }
  })

  for (const value of [
    undefined,
    () => 1,
    1n,
    Symbol("value"),
    Number.NaN,
    Number.POSITIVE_INFINITY,
    -0,
    new Date(),
    new RecordLike(),
    sparse,
    decorated,
    hidden,
    symbolObject,
    accessor,
    cycle,
    [undefined],
    { value: undefined }
  ]) {
    expect(() => snapshotCodeModeJson(value)).toThrow(CodeModeProtocolError)
  }
  expect(accessorReads).toBe(0)
})

test("code-mode JSON snapshots preserve structural bounds", () => {
  let tooDeep: unknown = null
  for (let depth = 0; depth <= maxCodeModeJsonDepth; depth++) tooDeep = [tooDeep]
  const tooMany = Array.from({ length: maxCodeModeJsonNodes }, () => null)

  expect(() => snapshotCodeModeJson(tooDeep)).toThrow("structural bound")
  expect(() => snapshotCodeModeJson(tooMany)).toThrow("structural bound")
})

test("code-mode JSON snapshots keep working after guest-visible intrinsics are replaced", () => {
  const source = { payload: ["€", 42, { ok: true }] }
  const defineProperty = Object.defineProperty
  const arrayIsArray = Object.getOwnPropertyDescriptor(Array, "isArray")!
  const arrayPush = Object.getOwnPropertyDescriptor(Array.prototype, "push")!
  const numberIsFinite = Object.getOwnPropertyDescriptor(Number, "isFinite")!
  const objectDefineProperty = Object.getOwnPropertyDescriptor(Object, "defineProperty")!
  const objectGetOwnPropertyDescriptor = Object.getOwnPropertyDescriptor(Object, "getOwnPropertyDescriptor")!
  const objectGetPrototypeOf = Object.getOwnPropertyDescriptor(Object, "getPrototypeOf")!
  const objectHasOwn = Object.getOwnPropertyDescriptor(Object, "hasOwn")!
  const reflectApply = Object.getOwnPropertyDescriptor(Reflect, "apply")!
  const reflectOwnKeys = Object.getOwnPropertyDescriptor(Reflect, "ownKeys")!
  const setAdd = Object.getOwnPropertyDescriptor(Set.prototype, "add")!
  let snapshot: unknown

  try {
    defineProperty(Array, "isArray", { configurable: true, value: () => false, writable: true })
    defineProperty(Array.prototype, "push", {
      configurable: true,
      value: () => {
        throw new Error("mutated push")
      },
      writable: true
    })
    defineProperty(Number, "isFinite", { configurable: true, value: () => false, writable: true })
    defineProperty(Object, "defineProperty", {
      configurable: true,
      value: () => {
        throw new Error("mutated defineProperty")
      },
      writable: true
    })
    defineProperty(Object, "getOwnPropertyDescriptor", {
      configurable: true,
      value: () => {
        throw new Error("mutated getOwnPropertyDescriptor")
      },
      writable: true
    })
    defineProperty(Object, "getPrototypeOf", {
      configurable: true,
      value: () => {
        throw new Error("mutated getPrototypeOf")
      },
      writable: true
    })
    defineProperty(Object, "hasOwn", { configurable: true, value: () => false, writable: true })
    defineProperty(Reflect, "apply", {
      configurable: true,
      value: () => {
        throw new Error("mutated apply")
      },
      writable: true
    })
    defineProperty(Reflect, "ownKeys", { configurable: true, value: () => [], writable: true })
    defineProperty(Set.prototype, "add", {
      configurable: true,
      value: () => {
        throw new Error("mutated set add")
      },
      writable: true
    })
    snapshot = snapshotCodeModeJson(source)
  } finally {
    defineProperty(Array, "isArray", arrayIsArray)
    defineProperty(Array.prototype, "push", arrayPush)
    defineProperty(Number, "isFinite", numberIsFinite)
    defineProperty(Object, "defineProperty", objectDefineProperty)
    defineProperty(Object, "getOwnPropertyDescriptor", objectGetOwnPropertyDescriptor)
    defineProperty(Object, "getPrototypeOf", objectGetPrototypeOf)
    defineProperty(Object, "hasOwn", objectHasOwn)
    defineProperty(Reflect, "apply", reflectApply)
    defineProperty(Reflect, "ownKeys", reflectOwnKeys)
    defineProperty(Set.prototype, "add", setAdd)
  }

  expect(snapshot).toEqual(source)
  expect(snapshot).not.toBe(source)
})
