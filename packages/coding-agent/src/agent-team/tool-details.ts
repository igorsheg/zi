import { isAgentTeamToolDetailsShape } from "../guards.js"
import type { AgentSnapshot } from "./agent-team.js"
import type { AgentPath } from "./path.js"
import type { AgentType } from "./spawn.js"

export const maxAgentTeamToolDetailsBytes = 64 * 1024

export interface AgentTeamToolAgentDetails {
  readonly path: AgentPath
  readonly parentPath: AgentPath
  readonly taskName: string
  readonly agentType: AgentType
  readonly residency: AgentSnapshot["residency"]
  readonly turnState: AgentSnapshot["turn"]
  readonly turnNumber: number
  readonly settledStatus: AgentSnapshot["status"]
}

export type AgentTeamToolDetails =
  | {
      readonly type: "agent_team"
      readonly outcome: "success"
      readonly operation: "spawn"
      readonly agent: AgentTeamToolAgentDetails
    }
  | { readonly type: "agent_team"; readonly outcome: "success"; readonly operation: "send"; readonly target: AgentPath }
  | {
      readonly type: "agent_team"
      readonly outcome: "success"
      readonly operation: "followup"
      readonly target: AgentPath
      readonly delivery: "started" | "joined"
    }
  | {
      readonly type: "agent_team"
      readonly outcome: "success"
      readonly operation: "wait"
      readonly activity: "mailbox" | "steered" | "timed_out"
      readonly timedOut: boolean
    }
  | {
      readonly type: "agent_team"
      readonly outcome: "success"
      readonly operation: "list"
      readonly agents: readonly AgentTeamToolAgentDetails[]
    }
  | {
      readonly type: "agent_team"
      readonly outcome: "success"
      readonly operation: "interrupt"
      readonly target: AgentPath
      readonly previousTurn: AgentSnapshot["turn"]
      readonly result: "interrupted" | "idle"
    }

export function projectAgentTeamToolAgent(snapshot: AgentSnapshot): AgentTeamToolAgentDetails {
  return Object.freeze({
    path: snapshot.path,
    parentPath: snapshot.parentPath,
    taskName: snapshot.taskName,
    agentType: snapshot.agentType,
    residency: snapshot.residency,
    turnState: snapshot.turn,
    turnNumber: snapshot.turnNumber,
    settledStatus: snapshot.status
  })
}

export function isAgentTeamToolDetails(value: unknown): value is AgentTeamToolDetails {
  if (!isAgentTeamToolDetailsShape(value)) return false
  if (value.operation === "wait" && value.timedOut !== (value.activity === "timed_out")) return false
  try {
    return Buffer.byteLength(JSON.stringify(value)) <= maxAgentTeamToolDetailsBytes
  } catch {
    return false
  }
}
