import type { AgentTool, AgentToolResult } from "@earendil-works/pi-agent-core"
import { Type } from "@earendil-works/pi-ai"

import type { CodeModeJson } from "../code-mode/protocol.js"
import type { CodeModeToolContract, CodeModeToolInvocation } from "../code-mode/tool-contract.js"
import {
  isWorkPlanSnapshot,
  maxWorkPlanExplanationBytes,
  maxWorkPlanStepBytes,
  maxWorkPlanSteps,
  type WorkPlan,
  type WorkPlanSnapshot
} from "../work-plan.js"

const status = Type.Union([
  Type.Literal("pending"),
  Type.Literal("in_progress"),
  Type.Literal("completed"),
  Type.Literal("cancelled")
])

const stepSchema = Type.Object({
  text: Type.String({ minLength: 1, maxLength: maxWorkPlanStepBytes, description: "Concise description of the step" }),
  status
})

const parameters = Type.Object({
  explanation: Type.Optional(
    Type.String({ minLength: 1, maxLength: maxWorkPlanExplanationBytes, description: "Why the plan changed" })
  ),
  steps: Type.Array(stepSchema, {
    maxItems: maxWorkPlanSteps,
    description: "Complete replacement plan in execution order"
  })
})

const outputSchema = Type.Object({
  revision: Type.Integer({ minimum: 0 }),
  explanation: Type.Optional(Type.String({ minLength: 1, maxLength: maxWorkPlanExplanationBytes })),
  steps: Type.Array(stepSchema, { maxItems: maxWorkPlanSteps })
})

export type UpdatePlanToolDetails = WorkPlanSnapshot

export type UpdatePlanTool = AgentTool<typeof parameters, UpdatePlanToolDetails> & {
  readonly codeMode: CodeModeToolContract
}

type UpdatePlanInvocation = CodeModeToolInvocation & { readonly result: AgentToolResult<UpdatePlanToolDetails> }

export function createUpdatePlanTool(workPlan: WorkPlan): UpdatePlanTool {
  const invoke = async (input: unknown, signal?: AbortSignal): Promise<UpdatePlanInvocation> => {
    if (signal?.aborted) throw new Error("Operation aborted")
    const snapshot = workPlan.replace(input)
    return { result: directResult(snapshot), value: codeModeSnapshot(snapshot) }
  }

  return {
    name: "update_plan",
    label: "update_plan",
    description: "Replace the current work plan and step statuses.",
    parameters,
    executionMode: "sequential",
    async execute(_toolCallId, input, signal) {
      return (await invoke(input, signal)).result
    },
    codeMode: {
      outputSchema,
      async execute(_toolCallId, input, signal) {
        return invoke(input, signal)
      }
    }
  }
}

export function isUpdatePlanToolDetails(value: unknown): value is UpdatePlanToolDetails {
  return isWorkPlanSnapshot(value)
}

function directResult(snapshot: WorkPlanSnapshot): AgentToolResult<UpdatePlanToolDetails> {
  return { content: [{ type: "text", text: `Plan updated to revision ${snapshot.revision}.` }], details: snapshot }
}

function codeModeSnapshot(snapshot: WorkPlanSnapshot): CodeModeJson {
  return {
    revision: snapshot.revision,
    ...(snapshot.explanation === undefined ? {} : { explanation: snapshot.explanation }),
    steps: snapshot.steps.map(step => ({ text: step.text, status: step.status }))
  }
}
