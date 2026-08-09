import { readFile, stat } from "node:fs/promises"

import type { AgentTool } from "@earendil-works/pi-agent-core"
import { Type } from "@earendil-works/pi-ai"

import { isPositiveInteger, isRecord } from "../guards.js"
import { splitTextLines } from "./lines.js"
import { resolveToolPath } from "./path.js"
import { boundToolText, isBoundedToolText } from "./text.js"
import {
  DEFAULT_MAX_BYTES,
  isTruncationDetails,
  truncateHead,
  truncationDetails,
  type TruncationDetails
} from "./truncate.js"

const maxPathLength = 4_096
const maxReadFileBytes = 16 * 1024 * 1024

const parameters = Type.Object({
  path: Type.String({ maxLength: maxPathLength, description: "Path to the file to read (relative or absolute)" }),
  offset: Type.Optional(Type.Integer({ minimum: 1, description: "Line number to start reading from (1-indexed)" })),
  limit: Type.Optional(Type.Integer({ minimum: 1, description: "Maximum number of lines to read" }))
})

export type ReadToolErrorReason =
  | "not_found"
  | "not_file"
  | "permission_denied"
  | "too_large"
  | "invalid_offset"
  | "unreadable"

export type ReadToolDetails =
  | {
      readonly outcome: "success"
      readonly startLine: number
      readonly endLine: number
      readonly totalLines: number
      readonly nextOffset?: number
      readonly remainingLines?: number
      readonly truncation: TruncationDetails
    }
  | { readonly outcome: "error"; readonly reason: ReadToolErrorReason; readonly error: string }

export function createReadTool(cwd: string): AgentTool<typeof parameters, ReadToolDetails> {
  return {
    name: "read",
    label: "read",
    description:
      "Read text file contents. Output is truncated to 2,000 lines or 50 KiB. Use offset and limit to continue through large files.",
    parameters,
    async execute(_id, input, signal) {
      throwIfAborted(signal)
      const path = resolveToolPath(input.path, cwd)
      let content: string
      try {
        const file = await stat(path)
        if (!file.isFile()) return failure("not_file", `Path is not a file: ${input.path}`)
        if (file.size > maxReadFileBytes) {
          return failure("too_large", `File exceeds the ${maxReadFileBytes} byte read limit`)
        }
        content = await readFile(path, "utf8")
      } catch (cause) {
        if (signal?.aborted) throw cause
        return filesystemFailure(input.path, cause)
      }
      throwIfAborted(signal)

      const lines = splitTextLines(content)
      const start = (input.offset ?? 1) - 1
      if (start >= lines.length) {
        return failure("invalid_offset", `Offset ${input.offset} is beyond end of file (${lines.length} lines total)`)
      }

      const requestedEnd = input.limit === undefined ? lines.length : Math.min(lines.length, start + input.limit)
      const selected = lines.slice(start, requestedEnd).join("\n")
      const truncation = truncateHead(selected)
      const startLine = start + 1
      const endLine = Math.max(startLine, startLine + truncation.outputLines - 1)
      const nextOffset = truncation.firstLineExceedsLimit
        ? undefined
        : truncation.truncated
          ? endLine + 1
          : requestedEnd < lines.length
            ? requestedEnd + 1
            : undefined
      const details: ReadToolDetails = {
        outcome: "success",
        startLine,
        endLine,
        totalLines: lines.length,
        ...(nextOffset === undefined ? {} : { nextOffset, remainingLines: Math.max(0, lines.length - nextOffset + 1) }),
        truncation: truncationDetails(truncation)
      }

      if (truncation.firstLineExceedsLimit) {
        return {
          content: [
            {
              type: "text",
              text: `[Line ${startLine} exceeds the ${DEFAULT_MAX_BYTES} byte limit. Use bash to inspect a bounded byte range.]`
            }
          ],
          details
        }
      }

      let text = truncation.content
      if (nextOffset !== undefined) {
        text += `\n\n[Showing lines ${startLine}-${endLine} of ${lines.length}. Use offset=${nextOffset} to continue.]`
      }
      return { content: [{ type: "text", text }], details }
    }
  }
}

export function isReadToolDetails(value: unknown): value is ReadToolDetails {
  if (!isRecord(value)) return false
  if (value.outcome === "error") return isReadErrorReason(value.reason) && isBoundedString(value.error)
  if (
    value.outcome !== "success" ||
    !isPositiveInteger(value.startLine) ||
    !isPositiveInteger(value.endLine) ||
    value.endLine < value.startLine ||
    !isPositiveInteger(value.totalLines) ||
    value.endLine > value.totalLines ||
    !isTruncationDetails(value.truncation)
  ) {
    return false
  }
  const selectedLines = Math.max(1, value.truncation.outputLines)
  if (value.endLine !== value.startLine + selectedLines - 1) return false
  const continuationExpected = !value.truncation.firstLineExceedsLimit && value.endLine < value.totalLines
  if (value.nextOffset === undefined && value.remainingLines === undefined) return !continuationExpected
  if (!continuationExpected) return false
  return (
    isPositiveInteger(value.nextOffset) &&
    isPositiveInteger(value.remainingLines) &&
    value.nextOffset === value.endLine + 1 &&
    value.nextOffset <= value.totalLines &&
    value.remainingLines === value.totalLines - value.endLine
  )
}

function filesystemFailure(path: string, cause: unknown) {
  const code = filesystemErrorCode(cause)
  if (code === "ENOENT") return failure("not_found", `File not found: ${path}`)
  if (code === "EISDIR" || code === "ENOTDIR") return failure("not_file", `Path is not a file: ${path}`)
  if (code === "EACCES" || code === "EPERM") return failure("permission_denied", `Permission denied: ${path}`)
  return failure("unreadable", cause instanceof Error ? cause.message : String(cause))
}

function failure(reason: ReadToolErrorReason, message: string) {
  const error = boundToolText(message)
  return { content: [{ type: "text" as const, text: error }], details: { outcome: "error" as const, reason, error } }
}

function filesystemErrorCode(cause: unknown): string | undefined {
  return typeof cause === "object" && cause !== null && typeof Reflect.get(cause, "code") === "string"
    ? String(Reflect.get(cause, "code"))
    : undefined
}

function isReadErrorReason(value: unknown): value is ReadToolErrorReason {
  return (
    value === "not_found" ||
    value === "not_file" ||
    value === "permission_denied" ||
    value === "too_large" ||
    value === "invalid_offset" ||
    value === "unreadable"
  )
}

function throwIfAborted(signal?: AbortSignal): void {
  if (signal?.aborted) throw new Error("Operation aborted")
}

function isBoundedString(value: unknown): value is string {
  return isBoundedToolText(value)
}
