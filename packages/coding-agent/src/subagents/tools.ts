import type { AgentTool } from "@earendil-works/pi-agent-core"
import { Type } from "@earendil-works/pi-ai"

import { maxSubagentTypeNameBytes, type SubagentTypeDefinition } from "./definitions.js"
import type { SubagentSupervisor, SubagentSnapshot } from "./supervisor.js"
import {
  defaultWaitTimeoutMs,
  maxSubagentAgentIdBytes,
  maxSubagentPromptBytes,
  maxWaitIds,
  maxWaitTimeoutMs
} from "./supervisor.js"
import { projectSubagentToolAgent, type SubagentToolDetails } from "./tool-details.js"

const maxPromptTypeDescriptionBytes = 160
const maxPromptTypeCatalogBytes = 8 * 1024

const messageParameters = Type.Object({
  agent_id: Type.String({ minLength: 1, maxLength: maxSubagentAgentIdBytes }),
  text: Type.String({ minLength: 1, maxLength: maxSubagentPromptBytes })
})
const agentParameters = Type.Object({ agent_id: Type.String({ minLength: 1, maxLength: maxSubagentAgentIdBytes }) })
const waitParameters = Type.Object({
  agent_ids: Type.Array(Type.String({ minLength: 1, maxLength: maxSubagentAgentIdBytes }), {
    minItems: 1,
    maxItems: maxWaitIds,
    uniqueItems: true
  }),
  timeout_ms: Type.Optional(Type.Number({ minimum: 0, maximum: maxWaitTimeoutMs }))
})
const listParameters = Type.Object({})

export function createSubagentTools(supervisor: SubagentSupervisor): readonly AgentTool[] {
  const spawnParameters = Type.Object({
    prompt: Type.String({
      minLength: 1,
      maxLength: maxSubagentPromptBytes,
      description: "Initial task for the child agent"
    }),
    type: Type.Optional(
      Type.String({
        minLength: 1,
        maxLength: maxSubagentTypeNameBytes,
        description: subagentTypeParameterDescription(supervisor.definitions())
      })
    )
  })
  const spawn: AgentTool<typeof spawnParameters> = {
    name: "spawn_subagent",
    label: "spawn_subagent",
    description:
      "Start one background Zi subagent with an initial direct prompt. Returns its id after admission; use wait_subagents for output.",
    parameters: spawnParameters,
    executionMode: "parallel",
    async execute(_id, input, signal) {
      const agentId = await supervisor.spawn(input.prompt, input.type, signal)
      return textResult(JSON.stringify({ agent_id: agentId }), {
        type: "subagent",
        outcome: "success",
        operation: "spawn",
        agent: projectSubagentToolAgent(requireSnapshot(supervisor, agentId))
      })
    }
  }
  const send: AgentTool<typeof messageParameters> = {
    name: "send_subagent",
    label: "send_subagent",
    description:
      "Queue-only delivery to a subagent. Idle children keep the message queued until continue_subagent; running children consume it as follow-up.",
    parameters: messageParameters,
    executionMode: "parallel",
    async execute(_id, input) {
      await supervisor.send(input.agent_id, input.text)
      return textResult(JSON.stringify({ agent_id: input.agent_id, delivered: "follow_up" }), {
        type: "subagent",
        outcome: "success",
        operation: "send",
        agent: projectSubagentToolAgent(requireSnapshot(supervisor, input.agent_id))
      })
    }
  }
  const continueTool: AgentTool<typeof messageParameters> = {
    name: "continue_subagent",
    label: "continue_subagent",
    description: "Atomically wake an idle subagent or queue follow-up on a running one.",
    parameters: messageParameters,
    executionMode: "parallel",
    async execute(_id, input) {
      await supervisor.continue(input.agent_id, input.text)
      return textResult(JSON.stringify({ agent_id: input.agent_id, delivered: "continue" }), {
        type: "subagent",
        outcome: "success",
        operation: "continue",
        agent: projectSubagentToolAgent(requireSnapshot(supervisor, input.agent_id))
      })
    }
  }
  const wait: AgentTool<typeof waitParameters> = {
    name: "wait_subagents",
    label: "wait_subagents",
    description:
      "Wait boundedly for one or more subagents. Timeout returns current snapshots and never cancels children.",
    parameters: waitParameters,
    executionMode: "parallel",
    async execute(_id, input, signal) {
      const snapshots = await supervisor.wait(input.agent_ids, input.timeout_ms ?? defaultWaitTimeoutMs, signal)
      return textResult(JSON.stringify({ agents: snapshots.map(projectSnapshot) }), {
        type: "subagent",
        outcome: "success",
        operation: "wait",
        agents: snapshots.map(projectSubagentToolAgent)
      })
    }
  }
  const interrupt: AgentTool<typeof agentParameters> = {
    name: "interrupt_subagent",
    label: "interrupt_subagent",
    description: "Interrupt current child work while keeping the process reusable.",
    parameters: agentParameters,
    executionMode: "parallel",
    async execute(_id, input) {
      const result = await supervisor.interrupt(input.agent_id)
      return textResult(JSON.stringify({ agent_id: input.agent_id, result }), {
        type: "subagent",
        outcome: "success",
        operation: "interrupt",
        agent: projectSubagentToolAgent(requireSnapshot(supervisor, input.agent_id)),
        result
      })
    }
  }
  const close: AgentTool<typeof agentParameters> = {
    name: "close_subagent",
    label: "close_subagent",
    description: "Close one child process and release its live-child capacity.",
    parameters: agentParameters,
    executionMode: "parallel",
    async execute(_id, input) {
      await supervisor.close(input.agent_id)
      return textResult(JSON.stringify({ agent_id: input.agent_id, closed: true }), {
        type: "subagent",
        outcome: "success",
        operation: "close",
        agent: projectSubagentToolAgent(requireSnapshot(supervisor, input.agent_id))
      })
    }
  }
  const list: AgentTool<typeof listParameters> = {
    name: "list_subagents",
    label: "list_subagents",
    description: "Return bounded direct-child snapshots without child conversations.",
    parameters: listParameters,
    executionMode: "parallel",
    execute() {
      const snapshots = supervisor.snapshots()
      const status = supervisor.status()
      return Promise.resolve(
        textResult(JSON.stringify({ agents: snapshots.map(projectSnapshot) }), {
          type: "subagent",
          outcome: "success",
          operation: "list",
          agents: snapshots.map(projectSubagentToolAgent),
          workingAgentIds: status.workingAgentIds,
          readyAgentIds: status.readyAgentIds
        })
      )
    }
  }
  return Object.freeze([spawn, send, continueTool, wait, interrupt, close, list])
}

