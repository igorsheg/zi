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
  readonly operation: string
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
      readonly operation: "work_cycle"
      readonly result: "succeeded" | "cancelled"
      readonly evidence: SubagentWorkCycleEvidence
    })
  | (SubagentOutcomeInputBase & {
      readonly operation: "work_cycle"
      readonly result: "failed"
      readonly evidence: SubagentWorkCycleFailureEvidence
    })

export type SubagentWorkCycleOutcome =
  | (SubagentOutcomeBase & {
      readonly operation: "work_cycle"
      readonly result: "succeeded" | "cancelled"
      readonly evidence: SubagentWorkCycleEvidence
    })
  | (SubagentOutcomeBase & {
      readonly operation: "work_cycle"
      readonly result: "failed"
      readonly evidence: SubagentWorkCycleFailureEvidence
    })

export type SubagentControlOperation = "spawn" | "message_delivery" | "task_assignment" | "interrupt" | "close"
export type SubagentControlErrorCode =
  | "spawn_failed"
  | "target_not_live"
  | "self_delivery"
  | "delivery_failed"
  | "assignment_failed"
  | "interrupt_failed"
  | "close_failed"

type SubagentControlEvidenceBase = { readonly commandId: string }

type SubagentSpawnFailureEvidence = { readonly errorCode: "spawn_failed" }
type SubagentMessageDeliveryFailureEvidence = {
  readonly errorCode: "target_not_live" | "self_delivery" | "delivery_failed"
}
type SubagentTaskAssignmentFailureEvidence = { readonly errorCode: "target_not_live" | "assignment_failed" }
type SubagentInterruptFailureEvidence = { readonly errorCode: "target_not_live" | "interrupt_failed" }
type SubagentCloseFailureEvidence = { readonly errorCode: "target_not_live" | "close_failed" }

type SubagentControlTargetEvidence = {
  readonly source: "host"
  readonly target: string
  readonly targetWorkCycle?: number
}

type SubagentMessageDeliveryEvidence =
  | {
      readonly channel: "host_to_subagent"
      readonly target: string
      readonly messageBytes: number
      readonly targetWorkCycle?: number
    }
  | {
      readonly channel: "peer_to_peer"
      readonly sender: string
      readonly target: string
      readonly messageBytes: number
      readonly peerRequestId: string
      readonly senderWorkCycle?: number
      readonly targetWorkCycle?: number
    }

type SubagentTaskAssignmentEvidence = SubagentControlTargetEvidence & { readonly taskBytes: number }

export type SubagentControlOutcomeInput =
  | (SubagentOutcomeInputBase & {
      readonly operation: "spawn"
      readonly result: "succeeded"
      readonly evidence: SubagentControlEvidenceBase & {
        readonly source: "host"
        readonly name: string
        readonly profile?: string
        readonly promptBytes: number
      }
    })
  | (SubagentOutcomeInputBase & {
      readonly operation: "spawn"
      readonly result: "failed"
      readonly evidence: SubagentControlEvidenceBase &
        SubagentSpawnFailureEvidence & {
          readonly source: "host"
          readonly name: string
          readonly profile?: string
          readonly promptBytes: number
        }
    })
  | (SubagentOutcomeInputBase & {
      readonly operation: "spawn"
      readonly result: "cancelled"
      readonly evidence: SubagentControlEvidenceBase & {
        readonly source: "host"
        readonly name: string
        readonly profile?: string
        readonly promptBytes: number
        readonly cancellationCode: "cancelled"
      }
    })
  | (SubagentOutcomeInputBase & {
      readonly operation: "message_delivery"
      readonly result: "succeeded"
      readonly evidence: SubagentControlEvidenceBase & SubagentMessageDeliveryEvidence
    })
  | (SubagentOutcomeInputBase & {
      readonly operation: "message_delivery"
      readonly result: "failed"
      readonly evidence: SubagentControlEvidenceBase &
        SubagentMessageDeliveryEvidence &
        SubagentMessageDeliveryFailureEvidence
    })
  | (SubagentOutcomeInputBase & {
      readonly operation: "task_assignment"
      readonly result: "succeeded"
      readonly evidence: SubagentControlEvidenceBase &
        SubagentTaskAssignmentEvidence & {
          readonly delivery: "started_cycle" | "follow_up"
          readonly targetWorkCycle: number
        }
    })
  | (SubagentOutcomeInputBase & {
      readonly operation: "task_assignment"
      readonly result: "failed"
      readonly evidence: SubagentControlEvidenceBase &
        SubagentTaskAssignmentEvidence &
        SubagentTaskAssignmentFailureEvidence
    })
  | (SubagentOutcomeInputBase & {
      readonly operation: "interrupt"
      readonly result: "succeeded"
      readonly evidence: SubagentControlEvidenceBase &
        SubagentControlTargetEvidence & { readonly disposition: "interrupted" | "already_idle" }
    })
  | (SubagentOutcomeInputBase & {
      readonly operation: "interrupt"
      readonly result: "failed"
      readonly evidence: SubagentControlEvidenceBase & SubagentControlTargetEvidence & SubagentInterruptFailureEvidence
    })
  | (SubagentOutcomeInputBase & {
      readonly operation: "close"
      readonly result: "succeeded"
      readonly evidence: SubagentControlEvidenceBase & SubagentControlTargetEvidence
    })
  | (SubagentOutcomeInputBase & {
      readonly operation: "close"
      readonly result: "failed"
      readonly evidence: SubagentControlEvidenceBase & SubagentControlTargetEvidence & SubagentCloseFailureEvidence
    })

