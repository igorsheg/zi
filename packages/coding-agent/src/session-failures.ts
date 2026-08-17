import { isCodeModeDetails } from "./code-mode/trace.js"
import type { AgentMessage } from "./messages.js"
import type { AgentTeamEntry, BackgroundTaskResultEntry, SessionEntry } from "./session-manager.js"
import { isBashToolDetails, type BashToolDetails } from "./tools/bash.js"
import { isEditToolDetails } from "./tools/edit.js"
import { isReadToolDetails } from "./tools/read.js"
import { isKillTaskToolDetails, isTaskOutputToolDetails } from "./tools/shell-tasks.js"
import { isWriteToolDetails } from "./tools/write.js"

export const maxSessionFailures = 1_024
export const maxSessionFailureMessageBytes = 8 * 1024

export interface ToolSessionFailure {
  readonly kind: "tool"
  readonly id: string
  readonly name: string
  readonly status: "failed"
  readonly code?: string
  readonly message?: string
  readonly timestamp: string
  readonly sourceEntryId: string
}

export interface CodeCallSessionFailure {
  readonly kind: "code_call"
  readonly id: string
  readonly parentId: string
  readonly name: string
  readonly status: "failed"
  readonly code?: string
  readonly message?: string
  readonly timestamp: string
  readonly durationMs: number
  readonly sourceEntryId: string
}

export interface BackgroundTaskSessionFailure {
  readonly kind: "background_task"
  readonly id: string
  readonly parentId?: string
  readonly name: "bash"
  readonly status: "failed"
  readonly code: string
  readonly message: string
  readonly timestamp: string
  readonly durationMs: number
  readonly sourceEntryId: string
}

export interface AgentTurnSessionFailure {
  readonly kind: "agent_turn"
  readonly id: string
  readonly name: string
  readonly status: "failed"
  readonly code: string
  readonly message?: string
  readonly timestamp: string
  readonly durationMs: number
  readonly sourceEntryId: string
}

export interface ProviderSessionFailure {
  readonly kind: "provider"
  readonly id: string
  readonly name: string
  readonly status: "failed"
  readonly code: "provider_error"
  readonly message?: string
  readonly retryAttempt?: number
  readonly timestamp: string
  readonly sourceEntryId: string
}

export type SessionFailure =
  | ToolSessionFailure
  | CodeCallSessionFailure
  | BackgroundTaskSessionFailure
  | AgentTurnSessionFailure
  | ProviderSessionFailure

export interface SessionFailureProjection {
  readonly failures: readonly SessionFailure[]
  readonly omitted: number
}

export function projectSessionFailures(entries: readonly SessionEntry[]): SessionFailureProjection {
  const failures: SessionFailure[] = []
  const retryAttempts = new Map(
    entries.flatMap(entry => (entry.type === "retry" ? [[entry.failedEntryId, entry.attempt] as const] : []))
  )
  const backgroundParents = new Map<string, string>()
  let omitted = 0

  const add = (failure: SessionFailure): void => {
    if (failures.length < maxSessionFailures) failures.push(Object.freeze(failure))
    else omitted++
  }

  for (const entry of entries) {
    if (entry.type === "agent_turn_settled") {
      if (entry.result.status === "failed") add(agentTurnFailure(entry))
      continue
    }
    if (entry.type === "background_task_result") {
      if (entry.result === "failed") add(backgroundTaskFailure(entry, backgroundParents.get(entry.taskId)))
      continue
    }
    if (entry.type !== "message") continue
    if (entry.message.role === "assistant" && entry.message.stopReason === "error") {
      add(providerFailure(entry.message, entry.id, entry.timestamp, retryAttempts.get(entry.id)))
      continue
    }
    if (entry.message.role !== "toolResult") continue
    const message = entry.message
    if (message.toolName === "bash" && isBashToolDetails(message.details) && message.details.state === "background") {
      backgroundParents.set(message.details.taskId, `tool/${message.toolCallId}`)
    }
    if (message.isError) add(toolFailure(message, entry.id, entry.timestamp))
    if (message.toolName !== "code" || !isCodeModeDetails(message.details)) continue
    for (const call of message.details.calls) {
      if (call.state !== "failed") continue
      add({
        kind: "code_call",
        id: `tool/${message.toolCallId}/code/${call.id}`,
        parentId: `tool/${message.toolCallId}`,
        name: call.name,
        status: "failed",
        ...(call.stage === undefined ? {} : { code: call.stage }),
        ...(call.error === undefined ? {} : { message: boundMessage(call.error) }),
        timestamp: entry.timestamp,
        durationMs: call.durationMs,
        sourceEntryId: entry.id
      })
    }
  }

  return Object.freeze({ failures: Object.freeze(failures), omitted })
}

