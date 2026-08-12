import type { AgentTool } from "@earendil-works/pi-agent-core"
import { Type } from "@earendil-works/pi-ai"

import { isNonNegativeInteger, isRecord } from "../guards.js"
import type {
  SessionShell,
  ShellFullOutput,
  ShellKillResult,
  ShellTaskOutcome,
  ShellTaskOutputSnapshot,
  ShellTaskSnapshot,
  ShellTaskSummary,
  ShellStopReason
} from "../session-shell.js"
import { boundToolText, isBoundedToolText, maxToolErrorScalars } from "./text.js"
import { isTruncationDetails, truncationDetails, type TruncationDetails } from "./truncate.js"

const maxTaskIdLength = 4_096
const maxTaskListResults = 100
const defaultTaskListResults = 20
const maxTaskCommandPreviewScalars = 160

const outputParameters = Type.Object({
  taskId: Type.String({ maxLength: maxTaskIdLength, description: "Background task ID returned by bash" }),
  timeout: Type.Optional(
    Type.Number({ minimum: 0, description: "Seconds to wait for completion; omit or use 0 to poll" })
  ),
  cursor: Type.Optional(
    Type.Integer({ minimum: 0, description: "Byte cursor returned by a previous task_output call" })
  )
})

const listParameters = Type.Object({
  limit: Type.Optional(
    Type.Integer({ minimum: 1, maximum: maxTaskListResults, description: "Maximum recent tasks to return" })
  )
})

const killParameters = Type.Object({
  taskId: Type.String({ maxLength: maxTaskIdLength, description: "Background task ID returned by bash" })
})

export interface ShellOutputDetails {
  readonly truncation: TruncationDetails
  readonly fullOutput: ShellFullOutput
  readonly cursor?: number
  readonly nextCursor?: number
  readonly omittedBytes?: number
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

interface TaskListItemBase {
  readonly taskId: string
  readonly command: string
  readonly startedAt: number
}

export type TaskListItemDetails =
  | (TaskListItemBase & { readonly state: "starting"; readonly placement: "foreground" | "background" })
  | (TaskListItemBase & { readonly state: "foreground" | "background" })
  | (TaskListItemBase & { readonly state: "stopping"; readonly stopReason: ShellStopReason })
  | (TaskListItemBase & { readonly state: "settling"; readonly finalOutcome: ShellTaskOutcome })
  | (TaskListItemBase & {
      readonly state: "completed"
      readonly finalOutcome: ShellTaskOutcome
      readonly completedAt: number
    })

export type TaskListToolDetails =
  | { readonly outcome: "success"; readonly tasks: readonly TaskListItemDetails[]; readonly omitted: number }
  | { readonly outcome: "error"; readonly error: string }

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
        task = await shell.wait(input.taskId, (input.timeout ?? 0) * 1_000, signal, input.cursor)
      } catch (cause) {
        if (signal?.aborted) throw cause
        return errorResult(input.taskId, errorMessage(cause))
      }
      if (!task) return errorResult(input.taskId, `Shell task not found: ${input.taskId}`)
      return { content: [{ type: "text", text: formatTask(task) }], details: taskOutputDetails(task) }
    }
  }
}

