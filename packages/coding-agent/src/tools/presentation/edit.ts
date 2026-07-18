import { isEditToolDetails, type EditToolDetails, type EditToolErrorReason } from "../edit.js"
import { truncateHead } from "../truncate.js"
import { maxExpandedToolRows, type ToolNotice, type ToolPresentation, type ToolPresentationSource } from "./types.js"
import {
  assertNever,
  boundHead,
  boundInline,
  matchesToolOutcome,
  normalizeToolText,
  recordValue,
  resultDetails,
  resultText,
  stringValue
} from "./values.js"

const maxPresentedChanges = 8

export function projectEdit(source: ToolPresentationSource): ToolPresentation {
  const args = recordValue(source.args)
  const path = stringValue(args?.path)
  const edits = editValues(args?.edits)
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
  const degradedResult = !success ? resultText(result) : undefined
  const argumentBody = edits ? replacementBody(edits.slice(0, maxPresentedChanges)) : undefined
  const body = success
    ? ({ type: "diff", text: boundHead(success.diff), path: boundInline(path ?? "") } as const)
    : degradedResult
      ? ({ type: "text", text: boundHead(degradedResult), tone: "normal" } as const)
      : argumentBody
        ? ({ type: "diff", text: argumentBody, path: boundInline(path ?? "") } as const)
        : undefined

  const notices: ToolNotice[] = []
  if (!success && edits && edits.length > maxPresentedChanges) {
    notices.push({
      type: "message",
      tone: "warning",
      visibility: "detailed",
      text: `${edits.length - maxPresentedChanges} proposed replacements omitted from preview`
    })
  }
  if (success?.diffTruncated) {
    notices.push({
      type: "message",
      tone: "warning",
      visibility: "detailed",
      text: "Diff preview truncated to bounded line, row, or byte limits"
    })
  }

  const headerDetails =
    edits && !success ? [`${formatReplacements(edits.length)}${source.status === "preparing" ? " so far" : ""}`] : []
  const preview = success
    ? {
        compact: { type: "edges" as const, head: 5, tail: 5 },
        detailed: { type: "edges" as const, head: 120, tail: 79 }
      }
    : degradedResult
      ? { compact: { type: "hidden" as const }, detailed: { type: "head" as const, rows: 20 } }
      : { compact: { type: "head" as const, rows: 6 }, detailed: { type: "head" as const, rows: maxExpandedToolRows } }

  return {
    header: {
      label: "Edit",
      subject: { type: "path", path: boundInline(path ?? "…") },
      details: headerDetails.map(detail => boundInline(detail)),
      ...(success ? { delta: { added: success.additions, removed: success.deletions } } : {})
    },
    ...(body ? { body } : {}),
    notices,
    preview,
    timing: "duration"
  }
}

function editValues(value: unknown): readonly { readonly oldText: string; readonly newText: string }[] | undefined {
  if (!Array.isArray(value)) return undefined
  const edits: { oldText: string; newText: string }[] = []
  for (const candidate of value) {
    const edit = recordValue(candidate)
    const oldText = stringValue(edit?.oldText)
    const newText = stringValue(edit?.newText)
    if (oldText === undefined || newText === undefined) return undefined
    edits.push({ oldText, newText })
  }
  return edits.length > 0 ? edits : undefined
}

function replacementBody(edits: readonly { readonly oldText: string; readonly newText: string }[]): string {
  const sections: string[] = []
  for (const edit of edits) {
    const lines = [...replacementLines("-", edit.oldText), ...replacementLines("+", edit.newText)]
    if (lines.length > 0) sections.push(lines.join("\n"))
  }
  return truncateHead(sections.join("\n\n")).content
}

function replacementLines(marker: "-" | "+", value: string): string[] {
  if (!value) return []
  return boundedReplacement(value)
    .split("\n")
    .map(line => `${marker}${line}`)
}

function boundedReplacement(value: string): string {
  const scalars = Array.from(normalizeToolText(value))
  return scalars.length <= 8_192 ? scalars.join("") : `${scalars.slice(0, 8_191).join("")}…`
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
