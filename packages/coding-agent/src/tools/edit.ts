import { access, readFile, stat, writeFile } from "node:fs/promises"

import type { AgentTool } from "@earendil-works/pi-agent-core"
import { Type } from "@earendil-works/pi-ai"

import { withFileMutation } from "./mutation-queue.js"
import { resolveToolPath } from "./path.js"
import { boundToolText, isBoundedToolText } from "./text.js"
import { truncateHead } from "./truncate.js"

const maxEditChanges = 64
const maxEditArgumentBytes = 8 * 1024 * 1024
// JSON Schema cannot express an aggregate string-byte limit. This per-field cap keeps every schema-valid batch
// below the execution bound even when every admitted Unicode scalar occupies four UTF-8 bytes.
const maxEditTextLength = Math.floor(maxEditArgumentBytes / (maxEditChanges * 2 * 4))
const maxEditedFileBytes = 16 * 1024 * 1024
const maxPathLength = 4_096

const replacement = Type.Object({
  oldText: Type.String({
    maxLength: maxEditTextLength,
    description: "Exact, unique text to replace in the original file"
  }),
  newText: Type.String({ maxLength: maxEditTextLength, description: "Replacement text" })
})

const parameters = Type.Object({
  path: Type.String({ maxLength: maxPathLength, description: "Path to the file to edit (relative or absolute)" }),
  edits: Type.Array(replacement, { minItems: 1, maxItems: maxEditChanges, description: "Non-overlapping replacements" })
})

export type EditToolDetails =
  | {
      readonly outcome: "success"
      readonly replacements: number
      readonly diff: string
      readonly diffTruncated: boolean
      readonly firstChangedLine?: number
    }
  | { readonly outcome: "error"; readonly replacements: number; readonly error: string }

export function createEditTool(cwd: string): AgentTool<typeof parameters, EditToolDetails> {
  return {
    name: "edit",
    label: "edit",
    description:
      "Edit one file with exact text replacements. Every oldText must be unique in the original file and replacements must not overlap.",
    parameters,
    async execute(_id, input, signal) {
      const argumentBytes = input.edits.reduce(
        (bytes, edit) => bytes + Buffer.byteLength(edit.oldText) + Buffer.byteLength(edit.newText),
        0
      )
      if (argumentBytes > maxEditArgumentBytes) {
        return failure(0, `Edit arguments exceed the ${maxEditArgumentBytes} byte limit`)
      }
      const path = resolveToolPath(input.path, cwd)
      return withFileMutation(path, async () => {
        throwIfAborted(signal)
        let raw: string
        try {
          await access(path)
          const file = await stat(path)
          if (file.size > maxEditedFileBytes)
            return failure(0, `File exceeds the ${maxEditedFileBytes} byte edit limit`)
          raw = await readFile(path, "utf8")
        } catch (cause) {
          if (signal?.aborted) throw cause
          if (!isFilesystemError(cause)) throw cause
          return failure(0, errorMessage(cause))
        }
        throwIfAborted(signal)

        const bom = raw.startsWith("\uFEFF") ? "\uFEFF" : ""
        const source = normalize(raw.slice(bom.length))
        const edits = input.edits.map(edit => ({ oldText: normalize(edit.oldText), newText: normalize(edit.newText) }))
        let ordered: OrderedEdit[]
        try {
          const matches = edits.map((edit, index) => match(source, edit.oldText, input.path, index, edits.length))
          ordered = matches
            .map((item, index) => ({
              start: item.start,
              end: item.end,
              oldText: edits[index]!.oldText,
              newText: edits[index]!.newText
            }))
            .toSorted((a, b) => a.start - b.start)

          for (let index = 1; index < ordered.length; index++) {
            const previous = ordered[index - 1]!
            const current = ordered[index]!
            if (previous.end > current.start) throw new EditFailure(`Overlapping edits in ${input.path}`)
          }
        } catch (cause) {
          if (cause instanceof EditFailure) return failure(0, cause.message)
          throw cause
        }

        let output = source
        for (const edit of ordered.toReversed()) {
          output = output.slice(0, edit.start) + edit.newText + output.slice(edit.end)
        }
        if (output === source) return failure(0, `Edit produced no change in ${input.path}`)
        const renderedDiff = truncateHead(renderEditDiff(source, ordered, input.path))
        const firstChangedLine = lineAtOffset(source, ordered[0]!.start)

        const lineEnding = raw.includes("\r\n") ? "\r\n" : "\n"
        try {
          await writeFile(path, bom + (lineEnding === "\r\n" ? output.replace(/\n/g, "\r\n") : output), "utf8")
        } catch (cause) {
          if (signal?.aborted) throw cause
          if (!isFilesystemError(cause)) throw cause
          return failure(0, errorMessage(cause))
        }
        throwIfAborted(signal)
        return {
          content: [{ type: "text", text: `Successfully replaced ${edits.length} block(s) in ${input.path}` }],
          details: {
            outcome: "success",
            replacements: edits.length,
            diff: renderedDiff.content,
            diffTruncated: renderedDiff.truncated,
            firstChangedLine
          }
        }
      })
    }
  }
}

