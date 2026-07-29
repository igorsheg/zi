import {
  maxCodeModeCalls,
  maxCodeModeErrorBytes,
  maxCodeModeJsonDepth,
  maxCodeModeJsonNodes,
  maxCodeModeLogBytes,
  maxCodeModeLogs
} from "./protocol.js"
import type { CodeModeJson } from "./protocol.js"

export type CodeModeCall =
  | {
      readonly state: "running"
      readonly id: number
      readonly name: string
      readonly arguments: CodeModeJson
      readonly startedAt: number
      readonly preview?: string
    }
  | {
      readonly state: "succeeded"
      readonly id: number
      readonly name: string
      readonly arguments: CodeModeJson
      readonly startedAt: number
      readonly durationMs: number
      readonly result: string
    }
  | {
      readonly state: "failed"
      readonly id: number
      readonly name: string
      readonly arguments: CodeModeJson
      readonly startedAt: number
      readonly durationMs: number
      readonly error: string
    }
  | {
      readonly state: "aborted"
      readonly id: number
      readonly name: string
      readonly arguments: CodeModeJson
      readonly startedAt: number
      readonly durationMs: number
    }

export type CodeModeDetails =
  | {
      readonly type: "code_mode"
      readonly outcome: "progress"
      readonly calls: readonly CodeModeCall[]
      readonly logs: readonly string[]
    }
  | {
      readonly type: "code_mode"
      readonly outcome: "success"
      readonly calls: readonly CodeModeCall[]
      readonly logs: readonly string[]
    }
  | {
      readonly type: "code_mode"
      readonly outcome: "error"
      readonly error: string
      readonly calls: readonly CodeModeCall[]
      readonly logs: readonly string[]
    }

export function isCodeModeDetails(value: unknown): value is CodeModeDetails {
  if (
    !isRecord(value) ||
    value.type !== "code_mode" ||
    (value.outcome !== "progress" && value.outcome !== "success" && value.outcome !== "error") ||
    !Array.isArray(value.calls) ||
    value.calls.length > maxCodeModeCalls ||
    !value.calls.every(isCodeModeCall) ||
    !Array.isArray(value.logs) ||
    value.logs.length > maxCodeModeLogs ||
    !value.logs.every(log => boundedString(log, maxCodeModeLogBytes))
  ) {
    return false
  }
  return value.outcome !== "error" || boundedString(value.error, maxCodeModeErrorBytes)
}

function isCodeModeCall(value: unknown): value is CodeModeCall {
  if (
    !isRecord(value) ||
    typeof value.id !== "number" ||
    !Number.isInteger(value.id) ||
    value.id < 0 ||
    value.id >= maxCodeModeCalls ||
    typeof value.name !== "string" ||
    value.name.length === 0 ||
    value.name.length > 128 ||
    typeof value.startedAt !== "number" ||
    !Number.isFinite(value.startedAt) ||
    !isCodeModeJson(value.arguments)
  ) {
    return false
  }
  switch (value.state) {
    case "running":
      return value.preview === undefined || boundedString(value.preview, maxCodeModeErrorBytes)
    case "succeeded":
      return duration(value.durationMs) && boundedString(value.result, maxCodeModeErrorBytes)
    case "failed":
      return duration(value.durationMs) && boundedString(value.error, maxCodeModeErrorBytes)
    case "aborted":
      return duration(value.durationMs)
    default:
      return false
  }
}

function isCodeModeJson(value: unknown): value is CodeModeJson {
  let nodes = 0
  const visit = (current: unknown, depth: number): boolean => {
    nodes++
    if (nodes > maxCodeModeJsonNodes || depth > maxCodeModeJsonDepth) return false
    if (current === null || typeof current === "boolean") return true
    if (typeof current === "string") return boundedString(current, maxCodeModeErrorBytes)
    if (typeof current === "number") return Number.isFinite(current)
    if (Array.isArray(current)) return current.every(item => visit(item, depth + 1))
    return (
      isRecord(current) &&
      Object.entries(current).every(([key, item]) => Buffer.byteLength(key) <= 1_024 && visit(item, depth + 1))
    )
  }
  return visit(value, 0)
}

function boundedString(value: unknown, bytes: number): value is string {
  return typeof value === "string" && Buffer.byteLength(value) <= bytes
}

function duration(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value) && value >= 0
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}
