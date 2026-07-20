import { readFile, stat, writeFile } from "node:fs/promises"

import type { AgentTool } from "@earendil-works/pi-agent-core"
import { Type } from "@earendil-works/pi-ai"
import { FILE_HEADERS_ONLY, formatPatch, structuredPatch, type StructuredPatch } from "diff"

import { withFileMutation } from "./mutation-queue.js"
import { resolveToolPath } from "./path.js"
import { boundToolText, isBoundedToolText } from "./text.js"
import { truncateHead } from "./truncate.js"

export const maxEditChanges = 64
const maxEditArgumentBytes = 8 * 1024 * 1024
// JSON Schema cannot express an aggregate string-byte limit. This per-field cap keeps every schema-valid batch
// below the execution bound even when every admitted Unicode scalar occupies four UTF-8 bytes.
const maxEditTextLength = Math.floor(maxEditArgumentBytes / (maxEditChanges * 2 * 4))
const maxEditedFileBytes = 16 * 1024 * 1024
// Diff complexity cannot turn an already-valid exact replacement into a failed edit; the bounded fallback uses admitted spans.
const maxDiffEditLength = 20_000
const maxDiffLineBytes = 8 * 1024
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

export type EditToolErrorReason =
  | "invalid_path"
  | "not_found"
  | "not_file"
  | "permission_denied"
  | "too_large"
  | "invalid_edit"
  | "match_missing"
  | "match_ambiguous"
  | "overlap"
  | "no_change"
  | "unreadable"
  | "unwritable"

export type EditToolDetails =
  | {
      readonly outcome: "success"
      readonly replacements: number
      readonly additions: number
      readonly deletions: number
      readonly diff: string
      readonly diffTruncated: boolean
      readonly firstChangedLine: number
    }
  | { readonly outcome: "error"; readonly reason: EditToolErrorReason; readonly error: string }

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
        return failure("too_large", `Edit arguments exceed the ${maxEditArgumentBytes} byte limit`)
      }
      if (input.path.includes("\0")) return failure("invalid_path", "Edit path contains a null byte")

      const path = resolveToolPath(input.path, cwd)
      return withFileMutation(path, async () => {
        throwIfAborted(signal)
        let raw: string
        try {
          const file = await stat(path)
          if (!file.isFile()) return failure("not_file", `Path is not a file: ${input.path}`)
          if (file.size > maxEditedFileBytes) {
            return failure("too_large", `File exceeds the ${maxEditedFileBytes} byte edit limit`)
          }
          raw = await readFile(path, "utf8")
        } catch (cause) {
          if (signal?.aborted) throw cause
          if (!isFilesystemError(cause)) throw cause
          return filesystemFailure(input.path, "read", cause)
        }
        throwIfAborted(signal)

        const bom = raw.startsWith("\uFEFF") ? "\uFEFF" : ""
        const source = normalize(raw.slice(bom.length))
        const edits = input.edits.map(edit => ({ oldText: normalize(edit.oldText), newText: normalize(edit.newText) }))
        let ordered: OrderedEdit[]
        try {
          ordered = edits
            .map((edit, index) => {
              const found = match(source, edit.oldText, input.path, index, edits.length)
              return { start: found.start, end: found.end, oldText: edit.oldText, newText: edit.newText }
            })
            .toSorted((a, b) => a.start - b.start)

          for (let index = 1; index < ordered.length; index++) {
            const previous = ordered[index - 1]!
            const current = ordered[index]!
            if (previous.end > current.start) {
              throw new EditFailure("overlap", `Overlapping edits in ${input.path}`)
            }
          }
        } catch (cause) {
          if (cause instanceof EditFailure) return failure(cause.reason, cause.message)
          throw cause
        }

        let output = source
        for (const edit of ordered.toReversed()) {
          output = output.slice(0, edit.start) + edit.newText + output.slice(edit.end)
        }
        if (output === source) return failure("no_change", `Edit produced no change in ${input.path}`)

        const diff = renderEditDiff(source, output, ordered, input.path)
        const boundedDiff = boundDiffLines(diff.text)
        const renderedDiff = truncateHead(boundedDiff.text)
        const lineEnding = raw.includes("\r\n") ? "\r\n" : "\n"
        try {
          // A resolved write is the commit point; cancellation cannot truthfully turn it into an aborted mutation.
          await writeFile(path, bom + (lineEnding === "\r\n" ? output.replace(/\n/g, "\r\n") : output), "utf8")
        } catch (cause) {
          if (signal?.aborted) throw cause
          if (!isFilesystemError(cause)) throw cause
          return filesystemFailure(input.path, "write", cause)
        }
        const replacementLabel = edits.length === 1 ? "block" : "blocks"
        return {
          content: [
            { type: "text", text: `Successfully replaced ${edits.length} ${replacementLabel} in ${input.path}` }
          ],
          details: {
            outcome: "success",
            replacements: edits.length,
            additions: diff.additions,
            deletions: diff.deletions,
            diff: renderedDiff.content,
            diffTruncated: boundedDiff.truncated || renderedDiff.truncated,
            firstChangedLine: diff.firstChangedLine
          }
        }
      })
    }
  }
}

