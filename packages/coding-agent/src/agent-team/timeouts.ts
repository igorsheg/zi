export const defaultAgentWaitTimeoutMs = 30_000
export const maxAgentWaitTimeoutMs = 60 * 60_000
export const defaultAgentTurnTimeoutMs = 15 * 60_000
export const maxAgentTurnTimeoutMs = 60 * 60_000

export function isAgentWaitTimeout(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0 && value <= maxAgentWaitTimeoutMs
}

export function isAgentTurnTimeout(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value > 0 && value <= maxAgentTurnTimeoutMs
}
