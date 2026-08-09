import { mkdir, writeFile } from "node:fs/promises"
import { dirname } from "node:path"

import type { AgentTool } from "@earendil-works/pi-agent-core"
import { Type } from "@earendil-works/pi-ai"

import { isNonNegativeInteger, isRecord } from "../guards.js"
import { countTextLines } from "./lines.js"
import { withFileMutation } from "./mutation-queue.js"
import { resolveToolPath } from "./path.js"
import { boundToolText, isBoundedToolText } from "./text.js"

const maxWriteBytes = 8 * 1024 * 1024
const maxPathLength = 4_096

const parameters = Type.Object({
  path: Type.String({ maxLength: maxPathLength, description: "Path to the file to write (relative or absolute)" }),
  content: Type.String({ maxLength: maxWriteBytes, description: "Content to write to the file" })
})

export type WriteToolErrorReason = "invalid_path" | "not_file" | "permission_denied" | "too_large" | "unwritable"

export type WriteToolDetails =
  | { readonly outcome: "success"; readonly bytes: number; readonly lines: number }
  | {
      readonly outcome: "error"
      readonly reason: WriteToolErrorReason
      readonly bytes: number
      readonly lines: number
      readonly error: string
    }

export function createWriteTool(cwd: string): AgentTool<typeof parameters, WriteToolDetails> {
  return {
    name: "write",
    label: "write",
    description: "Write content to a file. Creates parent directories and overwrites an existing file.",
    parameters,
    async execute(_id, input, signal) {
      const bytes = Buffer.byteLength(input.content)
      const lines = countWriteLines(input.content)
      if (input.path.includes("\0")) return failure("invalid_path", bytes, lines, "Write path contains a null byte")
      if (bytes > maxWriteBytes) {
        return failure("too_large", bytes, lines, `Write exceeds the ${maxWriteBytes} byte limit`)
      }

      const path = resolveToolPath(input.path, cwd)
      return withFileMutation(path, async () => {
        throwIfAborted(signal)
        try {
          await mkdir(dirname(path), { recursive: true })
          throwIfAborted(signal)
          // A resolved write is the commit point; cancellation cannot truthfully turn it into an aborted mutation.
          await writeFile(path, input.content, "utf8")
        } catch (cause) {
          if (signal?.aborted) throw cause
          if (!isFilesystemError(cause)) throw cause
          return filesystemFailure(input.path, bytes, lines, cause)
        }
        return {
          content: [
            { type: "text", text: `Successfully wrote ${bytes} ${bytes === 1 ? "byte" : "bytes"} to ${input.path}` }
          ],
          details: { outcome: "success", bytes, lines }
        }
      })
    }
  }
}

export function isWriteToolDetails(value: unknown): value is WriteToolDetails {
  if (
    !isRecord(value) ||
    (value.outcome !== "success" && value.outcome !== "error") ||
    !isNonNegativeInteger(value.bytes) ||
    !isNonNegativeInteger(value.lines)
  ) {
    return false
  }
  return value.outcome !== "error" || (isWriteErrorReason(value.reason) && isBoundedToolText(value.error))
}

function filesystemFailure(path: string, bytes: number, lines: number, cause: unknown) {
  const code = filesystemErrorCode(cause)
  if (code === "EISDIR" || code === "ENOTDIR" || code === "EEXIST") {
    return failure("not_file", bytes, lines, `Path is not writable as a file: ${path}`)
  }
  if (code === "EACCES" || code === "EPERM") {
    return failure("permission_denied", bytes, lines, `Permission denied: ${path}`)
  }
  if (code === "EINVAL" || code === "ENAMETOOLONG") {
    return failure("invalid_path", bytes, lines, `Invalid write path: ${path}`)
  }
  return failure("unwritable", bytes, lines, errorMessage(cause))
}

function failure(reason: WriteToolErrorReason, bytes: number, lines: number, message: string) {
  const error = boundToolText(message)
  return {
    content: [{ type: "text" as const, text: error }],
    details: { outcome: "error" as const, reason, bytes, lines, error }
  }
}

export function countWriteLines(content: string): number {
  return countTextLines(content)
}

function isFilesystemError(cause: unknown): boolean {
  return filesystemErrorCode(cause) !== undefined
}

function filesystemErrorCode(cause: unknown): string | undefined {
  return typeof cause === "object" && cause !== null && typeof Reflect.get(cause, "code") === "string"
    ? String(Reflect.get(cause, "code"))
    : undefined
}

function isWriteErrorReason(value: unknown): value is WriteToolErrorReason {
  return (
    value === "invalid_path" ||
    value === "not_file" ||
    value === "permission_denied" ||
    value === "too_large" ||
    value === "unwritable"
  )
}

function errorMessage(cause: unknown): string {
  return cause instanceof Error ? cause.message : String(cause)
}

function throwIfAborted(signal?: AbortSignal): void {
  if (signal?.aborted) throw new Error("Operation aborted")
}
