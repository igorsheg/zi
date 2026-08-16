import { isNonNegativeInteger, isRecord } from "../guards.js"
import type { AgentMessage } from "../messages.js"

export const maxAgentTurnTextBytes = 50 * 1024
export const maxAgentTurnResultBytes = 64 * 1024

interface AgentTurnResultBase {
  readonly durationMs: number
  readonly text: string
  readonly originalBytes: number
  readonly omittedBytes: number
  readonly truncated: boolean
}

export type AgentTurnFailureCode =
  | "assignment_failed"
  | "turn_timeout"
  | "missing_assistant"
  | "provider_error"
  | "missing_final_answer"
  | "incomplete_final_answer"
  | "session_unavailable"
  | "session_failed"

export type AgentTurnResult = AgentTurnResultBase &
  (
    | { readonly status: "completed" }
    | { readonly status: "interrupted"; readonly reason: "requested" | "restart" | "shutdown" | "turn_timeout" }
    | { readonly status: "failed"; readonly code: AgentTurnFailureCode; readonly message?: string }
  )

const baseFields = ["status", "durationMs", "text", "originalBytes", "omittedBytes", "truncated"] as const

export function isAgentTurnResult(value: unknown): value is AgentTurnResult {
  if (
    !isRecord(value) ||
    !isNonNegativeInteger(value.durationMs) ||
    typeof value.text !== "string" ||
    Buffer.byteLength(value.text) > maxAgentTurnTextBytes ||
    !isNonNegativeInteger(value.originalBytes) ||
    !isNonNegativeInteger(value.omittedBytes) ||
    typeof value.truncated !== "boolean" ||
    value.originalBytes !== Buffer.byteLength(value.text) + value.omittedBytes ||
    (!value.truncated && value.omittedBytes > 0)
  ) {
    return false
  }

  if (value.status === "completed") {
    if (!hasOnlyFields(value, baseFields)) return false
  } else if (value.status === "interrupted") {
    if (
      !hasOnlyFields(value, [...baseFields, "reason"]) ||
      (value.reason !== "requested" &&
        value.reason !== "restart" &&
        value.reason !== "shutdown" &&
        value.reason !== "turn_timeout")
    ) {
      return false
    }
  } else if (value.status === "failed") {
    if (
      !hasOnlyFields(value, [...baseFields, "code", "message"]) ||
      !isAgentTurnFailureCode(value.code) ||
      (value.message !== undefined && typeof value.message !== "string")
    ) {
      return false
    }
  } else {
    return false
  }

  return Buffer.byteLength(JSON.stringify(value)) <= maxAgentTurnResultBytes
}

export function agentTurnResult(
  messages: readonly AgentMessage[],
  durationMs: number,
  interruption?: "requested" | "turn_timeout" | "shutdown"
): AgentTurnResult {
  const assistant = messages.findLast(
    (message): message is Extract<AgentMessage, { readonly role: "assistant" }> => message.role === "assistant"
  )
  if (!assistant) return failed(durationMs, "missing_assistant", "Agent turn produced no assistant message")

  let text = ""
  for (const part of assistant.content) if (part.type === "text") text += part.text
  const clipped = clipUtf8(text, maxAgentTurnTextBytes)
  const base = {
    durationMs: Math.max(0, Math.floor(durationMs)),
    text: clipped.text,
    originalBytes: clipped.originalBytes,
    omittedBytes: clipped.omittedBytes,
    truncated: assistant.stopReason === "length" || clipped.omittedBytes > 0
  }
  switch (assistant.stopReason) {
    case "aborted":
      return { ...base, status: "interrupted", reason: interruption ?? "requested" }
    case "error":
      return {
        ...base,
        status: "failed",
        code: "provider_error",
        ...(assistant.errorMessage ? { message: clipUtf8(assistant.errorMessage, 2_000).text } : {})
      }
    case "toolUse":
      return { ...base, status: "failed", code: "missing_final_answer" }
    case "pending":
      return { ...base, status: "failed", code: "incomplete_final_answer" }
    case "stop":
    case "length":
      return { ...base, status: "completed" }
    default:
      return assertNever(assistant.stopReason)
  }
}

function failed(durationMs: number, code: AgentTurnFailureCode, message: string): AgentTurnResult {
  return {
    status: "failed",
    code,
    message,
    durationMs: Math.max(0, Math.floor(durationMs)),
    text: "",
    originalBytes: 0,
    omittedBytes: 0,
    truncated: false
  }
}

function clipUtf8(text: string, maxBytes: number) {
  const encoded = Buffer.from(text)
  const originalBytes = encoded.byteLength
  if (originalBytes <= maxBytes) return { text, originalBytes, omittedBytes: 0 }
  let end = Math.max(0, Math.min(maxBytes, originalBytes))
  while (end > 0 && (encoded[end]! & 0xc0) === 0x80) end--
  return { text: encoded.subarray(0, end).toString("utf8"), originalBytes, omittedBytes: originalBytes - end }
}

function hasOnlyFields(value: Record<string, unknown>, fields: readonly string[]): boolean {
  const admitted = new Set(fields)
  return Object.keys(value).every(field => admitted.has(field))
}

function isAgentTurnFailureCode(value: unknown): value is AgentTurnFailureCode {
  return (
    value === "assignment_failed" ||
    value === "turn_timeout" ||
    value === "missing_assistant" ||
    value === "provider_error" ||
    value === "missing_final_answer" ||
    value === "incomplete_final_answer" ||
    value === "session_unavailable" ||
    value === "session_failed"
  )
}

function assertNever(value: never): never {
  throw new Error(`Unexpected assistant stop reason: ${String(value)}`)
}
