// Adapted from DeepSeek Harness worker-json.ts at commit 47f943859bef60e4160492346772ded9b24f765a (MIT).

/* oxlint-disable typescript/unbound-method -- captured methods are invoked with captured Reflect.apply */

import { CodeModeProtocolError, maxCodeModeJsonDepth, maxCodeModeJsonNodes, type CodeModeJson } from "./protocol.js"

const intrinsicFunctionToString = Function.prototype.toString
const intrinsicFunctionHasInstance = Function.prototype[Symbol.hasInstance]
const intrinsicReflectApply = Reflect.apply
const IntrinsicSet = Set
const intrinsicArrayIsArray = Array.isArray
const intrinsicArrayPrototype = Array.prototype
const intrinsicNumberIsFinite = Number.isFinite
const intrinsicObjectDefineProperty = Object.defineProperty
const intrinsicObjectGetOwnPropertyDescriptor = Object.getOwnPropertyDescriptor
const intrinsicObjectGetPrototypeOf = Object.getPrototypeOf
const intrinsicObjectHasOwn = Object.hasOwn
const intrinsicObjectIs = Object.is
const intrinsicObjectPrototype = Object.prototype
const intrinsicReflectGet = Reflect.get
const intrinsicReflectOwnKeys = Reflect.ownKeys
const intrinsicSetAdd = Set.prototype.add
const intrinsicSetDelete = Set.prototype.delete
const intrinsicSetHas = Set.prototype.has

/* oxlint-enable typescript/unbound-method */

function defineEnumerableDataProperty(target: object, key: PropertyKey, value: unknown): void {
  intrinsicObjectDefineProperty(target, key, { configurable: true, enumerable: true, value, writable: true })
}

function append<T>(target: T[], value: T): void {
  defineEnumerableDataProperty(target, target.length, value)
}

function takeLast<T>(target: T[]): T | undefined {
  if (target.length === 0) return undefined
  const index = target.length - 1
  const value = target[index]
  intrinsicObjectDefineProperty(target, "length", { value: index })
  return value
}

function setHas(target: Set<object>, value: object): boolean {
  return intrinsicReflectApply(intrinsicSetHas, target, [value])
}

function setAdd(target: Set<object>, value: object): void {
  intrinsicReflectApply(intrinsicSetAdd, target, [value])
}

function setDelete(target: Set<object>, value: object): void {
  intrinsicReflectApply(intrinsicSetDelete, target, [value])
}

function hasIntrinsicConstructor(prototype: object, name: "Array" | "Object"): boolean {
  const descriptor = intrinsicObjectGetOwnPropertyDescriptor(prototype, "constructor")
  const constructor = descriptor?.value
  if (typeof constructor !== "function") return false
  try {
    return (
      intrinsicReflectGet(constructor, "name") === name &&
      intrinsicReflectGet(constructor, "prototype") === prototype &&
      intrinsicReflectApply(intrinsicFunctionToString, constructor, []) === `function ${name}() { [native code] }`
    )
  } catch {
    return false
  }
}

function isForeignIntrinsicObjectPrototype(value: object): boolean {
  return intrinsicObjectGetPrototypeOf(value) === null && hasIntrinsicConstructor(value, "Object")
}

function hasPlainArrayPrototype(value: unknown[]): boolean {
  const prototype: unknown = intrinsicObjectGetPrototypeOf(value)
  if (prototype === intrinsicArrayPrototype) return true
  if (!intrinsicArrayIsArray(prototype) || !hasIntrinsicConstructor(prototype, "Array")) return false
  const objectPrototype: unknown = intrinsicObjectGetPrototypeOf(prototype)
  return (
    typeof objectPrototype === "object" &&
    objectPrototype !== null &&
    isForeignIntrinsicObjectPrototype(objectPrototype)
  )
}

function hasPlainObjectPrototype(value: object): boolean {
  const prototype: unknown = intrinsicObjectGetPrototypeOf(value)
  return (
    prototype === null ||
    prototype === intrinsicObjectPrototype ||
    (typeof prototype === "object" && prototype !== null && isForeignIntrinsicObjectPrototype(prototype))
  )
}

function protocolError(message: string): CodeModeProtocolError {
  return new CodeModeProtocolError(message)
}

function isProtocolError(cause: unknown): cause is CodeModeProtocolError {
  return intrinsicReflectApply(intrinsicFunctionHasInstance, CodeModeProtocolError, [cause])
}

type SnapshotDestination =
  | { readonly type: "root" }
  | { readonly type: "array"; readonly target: CodeModeJson[]; readonly index: number }
  | { readonly type: "object"; readonly target: Record<string, CodeModeJson>; readonly key: string }

type SnapshotTask =
  | {
      readonly type: "visit"
      readonly value: unknown
      readonly depth: number
      readonly destination: SnapshotDestination
    }
  | { readonly type: "leave"; readonly source: object }