export function createListTasksTool(shell: SessionShell): AgentTool<typeof listParameters, TaskListToolDetails> {
  return {
    name: "list_tasks",
    label: "list tasks",
    description: "List recent shell tasks owned by this agent session without reading their output.",
    parameters: listParameters,
    async execute(_id, input) {
      try {
        const listed = shell.list(Math.min(input.limit ?? defaultTaskListResults, shell.limits.maxCompletedTasks))
        const tasks = listed.tasks.map(taskListItem)
        return {
          content: [{ type: "text", text: formatTaskList(tasks, listed.omitted) }],
          details: { outcome: "success", tasks, omitted: listed.omitted }
        }
      } catch (cause) {
        const error = boundToolText(errorMessage(cause))
        return { content: [{ type: "text", text: error }], details: { outcome: "error", error } }
      }
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
  return {
    truncation: truncationDetails(output.truncation),
    fullOutput: boundedFullOutput(output.fullOutput),
    ...(output.cursor === undefined ? {} : { cursor: output.cursor }),
    nextCursor: output.nextCursor,
    omittedBytes: output.omittedBytes
  }
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

export function isTaskListToolDetails(value: unknown): value is TaskListToolDetails {
  if (!isRecord(value) || (value.outcome !== "success" && value.outcome !== "error")) return false
  if (value.outcome === "error") return isBoundedToolText(value.error)
  return (
    Array.isArray(value.tasks) &&
    value.tasks.length <= maxTaskListResults &&
    value.tasks.every(isTaskListItemDetails) &&
    isNonNegativeInteger(value.omitted)
  )
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
  if (!isNonNegativeInteger(value.fullOutput.bytes) || typeof value.fullOutput.truncated !== "boolean") return false
  const hasCursorDetails =
    value.nextCursor !== undefined || value.omittedBytes !== undefined || value.cursor !== undefined
  if (
    hasCursorDetails &&
    ((value.cursor !== undefined && !isNonNegativeInteger(value.cursor)) ||
      !isNonNegativeInteger(value.nextCursor) ||
      !isNonNegativeInteger(value.omittedBytes) ||
      (value.cursor ?? 0) + value.omittedBytes + value.truncation.outputBytes !== value.nextCursor)
  ) {
    return false
  }
  if (!hasCursorDetails && value.fullOutput.bytes > value.truncation.totalBytes) return false
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

function taskListItem(task: ShellTaskSummary): TaskListItemDetails {
  const base = {
    taskId: task.taskId,
    command: boundToolText(task.command, maxTaskCommandPreviewScalars),
    startedAt: task.startedAt
  }
  switch (task.type) {
    case "starting":
      return { ...base, state: task.type, placement: task.placement }
    case "foreground":
    case "background":
      return { ...base, state: task.type }
    case "stopping":
      return { ...base, state: task.type, stopReason: task.reason }
    case "settling":
      return { ...base, state: task.type, finalOutcome: boundedOutcome(task.outcome) }
    case "completed":
      return { ...base, state: task.type, finalOutcome: boundedOutcome(task.outcome), completedAt: task.completedAt }
    default:
      return assertNever(task)
  }
}

function isTaskListItemDetails(value: unknown): value is TaskListItemDetails {
  if (
    !isRecord(value) ||
    !isBoundedString(value.taskId) ||
    !isTaskState(value.state) ||
    !isBoundedToolText(value.command, maxTaskCommandPreviewScalars) ||
    !isNonNegativeInteger(value.startedAt)
  ) {
    return false
  }
  if (
    value.state === "starting"
      ? value.placement !== "foreground" && value.placement !== "background"
      : value.placement !== undefined
  ) {
    return false
  }
  if (value.state === "stopping" ? !isStopReason(value.stopReason) : value.stopReason !== undefined) return false
  if (value.state === "settling" || value.state === "completed") {
    if (!isShellTaskOutcome(value.finalOutcome)) return false
  } else if (value.finalOutcome !== undefined) {
    return false
  }
  return value.state === "completed" ? isNonNegativeInteger(value.completedAt) : value.completedAt === undefined
}

function formatTaskList(tasks: readonly TaskListItemDetails[], omitted: number): string {
  if (tasks.length === 0) return "No shell tasks."
  const lines = tasks.map(task => `${task.taskId}  ${taskStateText(task)}  ${task.command}`)
  if (omitted > 0) lines.push(`\n${omitted} older task${omitted === 1 ? "" : "s"} omitted.`)
  return lines.join("\n")
}

function taskStateText(task: TaskListItemDetails): string {
  switch (task.state) {
    case "starting":
      return `starting (${task.placement})`
    case "foreground":
    case "background":
      return task.state
    case "stopping":
      return `stopping (${task.stopReason})`
    case "settling":
    case "completed":
      return formatOutcome(task.finalOutcome)
    default:
      return assertNever(task)
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
  let text = `${task.output.text}\n\nTask ${task.taskId}: ${status}\nNext cursor: ${task.output.nextCursor}`
  if (task.output.omittedBytes > 0) text += `\n[${task.output.omittedBytes} earlier output bytes omitted.]`
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

function isBoundedString(value: unknown): value is string {
  return isBoundedToolText(value)
}

function assertNever(value: never): never {
  throw new Error(`Unexpected shell task state: ${String(value)}`)
}
