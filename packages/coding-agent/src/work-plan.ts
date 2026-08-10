import { isNonNegativeInteger, isRecord } from "./guards.js"

export const maxWorkPlanSteps = 32
export const maxWorkPlanStepBytes = 512
export const maxWorkPlanStepTextBytes = 16 * 1024
export const maxWorkPlanExplanationBytes = 4 * 1024

export type WorkPlanStepStatus = "pending" | "in_progress" | "completed" | "cancelled"

export interface WorkPlanStep {
  readonly text: string
  readonly status: WorkPlanStepStatus
}

export interface WorkPlanSnapshot {
  readonly revision: number
  readonly explanation?: string
  readonly steps: readonly WorkPlanStep[]
}

export interface WorkPlanReplacement {
  readonly explanation?: string
  readonly steps: readonly WorkPlanStep[]
}

export interface WorkPlanJournal {
  latestWorkPlan(): WorkPlanSnapshot | undefined
  appendWorkPlan(plan: WorkPlanSnapshot): WorkPlanSnapshot
}

const emptySnapshot: WorkPlanSnapshot = Object.freeze({ revision: 0, steps: Object.freeze([]) })

export class WorkPlan {
  readonly #journal: WorkPlanJournal
  readonly #listeners = new Set<(snapshot: WorkPlanSnapshot) => void>()
  #current: WorkPlanSnapshot

  constructor(journal: WorkPlanJournal) {
    this.#journal = journal
    const restored = journal.latestWorkPlan()
    this.#current = restored ? snapshotFromEntry(restored) : emptySnapshot
  }

  get snapshot(): WorkPlanSnapshot {
    return this.#current
  }

  subscribe(listener: (snapshot: WorkPlanSnapshot) => void): () => void {
    this.#listeners.add(listener)
    return () => this.#listeners.delete(listener)
  }

  replace(replacement: unknown): WorkPlanSnapshot {
    const normalized = normalizeReplacement(replacement)
    const entry = this.#journal.appendWorkPlan({
      revision: this.#current.revision + 1,
      ...(normalized.explanation === undefined ? {} : { explanation: normalized.explanation }),
      steps: normalized.steps
    })
    const snapshot = snapshotFromEntry(entry)
    this.#current = snapshot
    for (const listener of this.#listeners) {
      try {
        listener(snapshot)
      } catch {
        // Persistence already committed; one observer cannot fail the replacement or block later observers.
      }
    }
    return snapshot
  }
}

export function isWorkPlanStepStatus(value: unknown): value is WorkPlanStepStatus {
  return value === "pending" || value === "in_progress" || value === "completed" || value === "cancelled"
}

export function isWorkPlanSnapshot(value: unknown): value is WorkPlanSnapshot {
  if (
    !isRecord(value) ||
    Object.keys(value).some(key => key !== "revision" && key !== "explanation" && key !== "steps") ||
    !isNonNegativeInteger(value.revision) ||
    (value.explanation !== undefined && !isTrimmedText(value.explanation, maxWorkPlanExplanationBytes)) ||
    !Array.isArray(value.steps) ||
    value.steps.length > maxWorkPlanSteps
  ) {
    return false
  }

  let textBytes = 0
  let inProgress = 0
  for (const step of value.steps) {
    if (
      !isRecord(step) ||
      Object.keys(step).some(key => key !== "text" && key !== "status") ||
      !isTrimmedText(step.text, maxWorkPlanStepBytes) ||
      !isWorkPlanStepStatus(step.status)
    ) {
      return false
    }
    textBytes += Buffer.byteLength(step.text)
    if (textBytes > maxWorkPlanStepTextBytes) return false
    if (step.status === "in_progress" && ++inProgress > 1) return false
  }
  return true
}

function normalizeReplacement(value: unknown): WorkPlanReplacement {
  if (
    !isRecord(value) ||
    Object.keys(value).some(key => key !== "explanation" && key !== "steps") ||
    !Array.isArray(value.steps)
  ) {
    throw new Error("Work plan steps must be an array")
  }
  if (value.steps.length > maxWorkPlanSteps) {
    throw new Error(`Work plan cannot contain more than ${maxWorkPlanSteps} steps`)
  }

  let textBytes = 0
  let inProgress = 0
  const steps = value.steps.map((candidate, index) => {
    if (
      !isRecord(candidate) ||
      Object.keys(candidate).some(key => key !== "text" && key !== "status") ||
      typeof candidate.text !== "string"
    ) {
      throw new Error(`Work plan step ${index + 1} must contain text`)
    }
    const text = candidate.text.trim()
    if (!text) throw new Error(`Work plan step ${index + 1} cannot be blank`)
    const bytes = Buffer.byteLength(text)
    if (bytes > maxWorkPlanStepBytes) {
      throw new Error(`Work plan step ${index + 1} cannot exceed ${maxWorkPlanStepBytes} bytes`)
    }
    textBytes += bytes
    if (textBytes > maxWorkPlanStepTextBytes) {
      throw new Error(`Work plan step text cannot exceed ${maxWorkPlanStepTextBytes} bytes`)
    }
    if (!isWorkPlanStepStatus(candidate.status)) {
      throw new Error(`Work plan step ${index + 1} has an invalid status`)
    }
    if (candidate.status === "in_progress" && ++inProgress > 1) {
      throw new Error("Work plan cannot contain more than one in-progress step")
    }
    return Object.freeze({ text, status: candidate.status })
  })

  let explanation: string | undefined
  if (value.explanation !== undefined) {
    if (typeof value.explanation !== "string") throw new Error("Work plan explanation must be text")
    explanation = value.explanation.trim()
    if (!explanation) throw new Error("Work plan explanation cannot be blank")
    if (Buffer.byteLength(explanation) > maxWorkPlanExplanationBytes) {
      throw new Error(`Work plan explanation cannot exceed ${maxWorkPlanExplanationBytes} bytes`)
    }
  }

  return Object.freeze({ ...(explanation === undefined ? {} : { explanation }), steps: Object.freeze(steps) })
}

function snapshotFromEntry(entry: WorkPlanSnapshot): WorkPlanSnapshot {
  const steps = Object.freeze(entry.steps.map(step => Object.freeze({ text: step.text, status: step.status })))
  return Object.freeze({
    revision: entry.revision,
    ...(entry.explanation === undefined ? {} : { explanation: entry.explanation }),
    steps
  })
}

function isTrimmedText(value: unknown, maxBytes: number): value is string {
  return typeof value === "string" && value.length > 0 && value.trim() === value && Buffer.byteLength(value) <= maxBytes
}
