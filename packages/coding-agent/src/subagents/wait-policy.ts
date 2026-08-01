export const defaultWaitTimeoutMs = 30_000
export const maxWaitTimeoutMs = 60 * 60 * 1_000

export function isSubagentWaitTimeout(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0 && value <= maxWaitTimeoutMs
}
