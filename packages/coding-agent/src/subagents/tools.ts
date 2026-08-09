import type { AgentTool } from "@earendil-works/pi-agent-core"
import { Type } from "@earendil-works/pi-ai"
import type { ExtensionSubagentProfile } from "@with-zi/extension-api"

import type { SubagentCompletion } from "./child-process.js"
import { clipUtf8 } from "./child-process.js"
import type { SubagentSupervisor, SubagentSnapshot } from "./supervisor.js"
import {
  maxLiveChildren,
  maxSubagentNameBytes,
  maxSubagentPromptBytes,
  maxWaitNames,
  maxWaitTimeoutMs
} from "./supervisor.js"
import {
  maxProjectedSubagentProfileDetailsBytes,
  projectSubagentToolAgent,
  projectSubagentToolAgents,
  type SubagentToolDetails
} from "./tool-details.js"

const subagentName = Type.String({
  minLength: 1,
  maxLength: maxSubagentNameBytes,
  pattern: "^[a-z][a-z0-9_-]*$",
  description:
    "Runtime routing name assigned by spawn_subagent; separate from the profile name. Reuse it for later operations. Use lowercase letters, numbers, _ or -."
})
const messageParameters = Type.Object({
  name: subagentName,
  text: Type.String({
    minLength: 1,
    maxLength: maxSubagentPromptBytes,
    description: "Context for the target's current or next task. Never starts an idle turn."
  })
})
const followupParameters = Type.Object({
  name: subagentName,
  text: Type.String({
    minLength: 1,
    maxLength: maxSubagentPromptBytes,
    description:
      "Task to perform. Starts a new work cycle when idle; while running, joins the current cycle rather than scheduling another."
  })
})
const nameParameters = Type.Object({ name: subagentName })
const waitParameters = Type.Object({
  names: Type.Optional(
    Type.Array(subagentName, {
      minItems: 1,
      maxItems: maxWaitNames,
      uniqueItems: true,
      description: `Runtime names whose captured work cycles may wake this receive. Omit to capture up to ${maxWaitNames} working or ready subagents once when the call begins.`
    })
  ),
  timeout_ms: Type.Optional(
    Type.Number({
      minimum: 0,
      maximum: maxWaitTimeoutMs,
      description: "Optional bounded wait in milliseconds. Omit to use the configured default; maximum is one hour."
    })
  )
})
const emptyParameters = Type.Object({})

export const maxSubagentToolResultBytes = 64 * 1024
const maxSpawnProfileCatalogDescriptionBytes = 8 * 1024
const maxSpawnProfilePurposeBytes = 256

type SpawnProfile = (profile: string, name: string, prompt: string, signal?: AbortSignal) => Promise<string>

