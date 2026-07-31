import type { SubagentSnapshot, SubagentStatus } from "@with-zi/coding-agent"

export function subagentStatusTitles(
  status: SubagentStatus,
  snapshots: readonly SubagentSnapshot[]
): readonly string[] {
  if (
    status.workingAgentIds.length === 1 &&
    status.readyAgentIds.length === 1 &&
    status.workingAgentIds[0] === status.readyAgentIds[0]
  ) {
    return [`${agentLabel(status.workingAgentIds[0]!, snapshots)} working · result ready`]
  }
  return [
    ...statusTitle(status.workingAgentIds, snapshots, "working"),
    ...statusTitle(status.readyAgentIds, snapshots, "ready")
  ]
}

function statusTitle(
  agentIds: readonly string[],
  snapshots: readonly SubagentSnapshot[],
  state: "working" | "ready"
): readonly string[] {
  if (agentIds.length === 0) return []
  if (agentIds.length > 1) return [`${agentIds.length} ${state === "working" ? "agents working" : "results ready"}`]
  return [`${agentLabel(agentIds[0]!, snapshots)} ${state}`]
}

function agentLabel(agentId: string, snapshots: readonly SubagentSnapshot[]): string {
  const snapshot = snapshots.find(value => value.agentId === agentId)
  return definitionLabel(snapshot?.definition.name ?? "agent")
}

function definitionLabel(value: string): string {
  const words = value.replace(/[-_]+/g, " ").trim()
  if (!words) return "Agent"
  return `${words[0]!.toUpperCase()}${words.slice(1)}`
}
