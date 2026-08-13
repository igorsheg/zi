import { isRecord } from "../guards.js"
import type { FramedJsonLimits } from "../processes/framed-json.js"

export const codeModeProtocolVersion = 4
export const codeModeWorkerArgument = "--zi-internal-code-mode-worker"

export const maxCodeBytes = 256 * 1024
export const maxCodeModeCalls = 64
export const maxCodeModeToolNames = 128
export const maxCodeModeFrameBytes = 9 * 1024 * 1024
export const maxCodeModeQueuedFrames = 128
export const maxCodeModeQueuedBytes = 18 * 1024 * 1024
export const codeModeFramingLimits: FramedJsonLimits = Object.freeze({
  maxFrameBytes: maxCodeModeFrameBytes,
  maxQueuedFrames: maxCodeModeQueuedFrames,
  maxQueuedBytes: maxCodeModeQueuedBytes
})
export const codeModeFramingLabel = "Code-mode protocol"
export const maxCodeModeErrorBytes = 16 * 1024
export const maxCodeModeLogs = 32
export const maxCodeModeLogBytes = 16 * 1024
export const maxCodeModeJsonDepth = 32
export const maxCodeModeJsonNodes = 16_384
export const maxCodeModeStateBytes = 256 * 1024

export type CodeModeJson =
  | null
  | boolean
  | number
  | string
  | readonly CodeModeJson[]
  | { readonly [key: string]: CodeModeJson }

export type CodeModeState = { readonly [key: string]: CodeModeJson }

interface Correlation {
  readonly generation: number
  readonly executionId: number
}

export type CodeModeHostMessage =
  | { readonly version: typeof codeModeProtocolVersion; readonly type: "initialize"; readonly generation: number }
  | ({
      readonly version: typeof codeModeProtocolVersion
      readonly type: "execute"
      readonly code: string
      readonly tools: readonly string[]
      readonly state: CodeModeState
    } & Correlation)
  | ({
      readonly version: typeof codeModeProtocolVersion
      readonly type: "tool_result"
      readonly id: number
      readonly value: CodeModeJson
      readonly terminate?: boolean
    } & Correlation)
  | ({
      readonly version: typeof codeModeProtocolVersion
      readonly type: "tool_error"
      readonly id: number
      readonly error: string
    } & Correlation)

export type CodeModeWorkerMessage =
  | { readonly version: typeof codeModeProtocolVersion; readonly type: "ready"; readonly generation: number }
  | ({
      readonly version: typeof codeModeProtocolVersion
      readonly type: "tool_call"
      readonly id: number
      readonly name: string
      readonly arguments: CodeModeJson
    } & Correlation)
  | ({
      readonly version: typeof codeModeProtocolVersion
      readonly type: "completed"
      readonly result?: CodeModeJson
      readonly state: CodeModeState
      readonly logs: readonly string[]
    } & Correlation)
  | ({
      readonly version: typeof codeModeProtocolVersion
      readonly type: "failed"
      readonly error: string
      readonly logs: readonly string[]
      readonly toolCallId?: number
      readonly reset?: boolean
    } & Correlation)

export class CodeModeProtocolError extends Error {
  constructor(message: string, options?: ErrorOptions) {
    super(message, options)
    this.name = "CodeModeProtocolError"
  }
}

export function validateHostMessage(value: unknown): CodeModeHostMessage {
  const message = messageRecord(value)
  if (message.type === "initialize") {
    return { version: codeModeProtocolVersion, type: "initialize", generation: generation(message.generation) }
  }
  const correlated = correlation(message)
  if (message.type === "execute") {
    if (typeof message.code !== "string" || Buffer.byteLength(message.code) > maxCodeBytes) {
      throw new CodeModeProtocolError(`Code must not exceed ${maxCodeBytes} bytes`)
    }
    if (
      !Array.isArray(message.tools) ||
      message.tools.length > maxCodeModeToolNames ||
      !message.tools.every(name => typeof name === "string" && isCodeModeToolName(name)) ||
      new Set(message.tools).size !== message.tools.length
    ) {
      throw new CodeModeProtocolError("Code-mode execution requires unique bounded tool names")
    }
    return {
      version: codeModeProtocolVersion,
      type: "execute",
      ...correlated,
      code: message.code,
      tools: Object.freeze([...message.tools]),
      state: validateCodeModeState(message.state)
    }
  }
  if (message.type === "tool_result") {
    return {
      version: codeModeProtocolVersion,
      type: "tool_result",
      ...correlated,
      id: callId(message.id),
      value: validateCodeModeJson(message.value),
      ...(message.terminate === true ? { terminate: true } : {})
    }
  }
  if (message.type === "tool_error") {
    return {
      version: codeModeProtocolVersion,
      type: "tool_error",
      ...correlated,
      id: callId(message.id),
      error: boundedError(message.error)
    }
  }
  throw new CodeModeProtocolError(`Unknown code-mode host message: ${String(message.type)}`)
}