export function createSubagentTools(
  profiles: readonly ExtensionSubagentProfile[],
  supervisor: SubagentSupervisor,
  spawnProfile: SpawnProfile
): readonly AgentTool[] {
  if (profiles.length === 0) return Object.freeze([])

  const profileNames = profiles.map(profile => profile.name)
  const spawnParameters = Type.Object({
    profile: Type.String({ enum: profileNames, description: spawnProfileDescription(profiles) }),
    name: subagentName,
    prompt: Type.String({
      minLength: 1,
      maxLength: maxSubagentPromptBytes,
      description: "Initial task for the subagent"
    })
  })
  const listProfiles: AgentTool<typeof emptyParameters, SubagentToolDetails> = {
    name: "list_subagent_profiles",
    label: "list_subagent_profiles",
    description:
      "Inspect the full admitted subagent profile catalog when the bounded spawn_subagent summaries are insufficient.",
    parameters: emptyParameters,
    executionMode: "parallel",
    execute() {
      const catalog = projectProfileCatalog(profiles)
      return Promise.resolve(
        textResult(JSON.stringify(catalog), {
          type: "subagent",
          outcome: "success",
          operation: "profiles",
          profiles: catalog.profiles,
          omittedBytes: catalog.omitted_bytes
        })
      )
    }
  }
  const spawn: AgentTool<typeof spawnParameters, SubagentToolDetails> = {
    name: "spawn_subagent",
    label: "spawn_subagent",
    description: `Start one background Zi subagent from an admitted profile under a new parent-session-unique runtime name. Returns after admission. Completion is delivered to parent context before its next model request; use wait_subagents only when synchronization is needed. A parent may have at most ${maxLiveChildren} live subagents.`,
    parameters: spawnParameters,
    executionMode: "parallel",
    async execute(_id, input, signal) {
      const name = await spawnProfile(input.profile, input.name, input.prompt, signal)
      return textResult(JSON.stringify({ name, profile: input.profile }), {
        type: "subagent",
        outcome: "success",
        operation: "spawn",
        profile: input.profile,
        agent: projectSubagentToolAgent(requireSnapshot(supervisor, name))
      })
    }
  }
  const send: AgentTool<typeof messageParameters, SubagentToolDetails> = {
    name: "send_subagent_message",
    label: "send_subagent_message",
    description:
      "Send context to an existing subagent without assigning a new task. The message is delivered promptly while work is active and never starts an idle turn; use assign_subagent_task to start work.",
    parameters: messageParameters,
    executionMode: "parallel",
    async execute(_id, input) {
      await supervisor.send(input.name, input.text)
      return textResult(`Sent context to ${input.name}.`, {
        type: "subagent",
        outcome: "success",
        operation: "send",
        agent: projectSubagentToolAgent(requireSnapshot(supervisor, input.name))
      })
    }
  }
  const continueTool: AgentTool<typeof followupParameters, SubagentToolDetails> = {
    name: "assign_subagent_task",
    label: "assign_subagent_task",
    description:
      "Assign a task to an existing subagent. Starts a new work cycle when idle; while running, delivers the task to the current cycle. Wait until idle first when the task must be a separate cycle.",
    parameters: followupParameters,
    executionMode: "parallel",
    async execute(_id, input) {
      const delivery = await supervisor.continue(input.name, input.text)
      return textResult(
        delivery === "started_turn"
          ? `Started a new task cycle for ${input.name}.`
          : `Assigned the task to ${input.name}'s current cycle.`,
        {
          type: "subagent",
          outcome: "success",
          operation: "continue",
          agent: projectSubagentToolAgent(requireSnapshot(supervisor, input.name))
        }
      )
    }
  }
  const wait: AgentTool<typeof waitParameters, SubagentToolDetails> = {
    name: "wait_subagents",
    label: "wait_subagents",
    description: `Receive the next completion from captured subagents when synchronization is needed. Returns after any captured work cycle completes and coalesces other completions ready at that instant; remaining children keep running. For each name, an older pending completion is returned before current work. With names omitted, capture up to ${maxWaitNames} working or ready subagents once. Completion delivery to parent context does not depend on this tool.`,
    parameters: waitParameters,
    executionMode: "parallel",
    async execute(id, input, signal) {
      const names = input.names ?? collectableNames(supervisor.status())
      const snapshots =
        names.length === 0
          ? []
          : await supervisor.waitForTool(names, input.timeout_ms ?? supervisor.waitTimeoutMs, signal, id)
      const status = supervisor.status()
      const pending = new Set([...status.workingNames, ...status.readyNames])
      const pendingNames = names.filter(name => pending.has(name))
      const timedOut = names.length > 0 && snapshots.length === 0
      return textResult(JSON.stringify(projectReceiveResult(snapshots, pendingNames, timedOut)), {
        type: "subagent",
        outcome: "success",
        operation: "wait",
        agents: projectSubagentToolAgents(snapshots),
        pendingNames,
        timedOut
      })
    }
  }
  const interrupt: AgentTool<typeof nameParameters, SubagentToolDetails> = {
    name: "interrupt_subagent",
    label: "interrupt_subagent",
    description:
      "Interrupt current subagent work, wait for bounded terminal evidence from that exact work cycle, and keep the process reusable.",
    parameters: nameParameters,
    executionMode: "parallel",
    async execute(id, input, signal) {
      const settlement = await supervisor.interruptAndWaitForTool(input.name, signal, id)
      return textResult(
        JSON.stringify({
          result: settlement.result,
          ...projectWaitResult([settlement.snapshot], maxSubagentToolResultBytes - 64)
        }),
        {
          type: "subagent",
          outcome: "success",
          operation: "interrupt",
          agent: projectSubagentToolAgent(settlement.snapshot),
          result: settlement.result
        }
      )
    }
  }
  const close: AgentTool<typeof nameParameters, SubagentToolDetails> = {
    name: "close_subagent",
    label: "close_subagent",
    description: `Close a subagent process, return its bounded terminal evidence, and release its live-child slot. Idle subagents still occupy one of ${maxLiveChildren} slots. The runtime name remains reserved.`,
    parameters: nameParameters,
    executionMode: "parallel",
    async execute(id, input) {
      const previous = requireSnapshot(supervisor, input.name)
      const snapshot = await supervisor.closeAndDeliverForTool(input.name, id)
      return textResult(
        JSON.stringify({
          previous_status: previous.lifecycle,
          ...projectWaitResult([snapshot], maxSubagentToolResultBytes - 64)
        }),
        {
          type: "subagent",
          outcome: "success",
          operation: "close",
          agent: projectSubagentToolAgent(snapshot),
          previousStatus: previous.lifecycle,
          ...(previous.completion ? { previousCompletionStatus: previous.completion.status } : {})
        }
      )
    }
  }
  const list: AgentTool<typeof emptyParameters, SubagentToolDetails> = {
    name: "list_subagents",
    label: "list_subagents",
    description:
      "List direct-subagent task, lifecycle, work cycle, elapsed time, and pending parent-context delivery without returning conversations. For an idle child, assign work with assign_subagent_task or release its slot with close_subagent.",
    parameters: emptyParameters,
    executionMode: "parallel",
    execute() {
      const snapshots = supervisor.snapshots()
      const status = supervisor.status()
      return Promise.resolve(
        textResult(JSON.stringify({ subagents: snapshots.map(projectListSnapshot) }), {
          type: "subagent",
          outcome: "success",
          operation: "list",
          agents: projectSubagentToolAgents(snapshots),
          workingNames: status.workingNames,
          readyNames: status.readyNames
        })
      )
    }
  }
  return Object.freeze([listProfiles, spawn, send, continueTool, wait, interrupt, close, list])
}

