import type { ChildLifecycleState, SubagentCompletion, SubagentCompletionStatus } from "./child-process.js"
import type { CompletionDelivery, SubagentSnapshot } from "./supervisor.js"

const maxAgentIdBytes = 256
const maxDefinitionNameBytes = 64
const maxCompletionTextBytes = 64 * 1024

export interface SubagentToolAgentDetails {
  readonly agentId: string
  readonly definitionName: string
  readonly lifecycle: ChildLifecycleState["type"]
  readonly workCycle?: number
  readonly completionDelivery?: CompletionDelivery["type"]
  readonly completion?: SubagentToolCompletionDetails
}

export interface SubagentToolCompletionDetails {
  readonly workCycle: number
  readonly status: SubagentCompletionStatus
  readonly text: string
  readonly omittedBytes: number
  readonly truncated: boolean
  readonly durationMs: number
  readonly reason?: string
  readonly error?: string
}

export type SubagentToolDetails =
  | {
      readonly type: "subagent"
      readonly outcome: "success"
      readonly operation: "spawn"
      readonly agent: SubagentToolAgentDetails
    }
  | {
      readonly type: "subagent"
      readonly outcome: "success"
      readonly operation: "send" | "continue" | "close"
      readonly agent: SubagentToolAgentDetails
    }
  | {
      readonly type: "subagent"
      readonly outcome: "success"
      readonly operation: "interrupt"
      readonly agent: SubagentToolAgentDetails
      readonly result: "interrupted" | "already_idle"
    }
  | {
      readonly type: "subagent"
      readonly outcome: "success"
      readonly operation: "wait"
      readonly agents: readonly SubagentToolAgentDetails[]
    }
  | {
      readonly type: "subagent"
      readonly outcome: "success"
      readonly operation: "list"
      readonly agents: readonly SubagentToolAgentDetails[]
      readonly workingAgentIds: readonly string[]
      readonly readyAgentIds: readonly string[]
    }

export function projectSubagentToolAgent(snapshot: SubagentSnapshot): SubagentToolAgentDetails {
  return {
    agentId: snapshot.agentId,
    definitionName: snapshot.definition.name,
    lifecycle: snapshot.lifecycle,
    ...(snapshot.workCycle !== undefined ? { workCycle: snapshot.workCycle } : {}),
    ...(snapshot.completionDelivery ? { completionDelivery: snapshot.completionDelivery } : {}),
    ...(snapshot.completion ? { completion: projectCompletion(snapshot.completion) } : {})
  }
}

export function isSubagentToolDetails(value: unknown): value is SubagentToolDetails {
  if (!isRecord(value) || value.type !== "subagent" || value.outcome !== "success") return false
  switch (value.operation) {
    case "spawn":
    case "send":
    case "continue":
    case "close":
      return isAgent(value.agent)
    case "interrupt":
      return isAgent(value.agent) && (value.result === "interrupted" || value.result === "already_idle")
    case "wait":
      return isAgentArray(value.agents)
    case "list":
      return isAgentArray(value.agents) && isStatusAgentIds(value.agents, value.workingAgentIds, value.readyAgentIds)
    default:
      return false
  }
}

function projectCompletion(completion: SubagentCompletion): SubagentToolCompletionDetails {
  return {
    workCycle: completion.workCycle,
    status: completion.status,
    text: completion.text,
    omittedBytes: completion.omittedBytes,
    truncated: completion.truncated,
    durationMs: completion.durationMs,
    ...(completion.reason ? { reason: completion.reason } : {}),
    ...(completion.error ? { error: completion.error } : {})
  }
}

function isAgentArray(value: unknown): value is readonly SubagentToolAgentDetails[] {
  return (
    Array.isArray(value) &&
    value.length <= 32 &&
    value.every(isAgent) &&
    new Set(value.map(agent => agent.agentId)).size === value.length
  )
}

function isStatusAgentIds(
  agents: readonly SubagentToolAgentDetails[],
  workingValue: unknown,
  readyValue: unknown
): boolean {
  if (!isAgentIdArray(workingValue) || !isAgentIdArray(readyValue)) return false
  const agentIds = new Set(agents.map(agent => agent.agentId))
  return workingValue.every(agentId => agentIds.has(agentId)) && readyValue.every(agentId => agentIds.has(agentId))
}

function isAgentIdArray(value: unknown): value is readonly string[] {
  return (
    Array.isArray(value) &&
    value.length <= 32 &&
    value.every(item => isBoundedText(item, maxAgentIdBytes)) &&
    new Set(value).size === value.length
  )
}

function isAgent(value: unknown): value is SubagentToolAgentDetails {
  if (
    !isRecord(value) ||
    !isBoundedText(value.agentId, maxAgentIdBytes) ||
    !isBoundedText(value.definitionName, maxDefinitionNameBytes) ||
    !isLifecycle(value.lifecycle)
  ) {
    return false
  }
  if (value.workCycle !== undefined && !isNonNegativeInteger(value.workCycle)) return false
  if (value.completionDelivery !== undefined && !isCompletionDelivery(value.completionDelivery)) return false
  return value.completion === undefined || isCompletion(value.completion)
}

function isCompletion(value: unknown): value is SubagentToolCompletionDetails {
  return (
    isRecord(value) &&
    isNonNegativeInteger(value.workCycle) &&
    isCompletionStatus(value.status) &&
    isBoundedText(value.text, maxCompletionTextBytes, true) &&
    isNonNegativeInteger(value.omittedBytes) &&
    typeof value.truncated === "boolean" &&
    typeof value.durationMs === "number" &&
    Number.isFinite(value.durationMs) &&
    value.durationMs >= 0 &&
    (value.reason === undefined || isBoundedText(value.reason, maxCompletionTextBytes, true)) &&
    (value.error === undefined || isBoundedText(value.error, maxCompletionTextBytes, true))
  )
}

function isBoundedText(value: unknown, maxBytes: number, allowEmpty = false): value is string {
  return (
    typeof value === "string" &&
    (allowEmpty || value.length > 0) &&
    !value.includes("\0") &&
    Buffer.byteLength(value) <= maxBytes
  )
}

function isNonNegativeInteger(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0
}

function isLifecycle(value: unknown): value is ChildLifecycleState["type"] {
  return (
    value === "starting" ||
    value === "idle" ||
    value === "spawn_admitting" ||
    value === "running" ||
    value === "interrupting" ||
    value === "closing" ||
    value === "exited"
  )
}

function isCompletionDelivery(value: unknown): value is CompletionDelivery["type"] {
  return value === "pending" || value === "durable" || value === "delivered"
}

function isCompletionStatus(value: unknown): value is SubagentCompletionStatus {
  return value === "completed" || value === "failed" || value === "cancelled"
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}
