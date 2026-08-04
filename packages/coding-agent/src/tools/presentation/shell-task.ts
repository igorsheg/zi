import type { ShellTaskOutcome } from "../../session-shell.js"
import {
  isKillTaskToolDetails,
  isTaskOutputToolDetails,
  type KillTaskToolDetails,
  type ShellOutputDetails,
  type TaskOutputToolDetails
} from "../shell-tasks.js"
import { maxExpandedToolRows, type ToolNotice, type ToolPresentation, type ToolPresentationSource } from "./types.js"
import {
  boundHead,
  boundInline,
  boundTail,
  formatBytes,
  matchesToolOutcome,
  recordValue,
  resultDetails,
  resultText,
  stringValue,
  utf8Prefix
} from "./values.js"

export function projectTaskOutput(source: ToolPresentationSource): ToolPresentation {
  const args = recordValue(source.args)
  const taskId = stringValue(args?.taskId)

  let details: TaskOutputToolDetails | undefined
  if ("result" in source && source.result !== undefined) {
    const value = resultDetails(source.result)
    if (isTaskOutputToolDetails(value) && matchesToolOutcome(source, value.outcome)) details = value
  }

  const text = "result" in source ? (resultText(source.result) ?? "") : ""
  const error = details?.outcome === "error" || source.status === "failed"
  const bodyText = details && details.outcome !== "error" ? shellBodyText(text, details.output) : text
  const settled = details && details.outcome !== "error" ? details : undefined
  return {
    header: {
      label: "Output",
      subject: { type: "task", id: boundInline(taskId ?? details?.taskId ?? "…") },
      details: settled ? taskDetails(settled) : [],
      ...(settled?.finalOutcome ? { status: outcomeLabel(settled.finalOutcome) } : {})
    },
    ...(bodyText
      ? {
          body: error
            ? ({ type: "text", text: boundHead(bodyText), tone: "error" } as const)
            : ({ type: "terminal", text: boundTail(bodyText) } as const)
        }
      : {}),
    notices:
      details?.outcome === "error"
        ? [{ type: "message", tone: "error", visibility: "always", text: boundInline(details.error) }]
        : details
          ? shellOutputNotices(details.output)
          : [],
    preview: { compact: { type: "tail", rows: 5 }, detailed: { type: "tail", rows: maxExpandedToolRows } },
    timing: "duration"
  }
}

export function projectKillTask(source: ToolPresentationSource): ToolPresentation {
  const args = recordValue(source.args)
  const taskId = stringValue(args?.taskId)

  let details: KillTaskToolDetails | undefined
  if ("result" in source && source.result !== undefined) {
    const value = resultDetails(source.result)
    if (isKillTaskToolDetails(value) && matchesToolOutcome(source, value.outcome)) details = value
  }

  const text = "result" in source ? (resultText(source.result) ?? "") : ""
  if (details?.outcome === "error" || (source.status === "failed" && !details)) {
    return {
      header: {
        label: "Kill",
        subject: { type: "task", id: boundInline(taskId ?? (details?.outcome === "error" ? details.taskId : "…")) },
        details: []
      },
      body: {
        type: "text",
        text: boundHead(text || (details?.outcome === "error" ? details.error : "Could not stop task")),
        tone: "error"
      },
      notices:
        details?.outcome === "error"
          ? [{ type: "message", tone: "error", visibility: "always", text: boundInline(details.error) }]
          : [],
      preview: { compact: { type: "head", rows: 8 }, detailed: { type: "head", rows: maxExpandedToolRows } },
      timing: "duration"
    }
  }

  const degradedText = details ? "" : text
  return {
    header: {
      label: "Kill",
      subject: { type: "task", id: boundInline(taskId ?? details?.taskId ?? "…") },
      details: details?.finalOutcome ? [boundInline(outcomeLabel(details.finalOutcome))] : [],
      ...(details ? { status: stopLabel(details.stop) } : {})
    },
    ...(degradedText ? { body: { type: "text" as const, text: boundHead(degradedText), tone: "muted" as const } } : {}),
    notices: [],
    preview: {
      compact: { type: "hidden" },
      detailed: degradedText ? { type: "head", rows: maxExpandedToolRows } : { type: "hidden" }
    },
    timing: "duration"
  }
}

function shellBodyText(text: string, output: ShellOutputDetails): string {
  const outputBytes = output.truncation.outputBytes
  if (outputBytes === 0) return text.startsWith("(no output)") ? "(no output)" : ""
  return Buffer.byteLength(text) < outputBytes ? text : utf8Prefix(text, outputBytes)
}

function taskDetails(details: Exclude<TaskOutputToolDetails, { outcome: "error" }>): string[] {
  return [
    boundInline(details.state),
    ...(details.placement ? [boundInline(details.placement)] : []),
    ...(details.stopReason ? [boundInline(details.stopReason)] : [])
  ]
}

function shellOutputNotices(output: ShellOutputDetails): ToolNotice[] {
  if (!output.truncation.truncated) return []
  const notices: ToolNotice[] = [
    {
      type: "message",
      tone: "warning",
      visibility: "always",
      text: `Output truncated to ${output.truncation.outputLines} lines (${formatBytes(output.truncation.outputBytes)})`
    }
  ]
  if (output.fullOutput.type === "available") {
    notices.push({
      type: "path",
      tone: "warning",
      visibility: "always",
      label: "Full output",
      path: boundInline(output.fullOutput.path)
    })
  } else {
    notices.push({
      type: "message",
      tone: "warning",
      visibility: "always",
      text: `Full output is no longer retained (${formatBytes(output.fullOutput.bytes)})`
    })
  }
  if (output.fullOutput.truncated) {
    notices.push({
      type: "message",
      tone: "warning",
      visibility: "always",
      text: "Full output reached its retention limit"
    })
  }
  return notices
}

function stopLabel(stop: Exclude<KillTaskToolDetails, { outcome: "error" }>["stop"]): string {
  switch (stop) {
    case "already_completed":
      return "already completed"
    case "settling":
      return "settling"
    case "stopping":
      return "stopping"
    default:
      return assertNever(stop)
  }
}

function outcomeLabel(outcome: ShellTaskOutcome): string {
  switch (outcome.type) {
    case "exited":
      return `exit ${outcome.exitCode}`
    case "signaled":
      return `signal ${outcome.signal}`
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
      return boundInline(`failed: ${outcome.message}`)
    default:
      return assertNever(outcome)
  }
}

function assertNever(value: never): never {
  throw new Error(`Unexpected shell task presentation: ${String(value)}`)
}