type WaitCompletion = {
  work_cycle: number
  status: SubagentCompletion["status"]
  text: string
  original_bytes: number
  omitted_bytes: number
  truncated: boolean
  duration_ms: number
  reason?: string
  error?: string
}

type WaitSubagent =
  | { name: string; completion: WaitCompletion }
  | { name: string; status: SubagentSnapshot["lifecycle"] }

function projectWaitResult(snapshots: readonly SubagentSnapshot[], maximumBytes = maxSubagentToolResultBytes) {
  const subagents: WaitSubagent[] = snapshots.map(projectSnapshot)
  let omittedBytes = subagents.reduce(
    (total, subagent) => total + ("completion" in subagent ? subagent.completion.omitted_bytes : 0),
    0
  )
  const projected = {
    subagents,
    all_completed: subagents.every(subagent => "completion" in subagent),
    omitted_bytes: omittedBytes
  }

  clipWaitEvidence(projected, subagents, maximumBytes, nextOmittedBytes => {
    projected.omitted_bytes = nextOmittedBytes
  })
  return projected
}

function projectReceiveResult(
  snapshots: readonly SubagentSnapshot[],
  pendingNames: readonly string[],
  timedOut: boolean,
  maximumBytes = maxSubagentToolResultBytes
) {
  const subagents: WaitSubagent[] = snapshots.map(projectSnapshot)
  let omittedBytes = subagents.reduce(
    (total, subagent) => total + ("completion" in subagent ? subagent.completion.omitted_bytes : 0),
    0
  )
  const projected = { subagents, pending_names: [...pendingNames], timed_out: timedOut, omitted_bytes: omittedBytes }

  clipWaitEvidence(projected, subagents, maximumBytes, next => {
    omittedBytes = next
    projected.omitted_bytes = omittedBytes
  })
  return projected
}

function clipWaitEvidence(
  projected: object,
  subagents: readonly WaitSubagent[],
  maximumBytes: number,
  setOmittedBytes: (value: number) => void
): void {
  let omittedBytes = subagents.reduce(
    (total, subagent) => total + ("completion" in subagent ? subagent.completion.omitted_bytes : 0),
    0
  )
  while (Buffer.byteLength(JSON.stringify(projected)) > maximumBytes) {
    const evidence = largestWaitEvidence(subagents)
    if (!evidence) throw new Error(`Subagent wait metadata exceeds ${maximumBytes} bytes`)
    const excess = Buffer.byteLength(JSON.stringify(projected)) - maximumBytes
    const clipped = clipUtf8(evidence.completion[evidence.field] ?? "", Math.max(0, evidence.bytes - excess))
    evidence.completion[evidence.field] = clipped.text
    evidence.completion.omitted_bytes += clipped.omittedBytes
    evidence.completion.truncated = true
    omittedBytes += clipped.omittedBytes
    setOmittedBytes(omittedBytes)
  }
}

