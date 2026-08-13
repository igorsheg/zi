// Adapted from DeepSeek Harness output-json.ts and OutputLedger at commit 47f943859bef60e4160492346772ded9b24f765a (MIT).

/* oxlint-disable typescript/unbound-method -- captured methods are invoked with captured Reflect.apply */

import { CodeModeProtocolError, type CodeModeJson } from "./protocol.js"

const intrinsicReflectApply = Reflect.apply
const intrinsicArrayIsArray = Array.isArray
const IntrinsicBuffer = Buffer
const intrinsicBufferByteLength = Buffer.byteLength
const intrinsicNumberIsSafeInteger = Number.isSafeInteger
const intrinsicObjectDefineProperty = Object.defineProperty
const intrinsicObjectKeys = Object.keys
const intrinsicString = String
const intrinsicStringCharCodeAt = String.prototype.charCodeAt
const intrinsicStringCodePointAt = String.prototype.codePointAt
const intrinsicStringSlice = String.prototype.slice

/* oxlint-enable typescript/unbound-method */

export type CodeModeTerminalOutput =
  | { readonly type: "result"; readonly result?: CodeModeJson }
  | { readonly type: "error"; readonly error: string }

export type BoundedCodeModeOutput =
  | { readonly type: "result"; readonly logs: readonly string[]; readonly result?: CodeModeJson }
  | { readonly type: "error"; readonly logs: readonly string[]; readonly error: string }
  | { readonly type: "output-limit"; readonly logs: readonly string[]; readonly error: string }

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

function byteLength(text: string): number {
  return intrinsicReflectApply(intrinsicBufferByteLength, IntrinsicBuffer, [text, "utf8"])
}

function characterAt(text: string, index: number): string {
  const codePoint = intrinsicReflectApply(intrinsicStringCodePointAt, text, [index])
  if (codePoint === undefined) throw new CodeModeProtocolError("Code-mode output character disappeared")
  const width = codePoint > 0xffff ? 2 : 1
  return intrinsicReflectApply(intrinsicStringSlice, text, [index, index + width])
}

function serializedCharacterBytes(character: string): number {
  if (character.length === 2) return 4
  if (character === '"' || character === "\\") return 2
  const code = intrinsicReflectApply(intrinsicStringCharCodeAt, character, [0])
  if (code >= 0xd800 && code <= 0xdfff) return 6
  if (code < 0x20) {
    return code === 0x08 || code === 0x09 || code === 0x0a || code === 0x0c || code === 0x0d ? 2 : 6
  }
  return byteLength(character)
}

function jsonStringBytesUpTo(text: string, maxBytes: number): number | undefined {
  if (maxBytes < 2) return undefined
  let bytes = 2
  for (let index = 0; index < text.length;) {
    const character = characterAt(text, index)
    bytes += serializedCharacterBytes(character)
    if (bytes > maxBytes) return undefined
    index += character.length
  }
  return bytes
}

function truncateJsonStringBytes(text: string, maxBytes: number): string {
  if (maxBytes < 2) return ""
  let bytes = 2
  let end = 0
  for (let index = 0; index < text.length;) {
    const character = characterAt(text, index)
    const cost = serializedCharacterBytes(character)
    if (bytes + cost > maxBytes) break
    bytes += cost
    end += character.length
    index += character.length
  }
  return end === text.length ? text : intrinsicReflectApply(intrinsicStringSlice, text, [0, end])
}

type JsonByteTask =
  | { readonly type: "value"; readonly value: CodeModeJson }
  | { readonly type: "array"; readonly value: readonly CodeModeJson[]; readonly index: number }
  | {
      readonly type: "object"
      readonly value: Readonly<Record<string, CodeModeJson>>
      readonly keys: readonly string[]
      readonly index: number
    }

function isJsonArray(value: CodeModeJson): value is readonly CodeModeJson[] {
  return intrinsicArrayIsArray(value)
}

