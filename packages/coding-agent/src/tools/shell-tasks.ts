import type { AgentTool } from "@earendil-works/pi-agent-core"
import { Type } from "@earendil-works/pi-ai"

import type {
  SessionShell,
  ShellFullOutput,
  ShellKillResult,
  ShellTaskOutcome,
  ShellTaskOutputSnapshot,
  ShellTaskSnapshot
} from "../session-shell.js"
import { boundToolText, isBoundedToolText, maxToolErrorScalars } from "./text.js"
import { isTruncationDetails, truncationDetails, type TruncationDetails } from "./truncate.js"

const maxTaskIdLength = 4_096

const outputParameters = Type.Object({
  taskId: Type.String({ maxLength: maxTaskIdLength, description: "Background task ID returned by bash" }),
  timeout: Type.Optional(
    Type.Number({ minimum: 0, description: "Seconds to wait for completion; omit or use 0 to poll" })
  )
})

const killParameters = Type.Object({
  taskId: Type.String({ maxLength: maxTaskIdLength, description: "Background task ID returned by bash" })
})

export interface ShellOutputDetails {
  readonly truncation: TruncationDetails
  readonly fullOutput: ShellFullOutput
}

interface TaskOutputBase {
  readonly taskId: string
  readonly state: ShellTaskSnapshot["type"]
  readonly placement?: "foreground" | "background"
  readonly stopReason?: Extract<ShellTaskSnapshot, { type: "stopping" }>["reason"]
  readonly finalOutcome?: ShellTaskOutcome
  readonly output: ShellOutputDetails
}

export type TaskOutputToolDetails =
  | (TaskOutputBase & { readonly outcome: "progress" })
  | (TaskOutputBase & { readonly outcome: "success" })
  | { readonly outcome: "error"; readonly taskId: string; readonly error: string }

interface KillTaskBase {
  readonly taskId: string
  readonly stop: Exclude<ShellKillResult["type"], "not_found">
  readonly finalOutcome?: ShellTaskOutcome
}

export type KillTaskToolDetails =
  | (KillTaskBase & { readonly outcome: "success" })
  | { readonly outcome: "error"; readonly taskId: string; readonly error: string }

export function createTaskOutputTool(shell: SessionShell): AgentTool<typeof outputParameters, TaskOutputToolDetails> {
  return {
    name: "task_output",
    label: "task output",
    description:
      "Read the current status and bounded output of a background shell task, optionally waiting for completion.",
    parameters: outputParameters,
    async execute(_id, input, signal) {
      let task: ShellTaskSnapshot | undefined
      try {
        task = await shell.wait(input.taskId, (input.timeout ?? 0) * 1_000, signal)
      } catch (cause) {
        if (signal?.aborted) throw cause
        return errorResult(input.taskId, errorMessage(cause))
      }
      if (!task) return errorResult(input.taskId, `Shell task not found: ${input.taskId}`)
      return { content: [{ type: "text", text: formatTask(task) }], details: taskOutputDetails(task) }
    }
  }
}

export function createKillTaskTool(shell: SessionShell): AgentTool<typeof killParameters, KillTaskToolDetails> {
  return {
    name: "kill_task",
    label: "kill task",
    description: "Stop a background shell task owned by this agent session.",
    parameters: killParameters,
    async execute(_id, input) {
      const result = await shell.kill(input.taskId)
      if (result.type === "not_found") {
        return {
          content: [{ type: "text", text: `Running shell task not found: ${input.taskId}` }],
          details: {
            outcome: "error",
            taskId: input.taskId,
            error: boundToolText(`Running shell task not found: ${input.taskId}`)
          }
        }
      }

      return {
        content: [{ type: "text", text: killResultText(input.taskId, result.type) }],
        details: {
          outcome: "success",
          taskId: input.taskId,
          stop: result.type,
          ...(result.task.type === "completed" || result.task.type === "settling"
            ? { finalOutcome: boundedOutcome(result.task.outcome) }
            : {})
        }
      }
    }
  }
}

export function shellOutputDetails(output: ShellTaskOutputSnapshot): ShellOutputDetails {
  return { truncation: truncationDetails(output.truncation), fullOutput: boundedFullOutput(output.fullOutput) }
}

export function isTaskOutputToolDetails(value: unknown): value is TaskOutputToolDetails {
  if (!isRecord(value) || !isBoundedString(value.taskId)) return false
  if (value.outcome === "error") return isBoundedString(value.error)
  if (value.outcome !== "progress" && value.outcome !== "success") return false
  if (!isTaskState(value.state) || !isShellOutputDetails(value.output)) return false
  if (
    value.state === "starting"
      ? value.placement !== "foreground" && value.placement !== "background"
      : value.placement !== undefined
  ) {
    return false
  }
  if (value.state === "stopping" ? !isStopReason(value.stopReason) : value.stopReason !== undefined) return false
  if (value.state === "completed" || value.state === "settling") {
    if (!isShellTaskOutcome(value.finalOutcome)) return false
  } else if (value.finalOutcome !== undefined) {
    return false
  }
  return value.outcome !== "progress" || value.state !== "completed"
}

