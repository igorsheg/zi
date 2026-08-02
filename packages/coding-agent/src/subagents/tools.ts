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
    description: "Context or information for the current or next task; not a new task. Never starts an idle turn."
  })
})
const followupParameters = Type.Object({
  name: subagentName,
  text: Type.String({
    minLength: 1,
    maxLength: maxSubagentPromptBytes,
    description: "Task to perform. Starts an idle subagent turn or extends its current work cycle."
  })
})
const nameParameters = Type.Object({ name: subagentName })
const waitParameters = Type.Object({
  names: Type.Optional(
    Type.Array(subagentName, {
      minItems: 1,
      maxItems: maxWaitNames,
      uniqueItems: true,
      description: `Runtime names to wait for. Omit to capture the bounded eligible set of up to ${maxWaitNames} subagents once when the call begins.`
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
    description: `Start one background Zi subagent from an admitted profile under a new parent-session-unique runtime name. Returns after admission, not completion; use wait_subagents to collect output. A parent may have at most ${maxLiveChildren} live subagents.`,
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
    name: "send_subagent",
    label: "send_subagent",
    description:
      "Queue context or information for an existing subagent. This never starts an idle turn; use continue_subagent to assign work or wake an idle subagent.",
    parameters: messageParameters,
    executionMode: "parallel",
    async execute(_id, input) {
      await supervisor.send(input.name, input.text)
      return textResult(`Queued message for ${input.name}.`, {
        type: "subagent",
        outcome: "success",
        operation: "send",
        agent: projectSubagentToolAgent(requireSnapshot(supervisor, input.name))
      })
    }
  }
  const continueTool: AgentTool<typeof followupParameters, SubagentToolDetails> = {
    name: "continue_subagent",
    label: "continue_subagent",
    description:
      "Assign follow-up work to an existing subagent. Starts a new turn when idle; while running, adds the task to the current work cycle.",
    parameters: followupParameters,
    executionMode: "parallel",
    async execute(_id, input) {
      const delivery = await supervisor.continue(input.name, input.text)
      return textResult(
        delivery === "started_turn"
          ? `Started follow-up for ${input.name}.`
          : `Delivered follow-up to ${input.name}'s current turn.`,
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
    description: `Wait for current work of named subagents. With names omitted, capture up to ${maxWaitNames} subagents that are working or have an uncollected result when the call begins; later changes do not join the wait. An empty capture returns immediately. Timeout never cancels work, and all_completed describes only the captured set.`,
    parameters: waitParameters,
    executionMode: "parallel",
    async execute(_id, input, signal) {
      const names = input.names ?? collectableNames(supervisor.status())
      const snapshots =
        names.length === 0 ? [] : await supervisor.wait(names, input.timeout_ms ?? supervisor.waitTimeoutMs, signal)
      return textResult(JSON.stringify(projectWaitResult(snapshots)), {
        type: "subagent",
        outcome: "success",
        operation: "wait",
        agents: projectSubagentToolAgents(snapshots)
      })
    }
  }
  const interrupt: AgentTool<typeof nameParameters, SubagentToolDetails> = {
    name: "interrupt_subagent",
    label: "interrupt_subagent",
    description: "Interrupt current subagent work while keeping its process reusable.",
    parameters: nameParameters,
    executionMode: "parallel",
    async execute(_id, input) {
      const outcome = await supervisor.interrupt(input.name)
      return textResult(JSON.stringify({ name: input.name, outcome }), {
        type: "subagent",
        outcome: "success",
        operation: "interrupt",
        agent: projectSubagentToolAgent(requireSnapshot(supervisor, input.name)),
        result: outcome
      })
    }
  }
  const close: AgentTool<typeof nameParameters, SubagentToolDetails> = {
    name: "close_subagent",
    label: "close_subagent",
    description: `Close a subagent process if it is still live. Idle subagents still occupy one of ${maxLiveChildren} live-child slots; closing one releases its slot. The runtime name remains reserved.`,
    parameters: nameParameters,
    executionMode: "parallel",
    async execute(_id, input) {
      const previous = requireSnapshot(supervisor, input.name)
      const snapshot = await supervisor.close(input.name)
      return textResult(JSON.stringify(projectListSnapshot(snapshot)), {
        type: "subagent",
        outcome: "success",
        operation: "close",
        agent: projectSubagentToolAgent(snapshot),
        previousStatus: previous.lifecycle,
        ...(previous.completion ? { previousCompletionStatus: previous.completion.status } : {})
      })
    }
  }
  const list: AgentTool<typeof emptyParameters, SubagentToolDetails> = {
    name: "list_subagents",
    label: "list_subagents",
    description:
      "List direct-subagent status and uncollected result readiness without returning conversations. For an idle child, assign work with continue_subagent or release its slot with close_subagent; collect a ready result with wait_subagents.",
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

function projectWaitResult(snapshots: readonly SubagentSnapshot[]) {
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

  while (Buffer.byteLength(JSON.stringify(projected)) > maxSubagentToolResultBytes) {
    const evidence = largestWaitEvidence(subagents)
    if (!evidence) throw new Error(`Subagent wait metadata exceeds ${maxSubagentToolResultBytes} bytes`)
    const excess = Buffer.byteLength(JSON.stringify(projected)) - maxSubagentToolResultBytes
    const clipped = clipUtf8(evidence.completion[evidence.field] ?? "", Math.max(0, evidence.bytes - excess))
    evidence.completion[evidence.field] = clipped.text
    evidence.completion.omitted_bytes += clipped.omittedBytes
    evidence.completion.truncated = true
    omittedBytes += clipped.omittedBytes
    projected.omitted_bytes = omittedBytes
  }

  return projected
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
