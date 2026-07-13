export * from "./bash.js"
export * from "./edit.js"
export * from "./read.js"
export * from "./truncate.js"
export * from "./write.js"

import type { AgentTool } from "@earendil-works/pi-agent-core"
import { createBashTool } from "./bash.js"
import { createEditTool } from "./edit.js"
import { createReadTool } from "./read.js"
import { createWriteTool } from "./write.js"

export function createCodingTools(cwd: string): AgentTool[] {
  return [createReadTool(cwd), createBashTool(cwd), createEditTool(cwd), createWriteTool(cwd)]
}
