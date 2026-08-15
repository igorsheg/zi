import { isNonNegativeInteger, isPositiveInteger, isRecord } from "../guards.js"
import { maxSubagentProfileNameBytes } from "../subagent-profiles.js"
import type { SubagentWorkCycleErrorCode } from "./child.js"

export const maxSubagentWorkResultEntryBytes = 8 * 1024

const subagentWorkResultFields = new Set([
  "type",
  "name",
  "workCycle",
  "profile",
  "result",
  "durationMs",
  "preview",
  "originalBytes",
  "omittedBytes",
  "truncated",
  "errorCode",
  "errorMessage"
])

interface SubagentWorkResultBase {
  readonly type: "subagent_work_result"
  readonly name: string
  readonly workCycle: number
  readonly profile?: string
  readonly durationMs: number
  readonly preview: string
  readonly originalBytes: number
  readonly omittedBytes: number
  readonly truncated: boolean
}

export type SubagentWorkResultEntryData = SubagentWorkResultBase &
  (
    | { readonly result: "succeeded" | "cancelled" }
    | { readonly result: "failed"; readonly errorCode: SubagentWorkCycleErrorCode; readonly errorMessage?: string }
  )

export type SubagentWorkResultInput = SubagentWorkResultEntryData extends infer Result
  ? Result extends { readonly type: "subagent_work_result" }
    ? Omit<Result, "type">
    : never
  : never

export function isSubagentWorkResultEntryData(value: unknown): value is SubagentWorkResultEntryData {
  if (
    !isRecord(value) ||
    value.type !== "subagent_work_result" ||
    !hasOnlySubagentWorkResultFields(value) ||
    !isSubagentName(value.name) ||
    !isPositiveInteger(value.workCycle) ||
    (value.profile !== undefined && !isSubagentProfileName(value.profile)) ||
    !isNonNegativeInteger(value.durationMs) ||
    typeof value.preview !== "string" ||
    !isNonNegativeInteger(value.originalBytes) ||
    !isNonNegativeInteger(value.omittedBytes) ||
    typeof value.truncated !== "boolean"
  ) {
    return false
  }

  if (value.result === "succeeded" || value.result === "cancelled") {
    if (value.errorCode !== undefined || value.errorMessage !== undefined) return false
  } else if (value.result === "failed") {
    if (!isSubagentWorkCycleErrorCode(value.errorCode)) return false
    if (value.errorMessage !== undefined && typeof value.errorMessage !== "string") return false
  } else {
    return false
  }

  return Buffer.byteLength(JSON.stringify(value)) <= maxSubagentWorkResultEntryBytes
}

function hasOnlySubagentWorkResultFields(value: Record<string, unknown>): boolean {
  return Object.keys(value).every(field => subagentWorkResultFields.has(field))
}

function isSubagentName(value: unknown): value is string {
  return (
    typeof value === "string" &&
    /^[a-z][a-z0-9_-]*$/.test(value) &&
    Buffer.byteLength(value) <= maxSubagentProfileNameBytes
  )
}

function isSubagentProfileName(value: unknown): value is string {
  return isSubagentName(value)
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
    value === "child_forced_settlement" ||
    value === "child_failed" ||
    value === "child_exited"
  )
}
