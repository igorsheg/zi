import { isReadToolDetails, type ReadToolDetails } from "../read.js"
import { DEFAULT_MAX_BYTES } from "../truncate.js"
import type { ToolNotice, ToolPresentation, ToolPresentationSource } from "./types.js"
import {
  boundHead,
  boundInline,
  formatBytes,
  integerValue,
  isPartialSource,
  isTerminalSource,
  matchesToolOutcome,
  recordValue,
  resultDetails,
  resultText,
  stringValue,
  utf8Prefix
} from "./values.js"

export function projectRead(source: ToolPresentationSource): ToolPresentation | undefined {
  const args = recordValue(source.args)
  const path = stringValue(args?.path)
  const offset = integerValue(args?.offset)
  const limit = integerValue(args?.limit)
  if (!isPartialSource(source) && !path) return undefined
  if ((offset !== undefined && offset < 1) || (limit !== undefined && limit < 1)) return undefined

  let details: ReadToolDetails | undefined
  if ("result" in source && source.result !== undefined) {
    const value = resultDetails(source.result)
    if (!isReadToolDetails(value) || !matchesToolOutcome(source, value.outcome)) return undefined
    details = value
  } else if (isTerminalSource(source)) {
    return undefined
  }

  const range =
    details?.outcome === "success"
      ? `${details.startLine}-${details.endLine} of ${details.totalLines}`
      : offset !== undefined || limit !== undefined
        ? requestedRange(offset ?? 1, limit)
        : undefined
  const notices = details?.outcome === "success" ? successNotices(details) : []
  const text = "result" in source ? (resultText(source.result) ?? "") : ""

  if (details?.outcome === "error") {
    return {
      header: {
        label: "Read",
        subject: { type: "path", path: boundInline(path ?? "…") },
        details: range ? [boundInline(range)] : []
      },
      body: { type: "text", text: boundHead(text || details.error), tone: "error" },
      notices: [{ type: "message", tone: "error", text: boundInline(details.error) }],
      preview: { type: "head", rows: 10 }
    }
  }

  const sourceText = details ? selectedText(text, details.truncation.outputBytes) : ""
  return {
    header: {
      label: "Read",
      subject: { type: "path", path: boundInline(path ?? "…") },
      details: range ? [boundInline(range)] : []
    },
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
    notices,
    preview: { type: "hidden" }
  }
}

function successNotices(details: Extract<ReadToolDetails, { outcome: "success" }>): ToolNotice[] {
  const notices: ToolNotice[] = []
  if (details.truncation.firstLineExceedsLimit) {
    notices.push({
      type: "message",
      tone: "warning",
      text: `Line ${details.startLine} exceeds the ${formatBytes(DEFAULT_MAX_BYTES)} read limit`
    })
  } else if (details.truncation.truncated) {
    notices.push({
      type: "message",
      tone: "warning",
      text: `Read truncated after ${details.truncation.outputLines} lines (${formatBytes(details.truncation.outputBytes)})`
    })
  }
  if (details.nextOffset !== undefined && details.remainingLines !== undefined) {
    notices.push({
      type: "message",
      tone: "muted",
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
