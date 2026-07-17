import { DEFAULT_MAX_BYTES, truncateHead } from "../truncate.js"
import { isWriteToolDetails, type WriteToolDetails } from "../write.js"
import type { ToolNotice, ToolPresentation, ToolPresentationSource } from "./types.js"
import {
  boundInline,
  formatBytes,
  isPartialSource,
  isTerminalSource,
  matchesToolOutcome,
  normalizeToolText,
  recordValue,
  resultDetails,
  stringValue,
  utf8Prefix
} from "./values.js"

export function projectWrite(source: ToolPresentationSource): ToolPresentation | undefined {
  const args = recordValue(source.args)
  const path = stringValue(args?.path)
  const content = stringValue(args?.content)
  if (!isPartialSource(source) && (!path || content === undefined)) return undefined

  let details: WriteToolDetails | undefined
  if ("result" in source && source.result !== undefined) {
    const value = resultDetails(source.result)
    if (!isWriteToolDetails(value) || !matchesToolOutcome(source, value.outcome)) return undefined
    details = value
  } else if (isTerminalSource(source)) {
    return undefined
  }

  const safeContent = normalizeToolText(content ?? "")
  const preview = truncateHead(safeContent)
  const displayContent = preview.firstLineExceedsLimit ? utf8Prefix(safeContent, DEFAULT_MAX_BYTES) : preview.content
  const notices: ToolNotice[] = []
  if (preview.truncated) {
    notices.push({
      type: "message",
      tone: "warning",
      text: `Arguments truncated for display (${preview.totalLines} lines, ${formatBytes(preview.totalBytes)})`
    })
  }
  if (details?.outcome === "error") {
    notices.push({ type: "message", tone: "error", text: boundInline(details.error) })
  }

  const headerDetails = details ? [`${details.lines} lines`, formatBytes(details.bytes)] : []
  return {
    header: {
      label: "Write",
      subject: { type: "path", path: boundInline(path ?? "…") },
      details: headerDetails.map(detail => boundInline(detail))
    },
    ...(content === undefined
      ? {}
      : { body: { type: "source" as const, text: displayContent, path: boundInline(path ?? "") } }),
    notices,
    preview: { type: "head", rows: 10 }
  }
}
