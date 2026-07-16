import type { AgentTool } from "@earendil-works/pi-agent-core"
import { Type } from "@earendil-works/pi-ai"

import type { SessionShell, ShellTaskSnapshot } from "../session-shell.js"

const outputParameters = Type.Object({
  taskId: Type.String({ description: "Background task ID returned by bash" }),
  timeout: Type.Optional(
    Type.Number({ minimum: 0, description: "Seconds to wait for completion; omit or use 0 to poll" })
  )
})

const killParameters = Type.Object({ taskId: Type.String({ description: "Background task ID returned by bash" }) })

export function createTaskOutputTool(shell: SessionShell): AgentTool<typeof outputParameters, ShellTaskSnapshot> {
  return {
    name: "task_output",
    label: "task output",
    description:
      "Read the current status and bounded output of a background shell task, optionally waiting for completion.",
    parameters: outputParameters,
    async execute(_id, input, signal) {
      const task = await shell.wait(input.taskId, (input.timeout ?? 0) * 1_000, signal)
      if (!task) throw new Error(`Shell task not found: ${input.taskId}`)
      return { content: [{ type: "text", text: formatTask(task) }], details: task }
    }
  }
}

export function createKillTaskTool(
  shell: SessionShell
): AgentTool<typeof killParameters, ShellTaskSnapshot | undefined> {
  return {
    name: "kill_task",
    label: "kill task",
    description: "Stop a background shell task owned by this agent session.",
    parameters: killParameters,
    async execute(_id, input) {
      const result = await shell.kill(input.taskId)
      switch (result.type) {
        case "not_found":
          throw new Error(`Running shell task not found: ${input.taskId}`)
        case "already_completed":
          return {
            content: [{ type: "text", text: `Shell task ${input.taskId} already completed.` }],
            details: result.task
          }
        case "settling":
          return { content: [{ type: "text", text: `Shell task ${input.taskId} is settling.` }], details: result.task }
        case "stopping":
          return { content: [{ type: "text", text: `Stopping shell task ${input.taskId}.` }], details: result.task }
        default:
          return assertNever(result)
      }
    }
  }
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
  let text = `Task ${task.taskId}: ${status}\n${task.output.text}`
  if (task.output.truncation.truncated && task.output.fullOutput.type === "available") {
    text += `\n\n[Output truncated. Full output: ${task.output.fullOutput.path}]`
  }
  return text
}

function formatOutcome(outcome: Extract<ShellTaskSnapshot, { type: "completed" }>["outcome"]): string {
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

function assertNever(value: never): never {
  throw new Error(`Unexpected shell task state: ${String(value)}`)
}
