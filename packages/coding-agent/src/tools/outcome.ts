import { isBashToolDetails } from "./bash.js"
import { isEditToolDetails } from "./edit.js"
import { isReadToolDetails } from "./read.js"
import { isKillTaskToolDetails, isTaskOutputToolDetails } from "./shell-tasks.js"
import { isWriteToolDetails } from "./write.js"

export type BuiltInToolOutcome = "progress" | "success" | "error"

export function isBuiltInToolError(name: string, details: unknown): boolean {
  return builtInToolFailureReason(name, details) !== undefined
}

export function builtInToolFailureReason(name: string, details: unknown): string | undefined {
  switch (name) {
    case "bash":
      if (!isBashToolDetails(details) || details.outcome !== "error") return undefined
      if (details.state === "rejected") return "rejected"
      const outcome = details.finalOutcome
      if (outcome === undefined) return undefined
      switch (outcome.type) {
        case "exited":
          return `exit_nonzero (exit ${outcome.exitCode})`
        case "signaled":
          return `signaled (${outcome.signal})`
        case "failed":
          return "execution_failed"
        default:
          return outcome.type
      }
    case "read":
      return isReadToolDetails(details) && details.outcome === "error" ? details.reason : undefined
    case "write":
      return isWriteToolDetails(details) && details.outcome === "error" ? details.reason : undefined
    case "edit":
      return isEditToolDetails(details) && details.outcome === "error" ? details.reason : undefined
    case "task_output":
      return isTaskOutputToolDetails(details) && details.outcome === "error" ? "task_error" : undefined
    case "kill_task":
      return isKillTaskToolDetails(details) && details.outcome === "error" ? "task_error" : undefined
    default:
      return undefined
  }
}