function jsonValueBytesUpTo(value: CodeModeJson, maxBytes: number): number | undefined {
  let bytes = 0
  const add = (cost: number): boolean => {
    bytes += cost
    return bytes <= maxBytes
  }
  const tasks: JsonByteTask[] = [{ type: "value", value }]
  for (let task = takeLast(tasks); task !== undefined; task = takeLast(tasks)) {
    if (task.type === "value") {
      const current = task.value
      if (current === null) {
        if (!add(4)) return undefined
      } else if (typeof current === "string") {
        const stringBytes = jsonStringBytesUpTo(current, maxBytes - bytes)
        if (stringBytes === undefined) return undefined
        bytes += stringBytes
      } else if (typeof current === "number") {
        if (!add(byteLength(intrinsicString(current)))) return undefined
      } else if (typeof current === "boolean") {
        if (!add(current ? 4 : 5)) return undefined
      } else if (isJsonArray(current)) {
        if (!add(2)) return undefined
        if (current.length > 0) append(tasks, { type: "array", value: current, index: 0 })
      } else {
        if (!add(2)) return undefined
        const keys = intrinsicObjectKeys(current)
        if (keys.length > 0) append(tasks, { type: "object", value: current, keys, index: 0 })
      }
      continue
    }

    if (task.index > 0 && !add(1)) return undefined
    if (task.type === "array") {
      const item = task.value[task.index]
      if (item === undefined) return undefined
      if (task.index + 1 < task.value.length) {
        append(tasks, { type: "array", value: task.value, index: task.index + 1 })
      }
      append(tasks, { type: "value", value: item })
      continue
    }

    const key = task.keys[task.index]
    if (key === undefined) return undefined
    const keyBytes = jsonStringBytesUpTo(key, maxBytes - bytes)
    if (keyBytes === undefined || !add(keyBytes + 1)) return undefined
    const item = task.value[key]
    if (item === undefined) return undefined
    if (task.index + 1 < task.keys.length) {
      append(tasks, { type: "object", value: task.value, keys: task.keys, index: task.index + 1 })
    }
    append(tasks, { type: "value", value: item })
  }
  return bytes
}

function copyLogsUpTo(
  logs: readonly string[],
  maxBytes: number
): { readonly logs: readonly string[]; readonly bytes: number } | undefined {
  const copied: string[] = []
  let bytes = 2
  for (let index = 0; index < logs.length; index++) {
    const separatorBytes = index > 0 ? 1 : 0
    const text = logs[index]
    if (text === undefined) return undefined
    const stringBytes = jsonStringBytesUpTo(text, maxBytes - bytes - separatorBytes)
    if (stringBytes === undefined) return undefined
    append(copied, text)
    bytes += stringBytes + separatorBytes
  }
  return { logs: copied, bytes }
}

function outputLimit(maxBytes: number, logs: readonly string[]): BoundedCodeModeOutput {
  const fullError = `Code-mode output exceeded ${maxBytes} bytes`
  const fullErrorBytes = fullError.length + 2
  const retained: string[] = []
  let retainedBytes = 2
  const logBudget = maxBytes - fullErrorBytes

  for (let index = 0; index < logs.length; index++) {
    const text = logs[index]
    if (text === undefined) break
    const separatorBytes = retained.length > 0 ? 1 : 0
    const availableBytes = logBudget - retainedBytes - separatorBytes
    const stringBytes = jsonStringBytesUpTo(text, availableBytes)
    if (stringBytes !== undefined) {
      append(retained, text)
      retainedBytes += stringBytes + separatorBytes
      continue
    }
    const prefix = truncateJsonStringBytes(text, availableBytes)
    if (prefix.length > 0) {
      const prefixBytes = jsonStringBytesUpTo(prefix, availableBytes)
      if (prefixBytes === undefined) throw new CodeModeProtocolError("Code-mode output prefix exceeded its budget")
      append(retained, prefix)
      retainedBytes += prefixBytes + separatorBytes
    }
    break
  }

  const error = truncateJsonStringBytes(fullError, maxBytes - retainedBytes)
  return { type: "output-limit", logs: retained, error }
}

/** Bound the combined JSON serialization of logs and one terminal result or error. */
export function boundCodeModeOutput(
  maxBytes: number,
  logs: readonly string[],
  terminal: Extract<CodeModeTerminalOutput, { type: "result" }>
): Extract<BoundedCodeModeOutput, { type: "result" | "output-limit" }>
export function boundCodeModeOutput(
  maxBytes: number,
  logs: readonly string[],
  terminal: Extract<CodeModeTerminalOutput, { type: "error" }>
): Extract<BoundedCodeModeOutput, { type: "error" | "output-limit" }>
export function boundCodeModeOutput(
  maxBytes: number,
  logs: readonly string[],
  terminal: CodeModeTerminalOutput
): BoundedCodeModeOutput {
  if (!intrinsicNumberIsSafeInteger(maxBytes) || maxBytes < 4) {
    throw new CodeModeProtocolError("Code-mode output limit must be a safe integer of at least 4 bytes")
  }

  const copied = copyLogsUpTo(logs, maxBytes)
  if (copied === undefined) return outputLimit(maxBytes, logs)
  const remainingBytes = maxBytes - copied.bytes

  if (terminal.type === "result") {
    if (terminal.result === undefined) return { type: "result", logs: copied.logs }
    if (jsonValueBytesUpTo(terminal.result, remainingBytes) === undefined) return outputLimit(maxBytes, logs)
    return { type: "result", logs: copied.logs, result: terminal.result }
  }
  if (jsonStringBytesUpTo(terminal.error, remainingBytes) === undefined) return outputLimit(maxBytes, logs)
  return { type: "error", logs: copied.logs, error: terminal.error }
}
