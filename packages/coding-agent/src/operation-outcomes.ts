import type { SessionEntryBase, SessionJson } from "./session-manager.js"

export type OperationResult = "succeeded" | "failed" | "cancelled"

export const maxOperationOutcomeClassifierBytes = 64
export const maxOperationOutcomeIdBytes = 256
export const maxOperationOutcomeEvidenceBytes = 8 * 1024

export interface OperationOutcomeEntryData<Evidence extends SessionJson = SessionJson> {
  readonly type: "operation_outcome"
  readonly operationId: string
  readonly capability: string
  readonly operation: string
  readonly result: OperationResult
  readonly durationMs: number
  readonly evidence: Evidence
}

export type OperationOutcomeInput<Evidence extends SessionJson = SessionJson> = Omit<
  OperationOutcomeEntryData<Evidence>,
  "type"
>

export type OperationOutcome<Evidence extends SessionJson = SessionJson> = SessionEntryBase &
  OperationOutcomeEntryData<Evidence>

export function isOperationOutcomeClassifier(value: unknown): value is string {
  return (
    typeof value === "string" &&
    /^[a-z][a-z0-9_-]*$/.test(value) &&
    Buffer.byteLength(value) <= maxOperationOutcomeClassifierBytes
  )
}

export function isOperationOutcomeId(value: unknown): value is string {
  return (
    typeof value === "string" &&
    value.length > 0 &&
    !value.includes("\0") &&
    Buffer.byteLength(value) <= maxOperationOutcomeIdBytes
  )
}
