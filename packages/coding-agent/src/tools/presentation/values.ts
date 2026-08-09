import { isRecord } from "../../guards.js"
import { DEFAULT_MAX_BYTES, truncateHead, truncateTail } from "../truncate.js"
import { maxToolInlineScalars } from "./types.js"

export function normalizeToolText(value: string): string {
  return stripAnsi(value)
    .replace(/\r\n?/g, "\n")
    .split("")
    .filter(character => isSafeCharacter(character.charCodeAt(0)))
    .join("")
}

export function boundInline(value: string, limit = maxToolInlineScalars): string {
  return boundScalars(normalizeToolText(value).replace(/\s*\n\s*/g, " "), limit)
}

export function boundCommand(value: string): string {
  return boundScalars(normalizeToolText(value), maxToolInlineScalars)
}

export function boundHead(value: string): string {
  return truncateHead(normalizeToolText(value)).content
}

export function boundTail(value: string): string {
  return truncateTail(normalizeToolText(value)).content
}

const maxResultTextBytes = DEFAULT_MAX_BYTES + 24 * 1024
const maxResultTextParts = 32

export function resultText(result: unknown): string | undefined {
  if (typeof result === "string") return utf8Head(result, maxResultTextBytes)
  if (!isRecord(result) || !Array.isArray(result.content)) return undefined

  const output: string[] = []
  let bytes = 0
  for (let index = 0; index < result.content.length && index < maxResultTextParts; index++) {
    const part = result.content[index]
    if (!isRecord(part) || part.type !== "text" || typeof part.text !== "string" || !part.text) continue
    const separator = output.length === 0 ? 0 : 1
    const remaining = maxResultTextBytes - bytes - separator
    if (remaining <= 0) break
    const bounded = utf8Head(part.text, remaining)
    if (separator) {
      output.push("\n")
      bytes++
    }
    output.push(bounded)
    bytes += Buffer.byteLength(bounded)
    if (bounded !== part.text) break
  }
  return output.length > 0 ? output.join("") : undefined
}

export function resultDetails(result: unknown): unknown {
  return isRecord(result) ? result.details : undefined
}

export function isPartialSource(source: { readonly status: string }): boolean {
  return source.status === "preparing" || source.status === "ready"
}

export function isTerminalSource(source: { readonly status: string }): boolean {
  return source.status === "done" || source.status === "failed" || source.status === "aborted"
}

export function matchesToolOutcome(
  source: { readonly status: string },
  outcome: "progress" | "success" | "error"
): boolean {
  switch (source.status) {
    case "running":
      return outcome === "progress"
    case "done":
      return outcome === "success"
    case "failed":
      return outcome === "error"
    case "preparing":
    case "ready":
    case "aborted":
      return false
    default:
      return false
  }
}

export function recordValue(value: unknown): Record<string, unknown> | undefined {
  return isRecord(value) ? value : undefined
}

export function stringValue(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined
}

export function booleanValue(value: unknown): boolean | undefined {
  return typeof value === "boolean" ? value : undefined
}

export function numberValue(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined
}

export function integerValue(value: unknown): number | undefined {
  return typeof value === "number" && Number.isSafeInteger(value) ? value : undefined
}

export function utf8Prefix(value: string, maxBytes: number): string {
  return utf8Head(value, maxBytes)
}

export function formatBytes(bytes: number): string {
  if (bytes === 1) return "1 byte"
  if (bytes >= 1024 * 1024 && bytes % (1024 * 1024) === 0) return `${bytes / (1024 * 1024)} MiB`
  if (bytes >= 1024 && bytes % 1024 === 0) return `${bytes / 1024} KiB`
  return `${bytes} bytes`
}

export function assertNever(value: never): never {
  throw new Error(`Unexpected tool presentation value: ${String(value)}`)
}

function boundScalars(value: string, limit: number): string {
  const scalars = Array.from(value)
  return scalars.length <= limit ? value : `${scalars.slice(0, limit - 1).join("")}…`
}

function stripAnsi(value: string): string {
  let output = ""
  for (let index = 0; index < value.length; index++) {
    const code = value.charCodeAt(index)
    if (code === 0x1b) {
      const introducer = value.charCodeAt(index + 1)
      if (introducer === 0x5b) index = skipCsi(value, index + 2)
      else if (introducer === 0x5d) index = skipStringSequence(value, index + 2, true)
      else if (introducer === 0x50 || introducer === 0x58 || introducer === 0x5e || introducer === 0x5f) {
        index = skipStringSequence(value, index + 2, false)
      } else if (index + 1 < value.length) {
        index++
      }
      continue
    }
    if (code === 0x9b) {
      index = skipCsi(value, index + 1)
      continue
    }
    output += value[index]
  }
  return output
}

function skipCsi(value: string, start: number): number {
  for (let index = start; index < value.length; index++) {
    const code = value.charCodeAt(index)
    if (code >= 0x40 && code <= 0x7e) return index
  }
  return value.length - 1
}

function skipStringSequence(value: string, start: number, acceptsBell: boolean): number {
  for (let index = start; index < value.length; index++) {
    const code = value.charCodeAt(index)
    if (acceptsBell && code === 0x07) return index
    if (code === 0x1b && value.charCodeAt(index + 1) === 0x5c) return index + 1
  }
  return value.length - 1
}

function isSafeCharacter(code: number): boolean {
  return code === 0x09 || code === 0x0a || (code >= 0x20 && (code < 0x7f || code > 0x9f))
}

function utf8Head(value: string, maxBytes: number): string {
  const output: string[] = []
  let bytes = 0
  for (const scalar of value) {
    const scalarBytes = utf8ScalarBytes(scalar)
    if (bytes + scalarBytes > maxBytes) break
    output.push(scalar)
    bytes += scalarBytes
  }
  return output.join("")
}

function utf8ScalarBytes(scalar: string): number {
  const code = scalar.codePointAt(0) ?? 0
  if (code <= 0x7f) return 1
  if (code <= 0x7ff) return 2
  return code <= 0xffff ? 3 : 4
}