export function isEditToolDetails(value: unknown): value is EditToolDetails {
  if (!isRecord(value) || !isNonNegativeInteger(value.replacements) || value.replacements > maxEditChanges) {
    return false
  }
  if (value.outcome === "error") return isBoundedToolText(value.error)
  return (
    value.outcome === "success" &&
    value.replacements > 0 &&
    typeof value.diff === "string" &&
    Buffer.byteLength(value.diff) <= 50 * 1024 &&
    diffLines(value.diff).length <= 2_000 &&
    typeof value.diffTruncated === "boolean" &&
    (value.firstChangedLine === undefined || isPositiveInteger(value.firstChangedLine))
  )
}

type OrderedEdit = { readonly start: number; readonly end: number; readonly oldText: string; readonly newText: string }

class EditFailure extends Error {}

function failure(replacements: number, message: string) {
  const error = boundToolText(message)
  return {
    content: [{ type: "text" as const, text: error }],
    details: { outcome: "error" as const, replacements, error }
  }
}

function match(source: string, text: string, path: string, index: number, count: number) {
  if (!text) throw new EditFailure(`edits[${index}].oldText must not be empty`)
  const start = source.indexOf(text)
  const label = count === 1 ? "oldText" : `edits[${index}].oldText`
  if (start < 0) throw new EditFailure(`Could not find ${label} in ${path}`)
  if (source.indexOf(text, start + text.length) >= 0) throw new EditFailure(`${label} is not unique in ${path}`)
  return { start, end: start + text.length }
}

function normalize(text: string): string {
  return text.replace(/\r\n?/g, "\n")
}

function renderEditDiff(source: string, edits: readonly OrderedEdit[], path: string): string {
  const hunks: string[] = [`--- a/${path}`, `+++ b/${path}`]
  let sourceOffset = 0
  let sourceLine = 1
  let lineShift = 0
  for (const edit of edits) {
    for (let index = sourceOffset; index < edit.start; index++) {
      if (source.charCodeAt(index) === 10) sourceLine++
    }
    sourceOffset = edit.start
    const oldStart = sourceLine
    const oldLines = diffLines(edit.oldText)
    const newLines = diffLines(edit.newText)
    const newStart = oldStart + lineShift
    hunks.push(`@@ -${oldStart},${oldLines.length} +${newStart},${newLines.length} @@`)
    hunks.push(...oldLines.map(line => `-${line}`), ...newLines.map(line => `+${line}`))
    lineShift += newLines.length - oldLines.length
  }
  return hunks.join("\n")
}

function diffLines(text: string): string[] {
  return text ? text.split("\n") : []
}

function lineAtOffset(source: string, offset: number): number {
  let line = 1
  for (let index = 0; index < offset; index++) if (source.charCodeAt(index) === 10) line++
  return line
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

function isPositiveInteger(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value > 0
}

function isNonNegativeInteger(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}
