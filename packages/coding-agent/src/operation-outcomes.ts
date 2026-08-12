import { isNonNegativeInteger, isPositiveInteger, isRecord } from "./guards.js"
import type { SessionEntry } from "./session-manager.js"
import { maxSubagentProfileNameBytes } from "./subagent-profiles.js"

export type OperationResult = "succeeded" | "failed" | "cancelled"

export type SubagentWorkCycleErrorCode =
  | "assignment_failed"
  | "work_cycle_timeout"
  | "interrupt_settlement_timeout"
  | "missing_assistant"
  | "provider_error"
  | "missing_final_answer"
  | "incomplete_final_answer"
  | "child_killed"
  | "child_failed"
  | "child_exited"
  | "legacy_failure"

export type ShellBackgroundTaskOrigin = "requested" | "demoted"
export type ShellBackgroundTaskErrorCode =
  | "exit_nonzero"
  | "signaled"
  | "timed_out"
  | "output_limit"
  | "execution_failed"
export type ShellBackgroundTaskCancellationCode = "killed" | "disposed"

export const maxOperationOutcomeTextBytes = 8 * 1024
const maxShellSignalBytes = 32
const subagentWorkCycleFields = new Set([
  "type",
  "id",
  "parentId",
  "timestamp",
  "capability",
  "operation",
  "operationId",
  "durationMs",
  "name",
  "workCycle",
  "profile",
  "preview",
  "originalBytes",
  "omittedBytes",
  "truncated",
  "result",
  "errorCode",
  "errorMessage"
])
const shellBackgroundTaskFields = new Set([
  "type",
  "id",
  "parentId",
  "timestamp",
  "capability",
  "operation",
  "operationId",
  "durationMs",
  "taskId",
  "origin",
  "outputBytes",
  "result",
  "errorCode",
  "exitCode",
  "signal",
  "cancellationCode"
])

interface SubagentWorkCycleOutcomeEvidence {
  readonly type: "operation_outcome"
  readonly capability: "subagent"
  readonly operation: "work_cycle"
  readonly operationId: string
  readonly durationMs: number
  readonly name: string
  readonly workCycle: number
  readonly profile?: string
  readonly preview: string
  readonly originalBytes: number
  readonly omittedBytes: number
  readonly truncated: boolean
}

export type SubagentWorkCycleOperationOutcomeData = SubagentWorkCycleOutcomeEvidence &
  (
    | { readonly result: "succeeded"; readonly errorCode?: never; readonly errorMessage?: never }
    | { readonly result: "cancelled"; readonly errorCode?: never; readonly errorMessage?: never }
    | {
        readonly result: "failed"
        readonly errorCode: Exclude<SubagentWorkCycleErrorCode, "legacy_failure">
        readonly errorMessage?: string
      }
  )

interface ShellBackgroundTaskOutcomeEvidence {
  readonly type: "operation_outcome"
  readonly capability: "shell"
  readonly operation: "background_task"
  readonly operationId: string
  readonly taskId: string
  readonly origin: ShellBackgroundTaskOrigin
  readonly durationMs: number
  readonly outputBytes: number
}

export type ShellBackgroundTaskOperationOutcomeData = ShellBackgroundTaskOutcomeEvidence &
  (
    | { readonly result: "succeeded"; readonly exitCode: 0 }
    | { readonly result: "cancelled"; readonly cancellationCode: ShellBackgroundTaskCancellationCode }
    | { readonly result: "failed"; readonly errorCode: "exit_nonzero"; readonly exitCode: number }
    | { readonly result: "failed"; readonly errorCode: "signaled"; readonly signal: string }
    | {
        readonly result: "failed"
        readonly errorCode: Exclude<ShellBackgroundTaskErrorCode, "exit_nonzero" | "signaled">
      }
  )

export type SubagentWorkCycleOperationOutcomeInput = SubagentWorkCycleOperationOutcomeData extends infer Outcome
  ? Outcome extends { readonly type: "operation_outcome" }
    ? Omit<Outcome, "type">
    : never
  : never

export type ShellBackgroundTaskOperationOutcomeInput = ShellBackgroundTaskOperationOutcomeData extends infer Outcome
  ? Outcome extends { readonly type: "operation_outcome" }
    ? Omit<Outcome, "type">
    : never
  : never

