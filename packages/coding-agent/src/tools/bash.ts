import type { AgentTool } from "@earendil-works/pi-agent-core"
import { Type } from "@earendil-works/pi-ai"

import { isRecord } from "../guards.js"
import {
  ShellRunAdmissionError,
  type SessionShell,
  type ShellRunResult,
  type ShellTaskOutcome,
  type ShellTaskSnapshot
} from "../session-shell.js"
import { isShellOutputDetails, isShellTaskOutcome, shellOutputDetails, type ShellOutputDetails } from "./shell-tasks.js"
import { boundToolText, isBoundedToolText } from "./text.js"

const DEFAULT_TIMEOUT_SECONDS = 120
const maxCommandLength = 256 * 1024
const maxDescriptionLength = 160

const parameters = Type.Object({
  command: Type.String({ minLength: 1, maxLength: maxCommandLength, description: "Bash command to execute" }),
  description: Type.Optional(
    Type.String({
      minLength: 1,
      maxLength: maxDescriptionLength,
      description: "Brief human description of what the command does; do not start with Run or Running"
    })
  ),
  timeout: Type.Optional(Type.Number({ exclusiveMinimum: 0, description: "Timeout in seconds" })),
  background: Type.Optional(Type.Boolean({ description: "Run in the background and return a task ID immediately" }))
})

interface BashDetailsBase {
  readonly taskId: string
  readonly state: "foreground" | "background" | "completed"
  readonly timeoutSeconds: number
  readonly output: ShellOutputDetails
  readonly finalOutcome?: ShellTaskOutcome
}

export type BashToolDetails =
  | (BashDetailsBase & { readonly outcome: "progress" })
  | (BashDetailsBase & { readonly outcome: "success" })
  | (BashDetailsBase & { readonly outcome: "error"; readonly error: string })
  | { readonly outcome: "error"; readonly state: "rejected"; readonly timeoutSeconds: number; readonly error: string }

export function createBashTool(shell: SessionShell): AgentTool<typeof parameters, BashToolDetails> {
  return {
    name: "bash",
    label: "bash",
    description:
      "Execute a shell command in the working directory. Provide a brief description for the activity row. Output is limited to the last 2,000 lines or 50 KiB. Set background=true for a long-running command and use task_output or kill_task with the returned task ID.",
    parameters,
    executionMode: "sequential",
    async execute(id, input, signal, onUpdate) {
      const background = input.background ?? false
      const sessionTimeoutSeconds = shell.limits.maxRuntimeMs / 1_000
      const timeoutSeconds =
        input.timeout ?? (background ? sessionTimeoutSeconds : Math.min(DEFAULT_TIMEOUT_SECONDS, sessionTimeoutSeconds))
      const timeoutMs = timeoutSeconds * 1_000
      if (timeoutMs > shell.limits.maxRuntimeMs) {
        return rejected(
          timeoutSeconds,
          `Command timeout exceeds the ${shell.limits.maxRuntimeMs / 1_000} second session limit`
        )
      }

      let result: ShellRunResult
      try {
        result = await shell.run(id, { command: input.command, timeoutMs, background }, signal, task =>
          onUpdate?.(toolResult(task.output.text, details(task, "progress", timeoutSeconds)))
        )
      } catch (cause) {
        if (signal?.aborted || !(cause instanceof ShellRunAdmissionError) || cause.reason !== "background-capacity") {
          throw cause
        }
        return rejected(timeoutSeconds, cause.message)
      }
      return finish(result, timeoutSeconds)
    }
  }
}

export function isBashToolDetails(value: unknown): value is BashToolDetails {
  if (
    !isRecord(value) ||
    (value.outcome !== "progress" && value.outcome !== "success" && value.outcome !== "error") ||
    typeof value.timeoutSeconds !== "number" ||
    !Number.isFinite(value.timeoutSeconds) ||
    value.timeoutSeconds <= 0
  ) {
    return false
  }
  if (value.state === "rejected") return value.outcome === "error" && isBoundedToolText(value.error)
  if (
    !isBoundedToolText(value.taskId) ||
    (value.state !== "foreground" && value.state !== "background" && value.state !== "completed") ||
    !isShellOutputDetails(value.output)
  ) {
    return false
  }
  if (value.outcome === "progress") return value.state === "foreground" && value.finalOutcome === undefined
  if (value.outcome === "success") {
    return value.state === "background"
      ? value.finalOutcome === undefined
      : value.state === "completed" &&
          isShellTaskOutcome(value.finalOutcome) &&
          value.finalOutcome.type === "exited" &&
          value.finalOutcome.exitCode === 0
  }
  return (
    value.state === "completed" && isExpectedShellErrorOutcome(value.finalOutcome) && isBoundedToolText(value.error)
  )
}

