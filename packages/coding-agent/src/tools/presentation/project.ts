import { projectBash } from "./bash.js"
import { projectCodeTool } from "./code.js"
import { projectEdit } from "./edit.js"
import { projectGeneric } from "./generic.js"
import { projectRead } from "./read.js"
import { projectKillTask, projectTaskOutput } from "./shell-task.js"
import type { ToolPresentation, ToolPresentationSource } from "./types.js"
import { projectWrite } from "./write.js"

export function projectToolPresentation(source: ToolPresentationSource): ToolPresentation {
  let presentation: ToolPresentation | undefined
  switch (source.name) {
    case "bash":
      presentation = projectBash(source)
      break
    case "code":
      presentation = projectCodeTool(source)
      break
    case "read":
      presentation = projectRead(source)
      break
    case "write":
      presentation = projectWrite(source)
      break
    case "edit":
      presentation = projectEdit(source)
      break
    case "task_output":
      presentation = projectTaskOutput(source)
      break
    case "kill_task":
      presentation = projectKillTask(source)
      break
    default:
      break
  }
  return presentation ?? projectGeneric(source)
}