export type SubagentControlOutcome = SubagentControlOutcomeInput extends infer Outcome
  ? Outcome extends SubagentControlOutcomeInput
    ? SubagentOutcomeBase & Outcome
    : never
  : never
export type SubagentOutcomeInput = SubagentWorkCycleOutcomeInput | SubagentControlOutcomeInput

export interface SubagentControlAdmission {
  readonly commandId: string
  readonly operationId: string
  readonly startedAt: number
}

export function admitSubagentControlOperation(): SubagentControlAdmission {
  const commandId = crypto.randomUUID()
  return Object.freeze({ commandId, operationId: `subagent/control/${commandId}`, startedAt: Date.now() })
}

export function subagentWorkCycleOperationId(name: string, workCycle: number): string {
  return `subagent/${name}/work_cycle/${workCycle}`
}

export function isSubagentControlOutcome(outcome: OperationOutcome): outcome is SubagentControlOutcome {
  if (
    outcome.capability !== "subagent" ||
    !isNonNegativeInteger(outcome.durationMs) ||
    !isSubagentControlOperation(outcome.operation) ||
    !isRecord(outcome.evidence)
  ) {
    return false
  }
  const evidence = outcome.evidence
  if (
    typeof evidence.commandId !== "string" ||
    !/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(evidence.commandId) ||
    outcome.operationId !== `subagent/control/${evidence.commandId}`
  ) {
    return false
  }
  if (outcome.operation === "spawn") return isSpawnControlOutcome(outcome.result, evidence)
  if (outcome.operation === "message_delivery") return isMessageDeliveryControlOutcome(outcome.result, evidence)
  if (outcome.operation === "task_assignment") return isTaskAssignmentControlOutcome(outcome.result, evidence)
  if (outcome.operation === "interrupt") return isInterruptControlOutcome(outcome.result, evidence)
  return isCloseControlOutcome(outcome.result, evidence)
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

function isSubagentControlOperation(value: string): value is SubagentControlOperation {
  return (
    value === "spawn" ||
    value === "message_delivery" ||
    value === "task_assignment" ||
    value === "interrupt" ||
    value === "close"
  )
}

function isSpawnControlOutcome(result: OperationOutcome["result"], evidence: Record<string, unknown>): boolean {
  const fields = ["commandId", "source", "name", "profile", "promptBytes"]
  if (
    !isControlSource(evidence.source) ||
    !isSubagentIdentity(evidence.name) ||
    (evidence.profile !== undefined && !isSubagentIdentity(evidence.profile)) ||
    !isPositiveInteger(evidence.promptBytes)
  ) {
    return false
  }
  if (result === "succeeded") return hasOnlyFields(evidence, fields)
  if (result === "cancelled") {
    return evidence.cancellationCode === "cancelled" && hasOnlyFields(evidence, [...fields, "cancellationCode"])
  }
  return evidence.errorCode === "spawn_failed" && hasOnlyFields(evidence, [...fields, "errorCode"])
}

function isMessageDeliveryControlOutcome(
  result: OperationOutcome["result"],
  evidence: Record<string, unknown>
): boolean {
  if (
    result === "cancelled" ||
    !isSubagentIdentity(evidence.target) ||
    !isNonNegativeInteger(evidence.messageBytes) ||
    !isOptionalWorkCycle(evidence.targetWorkCycle)
  ) {
    return false
  }
  const fields = ["commandId", "channel", "target", "messageBytes", "targetWorkCycle"]
  if (evidence.channel === "peer_to_peer") {
    fields.push("sender", "peerRequestId", "senderWorkCycle")
    if (
      !isSubagentIdentity(evidence.sender) ||
      typeof evidence.peerRequestId !== "string" ||
      evidence.peerRequestId.length === 0 ||
      Buffer.byteLength(evidence.peerRequestId) > 64 ||
      !isOptionalWorkCycle(evidence.senderWorkCycle)
    ) {
      return false
    }
  } else if (evidence.channel !== "host_to_subagent") {
    return false
  }
  if (result === "succeeded") {
    return (
      (evidence.channel !== "peer_to_peer" || evidence.sender !== evidence.target) && hasOnlyFields(evidence, fields)
    )
  }
  if (evidence.errorCode === "self_delivery") {
    return (
      evidence.channel === "peer_to_peer" &&
      evidence.sender === evidence.target &&
      hasOnlyFields(evidence, [...fields, "errorCode"])
    )
  }
  return (
    (evidence.channel !== "peer_to_peer" || evidence.sender !== evidence.target) &&
    (evidence.errorCode === "target_not_live" || evidence.errorCode === "delivery_failed") &&
    hasOnlyFields(evidence, [...fields, "errorCode"])
  )
}

function isTaskAssignmentControlOutcome(
  result: OperationOutcome["result"],
  evidence: Record<string, unknown>
): boolean {
  const fields = ["commandId", "source", "target", "targetWorkCycle", "taskBytes"]
  if (result === "cancelled" || !isControlTargetEvidence(evidence) || !isPositiveInteger(evidence.taskBytes)) {
    return false
  }
  if (result === "succeeded") {
    return (
      isPositiveInteger(evidence.targetWorkCycle) &&
      (evidence.delivery === "started_cycle" || evidence.delivery === "follow_up") &&
      hasOnlyFields(evidence, [...fields, "delivery"])
    )
  }
  return (
    (evidence.errorCode === "target_not_live" || evidence.errorCode === "assignment_failed") &&
    hasOnlyFields(evidence, [...fields, "errorCode"])
  )
}

function isInterruptControlOutcome(result: OperationOutcome["result"], evidence: Record<string, unknown>): boolean {
  const fields = ["commandId", "source", "target", "targetWorkCycle"]
  if (result === "cancelled" || !isControlTargetEvidence(evidence)) return false
  if (result === "succeeded") {
    return (
      (evidence.disposition === "interrupted" || evidence.disposition === "already_idle") &&
      hasOnlyFields(evidence, [...fields, "disposition"])
    )
  }
  return (
    (evidence.errorCode === "target_not_live" || evidence.errorCode === "interrupt_failed") &&
    hasOnlyFields(evidence, [...fields, "errorCode"])
  )
}

function isCloseControlOutcome(result: OperationOutcome["result"], evidence: Record<string, unknown>): boolean {
  const fields = ["commandId", "source", "target", "targetWorkCycle"]
  if (result === "cancelled" || !isControlTargetEvidence(evidence)) return false
  if (result === "succeeded") return hasOnlyFields(evidence, fields)
  return (
    (evidence.errorCode === "target_not_live" || evidence.errorCode === "close_failed") &&
    hasOnlyFields(evidence, [...fields, "errorCode"])
  )
}

function isControlSource(value: unknown): value is "host" {
  return value === "host"
}

function isControlTargetEvidence(evidence: Record<string, unknown>): boolean {
  return (
    isControlSource(evidence.source) &&
    isSubagentIdentity(evidence.target) &&
    isOptionalWorkCycle(evidence.targetWorkCycle)
  )
}

function isOptionalWorkCycle(value: unknown): boolean {
  return value === undefined || isPositiveInteger(value)
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
