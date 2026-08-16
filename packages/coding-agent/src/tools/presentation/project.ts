import { projectAgentTeam } from "./agent-team.js"
import { projectBash } from "./bash.js"
import { projectCodeTool } from "./code.js"
import { projectEdit } from "./edit.js"
import { projectGeneric } from "./generic.js"
import { projectRead } from "./read.js"
import { projectKillTask, projectListTasks, projectTaskOutput } from "./shell-task.js"
import type { ToolPresentation, ToolPresentationSource } from "./types.js"
import { projectWorkPlan } from "./work-plan.js"
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
    case "list_tasks":
      presentation = projectListTasks(source)
      break
    case "task_output":
      presentation = projectTaskOutput(source)
      break
    case "kill_task":
      presentation = projectKillTask(source)
      break
    case "update_plan":
      presentation = projectWorkPlan(source)
      break
    case "spawn_agent":
    case "send_message":
    case "followup_task":
    case "wait_agent":
    case "list_agents":
    case "interrupt_agent":
      presentation = projectAgentTeam(source)
      break
    default:
      break
  }
  return presentation ?? projectGeneric(source)
}
