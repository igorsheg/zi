import type { AgentTool } from "@earendil-works/pi-agent-core"
import { Type } from "@earendil-works/pi-ai"

import type { SubagentCompletion } from "./child-process.js"
import { clipUtf8 } from "./child-process.js"
import type { SubagentSupervisor, SubagentSnapshot } from "./supervisor.js"
import { maxSubagentNameBytes, maxSubagentPromptBytes, maxWaitNames, maxWaitTimeoutMs } from "./supervisor.js"
import { projectSubagentToolAgent, type SubagentToolDetails } from "./tool-details.js"

const messageParameters = Type.Object({
  name: Type.String({ minLength: 1, maxLength: maxSubagentNameBytes, pattern: "^[a-z][a-z0-9_-]*$" }),
  text: Type.String({ minLength: 1, maxLength: maxSubagentPromptBytes })
})
const agentParameters = Type.Object({
  name: Type.String({ minLength: 1, maxLength: maxSubagentNameBytes, pattern: "^[a-z][a-z0-9_-]*$" })
})
const waitParameters = Type.Object({
  names: Type.Array(Type.String({ minLength: 1, maxLength: maxSubagentNameBytes, pattern: "^[a-z][a-z0-9_-]*$" }), {
    minItems: 1,
    maxItems: maxWaitNames,
    uniqueItems: true
  }),
  timeout_ms: Type.Optional(
    Type.Number({
      minimum: 0,
      maximum: maxWaitTimeoutMs,
      description: "Optional bounded wait in milliseconds. Omit to use the configured default; maximum is one hour."
    })
  )
})
const listParameters = Type.Object({})

export const maxWaitResultBytes = 64 * 1024

