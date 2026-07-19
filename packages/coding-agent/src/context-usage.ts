import {
  calculateContextTokens,
  estimateContextTokens,
  estimateTokens,
  type AgentMessage
} from "@earendil-works/pi-agent-core"

export interface ContextUsage {
  readonly tokens: number
  readonly contextWindow: number
  readonly percent: number
}

export function estimateContextUsage(messages: readonly AgentMessage[], contextWindow: number): ContextUsage {
  return contextUsage(estimateContextTokens([...messages]).tokens, contextWindow)
}

export function advanceContextUsage(usage: ContextUsage, message: AgentMessage, contextWindow: number): ContextUsage {
  const reported = reportedContextTokens(message)
  return contextUsage(reported ?? usage.tokens + estimateTokens(message), contextWindow)
}

function reportedContextTokens(message: AgentMessage): number | undefined {
  if (message.role !== "assistant" || message.stopReason === "aborted" || message.stopReason === "error") {
    return undefined
  }
  const tokens = calculateContextTokens(message.usage)
  return tokens > 0 ? tokens : undefined
}

function contextUsage(tokens: number, contextWindow: number): ContextUsage {
  return Object.freeze({ tokens, contextWindow, percent: (tokens / contextWindow) * 100 })
}