export type OperationOutcomeEntryData = SubagentWorkCycleOperationOutcomeData | ShellBackgroundTaskOperationOutcomeData

export type OperationOutcomeEntryInput = OperationOutcomeEntryData extends infer Outcome
  ? Outcome extends { readonly type: "operation_outcome" }
    ? Omit<Outcome, "type">
    : never
  : never

interface ProjectedOperationOutcomeEvidence {
  readonly sourceEntryId: string
  readonly timestamp: string
}

export type ProjectedSubagentWorkCycleOutcome = SubagentWorkCycleOutcomeEvidence &
  ProjectedOperationOutcomeEvidence &
  (
    | { readonly result: "succeeded"; readonly errorCode?: never; readonly errorMessage?: never }
    | { readonly result: "cancelled"; readonly errorCode?: never; readonly errorMessage?: never }
    | { readonly result: "failed"; readonly errorCode: SubagentWorkCycleErrorCode; readonly errorMessage?: string }
  )

export type ProjectedShellBackgroundTaskOutcome = ShellBackgroundTaskOperationOutcomeData &
  ProjectedOperationOutcomeEvidence

export type ProjectedOperationOutcome = ProjectedSubagentWorkCycleOutcome | ProjectedShellBackgroundTaskOutcome

export function subagentWorkCycleOperationId(name: string, workCycle: number): string {
  return `subagent/${name}/work_cycle/${workCycle}`
}

export function shellBackgroundTaskOperationId(taskId: string): string {
  return `shell/background_task/${taskId}`
}

export function isOperationOutcomeEntryData(value: unknown): value is OperationOutcomeEntryData {
  if (!isRecord(value) || value.type !== "operation_outcome") return false
  if (value.capability === "subagent") return isSubagentWorkCycleOutcome(value)
  if (value.capability === "shell") return isShellBackgroundTaskOutcome(value)
  return false
}

export function isOperationOutcomeEntry(
  value: unknown
): value is OperationOutcomeEntryData & { readonly id: string; readonly timestamp: string } {
  return (
    isOperationOutcomeEntryData(value) &&
    isRecord(value) &&
    value.id === value.operationId &&
    typeof value.timestamp === "string"
  )
}

export function projectSessionOutcomes(entries: readonly SessionEntry[]): readonly ProjectedOperationOutcome[] {
  const selected = new Map<
    string,
    { readonly outcome: ProjectedOperationOutcome; readonly index: number; readonly native: boolean }
  >()

  for (const [index, entry] of entries.entries()) {
    const projected = projectEntry(entry)
    if (!projected) continue
    const current = selected.get(projected.outcome.operationId)
    if (!current || (projected.native && !current.native)) {
      selected.set(projected.outcome.operationId, { ...projected, index })
    }
  }

  return [...selected.values()]
    .toSorted((left, right) => left.index - right.index)
    .map(selectedOutcome => selectedOutcome.outcome)
}

function projectEntry(
  entry: SessionEntry
): { readonly outcome: ProjectedOperationOutcome; readonly native: boolean } | undefined {
  if (entry.type === "operation_outcome") {
    return { native: true, outcome: { ...entry, sourceEntryId: entry.id, timestamp: entry.timestamp } }
  }
  if (entry.type !== "subagent" || entry.event !== "work_cycle_finished") return undefined

  const evidence = {
    type: "operation_outcome" as const,
    capability: "subagent" as const,
    operation: "work_cycle" as const,
    operationId: subagentWorkCycleOperationId(entry.name, entry.workCycle),
    durationMs: entry.durationMs,
    name: entry.name,
    workCycle: entry.workCycle,
    preview: entry.preview,
    originalBytes: entry.originalBytes,
    omittedBytes: entry.omittedBytes,
    truncated: entry.truncated,
    sourceEntryId: entry.id,
    timestamp: entry.timestamp
  }
  if (entry.status === "completed") return { native: false, outcome: { ...evidence, result: "succeeded" } }
  if (entry.status === "cancelled") return { native: false, outcome: { ...evidence, result: "cancelled" } }
  return {
    native: false,
    outcome: {
      ...evidence,
      result: "failed",
      errorCode: isSubagentWorkCycleErrorCode(entry.reason) ? entry.reason : "legacy_failure",
      ...(entry.error === undefined ? {} : { errorMessage: entry.error })
    }
  }
}

