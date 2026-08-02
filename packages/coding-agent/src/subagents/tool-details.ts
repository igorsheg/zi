import type { ChildLifecycleState, SubagentCompletion, SubagentCompletionStatus } from "./child-process.js"
import { clipUtf8 } from "./child-process.js"
import { maxLiveChildren, maxRetainedSubagents, type CompletionDelivery, type SubagentSnapshot } from "./supervisor.js"

const maxSubagentNameBytes = 64
const maxProfileDescriptionBytes = 4 * 1024
const maxCompletionTextBytes = 64 * 1024
export const maxSubagentToolDetailsBytes = 64 * 1024
export const maxProjectedSubagentToolEvidenceBytes = 16 * 1024
export const maxProjectedSubagentProfileDetailsBytes = 60 * 1024

export interface SubagentToolProfileDetails {
  readonly name: string
  readonly description: string
}

export interface SubagentToolAgentDetails {
  readonly name: string
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
      readonly operation: "profiles"
      readonly profiles: readonly SubagentToolProfileDetails[]
      readonly omittedBytes: number
    }
  | {
      readonly type: "subagent"
      readonly outcome: "success"
      readonly operation: "spawn"
      readonly profile: string
      readonly agent: SubagentToolAgentDetails
    }
  | {
      readonly type: "subagent"
      readonly outcome: "success"
      readonly operation: "send" | "continue"
      readonly agent: SubagentToolAgentDetails
    }
  | {
      readonly type: "subagent"
      readonly outcome: "success"
      readonly operation: "close"
      readonly agent: SubagentToolAgentDetails
      readonly previousStatus: ChildLifecycleState["type"]
      readonly previousCompletionStatus?: SubagentCompletion["status"]
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
      readonly workingNames: readonly string[]
      readonly readyNames: readonly string[]
    }

export function projectSubagentToolAgent(snapshot: SubagentSnapshot): SubagentToolAgentDetails {
  return projectSubagentToolAgents([snapshot])[0]!
}

export function projectSubagentToolAgents(snapshots: readonly SubagentSnapshot[]): readonly SubagentToolAgentDetails[] {
  const agents: MutableAgentDetails[] = snapshots.map(snapshot => {
    const projected = projectAgent(snapshot)
    return { ...projected, ...(projected.completion ? { completion: { ...projected.completion } } : {}) }
  })

  while (Buffer.byteLength(JSON.stringify(agents)) > maxProjectedSubagentToolEvidenceBytes) {
    const evidence = completionEvidence(agents)
    if (evidence.length === 0) {
      throw new Error(`Subagent tool metadata exceeds ${maxProjectedSubagentToolEvidenceBytes} bytes`)
    }
    const excess = Buffer.byteLength(JSON.stringify(agents)) - maxProjectedSubagentToolEvidenceBytes
    const retainedBytes = Math.max(0, evidence.reduce((total, item) => total + item.bytes, 0) - excess)
    const limit = fairEvidenceLimit(evidence, retainedBytes)
    for (const item of evidence) {
      if (item.bytes <= limit) continue
      const value = item.completion[item.field] ?? ""
      const clipped = clipUtf8(value, limit)
      item.completion[item.field] = clipped.text
      item.completion.omittedBytes += clipped.omittedBytes
      item.completion.truncated = true
    }
  }

  return Object.freeze(
    agents.map(agent =>
      Object.freeze({ ...agent, ...(agent.completion ? { completion: Object.freeze(agent.completion) } : {}) })
    )
  )
}

export function isSubagentToolDetails(value: unknown): value is SubagentToolDetails {
  if (!isRecord(value) || value.type !== "subagent" || value.outcome !== "success") return false
  try {
    if (Buffer.byteLength(JSON.stringify(value)) > maxSubagentToolDetailsBytes) return false
  } catch {
    return false
  }
  switch (value.operation) {
    case "profiles":
      return isProfileArray(value.profiles) && isNonNegativeInteger(value.omittedBytes)
    case "spawn":
      return isSubagentName(value.profile) && isAgent(value.agent)
    case "send":
    case "continue":
      return isAgent(value.agent)
    case "close":
      return (
        isAgent(value.agent) &&
        isLifecycle(value.previousStatus) &&
        (value.previousCompletionStatus === undefined || isCompletionStatus(value.previousCompletionStatus))
      )
    case "interrupt":
      return isAgent(value.agent) && (value.result === "interrupted" || value.result === "already_idle")
    case "wait":
      return isAgentArray(value.agents) && serializedBytes(value.agents) <= maxProjectedSubagentToolEvidenceBytes
    case "list":
      return (
        isAgentArray(value.agents) &&
        serializedBytes(value.agents) <= maxProjectedSubagentToolEvidenceBytes &&
        isStatusNames(value.agents, value.workingNames, value.readyNames)
      )
    default:
      return false
  }
}