export function isEditToolDetails(value: unknown): value is EditToolDetails {
  if (!isRecord(value)) return false
  if (value.outcome === "error") return isEditErrorReason(value.reason) && isBoundedToolText(value.error)
  if (
    value.outcome !== "success" ||
    !isPositiveInteger(value.replacements) ||
    value.replacements > maxEditChanges ||
    !isNonNegativeInteger(value.additions) ||
    !isNonNegativeInteger(value.deletions) ||
    value.additions + value.deletions === 0 ||
    typeof value.diff !== "string" ||
    Buffer.byteLength(value.diff) > 50 * 1024 ||
    diffLines(value.diff).length > 2_000 ||
    typeof value.diffTruncated !== "boolean" ||
    !isPositiveInteger(value.firstChangedLine)
  ) {
    return false
  }

  const displayed = diffChangeCounts(value.diff)
  if (displayed.additions + displayed.deletions === 0) return false
  return value.diffTruncated
    ? displayed.additions <= value.additions && displayed.deletions <= value.deletions
    : displayed.additions === value.additions && displayed.deletions === value.deletions
}

type OrderedEdit = { readonly start: number; readonly end: number; readonly oldText: string; readonly newText: string }
type EditFileStage = "read" | "write"

class EditFailure extends Error {
  constructor(
    readonly reason: EditToolErrorReason,
    message: string
  ) {
    super(message)
  }
}

function filesystemFailure(path: string, stage: EditFileStage, cause: unknown) {
  const code = filesystemErrorCode(cause)
  if (code === "ENOENT") return failure("not_found", `File not found: ${path}`)
  if (code === "EISDIR" || code === "ENOTDIR") return failure("not_file", `Path is not a file: ${path}`)
  if (code === "EACCES" || code === "EPERM") return failure("permission_denied", `Permission denied: ${path}`)
  if (code === "EINVAL" || code === "ENAMETOOLONG") return failure("invalid_path", `Invalid edit path: ${path}`)
  return failure(stage === "read" ? "unreadable" : "unwritable", errorMessage(cause))
}

function failure(reason: EditToolErrorReason, message: string) {
  const error = boundToolText(message)
  return { content: [{ type: "text" as const, text: error }], details: { outcome: "error" as const, reason, error } }
}

function match(source: string, text: string, path: string, index: number, count: number) {
  if (!text) throw new EditFailure("invalid_edit", `edits[${index}].oldText must not be empty`)
  const start = source.indexOf(text)
  const label = count === 1 ? "oldText" : `edits[${index}].oldText`
  if (start < 0) throw new EditFailure("match_missing", `Could not find ${label} in ${path}`)
  if (source.indexOf(text, start + text.length) >= 0) {
    throw new EditFailure("match_ambiguous", `${label} is not unique in ${path}`)
  }
  return { start, end: start + text.length }
}

function normalize(text: string): string {
  return text.replace(/\r\n?/g, "\n")
}

function renderEditDiff(
  source: string,
  output: string,
  edits: readonly OrderedEdit[],
  path: string
): { text: string; additions: number; deletions: number; firstChangedLine: number } {
  const displayPath = path.replace(/[\r\n]/g, " ")
  const patch = structuredPatch(`a/${displayPath}`, `b/${displayPath}`, source, output, "", "", {
    context: 3,
    maxEditLength: maxDiffEditLength
  })
  if (patch) return renderedStructuredPatch(patch)
  return renderedReplacementPatch(source, edits, displayPath)
}

