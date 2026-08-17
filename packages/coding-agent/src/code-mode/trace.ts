import { isNonNegativeFinite, isRecord } from "../guards.js"
import {
  maxCodeModeCalls,
  maxCodeModeErrorBytes,
  maxCodeModeJsonDepth,
  maxCodeModeJsonNodes,
  maxCodeModeLogBytes,
  maxCodeModeLogs
} from "./protocol.js"
import type { CodeModeJson } from "./protocol.js"

export const codeModeTraceVersion = 1
export const maxCodeModeTerminalDetailsBytes = 384 * 1024
export const maxCodeModeTracePathBytes = 4_096

const maxCodeModeTraceNumber = 1_000_000_000

export type CodeModeFailureStage = "prepare" | "validate" | "invoke"

interface CodeModeCallBase {
  readonly id: number
  readonly name: string
  readonly arguments: CodeModeJson
  readonly startedAt: number
}

export type CodeModeCall =
  | (CodeModeCallBase & { readonly state: "running"; readonly preview?: string })
  | (CodeModeCallBase & { readonly state: "succeeded"; readonly durationMs: number; readonly result: string })
  | (CodeModeCallBase & {
      readonly state: "failed"
      readonly durationMs: number
      readonly stage?: CodeModeFailureStage
      readonly error: string
    })
  | (CodeModeCallBase & { readonly state: "aborted"; readonly durationMs: number })

export type CodeModeLiveCall =
  | Exclude<CodeModeCall, { readonly state: "failed" }>
  | (Extract<CodeModeCall, { readonly state: "failed" }> & { readonly stage: CodeModeFailureStage })

export type CodeModeTerminalCall =
  | (CodeModeCallBase & { readonly state: "succeeded"; readonly durationMs: number })
  | (CodeModeCallBase & {
      readonly state: "failed"
      readonly durationMs: number
      readonly stage: CodeModeFailureStage
      readonly error?: string
    })
  | (CodeModeCallBase & { readonly state: "aborted"; readonly durationMs: number })

export type CodeModeTraceCall = CodeModeCall | CodeModeTerminalCall

interface LegacyCodeModeDetailBase {
  readonly type: "code_mode"
  readonly version?: undefined
  readonly calls: readonly CodeModeCall[]
  readonly logs: readonly string[]
}

export type CodeModeTerminalDetails =
  | {
      readonly type: "code_mode"
      readonly version: typeof codeModeTraceVersion
      readonly outcome: "success"
      readonly calls: readonly CodeModeTerminalCall[]
      readonly logs: readonly []
    }
  | {
      readonly type: "code_mode"
      readonly version: typeof codeModeTraceVersion
      readonly outcome: "error"
      readonly error: string
      readonly calls: readonly CodeModeTerminalCall[]
      readonly logs: readonly []
    }

export type CodeModeDetails =
  | (LegacyCodeModeDetailBase & { readonly outcome: "progress" })
  | (LegacyCodeModeDetailBase & { readonly outcome: "success" })
  | (LegacyCodeModeDetailBase & { readonly outcome: "error"; readonly error: string })
  | {
      readonly type: "code_mode"
      readonly version: typeof codeModeTraceVersion
      readonly outcome: "progress"
      readonly calls: readonly CodeModeLiveCall[]
      readonly logs: readonly string[]
    }
  | CodeModeTerminalDetails

export function isCodeModeDetails(value: unknown): value is CodeModeDetails {
  if (
    !isRecord(value) ||
    value.type !== "code_mode" ||
    (value.version !== undefined && value.version !== codeModeTraceVersion) ||
    (value.outcome !== "progress" && value.outcome !== "success" && value.outcome !== "error") ||
    !Array.isArray(value.calls) ||
    value.calls.length > maxCodeModeCalls ||
    !Array.isArray(value.logs) ||
    value.logs.length > maxCodeModeLogs ||
    !value.logs.every(log => boundedString(log, maxCodeModeLogBytes)) ||
    (value.outcome === "error" && !boundedString(value.error, maxCodeModeErrorBytes))
  ) {
    return false
  }
  if (value.version === undefined) return value.calls.every(isLegacyCodeModeCall)
  if (!isVersionedDetailShape(value)) return false
  if (value.outcome === "progress") return value.calls.every(isLiveCodeModeCall)
  return (
    value.logs.length === 0 &&
    value.calls.every(isTerminalCodeModeCall) &&
    serializedBytes(value) <= maxCodeModeTerminalDetailsBytes
  )
}

function isLiveCodeModeCall(value: unknown): value is CodeModeLiveCall {
  if (!isCodeModeCallBase(value)) return false
  switch (value.state) {
    case "running":
      return (
        hasOnlyKeys(value, "state", "id", "name", "arguments", "startedAt", "preview") &&
        (value.preview === undefined || boundedString(value.preview, maxCodeModeErrorBytes))
      )
    case "succeeded":
      return (
        hasOnlyKeys(value, "state", "id", "name", "arguments", "startedAt", "durationMs", "result") &&
        isNonNegativeFinite(value.durationMs) &&
        boundedString(value.result, maxCodeModeErrorBytes)
      )
    case "failed":
      return (
        hasOnlyKeys(value, "state", "id", "name", "arguments", "startedAt", "durationMs", "stage", "error") &&
        isNonNegativeFinite(value.durationMs) &&
        isCodeModeFailureStage(value.stage) &&
        boundedString(value.error, maxCodeModeErrorBytes)
      )
    case "aborted":
      return (
        hasOnlyKeys(value, "state", "id", "name", "arguments", "startedAt", "durationMs") &&
        isNonNegativeFinite(value.durationMs)
      )
    default:
      return false
  }
}