function providerFailure(
  message: Extract<AgentMessage, { readonly role: "assistant" }>,
  sourceEntryId: string,
  timestamp: string,
  retryAttempt: number | undefined
): ProviderSessionFailure {
  return {
    kind: "provider",
    id: `provider/${sourceEntryId}`,
    name: `${message.provider}/${message.model}`,
    status: "failed",
    code: "provider_error",
    ...(message.errorMessage === undefined ? {} : { message: boundMessage(message.errorMessage) }),
    ...(retryAttempt === undefined ? {} : { retryAttempt }),
    timestamp,
    sourceEntryId
  }
}

function agentTurnFailure(
  entry: Extract<AgentTeamEntry, { readonly type: "agent_turn_settled" }>
): AgentTurnSessionFailure {
  if (entry.result.status !== "failed") throw new Error("Agent turn failure projection requires a failed result")
  return {
    kind: "agent_turn",
    id: `agent-turn/${entry.operationId}`,
    name: entry.path,
    status: "failed",
    code: entry.result.code,
    ...(entry.result.message === undefined ? {} : { message: boundMessage(entry.result.message) }),
    timestamp: entry.timestamp,
    durationMs: entry.result.durationMs,
    sourceEntryId: entry.id
  }
}

function backgroundTaskFailure(
  entry: BackgroundTaskResultEntry,
  parentId: string | undefined
): BackgroundTaskSessionFailure {
  if (entry.result !== "failed") throw new Error("Background task failure projection requires a failed result")
  const message =
    entry.errorCode === "exit_nonzero"
      ? `Command exited with code ${entry.exitCode}`
      : entry.errorCode === "signaled"
        ? `Command terminated by ${entry.signal}`
        : entry.errorCode === "timed_out"
          ? "Command timed out"
          : entry.errorCode === "output_limit"
            ? "Command stopped after reaching its output limit"
            : "Command execution failed"
  return {
    kind: "background_task",
    id: `background-task/${entry.taskId}`,
    ...(parentId === undefined ? {} : { parentId }),
    name: "bash",
    status: "failed",
    code: entry.errorCode,
    message,
    timestamp: entry.timestamp,
    durationMs: entry.durationMs,
    sourceEntryId: entry.id
  }
}

function toolFailure(
  message: Extract<AgentMessage, { readonly role: "toolResult" }>,
  sourceEntryId: string,
  timestamp: string
): ToolSessionFailure {
  const evidence = toolFailureEvidence(message)
  const text = message.content.flatMap(part => (part.type === "text" ? [part.text] : [])).join("\n")
  return {
    kind: "tool",
    id: `tool/${message.toolCallId}`,
    name: message.toolName,
    status: "failed",
    ...(evidence?.code === undefined ? {} : { code: evidence.code }),
    ...(evidence?.message ? { message: boundMessage(evidence.message) } : text ? { message: boundMessage(text) } : {}),
    timestamp,
    sourceEntryId
  }
}

function toolFailureEvidence(
  message: Extract<AgentMessage, { readonly role: "toolResult" }>
): { readonly code?: string; readonly message: string } | undefined {
  const details = message.details
  switch (message.toolName) {
    case "read":
      return isReadToolDetails(details) && details.outcome === "error"
        ? { code: details.reason, message: details.error }
        : undefined
    case "write":
      return isWriteToolDetails(details) && details.outcome === "error"
        ? { code: details.reason, message: details.error }
        : undefined
    case "edit":
      return isEditToolDetails(details) && details.outcome === "error"
        ? { code: details.reason, message: details.error }
        : undefined
    case "bash":
      return isBashToolDetails(details) && details.outcome === "error"
        ? { code: bashFailureCode(details), message: details.error }
        : undefined
    case "task_output":
      return isTaskOutputToolDetails(details) && details.outcome === "error" ? { message: details.error } : undefined
    case "kill_task":
      return isKillTaskToolDetails(details) && details.outcome === "error" ? { message: details.error } : undefined
    case "code":
      return isCodeModeDetails(details) && details.outcome === "error"
        ? { code: "program_error", message: details.error }
        : undefined
    default:
      return undefined
  }
}

function bashFailureCode(details: Extract<BashToolDetails, { readonly outcome: "error" }>): string {
  if (details.state === "rejected") return "rejected"
  switch (details.finalOutcome?.type) {
    case "exited":
      return "exit_nonzero"
    case "signaled":
      return "signaled"
    case "timed_out":
      return "timed_out"
    case "output_limit":
      return "output_limit"
    case "failed":
      return "execution_failed"
    case "aborted":
    case "killed":
    case "disposed":
      return details.finalOutcome.type
    case undefined:
      return "execution_failed"
    default:
      return assertNever(details.finalOutcome)
  }
}

function assertNever(value: never): never {
  throw new Error(`Unexpected shell task outcome: ${String(value)}`)
}

function boundMessage(message: string): string {
  const encoded = Buffer.from(message)
  if (encoded.byteLength <= maxSessionFailureMessageBytes) return message
  let end = maxSessionFailureMessageBytes
  while (end > 0 && (encoded[end]! & 0xc0) === 0x80) end--
  return encoded.subarray(0, end).toString("utf8")
}
