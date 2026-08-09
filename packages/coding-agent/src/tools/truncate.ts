import { isNonNegativeInteger, isRecord } from "../guards.js"
import { countTextLines, splitTextLines } from "./lines.js"

export const DEFAULT_MAX_LINES = 2_000
export const DEFAULT_MAX_BYTES = 50 * 1024

export interface TruncationResult {
  content: string
  truncated: boolean
  truncatedBy: "lines" | "bytes" | null
  totalLines: number
  totalBytes: number
  outputLines: number
  outputBytes: number
  firstLineExceedsLimit: boolean
  lastLinePartial: boolean
}

export type TruncationDetails = Omit<TruncationResult, "content">

export function truncationDetails(truncation: TruncationResult): TruncationDetails {
  const { content: _content, ...details } = truncation
  return details
}

export function isTruncationDetails(value: unknown): value is TruncationDetails {
  if (
    !isRecord(value) ||
    typeof value.truncated !== "boolean" ||
    (value.truncatedBy !== "lines" && value.truncatedBy !== "bytes" && value.truncatedBy !== null) ||
    !isNonNegativeInteger(value.totalLines) ||
    !isNonNegativeInteger(value.totalBytes) ||
    !isNonNegativeInteger(value.outputLines) ||
    !isNonNegativeInteger(value.outputBytes) ||
    value.outputLines > value.totalLines ||
    value.outputBytes > value.totalBytes ||
    typeof value.firstLineExceedsLimit !== "boolean" ||
    typeof value.lastLinePartial !== "boolean" ||
    (value.firstLineExceedsLimit && value.lastLinePartial)
  ) {
    return false
  }

  if (!value.truncated) {
    return (
      value.truncatedBy === null &&
      !value.firstLineExceedsLimit &&
      !value.lastLinePartial &&
      value.outputBytes === value.totalBytes &&
      (value.totalBytes === 0 ? value.outputLines === 0 : value.outputLines === value.totalLines)
    )
  }
  if (value.truncatedBy === null) return false
  if (value.firstLineExceedsLimit) {
    return value.truncatedBy === "bytes" && value.outputLines === 0 && value.outputBytes === 0
  }
  if (value.lastLinePartial) return value.truncatedBy === "bytes" && value.outputLines === 1
  return value.outputLines < value.totalLines || value.outputBytes < value.totalBytes
}

export function truncateHead(
  content: string,
  maxLines = DEFAULT_MAX_LINES,
  maxBytes = DEFAULT_MAX_BYTES
): TruncationResult {
  const lines = splitTextLines(content)
  const totalLines = countTextLines(content)
  const totalBytes = Buffer.byteLength(content)
  if (totalLines <= maxLines && totalBytes <= maxBytes) return result(content, false, null, totalLines, totalBytes)

  const output: string[] = []
  let bytes = 0
  let truncatedBy: "lines" | "bytes" = totalLines > maxLines ? "lines" : "bytes"
  for (const line of lines.slice(0, maxLines)) {
    const lineBytes = Buffer.byteLength(line) + (output.length > 0 ? 1 : 0)
    if (bytes + lineBytes > maxBytes) {
      truncatedBy = "bytes"
      break
    }
    output.push(line)
    bytes += lineBytes
  }

  const text = output.join("\n")
  return { ...result(text, true, truncatedBy, totalLines, totalBytes), firstLineExceedsLimit: output.length === 0 }
}

export function truncateTail(
  content: string,
  maxLines = DEFAULT_MAX_LINES,
  maxBytes = DEFAULT_MAX_BYTES
): TruncationResult {
  const lines = splitTextLines(content)
  const totalLines = countTextLines(content)
  const totalBytes = Buffer.byteLength(content)
  if (totalLines <= maxLines && totalBytes <= maxBytes) return result(content, false, null, totalLines, totalBytes)

  const output: string[] = []
  let bytes = 0
  let truncatedBy: "lines" | "bytes" = totalLines > maxLines ? "lines" : "bytes"
  let lastLinePartial = false
  for (let index = lines.length - 1; index >= 0 && output.length < maxLines; index--) {
    const line = lines[index] ?? ""
    const lineBytes = Buffer.byteLength(line) + (output.length > 0 ? 1 : 0)
    if (bytes + lineBytes > maxBytes) {
      truncatedBy = "bytes"
      if (output.length === 0) {
        output.unshift(tailBytes(line, maxBytes))
        lastLinePartial = true
      }
      break
    }
    output.unshift(line)
    bytes += lineBytes
  }

  return { ...result(output.join("\n"), true, truncatedBy, totalLines, totalBytes), lastLinePartial }
}

function result(
  content: string,
  truncated: boolean,
  truncatedBy: TruncationResult["truncatedBy"],
  totalLines: number,
  totalBytes: number
): TruncationResult {
  return {
    content,
    truncated,
    truncatedBy,
    totalLines,
    totalBytes,
    outputLines: countTextLines(content),
    outputBytes: Buffer.byteLength(content),
    firstLineExceedsLimit: false,
    lastLinePartial: false
  }
}

function tailBytes(text: string, maxBytes: number): string {
  const buffer = Buffer.from(text)
  let start = Math.max(0, buffer.length - maxBytes)
  while (start < buffer.length && (buffer[start]! & 0xc0) === 0x80) start++
  return buffer.subarray(start).toString()
}