function isSubagentWorkCycleOutcome(value: unknown): value is SubagentWorkCycleOperationOutcomeData {
  if (
    !isRecord(value) ||
    !hasOnlyFields(value, subagentWorkCycleFields) ||
    value.operation !== "work_cycle" ||
    !isSubagentIdentity(value.name) ||
    !isPositiveInteger(value.workCycle) ||
    value.operationId !== subagentWorkCycleOperationId(value.name, value.workCycle) ||
    (value.profile !== undefined && !isSubagentIdentity(value.profile)) ||
    !isBoundedOutcomeText(value.preview) ||
    !isNonNegativeInteger(value.originalBytes) ||
    !isNonNegativeInteger(value.omittedBytes) ||
    typeof value.truncated !== "boolean" ||
    !isNonNegativeInteger(value.durationMs)
  ) {
    return false
  }

  if (value.result === "succeeded" || value.result === "cancelled") {
    return value.errorCode === undefined && value.errorMessage === undefined
  }
  return (
    value.result === "failed" &&
    isNativeSubagentWorkCycleErrorCode(value.errorCode) &&
    (value.errorMessage === undefined || isBoundedOutcomeText(value.errorMessage))
  )
}

function isShellBackgroundTaskOutcome(value: unknown): value is ShellBackgroundTaskOperationOutcomeData {
  if (
    !isRecord(value) ||
    !hasOnlyFields(value, shellBackgroundTaskFields) ||
    value.operation !== "background_task" ||
    !isShellTaskId(value.taskId) ||
    value.operationId !== shellBackgroundTaskOperationId(value.taskId) ||
    (value.origin !== "requested" && value.origin !== "demoted") ||
    !isNonNegativeInteger(value.durationMs) ||
    !isNonNegativeInteger(value.outputBytes)
  ) {
    return false
  }

  if (value.result === "succeeded") {
    return (
      value.exitCode === 0 &&
      value.errorCode === undefined &&
      value.errorMessage === undefined &&
      value.cancellationCode === undefined &&
      value.signal === undefined
    )
  }
  if (value.result === "cancelled") {
    return (
      (value.cancellationCode === "killed" || value.cancellationCode === "disposed") &&
      value.errorCode === undefined &&
      value.errorMessage === undefined &&
      value.exitCode === undefined &&
      value.signal === undefined
    )
  }
  if (
    value.result !== "failed" ||
    !isShellBackgroundTaskErrorCode(value.errorCode) ||
    value.errorMessage !== undefined
  ) {
    return false
  }
  if (value.errorCode === "exit_nonzero") {
    return isPositiveInteger(value.exitCode) && value.cancellationCode === undefined && value.signal === undefined
  }
  if (value.errorCode === "signaled") {
    return isShellSignal(value.signal) && value.cancellationCode === undefined && value.exitCode === undefined
  }
  return value.cancellationCode === undefined && value.exitCode === undefined && value.signal === undefined
}

function hasOnlyFields(value: Record<string, unknown>, fields: ReadonlySet<string>): boolean {
  return Object.keys(value).every(field => fields.has(field))
}

function isSubagentIdentity(value: unknown): value is string {
  return (
    typeof value === "string" &&
    /^[a-z][a-z0-9_-]*$/.test(value) &&
    Buffer.byteLength(value) <= maxSubagentProfileNameBytes
  )
}

function isShellTaskId(value: unknown): value is string {
  return (
    typeof value === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u.test(value)
  )
}

function isShellSignal(value: unknown): value is string {
  return typeof value === "string" && /^SIG[A-Z0-9]+$/u.test(value) && Buffer.byteLength(value) <= maxShellSignalBytes
}

function isBoundedOutcomeText(value: unknown): value is string {
  return typeof value === "string" && Buffer.byteLength(value) <= maxOperationOutcomeTextBytes
}

function isNativeSubagentWorkCycleErrorCode(
  value: unknown
): value is Exclude<SubagentWorkCycleErrorCode, "legacy_failure"> {
  return isSubagentWorkCycleErrorCode(value) && value !== "legacy_failure"
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
    value === "child_exited" ||
    value === "legacy_failure"
  )
}

function isShellBackgroundTaskErrorCode(value: unknown): value is ShellBackgroundTaskErrorCode {
  return (
    value === "exit_nonzero" ||
    value === "signaled" ||
    value === "timed_out" ||
    value === "output_limit" ||
    value === "execution_failed"
  )
}