export function createSubagentTools(supervisor: SubagentSupervisor): readonly AgentTool[] {
  const spawnParameters = Type.Object({
    name: Type.String({
      minLength: 1,
      maxLength: maxSubagentNameBytes,
      pattern: "^[a-z][a-z0-9_-]*$",
      description: "Unique short name for this child. Use lowercase letters, numbers, _ or -."
    }),
    prompt: Type.String({
      minLength: 1,
      maxLength: maxSubagentPromptBytes,
      description: "Initial task for the child agent"
    })
  })
  const spawn: AgentTool<typeof spawnParameters> = {
    name: "spawn_subagent",
    label: "spawn_subagent",
    description:
      "Start one background Zi subagent with an initial direct prompt. Returns its name after admission; use wait_subagents for output.",
    parameters: spawnParameters,
    executionMode: "parallel",
    async execute(_id, input, signal) {
      const name = await supervisor.spawn(input.name, input.prompt, signal)
      return textResult(JSON.stringify({ name }), {
        type: "subagent",
        outcome: "success",
        operation: "spawn",
        agent: projectSubagentToolAgent(requireSnapshot(supervisor, name))
      })
    }
  }
  const send: AgentTool<typeof messageParameters> = {
    name: "send_subagent",
    label: "send_subagent",
    description:
      "Deliver information without starting a child turn. An idle child stores it for its next assigned task; a running child receives it as follow-up.",
    parameters: messageParameters,
    executionMode: "parallel",
    async execute(_id, input) {
      await supervisor.send(input.name, input.text)
      return textResult(JSON.stringify({ name: input.name, accepted: true, started_turn: false }), {
        type: "subagent",
        outcome: "success",
        operation: "send",
        agent: projectSubagentToolAgent(requireSnapshot(supervisor, input.name))
      })
    }
  }
  const continueTool: AgentTool<typeof messageParameters> = {
    name: "continue_subagent",
    label: "continue_subagent",
    description:
      "Assign follow-up work to a child. Starts a turn when the child is idle; otherwise delivers the task to its current turn.",
    parameters: messageParameters,
    executionMode: "parallel",
    async execute(_id, input) {
      const delivery = await supervisor.continue(input.name, input.text)
      return textResult(
        JSON.stringify({ name: input.name, accepted: true, started_turn: delivery === "started_turn" }),
        {
          type: "subagent",
          outcome: "success",
          operation: "continue",
          agent: projectSubagentToolAgent(requireSnapshot(supervisor, input.name))
        }
      )
    }
  }
  const wait: AgentTool<typeof waitParameters> = {
    name: "wait_subagents",
    label: "wait_subagents",
    description:
      "Wait for all requested current child tasks. Returns each completion, or current status on timeout, without cancelling children.",
    parameters: waitParameters,
    executionMode: "parallel",
    async execute(_id, input, signal) {
      const snapshots = await supervisor.wait(input.names, input.timeout_ms ?? supervisor.waitTimeoutMs, signal)
      return textResult(JSON.stringify(projectWaitResult(snapshots)), {
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
      const result = await supervisor.interrupt(input.name)
      return textResult(JSON.stringify({ name: input.name, result }), {
        type: "subagent",
        outcome: "success",
        operation: "interrupt",
        agent: projectSubagentToolAgent(requireSnapshot(supervisor, input.name)),
        result
      })
    }
  }
  const close: AgentTool<typeof agentParameters> = {
    name: "close_subagent",
    label: "close_subagent",
    description:
      "Close one child process, return its prior status and previous completion status, and release its live-child capacity.",
    parameters: agentParameters,
    executionMode: "parallel",
    async execute(_id, input) {
      const previous = await supervisor.close(input.name)
      const previousCompletion = previous.completion ? { status: previous.completion.status } : undefined
      return textResult(
        JSON.stringify({
          name: input.name,
          closed: true,
          previous_status: previous.lifecycle,
          ...(previousCompletion ? { previous_completion: previousCompletion } : {})
        }),
        {
          type: "subagent",
          outcome: "success",
          operation: "close",
          agent: projectSubagentToolAgent(requireSnapshot(supervisor, input.name)),
          previousStatus: previous.lifecycle,
          ...(previous.completion ? { previousCompletionStatus: previous.completion.status } : {})
        }
      )
    }
  }
  const list: AgentTool<typeof listParameters> = {
    name: "list_subagents",
    label: "list_subagents",
    description:
      "Return current direct-child status and any uncollected result readiness, without child conversations.",
    parameters: listParameters,
    executionMode: "parallel",
    execute() {
      const snapshots = supervisor.snapshots()
      const status = supervisor.status()
      return Promise.resolve(
        textResult(JSON.stringify({ agents: snapshots.map(projectListSnapshot) }), {
          type: "subagent",
          outcome: "success",
          operation: "list",
          agents: snapshots.map(projectSubagentToolAgent),
          workingNames: status.workingNames,
          readyNames: status.readyNames
        })
      )
    }
  }
  return Object.freeze([spawn, send, continueTool, wait, interrupt, close, list])
}

type WaitCompletion = {
  status: SubagentCompletion["status"]
  text: string
  original_bytes: number
  omitted_bytes: number
  truncated: boolean
  duration_ms: number
  reason?: string
  error?: string
}

type WaitAgent = { name: string; completion: WaitCompletion } | { name: string; status: SubagentSnapshot["lifecycle"] }

function projectWaitResult(snapshots: readonly SubagentSnapshot[]) {
  const agents: WaitAgent[] = snapshots.map(projectSnapshot)
  let omittedBytes = agents.reduce(
    (total, agent) => total + ("completion" in agent ? agent.completion.omitted_bytes : 0),
    0
  )
  const result = { agents, all_completed: agents.every(agent => "completion" in agent), omitted_bytes: omittedBytes }

  while (Buffer.byteLength(JSON.stringify(result)) > maxWaitResultBytes) {
    const evidence = largestWaitEvidence(agents)
    if (!evidence) throw new Error(`Subagent wait metadata exceeds ${maxWaitResultBytes} bytes`)
    const excess = Buffer.byteLength(JSON.stringify(result)) - maxWaitResultBytes
    const clipped = clipUtf8(evidence.completion[evidence.field] ?? "", Math.max(0, evidence.bytes - excess))
    evidence.completion[evidence.field] = clipped.text
    evidence.completion.omitted_bytes += clipped.omittedBytes
    evidence.completion.truncated = true
    omittedBytes += clipped.omittedBytes
    result.omitted_bytes = omittedBytes
  }

  return result
}

function largestWaitEvidence(
  agents: readonly WaitAgent[]
): { completion: WaitCompletion; field: "text" | "reason" | "error"; bytes: number } | undefined {
  let largest: { completion: WaitCompletion; field: "text" | "reason" | "error"; bytes: number } | undefined
  for (const agent of agents) {
    if (!("completion" in agent)) continue
    const completion = agent.completion
    for (const field of ["text", "reason", "error"] as const) {
      const value = completion[field]
      if (!value) continue
      const bytes = Buffer.byteLength(value)
      if (!largest || bytes > largest.bytes) largest = { completion, field, bytes }
    }
  }
  return largest
}

function projectSnapshot(snapshot: SubagentSnapshot): WaitAgent {
  const completion = snapshot.completion
  if (!completion || completion.workCycle !== snapshot.workCycle) {
    return { name: snapshot.name, status: snapshot.lifecycle }
  }
  return {
    name: snapshot.name,
    completion: {
      status: completion.status,
      text: completion.text,
      original_bytes: completion.originalBytes,
      omitted_bytes: completion.omittedBytes,
      truncated: completion.truncated,
      duration_ms: completion.durationMs,
      ...(completion.reason ? { reason: completion.reason } : {}),
      ...(completion.error ? { error: completion.error } : {})
    }
  }
}

function projectListSnapshot(snapshot: SubagentSnapshot) {
  return {
    name: snapshot.name,
    status: snapshot.lifecycle,
    ...(snapshot.completion && snapshot.completionDelivery === "durable"
      ? { result_ready: { status: snapshot.completion.status } }
      : {})
  }
}

function requireSnapshot(supervisor: SubagentSupervisor, name: string): SubagentSnapshot {
  const snapshot = supervisor.snapshots().find(value => value.name === name)
  if (!snapshot) throw new Error(`Subagent ${name} completed an operation without a retained snapshot`)
  return snapshot
}

function textResult(text: string, details: SubagentToolDetails) {
  return { content: [{ type: "text" as const, text }], details }
}