function projectProfileCatalog(profiles: readonly ExtensionSubagentProfile[]) {
  const projected = profiles.map(profile => ({ name: profile.name, description: profile.description }))
  let omittedBytes = 0
  const catalog = { profiles: projected, omitted_bytes: omittedBytes }
  while (Buffer.byteLength(JSON.stringify(catalog)) > maxProjectedSubagentProfileDetailsBytes) {
    const largest = projected.reduce<{ profile: (typeof projected)[number]; bytes: number } | undefined>(
      (current, profile) => {
        const bytes = Buffer.byteLength(profile.description)
        return !current || bytes > current.bytes ? { profile, bytes } : current
      },
      undefined
    )
    if (!largest || largest.bytes === 0)
      throw new Error(`Subagent profile metadata exceeds ${maxSubagentToolResultBytes} bytes`)
    const excess = Buffer.byteLength(JSON.stringify(catalog)) - maxProjectedSubagentProfileDetailsBytes
    const clipped = clipUtf8(largest.profile.description, Math.max(0, largest.bytes - excess))
    largest.profile.description = clipped.text
    omittedBytes += clipped.omittedBytes
    catalog.omitted_bytes = omittedBytes
  }
  return catalog
}

function largestWaitEvidence(
  subagents: readonly WaitSubagent[]
): { completion: WaitCompletion; field: "text" | "reason" | "error"; bytes: number } | undefined {
  let largest: { completion: WaitCompletion; field: "text" | "reason" | "error"; bytes: number } | undefined
  for (const subagent of subagents) {
    if (!("completion" in subagent)) continue
    for (const field of ["text", "reason", "error"] as const) {
      const value = subagent.completion[field]
      if (!value) continue
      const bytes = Buffer.byteLength(value)
      if (!largest || bytes > largest.bytes) largest = { completion: subagent.completion, field, bytes }
    }
  }
  return largest
}

function projectSnapshot(snapshot: SubagentSnapshot): WaitSubagent {
  const completion = snapshot.completion
  if (!completion) return { name: snapshot.name, status: snapshot.lifecycle }
  return {
    name: snapshot.name,
    completion: {
      work_cycle: completion.workCycle,
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
    ...(snapshot.workCycle !== undefined ? { work_cycle: snapshot.workCycle } : {}),
    ...(snapshot.task ? { task: snapshot.task } : {}),
    ...(snapshot.elapsedMs !== undefined ? { elapsed_ms: snapshot.elapsedMs } : {}),
    ...(snapshot.completion && snapshot.completionDelivery === "durable"
      ? { result_ready: { work_cycle: snapshot.completion.workCycle, status: snapshot.completion.status } }
      : {})
  }
}

function spawnProfileDescription(profiles: readonly ExtensionSubagentProfile[]): string {
  const heading = "Admitted profile (reusable configuration, not a runtime name). Choose by purpose:\n"
  const structuralBytes =
    Buffer.byteLength(heading) +
    profiles.reduce((total, profile) => total + Buffer.byteLength(profile.name) + Buffer.byteLength(": \n"), 0)
  const purposeBytes = Math.min(
    maxSpawnProfilePurposeBytes,
    Math.max(0, Math.floor((maxSpawnProfileCatalogDescriptionBytes - structuralBytes) / profiles.length))
  )
  const lines = profiles.map(profile => {
    if (purposeBytes === 0) return profile.name
    const purpose = profile.description.replace(/\s+/g, " ").trim()
    const clipped = clipUtf8(purpose, purposeBytes)
    if (clipped.omittedBytes === 0) return `${profile.name}: ${clipped.text}`
    if (purposeBytes < 3) return `${profile.name}: ${clipped.text}`
    return `${profile.name}: ${clipUtf8(purpose, purposeBytes - 3).text}…`
  })
  return `${heading}${lines.join("\n")}`
}

function collectableNames(status: ReturnType<SubagentSupervisor["status"]>): readonly string[] {
  return Object.freeze([...new Set([...status.workingNames, ...status.readyNames])].slice(0, maxWaitNames))
}

function requireSnapshot(supervisor: SubagentSupervisor, name: string): SubagentSnapshot {
  const snapshot = supervisor.snapshots().find(candidate => candidate.name === name)
  if (!snapshot) throw new Error(`Unknown subagent: ${name}`)
  return snapshot
}

function textResult(text: string, details: SubagentToolDetails) {
  return { content: [{ type: "text" as const, text }], details }
}
