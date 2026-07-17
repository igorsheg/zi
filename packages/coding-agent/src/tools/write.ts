import { mkdir, writeFile } from "node:fs/promises"
import { dirname } from "node:path"

import type { AgentTool } from "@earendil-works/pi-agent-core"
import { Type } from "@earendil-works/pi-ai"

import { withFileMutation } from "./mutation-queue.js"
import { resolveToolPath } from "./path.js"
import { boundToolText, isBoundedToolText } from "./text.js"

const maxWriteBytes = 8 * 1024 * 1024
const maxPathLength = 4_096

const parameters = Type.Object({
  path: Type.String({ maxLength: maxPathLength, description: "Path to the file to write (relative or absolute)" }),
  content: Type.String({ maxLength: maxWriteBytes, description: "Content to write to the file" })
})

export type WriteToolDetails =
  | { readonly outcome: "success"; readonly bytes: number; readonly lines: number }
  | { readonly outcome: "error"; readonly bytes: number; readonly lines: number; readonly error: string }

export function createWriteTool(cwd: string): AgentTool<typeof parameters, WriteToolDetails> {
  return {
    name: "write",
    label: "write",
    description: "Write content to a file. Creates parent directories and overwrites an existing file.",
    parameters,
    async execute(_id, input, signal) {
      const path = resolveToolPath(input.path, cwd)
      const bytes = Buffer.byteLength(input.content)
      const lines = logicalLines(input.content)
      if (bytes > maxWriteBytes) {
        return failure(bytes, lines, `Write exceeds the ${maxWriteBytes} byte limit`)
      }

      return withFileMutation(path, async () => {
        throwIfAborted(signal)
        try {
          await mkdir(dirname(path), { recursive: true })
          throwIfAborted(signal)
          await writeFile(path, input.content, "utf8")
        } catch (cause) {
          if (signal?.aborted) throw cause
          if (!isFilesystemError(cause)) throw cause
          return failure(bytes, lines, errorMessage(cause))
        }
        throwIfAborted(signal)
        return {
          content: [{ type: "text", text: `Successfully wrote ${bytes} bytes to ${input.path}` }],
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
  return value.outcome !== "error" || isBoundedToolText(value.error)
}

function failure(bytes: number, lines: number, message: string) {
  const error = boundToolText(message)
  return {
    content: [{ type: "text" as const, text: error }],
    details: { outcome: "error" as const, bytes, lines, error }
  }
}

function logicalLines(content: string): number {
  if (!content) return 0
  let lines = 1
  for (const character of content) if (character === "\n") lines++
  return lines
}

function isFilesystemError(cause: unknown): boolean {
  return typeof cause === "object" && cause !== null && typeof Reflect.get(cause, "code") === "string"
}

function errorMessage(cause: unknown): string {
  return cause instanceof Error ? cause.message : String(cause)
}

function throwIfAborted(signal?: AbortSignal): void {
  if (signal?.aborted) throw new Error("Operation aborted")
}

function isNonNegativeInteger(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}
