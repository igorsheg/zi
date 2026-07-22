import { DEFAULT_MAX_BYTES, truncateHead } from "../truncate.js"
import { countWriteLines, isWriteToolDetails, type WriteToolDetails, type WriteToolErrorReason } from "../write.js"
import { maxExpandedToolRows, type ToolNotice, type ToolPresentation, type ToolPresentationSource } from "./types.js"
import {
  assertNever,
  boundHead,
  boundInline,
  formatBytes,
  matchesToolOutcome,
  normalizeToolText,
  recordValue,
  resultDetails,
  resultText,
  stringValue,
  utf8Prefix
} from "./values.js"

export function projectWrite(source: ToolPresentationSource): ToolPresentation {
  const args = recordValue(source.args)
  const path = stringValue(args?.path)
  const content = stringValue(args?.content)

  const result = "result" in source ? source.result : undefined
  let details: WriteToolDetails | undefined
  if (result !== undefined) {
    const value = resultDetails(result)
    if (isWriteToolDetails(value) && matchesToolOutcome(source, value.outcome)) details = value
  }

  const failure = details?.outcome === "error" || source.status === "failed" || source.status === "aborted"
  if (failure) {
    const error = details?.outcome === "error" ? details.error : resultText(result)
    return {
      header: {
        label: "Write",
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
  const preview = contentPreview(content, success)
  const headerDetails = success
    ? [formatLines(success.lines), formatBytes(success.bytes)]
    : content === undefined
      ? []
      : source.status === "preparing"
        ? [formatStreamingLines(preview.observedLines, preview.inputTruncated)]
        : [formatLines(countWriteLines(content)), formatBytes(Buffer.byteLength(content))]
  return {
    header: {
      label: "Write",
      subject: { type: "path", path: boundInline(path ?? "…") },
      details: headerDetails.map(detail => boundInline(detail))
    },
    ...(preview.displayContent
      ? { body: { type: "source" as const, text: preview.displayContent, path: boundInline(path ?? "") } }
      : {}),
    notices: preview.notice ? [preview.notice] : [],
    preview: { compact: { type: "hidden" }, detailed: { type: "head", rows: maxExpandedToolRows } },
    timing: "duration"
  }
}

function contentPreview(
  content: string | undefined,
  details: Extract<WriteToolDetails, { outcome: "success" }> | undefined
): { displayContent: string; observedLines: number; inputTruncated: boolean; notice?: ToolNotice } {
  if (content === undefined) return { displayContent: "", observedLines: 0, inputTruncated: false }
  const boundedContent = utf8Prefix(content, DEFAULT_MAX_BYTES)
  const observedLines = countWriteLines(boundedContent)
  const inputTruncated = boundedContent.length < content.length
  const safeContent = normalizeToolText(boundedContent)
  const preview = truncateHead(safeContent)
  const displayContent = preview.firstLineExceedsLimit ? utf8Prefix(safeContent, DEFAULT_MAX_BYTES) : preview.content
  if (!inputTruncated && !preview.truncated) return { displayContent, observedLines, inputTruncated }

  const totalLines = details?.lines ?? (inputTruncated ? undefined : preview.totalLines)
  const totalBytes = details?.bytes ?? (inputTruncated ? undefined : preview.totalBytes)
  const facts =
    totalLines === undefined || totalBytes === undefined
      ? ""
      : ` (${formatLines(totalLines)}, ${formatBytes(totalBytes)})`
  return {
    displayContent,
    observedLines,
    inputTruncated,
    notice: { type: "message", tone: "warning", visibility: "detailed", text: `Content preview truncated${facts}` }
  }
}

function formatLines(lines: number): string {
  return `${lines} ${lines === 1 ? "line" : "lines"}`
}

function formatStreamingLines(lines: number, bounded: boolean): string {
  return bounded ? `at least ${formatLines(lines)} so far` : `${formatLines(lines)} so far`
}

function errorStatus(reason: WriteToolErrorReason): string {
  switch (reason) {
    case "invalid_path":
      return "invalid path"
    case "not_file":
      return "not a file"
    case "permission_denied":
      return "permission denied"
    case "too_large":
      return "too large"
    case "unwritable":
      return "failed"
    default:
      return assertNever(reason)
  }
}
