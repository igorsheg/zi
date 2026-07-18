export * from "./bash.js"
export * from "./edit.js"
export * from "./lines.js"
export * from "./read.js"
export * from "./presentation/project.js"
export * from "./presentation/types.js"
export * from "./shell-tasks.js"
export * from "./truncate.js"
export * from "./write.js"

import type { AgentTool } from "@earendil-works/pi-agent-core"

import type { SessionShell } from "../session-shell.js"
import { createBashTool, isBashToolDetails } from "./bash.js"
import { createEditTool, isEditToolDetails } from "./edit.js"
import { createReadTool, isReadToolDetails } from "./read.js"
import {
  createKillTaskTool,
  createTaskOutputTool,
  isKillTaskToolDetails,
  isTaskOutputToolDetails
} from "./shell-tasks.js"
import { createWriteTool, isWriteToolDetails } from "./write.js"

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

export interface CreateCodingToolsOptions {
  readonly cwd: string
  readonly shell: SessionShell
}

export function createCodingTools({ cwd, shell }: CreateCodingToolsOptions): AgentTool[] {
  return [
    createReadTool(cwd),
    createBashTool(shell),
    createEditTool(cwd),
    createWriteTool(cwd),
    createTaskOutputTool(shell),
    createKillTaskTool(shell)
  ]
}