type MutableCompletionDetails = {
  -readonly [Key in keyof SubagentToolCompletionDetails]: SubagentToolCompletionDetails[Key]
}

interface MutableAgentDetails {
  name: string
  lifecycle: ChildLifecycleState["type"]
  workCycle?: number
  completionDelivery?: CompletionDelivery["type"]
  completion?: MutableCompletionDetails
}

type CompletionEvidence = {
  readonly completion: MutableCompletionDetails
  readonly field: "text" | "reason" | "error"
  readonly bytes: number
}

function completionEvidence(agents: readonly MutableAgentDetails[]): CompletionEvidence[] {
  const evidence: CompletionEvidence[] = []
  for (const agent of agents) {
    const completion = agent.completion
    if (!completion) continue
    for (const field of ["text", "reason", "error"] as const) {
      const value = completion[field]
      if (value) evidence.push({ completion, field, bytes: Buffer.byteLength(value) })
    }
  }
  return evidence
}

function fairEvidenceLimit(evidence: readonly CompletionEvidence[], retainedBytes: number): number {
  let low = 0
  let high = evidence.reduce((largest, item) => Math.max(largest, item.bytes), 0)
  while (low < high) {
    const candidate = Math.ceil((low + high) / 2)
    const admitted = evidence.reduce((total, item) => total + Math.min(item.bytes, candidate), 0)
    if (admitted <= retainedBytes) low = candidate
    else high = candidate - 1
  }
  return low
}

function projectAgent(snapshot: SubagentSnapshot): SubagentToolAgentDetails {
  return {
    name: snapshot.name,
    lifecycle: snapshot.lifecycle,
    ...(snapshot.workCycle !== undefined ? { workCycle: snapshot.workCycle } : {}),
    ...(snapshot.completionDelivery ? { completionDelivery: snapshot.completionDelivery } : {}),
    ...(snapshot.completion ? { completion: projectCompletion(snapshot.completion) } : {})
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

function isProfileArray(value: unknown): value is readonly SubagentToolProfileDetails[] {
  return (
    Array.isArray(value) &&
    value.length <= 128 &&
    value.every(
      profile =>
        isRecord(profile) &&
        isSubagentName(profile.name) &&
        isBoundedText(profile.description, maxProfileDescriptionBytes, true)
    ) &&
    new Set(value.map(profile => profile.name)).size === value.length
  )
}

function isAgentArray(value: unknown): value is readonly SubagentToolAgentDetails[] {
  return (
    Array.isArray(value) &&
    value.length <= maxLiveChildren + maxRetainedSubagents &&
    value.every(isAgent) &&
    new Set(value.map(agent => agent.name)).size === value.length
  )
}

function isStatusNames(
  agents: readonly SubagentToolAgentDetails[],
  workingValue: unknown,
  readyValue: unknown
): boolean {
  if (!isNameArray(workingValue) || !isNameArray(readyValue)) return false
  const names = new Set(agents.map(agent => agent.name))
  return workingValue.every(name => names.has(name)) && readyValue.every(name => names.has(name))
}

function isNameArray(value: unknown): value is readonly string[] {
  return (
    Array.isArray(value) &&
    value.length <= maxLiveChildren + maxRetainedSubagents &&
    value.every(isSubagentName) &&
    new Set(value).size === value.length
  )
}

function isAgent(value: unknown): value is SubagentToolAgentDetails {
  if (!isRecord(value) || !isSubagentName(value.name) || !isLifecycle(value.lifecycle)) {
    return false
  }
  if (value.workCycle !== undefined && !isNonNegativeInteger(value.workCycle)) return false
  if (value.completionDelivery !== undefined && !isCompletionDelivery(value.completionDelivery)) return false
  return value.completion === undefined || isCompletion(value.completion)
}

function isSubagentName(value: unknown): value is string {
  return isBoundedText(value, maxSubagentNameBytes) && /^[a-z][a-z0-9_-]*$/.test(value)
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

function serializedBytes(value: unknown): number {
  return Buffer.byteLength(JSON.stringify(value))
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}