export function isKillTaskToolDetails(value: unknown): value is KillTaskToolDetails {
  if (!isRecord(value) || !isBoundedString(value.taskId)) return false
  if (value.outcome === "error") return isBoundedString(value.error)
  if (value.outcome !== "success") return false
  if (value.stop !== "already_completed" && value.stop !== "settling" && value.stop !== "stopping") return false
  return value.stop === "stopping" ? value.finalOutcome === undefined : isShellTaskOutcome(value.finalOutcome)
}

export function isShellOutputDetails(value: unknown): value is ShellOutputDetails {
  if (!isRecord(value) || !isTruncationDetails(value.truncation) || !isRecord(value.fullOutput)) return false
  if (
    !isNonNegativeInteger(value.fullOutput.bytes) ||
    value.fullOutput.bytes > value.truncation.totalBytes ||
    typeof value.fullOutput.truncated !== "boolean"
  ) {
    return false
  }
  if (value.fullOutput.type === "evicted") return true
  return value.fullOutput.type === "available" && isBoundedString(value.fullOutput.path)
}

export function isShellTaskOutcome(value: unknown): value is ShellTaskOutcome {
  if (!isRecord(value)) return false
  switch (value.type) {
    case "exited":
      return Number.isInteger(value.exitCode)
    case "signaled":
      return isBoundedString(value.signal)
    case "failed":
      return isBoundedString(value.message)
    case "aborted":
    case "timed_out":
    case "killed":
    case "output_limit":
    case "disposed":
      return true
    default:
      return false
  }
}

function taskOutputDetails(task: ShellTaskSnapshot): TaskOutputToolDetails {
  return {
    outcome: "success",
    taskId: task.taskId,
    state: task.type,
    ...(task.type === "starting" ? { placement: task.placement } : {}),
    ...(task.type === "stopping" ? { stopReason: task.reason } : {}),
    ...(task.type === "completed" || task.type === "settling" ? { finalOutcome: boundedOutcome(task.outcome) } : {}),
    output: shellOutputDetails(task.output)
  }
}

function errorResult(taskId: string, message: string) {
  const error = boundToolText(message)
  return { content: [{ type: "text" as const, text: error }], details: { outcome: "error" as const, taskId, error } }
}

function formatTask(task: ShellTaskSnapshot): string {
  const status =
    task.type === "completed"
      ? formatOutcome(task.outcome)
      : task.type === "stopping"
        ? `stopping (${task.reason})`
        : task.type === "starting"
          ? `starting (${task.placement})`
          : task.type
  let text = `${task.output.text}\n\nTask ${task.taskId}: ${status}`
  if (task.output.truncation.truncated && task.output.fullOutput.type === "available") {
    text += `\n\n[Output truncated. Full output: ${task.output.fullOutput.path}]`
  }
  return text
}

function formatOutcome(outcome: ShellTaskOutcome): string {
  switch (outcome.type) {
    case "exited":
      return `completed (exit ${outcome.exitCode})`
    case "signaled":
      return `terminated (${outcome.signal})`
    case "aborted":
      return "aborted"
    case "timed_out":
      return "timed out"
    case "killed":
      return "killed"
    case "output_limit":
      return "stopped at output limit"
    case "disposed":
      return "disposed"
    case "failed":
      return `failed (${outcome.message})`
    default:
      return assertNever(outcome)
  }
}

function killResultText(taskId: string, stop: KillTaskBase["stop"]): string {
  switch (stop) {
    case "already_completed":
      return `Shell task ${taskId} already completed.`
    case "settling":
      return `Shell task ${taskId} is settling.`
    case "stopping":
      return `Stopping shell task ${taskId}.`
    default:
      return assertNever(stop)
  }
}

function boundedOutcome(outcome: ShellTaskOutcome): ShellTaskOutcome {
  return outcome.type === "failed" ? { type: "failed", message: boundToolText(outcome.message) } : outcome
}

function boundedFullOutput(output: ShellFullOutput): ShellFullOutput {
  return output.type === "available"
    ? {
        type: "available",
        path: boundToolText(output.path, maxToolErrorScalars),
        bytes: output.bytes,
        truncated: output.truncated
      }
    : { type: "evicted", bytes: output.bytes, truncated: output.truncated }
}

function errorMessage(cause: unknown): string {
  return cause instanceof Error ? cause.message : String(cause)
}

function isStopReason(value: unknown): value is Extract<ShellTaskSnapshot, { type: "stopping" }>["reason"] {
  return (
    value === "abort" ||
    value === "timeout" ||
    value === "killed" ||
    value === "output-limit" ||
    value === "output-error" ||
    value === "dispose"
  )
}

function isTaskState(value: unknown): value is ShellTaskSnapshot["type"] {
  return (
    value === "starting" ||
    value === "foreground" ||
    value === "background" ||
    value === "stopping" ||
    value === "settling" ||
    value === "completed"
  )
}

function isNonNegativeInteger(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0
}

function isBoundedString(value: unknown): value is string {
  return isBoundedToolText(value)
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}

function assertNever(value: never): never {
  throw new Error(`Unexpected shell task state: ${String(value)}`)
}
