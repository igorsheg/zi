import type { ForkTurns } from "./agent-team/journal.js"
import { agentTaskCustomType } from "./agent-team/mail.js"
import { parentAgentPath, rootAgentPath, type AgentPath } from "./agent-team/path.js"
import type { AgentMessage } from "./messages.js"
import type { ZiPaths } from "./paths.js"
import {
  SessionManager,
  sessionEntryToContextMessage,
  type AgentSessionLineage,
  type SessionContext,
  type SessionForkCheckpoint
} from "./session-manager.js"

export type { ForkTurns } from "./agent-team/journal.js"
export { agentTaskCustomType } from "./agent-team/mail.js"

export interface SessionForkRequest {
  readonly path: AgentPath
  readonly rootSessionId: string
  readonly sessionId: string
  readonly forkTurns: ForkTurns
  readonly checkpoint?: SessionForkCheckpoint
}

export function projectSessionFork(checkpoint: SessionForkCheckpoint, forkTurns: ForkTurns): SessionContext {
  validateForkTurns(forkTurns)
  const inherited = trimIncompleteToolTail(
    checkpoint.entries.flatMap(entry => {
      const message = sessionEntryToContextMessage(entry)
      const selected = message ? inheritedMessage(message) : undefined
      return selected ? [selected] : []
    })
  )
  const messages = forkTurns === "none" ? [] : forkTurns === "all" ? inherited : recentTurns(inherited, forkTurns)
  return Object.freeze({
    messages: Object.freeze([...messages]),
    ...(checkpoint.model ? { model: Object.freeze({ ...checkpoint.model }) } : {}),
    ...(checkpoint.thinkingLevel ? { thinkingLevel: checkpoint.thinkingLevel } : {})
  })
}

export async function createSessionFork(
  parent: SessionManager,
  paths: ZiPaths,
  request: SessionForkRequest
): Promise<SessionManager> {
  const checkpoint = request.checkpoint ?? parent.captureForkCheckpoint()
  const parentPath = checkpoint.lineage?.path ?? rootAgentPath
  const rootSessionId = checkpoint.lineage?.rootSessionId ?? checkpoint.sessionId
  if (request.rootSessionId !== rootSessionId) throw new Error("Session fork root does not match its parent")
  if (parentAgentPath(request.path) !== parentPath) throw new Error("Session fork path is not a child of its parent")

  const lineage: AgentSessionLineage = {
    rootSessionId,
    parentSessionId: checkpoint.sessionId,
    parentEntryId: checkpoint.leafId,
    path: request.path,
    generation: (checkpoint.lineage?.generation ?? 0) + 1
  }
  return SessionManager.createAgentFork(
    paths,
    request.sessionId,
    lineage,
    projectSessionFork(checkpoint, request.forkTurns),
    parent.file !== undefined
  )
}

function recentTurns(messages: readonly AgentMessage[], count: number): readonly AgentMessage[] {
  const starts: number[] = []
  for (let index = 0; index < messages.length; index++) if (startsTurn(messages[index]!)) starts.push(index)
  const completed: Array<{ readonly start: number; readonly end: number }> = []
  for (let index = 0; index < starts.length; index++) {
    const start = starts[index]!
    const end = starts[index + 1] ?? messages.length
    if (messages.slice(start, end).some(isFinalAssistant)) completed.push({ start, end })
  }
  const selected = completed.slice(-count)
  if (selected.length === 0) return []
  const start = count > completed.length ? 0 : selected[0]!.start
  return messages.slice(start, selected.at(-1)!.end)
}

function trimIncompleteToolTail(messages: readonly AgentMessage[]): readonly AgentMessage[] {
  const pending = new Map<string, number>()
  let incompleteToolUse: number | undefined
  for (let index = 0; index < messages.length; index++) {
    const message = messages[index]!
    if (message.role === "assistant") {
      let calls = 0
      for (const part of message.content) {
        if (part.type !== "toolCall") continue
        pending.set(part.id, index)
        calls++
      }
      if (message.stopReason === "toolUse" && calls === 0) incompleteToolUse = index
    } else if (message.role === "toolResult") {
      pending.delete(message.toolCallId)
    }
  }
  const unmatched = [...pending.values(), ...(incompleteToolUse === undefined ? [] : [incompleteToolUse])]
  return unmatched.length === 0 ? messages : messages.slice(0, Math.min(...unmatched))
}

function isFinalAssistant(message: AgentMessage): boolean {
  return message.role === "assistant" && (message.stopReason === "stop" || message.stopReason === "length")
}

function startsTurn(message: AgentMessage): boolean {
  return message.role === "user" || (message.role === "custom" && message.customType === agentTaskCustomType)
}

function inheritedMessage(message: AgentMessage): AgentMessage | undefined {
  switch (message.role) {
    case "user":
    case "assistant":
    case "toolResult":
    case "branchSummary":
    case "compactionSummary":
      return message
    case "custom":
      return message.customType === agentTaskCustomType
        ? Object.freeze({
            role: message.role,
            customType: message.customType,
            content: message.content,
            display: message.display,
            timestamp: message.timestamp
          })
        : undefined
    case "bashExecution":
      return undefined
    default:
      return assertNever(message)
  }
}

function validateForkTurns(value: ForkTurns): void {
  if (value === "all" || value === "none") return
  if (!Number.isSafeInteger(value) || value < 1) throw new Error("fork_turns must be all, none, or a positive integer")
}

function assertNever(value: never): never {
  throw new Error(`Unexpected session fork message: ${String(value)}`)
}
