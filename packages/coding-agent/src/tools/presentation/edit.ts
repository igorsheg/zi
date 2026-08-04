import { isEditToolDetails, maxEditChanges, type EditToolDetails, type EditToolErrorReason } from "../edit.js"
import { splitWindow, type ToolNotice, type ToolPresentation, type ToolPresentationSource } from "./types.js"
import {
  assertNever,
  boundHead,
  boundInline,
  matchesToolOutcome,
  recordValue,
  resultDetails,
  resultText,
  stringValue
} from "./values.js"

export function projectEdit(source: ToolPresentationSource): ToolPresentation {
  const args = recordValue(source.args)
  const path = stringValue(args?.path)
  const replacements =
    source.status === "preparing" ? streamedReplacementCount(args?.edits) : settledReplacementCount(args?.edits)
  const result = "result" in source ? source.result : undefined

  let details: EditToolDetails | undefined
  if (result !== undefined) {
    const value = resultDetails(result)
    if (isEditToolDetails(value) && matchesToolOutcome(source, value.outcome)) details = value
  }

  const failure = details?.outcome === "error" || source.status === "failed" || source.status === "aborted"
  if (failure) {
    const error = details?.outcome === "error" ? details.error : resultText(result)
    return {
      header: {
        label: "Edit",
        subject: { type: "path", path: boundInline(path ?? "…") },
        details: [],
        ...(details?.outcome === "error" ? { status: errorStatus(details.reason) } : {})
      },
      ...(error ? { body: { type: "text" as const, text: boundHead(error), tone: "error" as const } } : {}),
      notices: [],
      preview: error
        ? { compact: { type: "head", rows: 4 }, detailed: { type: "head", rows: 20 } }
        : { compact: { type: "hidden" }, detailed: { type: "hidden" } },
      timing: "duration"
    }
  }

  const success = details?.outcome === "success" ? details : undefined
  const degradedResult = source.status === "done" && !success ? resultText(result) : undefined
  const notices: ToolNotice[] = []
  if (success?.diffTruncated) {
    notices.push({
      type: "message",
      tone: "warning",
      visibility: "detailed",
      text: "Diff preview truncated to bounded line, row, or byte limits"
    })
  }

  return {
    header: {
      label: "Edit",
      subject: { type: "path", path: boundInline(path ?? "…") },
      details:
        replacements === undefined || success
          ? []
          : [boundInline(`${formatReplacements(replacements)}${source.status === "preparing" ? " so far" : ""}`)],
      ...(success ? { delta: { added: success.additions, removed: success.deletions } } : {})
    },
    ...(success
      ? { body: { type: "diff" as const, text: boundHead(success.diff), path: boundInline(path ?? "") } }
      : degradedResult
        ? { body: { type: "text" as const, text: boundHead(degradedResult), tone: "normal" as const } }
        : {}),
    notices,
    preview: success
      ? { compact: { type: "edges", head: 5, tail: 5 }, detailed: splitWindow(120) }
      : degradedResult
        ? { compact: { type: "hidden" }, detailed: { type: "head", rows: 20 } }
        : { compact: { type: "hidden" }, detailed: { type: "hidden" } },
    timing: "duration"
  }
}

function streamedReplacementCount(value: unknown): number | undefined {
  if (!Array.isArray(value) || value.length > maxEditChanges) return undefined
  let count = 0
  for (const candidate of value) {
    if (isCompleteReplacement(candidate)) count++
  }
  return count > 0 ? count : undefined
}

function settledReplacementCount(value: unknown): number | undefined {
  if (!Array.isArray(value) || value.length === 0 || value.length > maxEditChanges) return undefined
  return value.every(isCompleteReplacement) ? value.length : undefined
}

function isCompleteReplacement(value: unknown): boolean {
  const edit = recordValue(value)
  return stringValue(edit?.oldText) !== undefined && stringValue(edit?.newText) !== undefined
}

function formatReplacements(replacements: number): string {
  return `${replacements} replacement${replacements === 1 ? "" : "s"}`
}

function errorStatus(reason: EditToolErrorReason): string {
  switch (reason) {
    case "invalid_path":
      return "invalid path"
    case "not_found":
      return "not found"
    case "not_file":
      return "not a file"
    case "permission_denied":
      return "permission denied"
    case "too_large":
      return "too large"
    case "invalid_edit":
      return "invalid edit"
    case "match_missing":
      return "match not found"
    case "match_ambiguous":
      return "ambiguous match"
    case "overlap":
      return "overlapping edits"
    case "no_change":
      return "no change"
    case "unreadable":
    case "unwritable":
      return "failed"
    default:
      return assertNever(reason)
  }
}
