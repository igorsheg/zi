import type { SubagentSnapshot, SubagentStatus } from "@with-zi/coding-agent"

export function subagentStatusTitles(
  status: SubagentStatus,
  snapshots: readonly SubagentSnapshot[]
): readonly string[] {
  if (status.workingNames.length === 1 && status.readyNames.includes(status.workingNames[0]!)) {
    const name = status.workingNames[0]!
    return [`${agentLabel(name, snapshots)} working · ${readyLabel(readyState(name, snapshots))}`]
  }
  return [...workingTitles(status.workingNames, snapshots), ...readyTitles(status.readyNames, snapshots)]
}

function workingTitles(names: readonly string[], snapshots: readonly SubagentSnapshot[]): readonly string[] {
  if (names.length === 0) return []
  if (names.length > 1) return [`${names.length} agents working`]
  return [`${agentLabel(names[0]!, snapshots)} working`]
}

function readyTitles(names: readonly string[], snapshots: readonly SubagentSnapshot[]): readonly string[] {
  if (names.length === 0) return []
  if (names.length === 1) {
    const name = names[0]!
    return [`${agentLabel(name, snapshots)} ${singularReadyLabel(readyState(name, snapshots))}`]
  }
  const counts: Record<ReadyState, number> = { completed: 0, failed: 0, cancelled: 0 }
  for (const name of names) counts[readyState(name, snapshots)]++
  return [
    ...(counts.completed > 0 ? [`${counts.completed} ${counts.completed === 1 ? "result" : "results"} ready`] : []),
    ...(counts.failed > 0 ? [`${counts.failed} ${counts.failed === 1 ? "agent" : "agents"} failed`] : []),
    ...(counts.cancelled > 0 ? [`${counts.cancelled} ${counts.cancelled === 1 ? "agent" : "agents"} cancelled`] : [])
  ]
}

type ReadyState = "completed" | "failed" | "cancelled"

function readyState(name: string, snapshots: readonly SubagentSnapshot[]): ReadyState {
  const status = snapshots.find(snapshot => snapshot.name === name)?.completion?.status
  return status === "failed" || status === "cancelled" ? status : "completed"
}

function singularReadyLabel(state: ReadyState): string {
  if (state === "failed") return "failed"
  if (state === "cancelled") return "cancelled"
  return "ready"
}

function readyLabel(state: ReadyState): string {
  return state === "completed" ? "result ready" : state
}

function agentLabel(name: string, snapshots: readonly SubagentSnapshot[]): string {
  const snapshot = snapshots.find(value => value.name === name)
  return titleCase(snapshot?.name ?? name)
}

function titleCase(value: string): string {
  const label = value.replace(/[-_]+/g, " ")
  return label[0]?.toUpperCase() + label.slice(1)
}
