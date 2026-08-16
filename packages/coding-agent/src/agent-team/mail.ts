import { isRecord } from "../guards.js"
import type { CustomMessageEntry, CustomMessageInput } from "../session-manager.js"
import { maxAgentMailTextBytes } from "./journal.js"
import { parseAgentPath, type AgentPath } from "./path.js"

export const agentTaskCustomType = "zi.agent-task.v1"
export const agentMessageCustomType = "zi.agent-message.v1"
export const agentCompletionCustomType = "zi.agent-completion.v1"
export const maxAgentDeliveryIdBytes = 768

export type AgentMailPublication = "append" | "boundary"

export interface AgentMailInput {
  readonly deliveryId: string
  readonly sender: AgentPath
  readonly target: AgentPath
  readonly kind: "message" | "task" | "completion"
  readonly text: string
}

export function agentMailMessage(input: AgentMailInput): CustomMessageInput {
  validateAgentMailInput(input)
  return {
    customType: customType(input.kind),
    content: content(input),
    display: false,
    details: { deliveryId: input.deliveryId, sender: input.sender, target: input.target, kind: input.kind }
  }
}

export function agentMailDeliveryId(entry: CustomMessageEntry): string | undefined {
  if (
    entry.customType !== agentTaskCustomType &&
    entry.customType !== agentMessageCustomType &&
    entry.customType !== agentCompletionCustomType
  ) {
    return undefined
  }
  const details = entry.details
  if (!isRecord(details) || !isDeliveryId(details.deliveryId)) return undefined
  return details.deliveryId
}

export function isAgentMailEntry(entry: CustomMessageEntry, input: AgentMailInput): boolean {
  const expected = agentMailMessage(input)
  return (
    entry.customType === expected.customType &&
    entry.content === expected.content &&
    entry.display === expected.display &&
    isRecord(entry.details) &&
    entry.details.deliveryId === input.deliveryId &&
    entry.details.sender === input.sender &&
    entry.details.target === input.target &&
    entry.details.kind === input.kind
  )
}

export function validateAgentMailInput(input: unknown): asserts input is AgentMailInput {
  if (
    !isRecord(input) ||
    !isDeliveryId(input.deliveryId) ||
    !isCanonicalPath(input.sender) ||
    !isCanonicalPath(input.target) ||
    (input.kind !== "message" && input.kind !== "task" && input.kind !== "completion") ||
    typeof input.text !== "string" ||
    Buffer.byteLength(input.text) > maxAgentMailTextBytes
  ) {
    throw new Error("Invalid agent mail")
  }
}

function customType(kind: AgentMailInput["kind"]): string {
  switch (kind) {
    case "message":
      return agentMessageCustomType
    case "task":
      return agentTaskCustomType
    case "completion":
      return agentCompletionCustomType
    default:
      return assertNever(kind)
  }
}

function content(input: AgentMailInput): string {
  switch (input.kind) {
    case "message":
      return `Agent message from ${input.sender}:\n${input.text}`
    case "task":
      return `Agent task from ${input.sender}:\n${input.text}`
    case "completion":
      return `Agent completion from ${input.sender}:\n${input.text}`
    default:
      return assertNever(input.kind)
  }
}

function isDeliveryId(value: unknown): value is string {
  return typeof value === "string" && value.length > 0 && Buffer.byteLength(value) <= maxAgentDeliveryIdBytes
}

function isCanonicalPath(value: unknown): value is AgentPath {
  if (typeof value !== "string") return false
  try {
    return parseAgentPath(value) === value
  } catch {
    return false
  }
}

function assertNever(value: never): never {
  throw new Error(`Unexpected agent mail kind: ${String(value)}`)
}