function rejected(timeoutSeconds: number, message: string) {
  const error = boundToolText(message)
  return toolResult(error, { outcome: "error", state: "rejected", timeoutSeconds, error })
}

function finish(result: ShellRunResult, timeoutSeconds: number) {
  if (result.type === "backgrounded") {
    const output = result.task.output
    return toolResult(
      `${output.text}\n\nCommand running in background (task ${result.task.taskId})`,
      details(result.task, "success", timeoutSeconds)
    )
  }

  const { task } = result
  const status = outcomeStatus(task.outcome)
  if (status) {
    const error = boundToolText(status)
    return toolResult(withStatus(outputText(task), error), { ...details(task, "error", timeoutSeconds), error })
  }
  return toolResult(outputText(task), details(task, "success", timeoutSeconds))
}

function outcomeStatus(outcome: ShellTaskOutcome): string | undefined {
  switch (outcome.type) {
    case "exited":
      return outcome.exitCode === 0 ? undefined : `Command exited with code ${outcome.exitCode}`
    case "signaled":
      return `Command terminated by ${outcome.signal}`
    case "aborted":
      return "Command aborted"
    case "timed_out":
      return "Command timed out"
    case "killed":
      return "Command killed"
    case "output_limit":
      return "Command stopped after reaching its output limit"
    case "disposed":
      return "Command stopped because the session was disposed"
    case "failed":
      return `Command failed: ${outcome.message}`
    default:
      return assertNever(outcome)
  }
}

function details(
  task: ShellTaskSnapshot,
  outcome: "progress",
  timeoutSeconds: number
): Extract<BashToolDetails, { outcome: "progress" }>
function details(
  task: ShellTaskSnapshot,
  outcome: "success",
  timeoutSeconds: number
): Extract<BashToolDetails, { outcome: "success" }>
function details(
  task: ShellTaskSnapshot,
  outcome: "error",
  timeoutSeconds: number
): Extract<BashToolDetails, { outcome: "error" }>
function details(
  task: ShellTaskSnapshot,
  outcome: BashToolDetails["outcome"],
  timeoutSeconds: number
): BashToolDetails {
  const base: BashDetailsBase = {
    taskId: task.taskId,
    state: task.type === "background" ? "background" : task.type === "completed" ? "completed" : "foreground",
    timeoutSeconds,
    output: shellOutputDetails(task.output),
    ...(task.type === "completed" || task.type === "settling" ? { finalOutcome: boundedOutcome(task.outcome) } : {})
  }
  switch (outcome) {
    case "progress":
      return { ...base, outcome }
    case "success":
      return { ...base, outcome }
    case "error":
      return { ...base, outcome, error: "Command failed" }
    default:
      return assertNever(outcome)
  }
}

function toolResult(text: string, resultDetails: BashToolDetails) {
  return { content: [{ type: "text" as const, text }], details: resultDetails }
}

function outputText(task: ShellTaskSnapshot): string {
  const output = task.output
  let text = output.text
  if (output.truncation.truncated && output.fullOutput.type === "available") {
    text += `\n\n[Output truncated. Full output: ${output.fullOutput.path}]`
    if (output.fullOutput.truncated) text += "\n[Full output file reached its retention limit.]"
  }
  return text
}

function withStatus(output: string, status: string): string {
  return output && output !== "(no output)" ? `${output}\n\n${status}` : status
}

function boundedOutcome(outcome: ShellTaskOutcome): ShellTaskOutcome {
  return outcome.type === "failed" ? { type: "failed", message: boundToolText(outcome.message) } : outcome
}

function isExpectedShellErrorOutcome(value: unknown): value is ShellTaskOutcome {
  if (!isShellTaskOutcome(value)) return false
  return (
    (value.type === "exited" && value.exitCode !== 0) ||
    value.type === "signaled" ||
    value.type === "timed_out" ||
    value.type === "killed" ||
    value.type === "aborted" ||
    value.type === "output_limit" ||
    value.type === "disposed" ||
    value.type === "failed"
  )
}

function assertNever(value: never): never {
  throw new Error(`Unexpected shell task outcome: ${String(value)}`)
}