function isLegacyCodeModeCall(value: unknown): value is CodeModeCall {
  if (!isCodeModeCallBase(value)) return false
  switch (value.state) {
    case "running":
      return value.preview === undefined || boundedString(value.preview, maxCodeModeErrorBytes)
    case "succeeded":
      return isNonNegativeFinite(value.durationMs) && boundedString(value.result, maxCodeModeErrorBytes)
    case "failed":
      return (
        isNonNegativeFinite(value.durationMs) &&
        (value.stage === undefined || isCodeModeFailureStage(value.stage)) &&
        boundedString(value.error, maxCodeModeErrorBytes)
      )
    case "aborted":
      return isNonNegativeFinite(value.durationMs)
    default:
      return false
  }
}

function isTerminalCodeModeCall(value: unknown): value is CodeModeTerminalCall {
  if (!isCodeModeCallBase(value) || !isTerminalArguments(value.name, value.arguments)) return false
  switch (value.state) {
    case "running":
      return false
    case "succeeded":
      return (
        hasOnlyKeys(value, "state", "id", "name", "arguments", "startedAt", "durationMs") &&
        isNonNegativeFinite(value.durationMs)
      )
    case "failed":
      return (
        hasOnlyKeys(value, "state", "id", "name", "arguments", "startedAt", "durationMs", "stage", "error") &&
        isNonNegativeFinite(value.durationMs) &&
        isCodeModeFailureStage(value.stage) &&
        (value.error === undefined || boundedString(value.error, maxCodeModeErrorBytes))
      )
    case "aborted":
      return (
        hasOnlyKeys(value, "state", "id", "name", "arguments", "startedAt", "durationMs") &&
        isNonNegativeFinite(value.durationMs)
      )
    default:
      return false
  }
}

function isCodeModeCallBase(
  value: unknown
): value is Record<string, unknown> & {
  readonly id: number
  readonly name: string
  readonly arguments: CodeModeJson
  readonly startedAt: number
} {
  return (
    isRecord(value) &&
    typeof value.id === "number" &&
    Number.isInteger(value.id) &&
    value.id >= 0 &&
    value.id < maxCodeModeCalls &&
    typeof value.name === "string" &&
    value.name.length > 0 &&
    value.name.length <= 128 &&
    typeof value.startedAt === "number" &&
    Number.isFinite(value.startedAt) &&
    isCodeModeJson(value.arguments)
  )
}

function isVersionedDetailShape(value: Record<string, unknown>): boolean {
  return hasOnlyKeys(
    value,
    "type",
    "version",
    "outcome",
    "calls",
    "logs",
    ...(value.outcome === "error" ? (["error"] as const) : [])
  )
}

function isTerminalArguments(name: string, value: CodeModeJson): boolean {
  if (!isRecord(value)) return false
  const keys = Object.keys(value)
  switch (name) {
    case "read":
      return (
        keys.every(key => key === "path" || key === "offset" || key === "limit") &&
        optionalPath(value.path) &&
        optionalTraceNumber(value.offset) &&
        optionalTraceNumber(value.limit)
      )
    case "write":
      return (
        keys.every(key => key === "path" || key === "contentBytes") &&
        optionalPath(value.path) &&
        optionalTraceNumber(value.contentBytes)
      )
    case "edit":
      return (
        keys.every(key => key === "path" || key === "operations") &&
        optionalPath(value.path) &&
        optionalTraceNumber(value.operations)
      )
    case "session_failures":
      return (
        keys.every(key => key === "cursor" || key === "limit") &&
        optionalTraceNumber(value.cursor) &&
        optionalTraceNumber(value.limit)
      )
    default:
      return keys.length === 0
  }
}

function isCodeModeFailureStage(value: unknown): value is CodeModeFailureStage {
  return value === "prepare" || value === "validate" || value === "invoke"
}

function optionalPath(value: unknown): boolean {
  return value === undefined || boundedString(value, maxCodeModeTracePathBytes)
}

function optionalTraceNumber(value: unknown): boolean {
  return (
    value === undefined ||
    (typeof value === "number" && Number.isSafeInteger(value) && value >= 0 && value <= maxCodeModeTraceNumber)
  )
}

function hasOnlyKeys(value: Record<string, unknown>, ...allowed: readonly string[]): boolean {
  const keys = new Set(allowed)
  return Object.keys(value).every(key => keys.has(key))
}

function serializedBytes(value: unknown): number {
  try {
    return Buffer.byteLength(JSON.stringify(value))
  } catch {
    return Number.POSITIVE_INFINITY
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
