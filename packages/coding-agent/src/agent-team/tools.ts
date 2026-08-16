import type { AgentTool } from "@earendil-works/pi-agent-core"
import { Type } from "@earendil-works/pi-ai"
import type { ExtensionSubagentProfile } from "@with-zi/extension-api"

import { type AgentSnapshot, type AgentTeam } from "./agent-team.js"
import { type ForkTurns, maxAgentMailTextBytes } from "./journal.js"
import { maxAgentPathBytes, maxAgentTaskNameBytes, resolveAgentPath, type AgentPath } from "./path.js"
import { type AgentTeamToolDetails, maxAgentTeamToolDetailsBytes, projectAgentTeamToolAgent } from "./tool-details.js"
import {
  type AgentWaitActivity,
  maxAgentWaitTimeoutMs,
  minAgentWaitTimeoutMs,
  resolveAgentWaitTimeout
} from "./wait.js"

const maxRoleDescriptionBytes = 8 * 1024
export const maxAgentTeamToolResultBytes = 64 * 1024

const taskName = Type.String({
  minLength: 1,
  maxLength: maxAgentTaskNameBytes,
  pattern: "^[a-z][a-z0-9_-]*$",
  description:
    "Task name for the new agent. Start with a lowercase letter and use lowercase letters, digits, underscores, or hyphens."
})
const message = Type.String({ minLength: 1, maxLength: maxAgentMailTextBytes })
const target = Type.String({
  minLength: 1,
  maxLength: maxAgentPathBytes,
  description: "Relative or canonical task path returned by spawn_agent."
})
const targetMessageParameters = Type.Object({ target, message })
const targetParameters = Type.Object({ target })
const waitParameters = Type.Object({
  timeout_ms: Type.Optional(Type.Integer({ minimum: 0, maximum: maxAgentWaitTimeoutMs }))
})
const listParameters = Type.Object({
  path_prefix: Type.Optional(Type.String({ minLength: 1, maxLength: maxAgentPathBytes }))
})

export type WaitForAgentActivity = (timeoutMs: number, signal?: AbortSignal) => Promise<AgentWaitActivity>

export function createAgentTeamTools(
  team: AgentTeam,
  caller: AgentPath,
  roles: readonly ExtensionSubagentProfile[],
  waitForActivity: WaitForAgentActivity,
  defaultWaitTimeoutMs: number
): readonly AgentTool[] {
  const spawnParameters = Type.Object({
    task_name: taskName,
    message,
    agent_type: Type.Optional(
      Type.String({
        minLength: 1,
        maxLength: maxAgentTaskNameBytes,
        pattern: "^[a-z][a-z0-9_-]*$",
        description: roleDescription(roles)
      })
    ),
    fork_turns: Type.Optional(
      Type.String({
        maxLength: 16,
        pattern: "^(all|none|[1-9][0-9]*)$",
        description: "Parent turns to inherit: all, none, or a positive integer. Defaults to all."
      })
    )
  })

  const spawn: AgentTool<typeof spawnParameters, AgentTeamToolDetails> = {
    name: "spawn_agent",
    label: "spawn_agent",
    description:
      "Spawn a durable child agent for a well-scoped task. Completion is delivered passively to its direct parent.",
    parameters: spawnParameters,
    executionMode: "parallel",
    async execute(_id, input) {
      const role = input.agent_type === undefined ? undefined : requireRole(roles, input.agent_type)
      const snapshot = await team.spawn({
        sender: caller,
        taskName: input.task_name,
        message: role ? `${role.instructions.trimEnd()}\n\nTask:\n${input.message}` : input.message,
        forkTurns: forkTurns(input.fork_turns),
        ...(role
          ? {
              role: role.name,
              roleSelection: {
                name: role.name,
                ...(role.model === undefined ? {} : { model: role.model }),
                ...(role.thinking === undefined ? {} : { thinking: role.thinking })
              }
            }
          : {})
      })
      return textResult(
        { agent: modelSnapshot(snapshot) },
        { type: "agent_team", outcome: "success", operation: "spawn", agent: projectAgentTeamToolAgent(snapshot) }
      )
    }
  }

  const send: AgentTool<typeof targetMessageParameters, AgentTeamToolDetails> = {
    name: "send_message",
    label: "send_message",
    description: "Send a durable message to an existing agent without starting an idle turn.",
    parameters: targetMessageParameters,
    executionMode: "parallel",
    async execute(_id, input) {
      const path = resolveAgentPath(caller, input.target)
      await team.sendMessage(caller, path, input.message)
      return textResult(
        { target: path, delivered: true },
        { type: "agent_team", outcome: "success", operation: "send", target: path }
      )
    }
  }

  const followup: AgentTool<typeof targetMessageParameters, AgentTeamToolDetails> = {
    name: "followup_task",
    label: "followup_task",
    description: "Send a follow-up task and start a turn only when the non-root target is idle.",
    parameters: targetMessageParameters,
    executionMode: "parallel",
    async execute(_id, input) {
      const path = resolveAgentPath(caller, input.target)
      const delivery = await team.followupTask(caller, path, input.message)
      return textResult(
        { target: path, delivery },
        { type: "agent_team", outcome: "success", operation: "followup", target: path, delivery }
      )
    }
  }

  const wait: AgentTool<typeof waitParameters, AgentTeamToolDetails> = {
    name: "wait_agent",
    label: "wait_agent",
    description:
      "Wait for a mailbox update from any agent or new input steered into the active turn. Completion content is delivered separately.",
    parameters: waitParameters,
    executionMode: "parallel",
    async execute(_id, input, signal) {
      const requestedTimeoutMs = input.timeout_ms
      const timeoutMs = resolveAgentWaitTimeout(requestedTimeoutMs, defaultWaitTimeoutMs)
      const activity = await waitForActivity(timeoutMs, signal)
      const summary = waitMessage(activity, requestedTimeoutMs, timeoutMs)
      return textResult(
        { message: summary, timed_out: activity === "timed_out" },
        { type: "agent_team", outcome: "success", operation: "wait", activity, timedOut: activity === "timed_out" }
      )
    }
  }

  const list: AgentTool<typeof listParameters, AgentTeamToolDetails> = {
    name: "list_agents",
    label: "list_agents",
    description: "List durable agents in the current root tree, optionally filtered by a task-path prefix.",
    parameters: listParameters,
    executionMode: "parallel",
    execute(_id, input) {
      const prefix = input.path_prefix === undefined ? undefined : resolveAgentPath(caller, input.path_prefix)
      const snapshots = team.snapshots(prefix)
      return Promise.resolve(
        textResult(
          { agents: snapshots.map(modelSnapshot) },
          {
            type: "agent_team",
            outcome: "success",
            operation: "list",
            agents: snapshots.map(projectAgentTeamToolAgent)
          }
        )
      )
    }
  }

  const interrupt: AgentTool<typeof targetParameters, AgentTeamToolDetails> = {
    name: "interrupt_agent",
    label: "interrupt_agent",
    description: "Interrupt an agent's current turn while keeping its durable address available.",
    parameters: targetParameters,
    executionMode: "parallel",
    async execute(_id, input) {
      const path = resolveAgentPath(caller, input.target)
      const previous = team.snapshots(path).find(snapshot => snapshot.path === path)
      if (!previous) throw new Error(`Unknown agent path: ${path}`)
      const result = await team.interrupt(path)
      return textResult(
        { target: path, previous_status: previous.turn, result },
        {
          type: "agent_team",
          outcome: "success",
          operation: "interrupt",
          target: path,
          previousTurn: previous.turn,
          result
        }
      )
    }
  }

  return Object.freeze([spawn, send, followup, wait, list, interrupt])
}