function renderedStructuredPatch(patch: StructuredPatch): {
  text: string
  additions: number
  deletions: number
  firstChangedLine: number
} {
  const text = formatPatch(patch, FILE_HEADERS_ONLY)
  const changes = diffChangeCounts(text)
  return { text, ...changes, firstChangedLine: firstPatchChangeLine(patch) }
}

function firstPatchChangeLine(patch: StructuredPatch): number {
  for (const hunk of patch.hunks) {
    let newLine = hunk.newStart
    for (const line of hunk.lines) {
      if (line.startsWith("+")) return newLine
      if (line.startsWith("-")) return newLine
      if (!line.startsWith("\\")) newLine++
    }
  }
  return 1
}

function renderedReplacementPatch(
  source: string,
  edits: readonly OrderedEdit[],
  path: string
): { text: string; additions: number; deletions: number; firstChangedLine: number } {
  const hunks: string[] = [`--- a/${path}`, `+++ b/${path}`]
  let sourceOffset = 0
  let sourceLine = 1
  let lineShift = 0
  let additions = 0
  let deletions = 0
  for (const edit of edits) {
    for (let index = sourceOffset; index < edit.start; index++) {
      if (source.charCodeAt(index) === 10) sourceLine++
    }
    sourceOffset = edit.start
    const oldLines = diffLines(edit.oldText)
    const newLines = diffLines(edit.newText)
    const newStart = sourceLine + lineShift
    hunks.push(`@@ -${sourceLine},${oldLines.length} +${newStart},${newLines.length} @@`)
    hunks.push(...oldLines.map(line => `-${line}`), ...newLines.map(line => `+${line}`))
    additions += newLines.length
    deletions += oldLines.length
    lineShift += newLines.length - oldLines.length
  }
  return { text: hunks.join("\n"), additions, deletions, firstChangedLine: lineAtOffset(source, edits[0]!.start) }
}

function boundDiffLines(diff: string): { text: string; truncated: boolean } {
  let truncated = false
  const lines = diffLines(diff).map(line => {
    const bytes = Buffer.byteLength(line)
    if (bytes <= maxDiffLineBytes) return line
    truncated = true
    const marker = line[0] === "+" || line[0] === "-" || line[0] === " " ? line[0] : ""
    const kind = marker === "+" ? "added" : marker === "-" ? "removed" : "context"
    const contentBytes = marker ? Buffer.byteLength(line.slice(1)) : bytes
    return `${marker}… ${kind} line omitted (${contentBytes} bytes)`
  })
  return { text: lines.join("\n"), truncated }
}

function diffChangeCounts(diff: string): { additions: number; deletions: number } {
  let additions = 0
  let deletions = 0
  let inHunk = false
  for (const line of diffLines(diff)) {
    if (line.startsWith("@@")) {
      inHunk = true
      continue
    }
    if (!inHunk) continue
    if (line.startsWith("+")) additions++
    else if (line.startsWith("-")) deletions++
  }
  return { additions, deletions }
}

function diffLines(text: string): string[] {
  return text ? text.split("\n") : []
}

function lineAtOffset(source: string, offset: number): number {
  let line = 1
  for (let index = 0; index < offset; index++) if (source.charCodeAt(index) === 10) line++
  return line
}

function isEditErrorReason(value: unknown): value is EditToolErrorReason {
  return (
    value === "invalid_path" ||
    value === "not_found" ||
    value === "not_file" ||
    value === "permission_denied" ||
    value === "too_large" ||
    value === "invalid_edit" ||
    value === "match_missing" ||
    value === "match_ambiguous" ||
    value === "overlap" ||
    value === "no_change" ||
    value === "unreadable" ||
    value === "unwritable"
  )
}

function isFilesystemError(cause: unknown): boolean {
  return filesystemErrorCode(cause) !== undefined
}

function filesystemErrorCode(cause: unknown): string | undefined {
  return typeof cause === "object" && cause !== null && typeof Reflect.get(cause, "code") === "string"
    ? String(Reflect.get(cause, "code"))
    : undefined
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
