import { isNonNegativeInteger, isPositiveInteger, isRecord } from "../guards.js"
import type { OperationOutcome } from "../operation-outcomes.js"
import { maxSubagentProfileNameBytes } from "../subagent-profiles.js"
import type { SubagentWorkCycleErrorCode } from "./child-process.js"

type SubagentWorkCycleEvidence = {
  readonly name: string
  readonly workCycle: number
  readonly profile?: string
  readonly preview: string
  readonly originalBytes: number
  readonly omittedBytes: number
  readonly truncated: boolean
}

type SubagentWorkCycleFailureEvidence = SubagentWorkCycleEvidence & {
  readonly errorCode: SubagentWorkCycleErrorCode
  readonly errorMessage?: string
}

interface SubagentOutcomeInputBase {
  readonly operationId: string
  readonly capability: "subagent"
  readonly operation: "work_cycle"
  readonly durationMs: number
}

type SubagentOutcomeBase = SubagentOutcomeInputBase & {
  readonly type: "operation_outcome"
  readonly id: string
  readonly parentId: string | null
  readonly timestamp: string
}

export type SubagentWorkCycleOutcomeInput =
  | (SubagentOutcomeInputBase & {
      readonly result: "succeeded" | "cancelled"
      readonly evidence: SubagentWorkCycleEvidence
    })
  | (SubagentOutcomeInputBase & { readonly result: "failed"; readonly evidence: SubagentWorkCycleFailureEvidence })

export type SubagentWorkCycleOutcome =
  | (SubagentOutcomeBase & { readonly result: "succeeded" | "cancelled"; readonly evidence: SubagentWorkCycleEvidence })
  | (SubagentOutcomeBase & { readonly result: "failed"; readonly evidence: SubagentWorkCycleFailureEvidence })

export function subagentWorkCycleOperationId(name: string, workCycle: number): string {
  return `subagent/${name}/work_cycle/${workCycle}`
}

export function isSubagentWorkCycleOutcome(outcome: OperationOutcome): outcome is SubagentWorkCycleOutcome {
  if (outcome.capability !== "subagent" || outcome.operation !== "work_cycle" || !isRecord(outcome.evidence)) {
    return false
  }
  const evidence = outcome.evidence
  if (
    !hasOnlyFields(evidence, [
      "name",
      "workCycle",
      "profile",
      "preview",
      "originalBytes",
      "omittedBytes",
      "truncated",
      "errorCode",
      "errorMessage"
    ]) ||
    !isSubagentIdentity(evidence.name) ||
    !isPositiveInteger(evidence.workCycle) ||
    outcome.operationId !== subagentWorkCycleOperationId(evidence.name, evidence.workCycle) ||
    (evidence.profile !== undefined && !isSubagentIdentity(evidence.profile)) ||
    typeof evidence.preview !== "string" ||
    !isNonNegativeInteger(evidence.originalBytes) ||
    !isNonNegativeInteger(evidence.omittedBytes) ||
    typeof evidence.truncated !== "boolean"
  ) {
    return false
  }
  if (outcome.result !== "failed") return evidence.errorCode === undefined && evidence.errorMessage === undefined
  return (
    isSubagentWorkCycleErrorCode(evidence.errorCode) &&
    (evidence.errorMessage === undefined || typeof evidence.errorMessage === "string")
  )
}

function isSubagentIdentity(value: unknown): value is string {
  return (
    typeof value === "string" &&
    /^[a-z][a-z0-9_-]*$/.test(value) &&
    Buffer.byteLength(value) <= maxSubagentProfileNameBytes
  )
}

function isSubagentWorkCycleErrorCode(value: unknown): value is SubagentWorkCycleErrorCode {
  return (
    value === "assignment_failed" ||
    value === "work_cycle_timeout" ||
    value === "interrupt_settlement_timeout" ||
    value === "missing_assistant" ||
    value === "provider_error" ||
    value === "missing_final_answer" ||
    value === "incomplete_final_answer" ||
    value === "child_killed" ||
    value === "child_failed" ||
    value === "child_exited"
  )
}

function hasOnlyFields(value: Record<string, unknown>, fields: readonly string[]): boolean {
  return Object.keys(value).every(field => fields.includes(field))
}
