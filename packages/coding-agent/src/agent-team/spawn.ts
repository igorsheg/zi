import type { ThinkingLevel } from "@earendil-works/pi-agent-core"

import { isRecord, isThinkingLevel } from "../guards.js"
import type { SessionModel } from "../session-manager.js"
import type { ForkTurns } from "./journal.js"

export const maxAgentModelIdentityBytes = 4 * 1024

export const agentTypes = ["default", "explorer", "worker"] as const
export type AgentType = (typeof agentTypes)[number]

export interface AgentExecutionSpec {
  readonly model: SessionModel
  readonly thinkingLevel: ThinkingLevel
}

export interface AgentSpawnSpec {
  readonly agentType: AgentType
  readonly forkTurns: ForkTurns
  readonly execution: AgentExecutionSpec
}

export const agentTypeDescription = `Built-in agent type. Omit to use default.
default: General delegated work.
explorer: Specific, well-scoped codebase questions. Prefer several parallel explorers for independent questions and reuse one for related follow-ups.
worker: Execution and production work. Assign explicit file or module ownership and warn that other workers may edit the repository concurrently.`

export function isAgentType(value: unknown): value is AgentType {
  return value === "default" || value === "explorer" || value === "worker"
}

export function isAgentExecutionSpec(value: unknown): value is AgentExecutionSpec {
  if (!isRecord(value) || !isRecord(value.model) || !isThinkingLevel(value.thinkingLevel)) return false
  return (
    nonEmptyBounded(value.model.provider) &&
    nonEmptyBounded(value.model.modelId) &&
    Object.keys(value.model).every(key => key === "provider" || key === "modelId") &&
    Object.keys(value).every(key => key === "model" || key === "thinkingLevel")
  )
}

function nonEmptyBounded(value: unknown): value is string {
  return typeof value === "string" && value.length > 0 && Buffer.byteLength(value) <= maxAgentModelIdentityBytes
}
