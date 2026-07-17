import { isBashToolDetails, type BashToolDetails } from "../bash.js"
import type { ToolNotice, ToolPresentation, ToolPresentationSource } from "./types.js"
import {
  assertNever,
  booleanValue,
  boundInline,
  boundTail,
  formatBytes,
  isPartialSource,
  isTerminalSource,
  matchesToolOutcome,
  numberValue,
  recordValue,
  resultDetails,
  resultText,
  stringValue,
  utf8Prefix
} from "./values.js"

export function projectBash(source: ToolPresentationSource): ToolPresentation | undefined {
  const args = recordValue(source.args)
  const command = stringValue(args?.command)
  const timeout = numberValue(args?.timeout)
  const background = booleanValue(args?.background)
  if (!isPartialSource(source) && !command) return undefined
  if (timeout !== undefined && timeout <= 0) return undefined

  let details: BashToolDetails | undefined
  if ("result" in source && source.result !== undefined) {
    const value = resultDetails(source.result)
    if (!isBashToolDetails(value) || !matchesToolOutcome(source, value.outcome)) return undefined
    details = value
  } else if (isTerminalSource(source)) {
    return undefined
  }

  const headerDetails: string[] = []
  if (timeout !== undefined) headerDetails.push(boundInline(`timeout ${timeout}s`))
  if (background === true || details?.state === "background") headerDetails.push("background")
  if (details && details.state !== "rejected") headerDetails.push(boundInline(`task ${details.taskId}`))

  const text =
    details && details.state !== "rejected" && "result" in source
      ? shellBodyText(resultText(source.result) ?? "", details)
      : ""
  return {
    header: { label: "Bash", subject: { type: "command", text: boundInline(command ?? "…") }, details: headerDetails },
    ...(text ? { body: { type: "terminal" as const, text: boundTail(text) } } : {}),
    notices: details ? shellNotices(details) : [],
    preview: { type: "tail", rows: 5 }
  }
}

type ExecutedBashToolDetails = Exclude<BashToolDetails, { state: "rejected" }>

function shellBodyText(text: string, details: ExecutedBashToolDetails): string {
  const outputBytes = details.output.truncation.outputBytes
  if (outputBytes === 0) return text.startsWith("(no output)") ? "(no output)" : ""
  if (Buffer.byteLength(text) < outputBytes) return text
  return utf8Prefix(text, outputBytes)
}

function shellNotices(details: BashToolDetails): ToolNotice[] {
  const notices: ToolNotice[] = []
  if (details.state === "rejected") {
    return [{ type: "message", tone: "error", text: boundInline(details.error) }]
  }
  const truncation = details.output.truncation
  if (truncation.truncated) {
    notices.push({ type: "message", tone: "warning", text: truncationNotice(truncation) })
    const full = details.output.fullOutput
    if (full.type === "available") {
      notices.push({ type: "path", tone: "warning", label: "Full output", path: boundInline(full.path) })
    } else {
      notices.push({
        type: "message",
        tone: "warning",
        text: `Full output is no longer retained (${formatBytes(full.bytes)})`
      })
    }
    if (full.truncated) {
      notices.push({ type: "message", tone: "warning", text: "Full output reached its retention limit" })
    }
  }
  if (details.outcome === "error") notices.push({ type: "message", tone: "error", text: boundInline(details.error) })
  return notices
}

function truncationNotice(truncation: ExecutedBashToolDetails["output"]["truncation"]): string {
  if (truncation.lastLinePartial) return `Showing the last ${formatBytes(truncation.outputBytes)} of an oversized line`
  switch (truncation.truncatedBy) {
    case "lines":
      return `Showing the last ${truncation.outputLines} of ${truncation.totalLines} lines`
    case "bytes":
      return `${truncation.outputLines} lines shown (${formatBytes(truncation.outputBytes)})`
    case null:
      return "Output truncated"
    default:
      return assertNever(truncation.truncatedBy)
  }
}