function projectSnapshot(snapshot: SubagentSnapshot) {
  return {
    agent_id: snapshot.agentId,
    lifecycle: snapshot.lifecycle,
    type: snapshot.definition.name,
    ...(snapshot.workCycle !== undefined ? { work_cycle: snapshot.workCycle } : {}),
    ...(snapshot.sessionId ? { session_id: snapshot.sessionId } : {}),
    ...(snapshot.completion
      ? {
          completion: {
            status: snapshot.completion.status,
            text: snapshot.completion.text,
            original_bytes: snapshot.completion.originalBytes,
            omitted_bytes: snapshot.completion.omittedBytes,
            truncated: snapshot.completion.truncated,
            duration_ms: snapshot.completion.durationMs,
            ...(snapshot.completion.reason ? { reason: snapshot.completion.reason } : {}),
            ...(snapshot.completion.error ? { error: snapshot.completion.error } : {})
          }
        }
      : {}),
    ...(snapshot.completionDelivery ? { completion_delivery: snapshot.completionDelivery } : {})
  }
}

function requireSnapshot(supervisor: SubagentSupervisor, agentId: string): SubagentSnapshot {
  const snapshot = supervisor.snapshots().find(value => value.agentId === agentId)
  if (!snapshot) throw new Error(`Subagent ${agentId} completed an operation without a retained snapshot`)
  return snapshot
}

export function subagentTypeParameterDescription(definitions: readonly SubagentTypeDefinition[]): string {
  const prefix = "Named subagent type. Defaults to general.\n\nAvailable types:\n"
  const lines: string[] = []
  let bytes = Buffer.byteLength(prefix)
  let omitted = 0
  for (const definition of definitions) {
    const description = normalizedPromptText(definition.description, maxPromptTypeDescriptionBytes)
    const line = `- ${definition.name} — ${description}\n`
    if (bytes + Buffer.byteLength(line) > maxPromptTypeCatalogBytes - 64) {
      omitted++
      continue
    }
    lines.push(line)
    bytes += Buffer.byteLength(line)
  }
  const omission = omitted > 0 ? `- ${omitted} additional types omitted\n` : ""
  return `${prefix}${lines.join("")}${omission}`.trimEnd()
}

function normalizedPromptText(value: string, maxBytes: number): string {
  const normalized =
    Buffer.from(value)
      .toString("utf8")
      .replaceAll(/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]+/gu, " ")
      .replaceAll(/\s+/gu, " ")
      .trim() || "(no description)"
  if (Buffer.byteLength(normalized) <= maxBytes) return normalized
  const suffix = "…"
  const budget = maxBytes - Buffer.byteLength(suffix)
  let bytes = 0
  let bounded = ""
  for (const scalar of normalized) {
    const scalarBytes = Buffer.byteLength(scalar)
    if (bytes + scalarBytes > budget) break
    bounded += scalar
    bytes += scalarBytes
  }
  return `${bounded.trimEnd()}${suffix}`
}

function textResult(text: string, details: SubagentToolDetails) {
  return { content: [{ type: "text" as const, text }], details }
}
