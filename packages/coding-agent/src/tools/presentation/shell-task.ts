import type { ShellTaskOutcome } from "../../session-shell.js"
import {
  isKillTaskToolDetails,
  isTaskOutputToolDetails,
  type KillTaskToolDetails,
  type ShellOutputDetails,
  type TaskOutputToolDetails
} from "../shell-tasks.js"
import type { ToolNotice, ToolPresentation, ToolPresentationSource } from "./types.js"
import {
  boundHead,
  boundInline,
  boundTail,
  formatBytes,
  isPartialSource,
  isTerminalSource,
  matchesToolOutcome,
  recordValue,
  resultDetails,
  resultText,
  stringValue,
  utf8Prefix
} from "./values.js"

export function projectTaskOutput(source: ToolPresentationSource): ToolPresentation | undefined {
  const args = recordValue(source.args)
  const taskId = stringValue(args?.taskId)
  if (!isPartialSource(source) && !taskId) return undefined

  let details: TaskOutputToolDetails | undefined
  if ("result" in source && source.result !== undefined) {
    const value = resultDetails(source.result)
    if (!isTaskOutputToolDetails(value) || !matchesToolOutcome(source, value.outcome)) return undefined
    details = value
  } else if (isTerminalSource(source)) {
    return undefined
  }

  const text = "result" in source ? (resultText(source.result) ?? "") : ""
  const error = details?.outcome === "error"
  const bodyText = details && details.outcome !== "error" ? shellBodyText(text, details.output) : text
  return {
    header: {
      label: "Task output",
      subject: { type: "task", id: boundInline(taskId ?? details?.taskId ?? "…") },
      details: details && details.outcome !== "error" ? taskDetails(details) : []
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
        ? [{ type: "message", tone: "error", text: boundInline(details.error) }]
        : details
          ? shellOutputNotices(details.output)
          : [],
    preview: { type: "tail", rows: 5 }
  }
}

export function projectKillTask(source: ToolPresentationSource): ToolPresentation | undefined {
  const args = recordValue(source.args)
  const taskId = stringValue(args?.taskId)
  if (!isPartialSource(source) && !taskId) return undefined

  let details: KillTaskToolDetails | undefined
  if ("result" in source && source.result !== undefined) {
    const value = resultDetails(source.result)
    if (!isKillTaskToolDetails(value) || !matchesToolOutcome(source, value.outcome)) return undefined
    details = value
  } else if (isTerminalSource(source)) {
    return undefined
  }

  const text = "result" in source ? (resultText(source.result) ?? "") : ""
  if (details?.outcome === "error") {
    return {
      header: { label: "Kill task", subject: { type: "task", id: boundInline(taskId ?? details.taskId) }, details: [] },
      body: { type: "text", text: boundHead(text || details.error), tone: "error" },
      notices: [{ type: "message", tone: "error", text: boundInline(details.error) }],
      preview: { type: "head", rows: 8 }
    }
  }

  return {
    header: {
      label: "Kill task",
      subject: { type: "task", id: boundInline(taskId ?? details?.taskId ?? "…") },
      details: details
        ? [
            boundInline(stopLabel(details.stop)),
            ...(details.finalOutcome ? [boundInline(outcomeLabel(details.finalOutcome))] : [])
          ]
        : []
    },
    notices: [],
    preview: { type: "hidden" }
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
    ...(details.stopReason ? [boundInline(details.stopReason)] : []),
    ...(details.finalOutcome ? [boundInline(outcomeLabel(details.finalOutcome))] : [])
  ]
}

function shellOutputNotices(output: ShellOutputDetails): ToolNotice[] {
  if (!output.truncation.truncated) return []
  const notices: ToolNotice[] = [
    {
      type: "message",
      tone: "warning",
      text: `Output truncated to ${output.truncation.outputLines} lines (${formatBytes(output.truncation.outputBytes)})`
    }
  ]
  if (output.fullOutput.type === "available") {
    notices.push({ type: "path", tone: "warning", label: "Full output", path: boundInline(output.fullOutput.path) })
  } else {
    notices.push({
      type: "message",
      tone: "warning",
      text: `Full output is no longer retained (${formatBytes(output.fullOutput.bytes)})`
    })
  }
  if (output.fullOutput.truncated) {
    notices.push({ type: "message", tone: "warning", text: "Full output reached its retention limit" })
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
      return `failed: ${outcome.message}`
    default:
      return assertNever(outcome)
  }
}

function assertNever(value: never): never {
  throw new Error(`Unexpected shell task presentation: ${String(value)}`)
}
