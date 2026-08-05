export const defaultSubagentWorkTimeoutMs = 15 * 60_000
export const maxSubagentWorkTimeoutMs = 60 * 60_000

export function isSubagentWorkTimeout(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value > 0 && value <= maxSubagentWorkTimeoutMs
}
