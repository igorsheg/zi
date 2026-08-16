export const minAgentWaitTimeoutMs = 10_000
export const maxAgentWaitTimeoutMs = 60 * 60 * 1_000

export type AgentWaitActivity = "mailbox" | "steered" | "timed_out"

export function resolveAgentWaitTimeout(requestedMs: number | undefined, configuredDefaultMs: number): number {
  return Math.max(requestedMs ?? configuredDefaultMs, minAgentWaitTimeoutMs)
}
