import { isUpdatePlanToolDetails } from "../work-plan.js"
import type { ToolPresentation, ToolPresentationSource } from "./types.js"
import { boundInline, recordValue, resultDetails } from "./values.js"

export function projectWorkPlan(source: ToolPresentationSource): ToolPresentation {
  const details = "result" in source ? resultDetails(source.result) : undefined
  const plan = isUpdatePlanToolDetails(details) ? details : undefined
  const steps = plan?.steps ?? argumentSteps(source.args)
  const counts = plan ? countStatuses(plan.steps) : undefined
  const subject = steps.length === 0 ? "cleared" : `${steps.length} ${steps.length === 1 ? "step" : "steps"}`
  const status =
    counts && counts.active === 0
      ? counts.pending === 0
        ? "complete"
        : undefined
      : counts?.active === 1
        ? "in progress"
        : undefined

  return {
    header: {
      label: "Plan",
      subject: { type: "text", text: subject },
      details: counts ? statusDetails(counts) : [],
      ...(status ? { status } : {})
    },
    ...(plan?.explanation
      ? { body: { type: "text" as const, text: boundInline(plan.explanation), tone: "muted" as const } }
      : {}),
    notices: [],
    preview: {
      compact: plan?.explanation ? { type: "head", rows: 2 } : { type: "hidden" },
      detailed: plan?.explanation ? { type: "head", rows: 2 } : { type: "hidden" }
    },
    timing: "hidden"
  }
}

interface StatusCounts {
  readonly active: number
  readonly pending: number
  readonly completed: number
  readonly cancelled: number
}

function countStatuses(steps: readonly { readonly status: string }[]): StatusCounts {
  let active = 0
  let pending = 0
  let completed = 0
  let cancelled = 0
  for (const step of steps) {
    switch (step.status) {
      case "in_progress":
        active++
        break
      case "pending":
        pending++
        break
      case "completed":
        completed++
        break
      case "cancelled":
        cancelled++
        break
    }
  }
  return { active, pending, completed, cancelled }
}

function statusDetails(counts: StatusCounts): string[] {
  const details: string[] = []
  if (counts.pending > 0) details.push(`${counts.pending} pending`)
  if (counts.completed > 0) details.push(`${counts.completed} completed`)
  if (counts.cancelled > 0) details.push(`${counts.cancelled} cancelled`)
  return details
}

function argumentSteps(args: unknown): readonly unknown[] {
  const steps = recordValue(args)?.steps
  return Array.isArray(steps) ? steps : []
}
