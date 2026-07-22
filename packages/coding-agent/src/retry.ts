import type { AssistantMessage } from "@earendil-works/pi-ai"

export const maxRetryCount = 3
// Three retries at this base keep the complete 1x + 2x + 4x wait below two minutes.
export const maxRetryBaseDelayMs = 17_000
export const maxRetryDelayMs = maxRetryBaseDelayMs * 4
export const maxRetryErrorBytes = 2_000

export function isRetryCount(value: unknown): value is number {
  return typeof value === "number" && Number.isInteger(value) && value >= 0 && value <= maxRetryCount
}

export function isRetryDelay(value: unknown): value is number {
  return typeof value === "number" && Number.isInteger(value) && value >= 0 && value <= maxRetryBaseDelayMs
}

export function retryDelayMs(baseDelayMs: number, attempt: number): number {
  return Math.min(baseDelayMs * 2 ** (attempt - 1), maxRetryDelayMs)
}

export function waitForRetryDelay(delayMs: number, signal: AbortSignal): Promise<boolean> {
  if (signal.aborted) return Promise.resolve(false)
  let timeout!: ReturnType<typeof setTimeout>
  let onAbort!: () => void
  const elapsed = new Promise<boolean>(resolve => {
    timeout = setTimeout(() => resolve(true), delayMs)
  })
  const aborted = new Promise<boolean>(resolve => {
    onAbort = () => resolve(false)
    signal.addEventListener("abort", onAbort, { once: true })
  })
  return Promise.race([elapsed, aborted]).finally(() => {
    clearTimeout(timeout)
    signal.removeEventListener("abort", onAbort)
  })
}

export function boundedRetryError(message: string): string {
  const suffix = "…"
  const budget = maxRetryErrorBytes - Buffer.byteLength(suffix)
  let result = ""
  let bytes = 0
  for (const character of message) {
    const next = Buffer.byteLength(character)
    if (bytes + next > budget) return result + suffix
    result += character
    bytes += next
  }
  return result
}

export function retryAbortedMessage(message: AssistantMessage): AssistantMessage {
  const result = { ...message, stopReason: "aborted" as const }
  delete result.errorMessage
  return result
}
