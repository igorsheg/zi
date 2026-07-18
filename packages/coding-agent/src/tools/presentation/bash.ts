import type { ShellTaskOutcome } from "../../session-shell.js"
import { isBashToolDetails, type BashToolDetails } from "../bash.js"
import {
  maxExpandedToolRows,
  type ToolNotice,
  type ToolPresentation,
  type ToolPresentationSource,
  type ToolPreviewPolicy,
  type ToolSubject
} from "./types.js"
import {
  assertNever,
  booleanValue,
  boundCommand,
  boundInline,
  boundTail,
  formatBytes,
  matchesToolOutcome,
  normalizeToolText,
  numberValue,
  recordValue,
  resultDetails,
  resultText,
  stringValue,
  utf8Prefix
} from "./values.js"

const compactBashRows = 5

export function projectBash(source: ToolPresentationSource): ToolPresentation {
  const args = recordValue(source.args)
  const command = stringValue(args?.command)
  const description = stringValue(args?.description)
  const requestedTimeout = numberValue(args?.timeout)
  const timeout = requestedTimeout !== undefined && requestedTimeout > 0 ? requestedTimeout : undefined
  const background = booleanValue(args?.background)

  const displayDescription = descriptionTitle(description)
  const title = displayDescription ?? command
  const primary: ToolSubject = title
    ? displayDescription
      ? { type: "text", text: boundInline(title) }
      : { type: "command", text: boundCommand(title), prompt: false }
    : { type: "text", text: "…" }
  const secondary =
    displayDescription && command
      ? ({ type: "command", text: boundCommand(command), prompt: true } as const)
      : undefined

  if (source.status === "aborted") return abortedPresentation(source, primary, secondary, timeout, background)

  let details: BashToolDetails | undefined
  if ("result" in source && source.result !== undefined) {
    const value = resultDetails(source.result)
    if (isBashToolDetails(value) && matchesToolOutcome(source, value.outcome)) details = value
  }

  const result = "result" in source ? (resultText(source.result) ?? "") : ""
  const text = details && details.state !== "rejected" ? shellBodyText(result, details) : details ? "" : result
  const status = bashStatus(source, details, background)
  return {
    header: {
      label: "Run",
      subject: primary,
      ...(secondary ? { secondary } : {}),
      details: timeout === undefined ? [] : [boundInline(`timeout ${timeout}s`)],
      ...(status ? { status } : {})
    },
    ...(text ? { body: { type: "terminal" as const, text: boundTail(text) } } : {}),
    notices: details ? shellNotices(details) : [],
    preview: bashPreview(source, details),
    timing: details?.state === "rejected" ? "hidden" : details?.state === "background" ? "started" : "duration"
  }
}

type ExecutedBashToolDetails = Exclude<BashToolDetails, { state: "rejected" }>

function abortedPresentation(
  source: Extract<ToolPresentationSource, { status: "aborted" }>,
  subject: ToolSubject,
  secondary: ToolSubject | undefined,
  timeout: number | undefined,
  background: boolean | undefined
): ToolPresentation {
  const result = resultText(source.result) ?? "Operation aborted"
  const body = result === "Operation aborted" ? "" : boundTail(result)
  return {
    header: {
      label: "Run",
      subject,
      ...(secondary ? { secondary } : {}),
      details: [
        ...(timeout === undefined ? [] : [boundInline(`timeout ${timeout}s`)]),
        ...(background ? ["background"] : [])
      ],
      status: "aborted"
    },
    ...(body ? { body: { type: "terminal", text: body } } : {}),
    notices: [
      {
        type: "message",
        tone: "error",
        visibility: "always",
        text: boundInline(result === "Operation aborted" ? "Operation aborted before execution" : "Command aborted")
      }
    ],
    preview: {
      compact: { type: "tail", rows: compactBashRows },
      detailed: { type: "tail", rows: maxExpandedToolRows }
    },
    timing: "duration"
  }
}

function shellBodyText(text: string, details: ExecutedBashToolDetails): string {
  const outputBytes = details.output.truncation.outputBytes
  if (outputBytes === 0) {
    return details.outcome === "success" && details.state === "completed" ? "(no output)" : ""
  }
  if (Buffer.byteLength(text) < outputBytes) return text
  return utf8Prefix(text, outputBytes)
}

