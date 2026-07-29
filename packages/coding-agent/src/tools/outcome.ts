import { isBashToolDetails } from "./bash.js"
import { isEditToolDetails } from "./edit.js"
import { isReadToolDetails } from "./read.js"
import { isKillTaskToolDetails, isTaskOutputToolDetails } from "./shell-tasks.js"
import { isWriteToolDetails } from "./write.js"

export type BuiltInToolOutcome = "progress" | "success" | "error"

export function isBuiltInToolError(name: string, details: unknown): boolean {
  switch (name) {
    case "bash":
      return isBashToolDetails(details) && details.outcome === "error"
    case "read":
      return isReadToolDetails(details) && details.outcome === "error"
    case "write":
      return isWriteToolDetails(details) && details.outcome === "error"
    case "edit":
      return isEditToolDetails(details) && details.outcome === "error"
    case "task_output":
      return isTaskOutputToolDetails(details) && details.outcome === "error"
    case "kill_task":
      return isKillTaskToolDetails(details) && details.outcome === "error"
    default:
      return false
  }
}
