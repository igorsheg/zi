import { basename, dirname } from "node:path"

import { isReadToolDetails, type ReadToolDetails, type ReadToolErrorReason } from "../read.js"
import { DEFAULT_MAX_BYTES } from "../truncate.js"
import { splitWindow, type ToolNotice, type ToolPresentation, type ToolPresentationSource } from "./types.js"
import {
  assertNever,
  boundHead,
  boundInline,
  formatBytes,
  integerValue,
  matchesToolOutcome,
  recordValue,
  resultDetails,
  resultText,
  stringValue,
  utf8Prefix
} from "./values.js"

const detailedReadHeadRows = 120

export function projectRead(source: ToolPresentationSource): ToolPresentation {
  const args = recordValue(source.args)
  const path = stringValue(args?.path)
  const requestedOffset = integerValue(args?.offset)
  const requestedLimit = integerValue(args?.limit)
  const offset = requestedOffset !== undefined && requestedOffset >= 1 ? requestedOffset : undefined
  const limit = requestedLimit !== undefined && requestedLimit >= 1 ? requestedLimit : undefined

  let details: ReadToolDetails | undefined
  if ("result" in source && source.result !== undefined) {
    const value = resultDetails(source.result)
    if (isReadToolDetails(value) && matchesToolOutcome(source, value.outcome)) details = value
  }

  const text = "result" in source ? (resultText(source.result) ?? "") : ""
  const range =
    details?.outcome === "success"
      ? completedRange(details, offset !== undefined || limit !== undefined)
      : offset !== undefined || limit !== undefined
        ? requestedRange(offset ?? 1, limit)
        : undefined
  const failure = details?.outcome === "error" || source.status === "failed" || source.status === "aborted"

  if (failure) {
    return {
      header: {
        ...readTarget(path),
        details: range ? [boundInline(range)] : [],
        ...(details?.outcome === "error" ? { status: errorStatus(details.reason) } : {})
      },
      body: {
        type: "text",
        text: boundHead(text || (details?.outcome === "error" ? details.error : "Read aborted")),
        tone: "error"
      },
      notices: [],
      preview: { compact: { type: "head", rows: 4 }, detailed: { type: "head", rows: 20 } },
      timing: "duration"
    }
  }

  const sourceText = details?.outcome === "success" ? selectedText(text, details.truncation.outputBytes) : text
  const status = details?.outcome === "success" ? successStatus(details) : undefined
  return {
    header: { ...readTarget(path), details: range ? [boundInline(range)] : [], ...(status ? { status } : {}) },
    ...(sourceText
      ? {
          body: {
            type: "source" as const,
            text: boundHead(sourceText),
            path: boundInline(path ?? ""),
            ...(details?.outcome === "success" ? { startLine: details.startLine } : offset ? { startLine: offset } : {})
          }
        }
      : {}),
    notices: details?.outcome === "success" ? successNotices(details) : [],
    preview: { compact: { type: "hidden" }, detailed: splitWindow(detailedReadHeadRows) },
    timing: "duration"
  }
}

// Skill loads are the one target-kind upgrade: the label stays the stable
// verb, and the skill name takes the subject slot with the path as secondary.
function readTarget(path: string | undefined) {
  const displayPath = boundInline(path ?? "…")
  const skillName = path === undefined || basename(path) !== "SKILL.md" ? undefined : basename(dirname(path))
  if (!skillName || skillName === ".") return { label: "Read", subject: { type: "path" as const, path: displayPath } }
  return {
    label: "Read",
    subject: { type: "text" as const, text: boundInline(skillName) },
    secondary: { type: "path" as const, path: displayPath }
  }
}

function completedRange(
  details: Extract<ReadToolDetails, { outcome: "success" }>,
  requested: boolean
): string | undefined {
  const partial = details.startLine !== 1 || details.endLine !== details.totalLines
  if (!requested && !partial) return undefined
  const range = `${details.startLine}-${details.endLine}`
  return partial ? `${range} of ${details.totalLines}` : range
}

function successStatus(details: Extract<ReadToolDetails, { outcome: "success" }>): string | undefined {
  return details.truncation.outputBytes === 0 && !details.truncation.firstLineExceedsLimit ? "empty" : undefined
}

function errorStatus(reason: ReadToolErrorReason): string {
  switch (reason) {
    case "not_found":
      return "not found"
    case "not_file":
      return "not a file"
    case "permission_denied":
      return "permission denied"
    case "too_large":
      return "too large"
    case "invalid_offset":
      return "invalid offset"
    case "unreadable":
      return "failed"
    default:
      return assertNever(reason)
  }
}

function successNotices(details: Extract<ReadToolDetails, { outcome: "success" }>): ToolNotice[] {
  const notices: ToolNotice[] = []
  if (details.truncation.firstLineExceedsLimit) {
    // Always visible: there is no body, so this is the only explanation.
    notices.push({
      type: "message",
      tone: "warning",
      visibility: "always",
      text: `Line ${details.startLine} exceeds the ${formatBytes(DEFAULT_MAX_BYTES)} read limit`
    })
  } else if (details.truncation.truncated) {
    notices.push({
      type: "message",
      tone: "warning",
      visibility: "detailed",
      text: `Read truncated after ${details.truncation.outputLines} lines (${formatBytes(details.truncation.outputBytes)})`
    })
  }
  if (details.nextOffset !== undefined && details.remainingLines !== undefined) {
    notices.push({
      type: "message",
      tone: "muted",
      visibility: "detailed",
      text: `${details.remainingLines} lines remain; continue at offset ${details.nextOffset}`
    })
  }
  return notices
}

function selectedText(text: string, bytes: number): string {
  if (bytes === 0) return ""
  return Buffer.byteLength(text) < bytes ? text : utf8Prefix(text, bytes)
}

function requestedRange(offset: number, limit: number | undefined): string {
  return limit === undefined ? `from line ${offset}` : `lines ${offset}-${offset + limit - 1}`
}
