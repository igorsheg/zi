import { isNonNegativeInteger, isPositiveInteger, isRecord } from "./guards.js"

export const maxBackgroundTaskIdBytes = 256
export const maxBackgroundTaskSignalBytes = 32

const backgroundTaskResultFields = new Set([
  "type",
  "taskId",
  "origin",
  "result",
  "durationMs",
  "outputBytes",
  "exitCode",
  "cancellationCode",
  "errorCode",
  "signal"
])

export type BackgroundTaskOrigin = "requested" | "demoted"
export type BackgroundTaskCancellationCode = "killed" | "disposed"
export type BackgroundTaskErrorCode = "exit_nonzero" | "signaled" | "timed_out" | "output_limit" | "execution_failed"

interface BackgroundTaskResultBase {
  readonly type: "background_task_result"
  readonly taskId: string
  readonly origin: BackgroundTaskOrigin
  readonly durationMs: number
  readonly outputBytes: number
}

export type BackgroundTaskResultEntryData = BackgroundTaskResultBase &
  (
    | { readonly result: "succeeded"; readonly exitCode: 0 }
    | { readonly result: "cancelled"; readonly cancellationCode: BackgroundTaskCancellationCode }
    | { readonly result: "failed"; readonly errorCode: "exit_nonzero"; readonly exitCode: number }
    | { readonly result: "failed"; readonly errorCode: "signaled"; readonly signal: string }
    | { readonly result: "failed"; readonly errorCode: Exclude<BackgroundTaskErrorCode, "exit_nonzero" | "signaled"> }
  )

export type BackgroundTaskResultInput = BackgroundTaskResultEntryData extends infer Result
  ? Result extends { readonly type: "background_task_result" }
    ? Omit<Result, "type">
    : never
  : never

export function isBackgroundTaskResultEntryData(value: unknown): value is BackgroundTaskResultEntryData {
  if (
    !isRecord(value) ||
    value.type !== "background_task_result" ||
    !hasOnlyBackgroundTaskResultFields(value) ||
    !isBackgroundTaskId(value.taskId) ||
    (value.origin !== "requested" && value.origin !== "demoted") ||
    !isNonNegativeInteger(value.durationMs) ||
    !isNonNegativeInteger(value.outputBytes)
  ) {
    return false
  }

  if (value.result === "succeeded") {
    return (
      value.exitCode === 0 &&
      value.cancellationCode === undefined &&
      value.errorCode === undefined &&
      value.signal === undefined
    )
  }
  if (value.result === "cancelled") {
    return (
      (value.cancellationCode === "killed" || value.cancellationCode === "disposed") &&
      value.exitCode === undefined &&
      value.errorCode === undefined &&
      value.signal === undefined
    )
  }
  if (value.result !== "failed" || value.cancellationCode !== undefined) return false
  if (value.errorCode === "exit_nonzero") {
    return isPositiveInteger(value.exitCode) && value.signal === undefined
  }
  if (value.errorCode === "signaled") {
    return (
      value.exitCode === undefined &&
      typeof value.signal === "string" &&
      /^SIG[A-Z0-9]+$/u.test(value.signal) &&
      Buffer.byteLength(value.signal) <= maxBackgroundTaskSignalBytes
    )
  }
  return (
    (value.errorCode === "timed_out" || value.errorCode === "output_limit" || value.errorCode === "execution_failed") &&
    value.exitCode === undefined &&
    value.signal === undefined
  )
}

function hasOnlyBackgroundTaskResultFields(value: Record<string, unknown>): boolean {
  return Object.keys(value).every(field => backgroundTaskResultFields.has(field))
}

function isBackgroundTaskId(value: unknown): value is string {
  return (
    typeof value === "string" &&
    value.length > 0 &&
    !value.includes("\0") &&
    Buffer.byteLength(value) <= maxBackgroundTaskIdBytes
  )
}
