import type { AgentTool } from "@earendil-works/pi-agent-core"
import { Type } from "@earendil-works/pi-ai"

import {
  type SessionShell,
  type ShellRunResult,
  type ShellTaskOutputSnapshot,
  type ShellTaskSnapshot
} from "../session-shell.js"
import type { TruncationResult } from "./truncate.js"

const DEFAULT_TIMEOUT_SECONDS = 120

const parameters = Type.Object({
  command: Type.String({ description: "Bash command to execute" }),
  timeout: Type.Optional(Type.Number({ exclusiveMinimum: 0, description: "Timeout in seconds" })),
  background: Type.Optional(Type.Boolean({ description: "Run in the background and return a task ID immediately" }))
})

export interface BashToolDetails {
  readonly taskId: string
  readonly status: "running" | "completed" | "backgrounded"
  readonly truncation?: TruncationResult
  readonly fullOutputPath?: string
  readonly fullOutputTruncated?: boolean
}

export function createBashTool(shell: SessionShell): AgentTool<typeof parameters, BashToolDetails> {
  return {
    name: "bash",
    label: "bash",
    description:
      "Execute a shell command in the working directory. Output is limited to the last 2,000 lines or 50 KiB. Set background=true for a long-running command and use task_output or kill_task with the returned task ID.",
    parameters,
    executionMode: "sequential",
    async execute(id, input, signal, onUpdate) {
      const background = input.background ?? false
      const timeoutSeconds = input.timeout ?? (background ? shell.limits.maxRuntimeMs / 1_000 : DEFAULT_TIMEOUT_SECONDS)
      const timeoutMs = timeoutSeconds * 1_000
      const result = await shell.run(id, { command: input.command, timeoutMs, background }, signal, task =>
        onUpdate?.(toolResult(task.output, details(task, "running")))
      )
      return finish(result)
    }
  }
}

function finish(result: ShellRunResult) {
  if (result.type === "backgrounded") {
    const output = result.task.output
    return toolResult(
      { ...output, text: `${output.text}\n\nCommand running in background (task ${result.task.taskId})` },
      details(result.task, "backgrounded")
    )
  }

  const { task } = result
  const output = task.output
  const status = outcomeStatus(task)
  if (status) throw new Error(withStatus(outputText(output), status))
  return toolResult(output, details(task, "completed"))
}

function outcomeStatus(task: Extract<ShellTaskSnapshot, { type: "completed" }>): string | undefined {
  switch (task.outcome.type) {
    case "exited":
      return task.outcome.exitCode === 0 ? undefined : `Command exited with code ${task.outcome.exitCode}`
    case "signaled":
      return `Command terminated by ${task.outcome.signal}`
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
      return `Command failed: ${task.outcome.message}`
    default:
      return assertNever(task.outcome)
  }
}

function details(task: ShellTaskSnapshot, status: BashToolDetails["status"]): BashToolDetails {
  const output = task.output
  return {
    taskId: task.taskId,
    status,
    ...(output.truncation.truncated ? { truncation: output.truncation } : {}),
    ...(output.truncation.truncated && output.fullOutput.type === "available"
      ? {
          fullOutputPath: output.fullOutput.path,
          ...(output.fullOutput.truncated ? { fullOutputTruncated: true } : {})
        }
      : {})
  }
}

function toolResult(output: ShellTaskOutputSnapshot, resultDetails: BashToolDetails) {
  return { content: [{ type: "text" as const, text: outputText(output) }], details: resultDetails }
}

function outputText(output: ShellTaskOutputSnapshot): string {
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

function assertNever(value: never): never {
  throw new Error(`Unexpected shell task outcome: ${String(value)}`)
}