function bashPreview(source: ToolPresentationSource, details: BashToolDetails | undefined): ToolPreviewPolicy {
  if (source.status === "running") {
    return { compact: { type: "tail", rows: compactBashRows }, detailed: { type: "tail", rows: maxExpandedToolRows } }
  }
  if (source.status === "failed" || (details?.outcome === "error" && details.state !== "rejected")) {
    return { compact: { type: "edges", head: 2, tail: 3 }, detailed: { type: "edges", head: 80, tail: 119 } }
  }
  if (details?.outcome === "success" && details.state === "completed" && details.output.truncation.outputBytes > 0) {
    return { compact: { type: "tail", rows: compactBashRows }, detailed: { type: "edges", head: 80, tail: 119 } }
  }
  if (!details && "result" in source) {
    return { compact: { type: "tail", rows: compactBashRows }, detailed: { type: "tail", rows: maxExpandedToolRows } }
  }
  return { compact: { type: "hidden" }, detailed: { type: "edges", head: 80, tail: 119 } }
}

function bashStatus(
  source: ToolPresentationSource,
  details: BashToolDetails | undefined,
  requestedBackground: boolean | undefined
): string | undefined {
  if (!details) {
    if (source.status === "failed") return "failed"
    return requestedBackground ? "background" : undefined
  }
  if (details.state === "rejected") return "rejected"

  const values: string[] = []
  if (details.state === "background") values.push("background", `task ${shortTaskId(details.taskId)}`)
  if (details.outcome === "error") values.push(outcomeLabel(details.finalOutcome))
  if (details.output.truncation.truncated) values.push("truncated")
  return values.length > 0 ? boundInline(values.join(" · ")) : undefined
}

function shellNotices(details: BashToolDetails): ToolNotice[] {
  if (details.state === "rejected") {
    return [{ type: "message", tone: "error", visibility: "always", text: boundInline(details.error) }]
  }

  const notices: ToolNotice[] = []
  if (details.state === "background") {
    notices.push({
      type: "message",
      tone: "muted",
      visibility: "detailed",
      text: boundInline(`Task ${details.taskId} started in background`)
    })
  }

  const truncation = details.output.truncation
  if (truncation.truncated) {
    notices.push({ type: "message", tone: "warning", visibility: "detailed", text: truncationNotice(truncation) })
    const full = details.output.fullOutput
    if (full.type === "available") {
      notices.push({
        type: "path",
        tone: "warning",
        visibility: "detailed",
        label: "Full output",
        path: boundInline(full.path)
      })
    } else {
      notices.push({
        type: "message",
        tone: "warning",
        visibility: "detailed",
        text: `Full output is no longer retained (${formatBytes(full.bytes)})`
      })
    }
    if (full.truncated) {
      notices.push({
        type: "message",
        tone: "warning",
        visibility: "detailed",
        text: "Full output reached its retention limit"
      })
    }
  }
  if (details.outcome === "error") {
    notices.push({ type: "message", tone: "error", visibility: "always", text: boundInline(details.error) })
  }
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

function outcomeLabel(outcome: ShellTaskOutcome | undefined): string {
  if (!outcome) return "failed"
  switch (outcome.type) {
    case "exited":
      return `exit ${outcome.exitCode}`
    case "signaled":
      return boundInline(outcome.signal)
    case "aborted":
      return "aborted"
    case "timed_out":
      return "timed out"
    case "killed":
      return "killed"
    case "output_limit":
      return "output limit"
    case "disposed":
      return "disposed"
    case "failed":
      return "failed"
    default:
      return assertNever(outcome)
  }
}

function descriptionTitle(value: string | undefined): string | undefined {
  const description = value
    ? normalizeToolText(value)
        .trim()
        .replace(/\s*\n\s*/g, " ")
    : undefined
  if (!description) return undefined
  const match = /^(?:run|running)(?:\s+|$)/i.exec(description)
  const stripped = match ? description.slice(match[0].length).trimStart() : description
  return stripped || undefined
}

function shortTaskId(value: string): string {
  const scalars = Array.from(value)
  return scalars.length <= 12 ? value : scalars.slice(0, 8).join("")
}
