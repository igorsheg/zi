export const minAgentWaitTimeoutMs = 10_000
export const maxAgentWaitTimeoutMs = 60 * 60 * 1_000

export type AgentWaitActivity = "mailbox" | "steered" | "timed_out"

export function resolveAgentWaitTimeout(requestedMs: number | undefined, configuredDefaultMs: number): number {
  return Math.max(requestedMs ?? configuredDefaultMs, minAgentWaitTimeoutMs)
}

export function agentWaitMessage(
  activity: AgentWaitActivity,
  requestedTimeoutMs: number | undefined,
  timeoutMs: number
): string {
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
