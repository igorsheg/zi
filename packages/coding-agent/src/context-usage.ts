import { estimateContextTokens, estimateMessageTokens } from "./compaction.js"
import type { AgentMessage } from "./messages.js"

export type ContextUsage =
  | { readonly type: "unavailable"; readonly reason: "no_model" | "unknown_window" }
  | {
      readonly type: "measured" | "estimated"
      readonly tokens: number
      readonly contextWindow: number
      readonly percent: number
    }

export type AvailableContextUsage = Exclude<ContextUsage, { type: "unavailable" }>

export function estimateContextUsage(
  messages: readonly AgentMessage[],
  contextWindow: number,
  minimumAnchorIndex = 0
): AvailableContextUsage {
  const estimate = estimateContextTokens(messages, minimumAnchorIndex)
  return contextUsage(
    estimate.tokens,
    contextWindow,
    estimate.lastUsageIndex === null || estimate.trailingTokens > 0 ? "estimated" : "measured"
  )
}

export function advanceContextUsage(
  usage: AvailableContextUsage,
  message: AgentMessage,
  contextWindow: number
): AvailableContextUsage {
  const reported = reportedContextTokens(message)
  return reported === undefined
    ? contextUsage(usage.tokens + estimateMessageTokens(message), contextWindow, "estimated")
    : contextUsage(reported, contextWindow, "measured")
}

function reportedContextTokens(message: AgentMessage): number | undefined {
  if (message.role !== "assistant" || message.stopReason === "aborted" || message.stopReason === "error") {
    return undefined
  }
  const tokens =
    message.usage.totalTokens ||
    message.usage.input + message.usage.output + message.usage.cacheRead + message.usage.cacheWrite
  return Number.isFinite(tokens) && tokens > 0 ? tokens : undefined
}

function contextUsage(
  tokens: number,
  contextWindow: number,
  type: AvailableContextUsage["type"]
): AvailableContextUsage {
  return Object.freeze({
    type,
    tokens,
    contextWindow,
    percent: Math.max(0, Math.min(100, (tokens / contextWindow) * 100))
  })
}