export function validateWorkerMessage(value: unknown): CodeModeWorkerMessage {
  const message = messageRecord(value)
  if (message.type === "ready") {
    return { version: codeModeProtocolVersion, type: "ready", generation: generation(message.generation) }
  }
  const correlated = correlation(message)
  if (message.type === "tool_call") {
    if (typeof message.name !== "string" || !isCodeModeToolName(message.name)) {
      throw new CodeModeProtocolError("Code-mode tool calls require a valid tool name")
    }
    return {
      version: codeModeProtocolVersion,
      type: "tool_call",
      ...correlated,
      id: callId(message.id),
      name: message.name,
      arguments: validateCodeModeJson(message.arguments)
    }
  }
  const logs = logValues(message.logs)
  if (message.type === "completed") {
    return {
      version: codeModeProtocolVersion,
      type: "completed",
      ...correlated,
      ...(message.result === undefined ? {} : { result: validateCodeModeJson(message.result) }),
      state: validateCodeModeState(message.state),
      logs
    }
  }
  if (message.type === "failed") {
    return {
      version: codeModeProtocolVersion,
      type: "failed",
      ...correlated,
      error: boundedError(message.error),
      logs,
      ...(message.toolCallId === undefined ? {} : { toolCallId: callId(message.toolCallId) }),
      ...(message.reset === true ? { reset: true } : {})
    }
  }
  throw new CodeModeProtocolError(`Unknown code-mode worker message: ${String(message.type)}`)
}

export function validateCodeModeState(value: unknown): CodeModeState {
  const state = validateCodeModeJson(value)
  if (!isRecord(state)) throw new CodeModeProtocolError("Code-mode state must be an object")
  if (Buffer.byteLength(JSON.stringify(state)) > maxCodeModeStateBytes) {
    throw new CodeModeProtocolError(`Code-mode state must not exceed ${maxCodeModeStateBytes} bytes`)
  }
  return state
}

export function validateCodeModeJson(value: unknown): CodeModeJson {
  let nodes = 0
  const visit = (current: unknown, depth: number): CodeModeJson => {
    nodes++
    if (nodes > maxCodeModeJsonNodes || depth > maxCodeModeJsonDepth) {
      throw new CodeModeProtocolError("Code-mode JSON exceeded its structural bound")
    }
    if (current === null || typeof current === "boolean" || typeof current === "string") return current
    if (typeof current === "number") {
      if (!Number.isFinite(current)) throw new CodeModeProtocolError("Code-mode JSON numbers must be finite")
      return current
    }
    if (Array.isArray(current)) return current.map(item => visit(item, depth + 1))
    if (!isRecord(current)) throw new CodeModeProtocolError("Code-mode values must be JSON compatible")
    return Object.fromEntries(Object.entries(current).map(([key, item]) => [key, visit(item, depth + 1)]))
  }
  return visit(value, 0)
}

function messageRecord(value: unknown): Record<string, unknown> {
  if (!isRecord(value) || value.version !== codeModeProtocolVersion || typeof value.type !== "string") {
    throw new CodeModeProtocolError("Invalid code-mode protocol message")
  }
  return value
}

function correlation(value: Record<string, unknown>): Correlation {
  return { generation: generation(value.generation), executionId: executionId(value.executionId) }
}

function generation(value: unknown): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 1) {
    throw new CodeModeProtocolError("Invalid code-mode generation")
  }
  return value
}

function executionId(value: unknown): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0) {
    throw new CodeModeProtocolError("Invalid code-mode execution ID")
  }
  return value
}

function callId(value: unknown): number {
  if (typeof value !== "number" || !Number.isInteger(value) || value < 0 || value >= maxCodeModeCalls) {
    throw new CodeModeProtocolError("Invalid code-mode call ID")
  }
  return value
}

function logValues(value: unknown): readonly string[] {
  if (!Array.isArray(value) || value.length > maxCodeModeLogs || !value.every(log => typeof log === "string")) {
    throw new CodeModeProtocolError("Invalid code-mode console logs")
  }
  return Object.freeze(value.map(log => utf8Prefix(log, maxCodeModeLogBytes)))
}

function boundedError(value: unknown): string {
  if (typeof value !== "string") throw new CodeModeProtocolError("Code-mode errors must be strings")
  return utf8Prefix(value, maxCodeModeErrorBytes)
}

function utf8Prefix(value: string, limit: number): string {
  let output = ""
  let bytes = 0
  for (const scalar of value) {
    const scalarBytes = Buffer.byteLength(scalar)
    if (bytes + scalarBytes > limit) break
    output += scalar
    bytes += scalarBytes
  }
  return output
}

export function isCodeModeToolName(value: string): boolean {
  if (value.length === 0 || value.length > 128) return false
  for (const character of value) {
    const code = character.codePointAt(0)
    if (code === undefined || code <= 0x1f || code === 0x7f) return false
  }
  return true
}