function waitMessage(activity: AgentWaitActivity, requestedTimeoutMs: number | undefined, timeoutMs: number): string {
  const summary =
    activity === "mailbox"
      ? "Wait completed."
      : activity === "steered"
        ? "Wait interrupted by new input."
        : "Wait timed out."
  return requestedTimeoutMs !== undefined && requestedTimeoutMs < timeoutMs
    ? `${summary}\n\nRequested timeout of ${requestedTimeoutMs}ms was clamped to the minimum of ${minAgentWaitTimeoutMs}ms.`
    : summary
}

function forkTurns(value: string | undefined): ForkTurns {
  if (value === undefined || value === "all") return "all"
  if (value === "none") return "none"
  const turns = Number(value)
  if (!Number.isSafeInteger(turns) || turns <= 0) throw new Error(`Invalid fork_turns: ${value}`)
  return turns
}

function requireRole(roles: readonly ExtensionSubagentProfile[], name: string): ExtensionSubagentProfile {
  const role = roles.find(candidate => candidate.name === name)
  if (!role) throw new Error(`Unknown agent role: ${name}`)
  return role
}

function roleDescription(roles: readonly ExtensionSubagentProfile[]): string {
  if (roles.length === 0) return "Optional agent role. No named roles are currently admitted."
  const prefix = "Optional agent role. Admitted roles: "
  const retained: string[] = []
  for (const role of roles) {
    const candidate = `${role.name} — ${role.description}`
    const text = `${prefix}${retained.length === 0 ? "" : `${retained.join("; ")}; `}${candidate}`
    if (Buffer.byteLength(text) > maxRoleDescriptionBytes) break
    retained.push(candidate)
  }
  const omitted = roles.length - retained.length
  return `${prefix}${retained.join("; ")}${omitted > 0 ? `; ${omitted} omitted` : ""}`
}

function modelSnapshot(snapshot: AgentSnapshot) {
  return {
    path: snapshot.path,
    parent_path: snapshot.parentPath,
    task_name: snapshot.taskName,
    ...(snapshot.role === undefined ? {} : { agent_type: snapshot.role }),
    residency: snapshot.residency,
    status: snapshot.turn,
    turn: snapshot.turnNumber,
    settled_status: snapshot.status
  }
}

function textResult(value: Readonly<Record<string, unknown>>, details: AgentTeamToolDetails) {
  const text = JSON.stringify(value)
  if (Buffer.byteLength(text) > maxAgentTeamToolResultBytes) throw new Error("Agent tool result exceeds its byte bound")
  if (Buffer.byteLength(JSON.stringify(details)) > maxAgentTeamToolDetailsBytes) {
    throw new Error("Agent tool details exceed their byte bound")
  }
  return { content: [{ type: "text" as const, text }], details }
}