function snapshot(value: unknown): CodeModeJson {
  const active = new IntrinsicSet<object>()
  let root: CodeModeJson | undefined
  let nodes = 0

  const assign = (destination: SnapshotDestination, item: CodeModeJson): void => {
    if (destination.type === "root") {
      root = item
    } else if (destination.type === "array") {
      defineEnumerableDataProperty(destination.target, destination.index, item)
    } else {
      defineEnumerableDataProperty(destination.target, destination.key, item)
    }
  }

  const tasks: SnapshotTask[] = [{ type: "visit", value, depth: 0, destination: { type: "root" } }]
  for (let task = takeLast(tasks); task !== undefined; task = takeLast(tasks)) {
    if (task.type === "leave") {
      setDelete(active, task.source)
      continue
    }

    nodes += 1
    if (nodes > maxCodeModeJsonNodes || task.depth > maxCodeModeJsonDepth) {
      throw protocolError("Code-mode JSON exceeded its structural bound")
    }

    const candidate = task.value
    if (candidate === null) {
      assign(task.destination, null)
      continue
    }
    if (typeof candidate === "boolean" || typeof candidate === "string") {
      assign(task.destination, candidate)
      continue
    }
    if (typeof candidate === "number") {
      if (!intrinsicNumberIsFinite(candidate) || intrinsicObjectIs(candidate, -0)) {
        throw protocolError("Code-mode JSON numbers must be finite and lossless")
      }
      assign(task.destination, candidate)
      continue
    }
    if (typeof candidate !== "object") {
      throw protocolError("Code-mode values must be lossless JSON")
    }
    if (setHas(active, candidate)) throw protocolError("Code-mode JSON must not contain cycles")

    if (intrinsicArrayIsArray(candidate)) {
      if (!hasPlainArrayPrototype(candidate)) throw protocolError("Code-mode JSON arrays must be plain")
      const length = candidate.length
      const ownKeys = intrinsicReflectOwnKeys(candidate)
      if (ownKeys.length !== length + 1 || length > maxCodeModeJsonNodes - nodes) {
        throw protocolError(
          length > maxCodeModeJsonNodes - nodes
            ? "Code-mode JSON exceeded its structural bound"
            : "Code-mode JSON arrays must be dense undecorated data arrays"
        )
      }

      const values: unknown[] = []
      for (let index = 0; index < length; index++) {
        if (!intrinsicObjectHasOwn(candidate, index)) {
          throw protocolError("Code-mode JSON arrays must be dense undecorated data arrays")
        }
        const descriptor = intrinsicObjectGetOwnPropertyDescriptor(candidate, index)
        if (!descriptor || !descriptor.enumerable || !intrinsicObjectHasOwn(descriptor, "value")) {
          throw protocolError("Code-mode JSON arrays must contain only enumerable data elements")
        }
        append(values, descriptor.value)
      }

      const target: CodeModeJson[] = []
      assign(task.destination, target)
      setAdd(active, candidate)
      append(tasks, { type: "leave", source: candidate })
      for (let index = length - 1; index >= 0; index--) {
        append(tasks, {
          type: "visit",
          value: values[index],
          depth: task.depth + 1,
          destination: { type: "array", target, index }
        })
      }
      continue
    }

    if (!hasPlainObjectPrototype(candidate)) throw protocolError("Code-mode JSON objects must be plain")
    const ownKeys = intrinsicReflectOwnKeys(candidate)
    if (ownKeys.length > maxCodeModeJsonNodes - nodes) {
      throw protocolError("Code-mode JSON exceeded its structural bound")
    }
    const entries: { readonly key: string; readonly value: unknown }[] = []
    for (let index = 0; index < ownKeys.length; index++) {
      const key = ownKeys[index]
      if (typeof key !== "string") {
        throw protocolError("Code-mode JSON objects must contain only enumerable string data properties")
      }
      const descriptor = intrinsicObjectGetOwnPropertyDescriptor(candidate, key)
      if (!descriptor || !descriptor.enumerable || !intrinsicObjectHasOwn(descriptor, "value")) {
        throw protocolError("Code-mode JSON objects must contain only enumerable string data properties")
      }
      append(entries, { key, value: descriptor.value })
    }

    const target: Record<string, CodeModeJson> = {}
    assign(task.destination, target)
    setAdd(active, candidate)
    append(tasks, { type: "leave", source: candidate })
    for (let index = entries.length - 1; index >= 0; index--) {
      const entry = entries[index]
      if (!entry) throw protocolError("Code-mode JSON object entry disappeared")
      append(tasks, {
        type: "visit",
        value: entry.value,
        depth: task.depth + 1,
        destination: { type: "object", target, key: entry.key }
      })
    }
  }

  if (root === undefined) throw protocolError("Code-mode values must be lossless JSON")
  return root
}

/** Snapshot one guest value without consulting mutable realm globals or prototypes. */
export function snapshotCodeModeJson(value: unknown): CodeModeJson {
  try {
    return snapshot(value)
  } catch (cause) {
    if (isProtocolError(cause)) throw cause
    throw new CodeModeProtocolError("Code-mode value could not be inspected safely", { cause })
  }
}
