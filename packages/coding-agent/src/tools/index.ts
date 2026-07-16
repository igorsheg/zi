export * from "./bash.js"
export * from "./edit.js"
export * from "./read.js"
export * from "./presentation.js"
export * from "./shell-tasks.js"
export * from "./truncate.js"
export * from "./write.js"

import type { AgentTool } from "@earendil-works/pi-agent-core"

import type { SessionShell } from "../session-shell.js"
import { createBashTool } from "./bash.js"
import { createEditTool } from "./edit.js"
import { createReadTool } from "./read.js"
import { createKillTaskTool, createTaskOutputTool } from "./shell-tasks.js"
import { createWriteTool } from "./write.js"

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
