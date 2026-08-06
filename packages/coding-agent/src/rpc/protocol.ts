import type { ThinkingLevel } from "@earendil-works/pi-agent-core"

import type { SettingsScope } from "../settings-manager.js"

export const rpcProtocolVersion = 1 as const
export const maxRpcFrameBytes = 16 * 1024 * 1024
export const maxRpcInputTextBytes = 8 * 1024 * 1024
export const maxRpcRequestIdBytes = 256
export const maxRpcMessagePageCount = 100
export const maxRpcMessagePageBytes = 8 * 1024 * 1024
export const maxRpcCompletionIdBytes = 256
export const maxRpcCompletionTextBytes = 50 * 1024
export const maxRpcCompletionErrorBytes = 8 * 1024
export const maxRpcCommandNameBytes = 64
export const maxRpcCommandArgumentsBytes = 256 * 1024

export type RpcInputDelivery = "direct" | "steer" | "follow_up" | "continue"
export type RpcEventMode = "all" | "none" | "activity"

export type RpcRequest =
  | { readonly version: 1; readonly id: string; readonly method: "session.get_state" }
  | {
      readonly version: 1
      readonly id: string
      readonly method: "session.get_messages"
      readonly params: { readonly start: number; readonly limit: number }
    }
  | {
      readonly version: 1
      readonly id: string
      readonly method: "session.prompt"
      readonly params: { readonly delivery: RpcInputDelivery; readonly text: string; readonly completionId?: string }
    }
  | { readonly version: 1; readonly id: string; readonly method: "session.interrupt" }
  | {
      readonly version: 1
      readonly id: string
      readonly method: "session.await_idle"
      readonly params?: { readonly completionId: string }
    }
  | {
      readonly version: 1
      readonly id: string
      readonly method: "connection.set_events"
      readonly params: { readonly mode: RpcEventMode }
    }
  | { readonly version: 1; readonly id: string; readonly method: "command.list" }
  | {
      readonly version: 1
      readonly id: string
      readonly method: "command.invoke"
      readonly params: { readonly name: string; readonly arguments: string }
    }
  | { readonly version: 1; readonly id: string; readonly method: "model.list" }
  | {
      readonly version: 1
      readonly id: string
      readonly method: "model.select"
      readonly params: { readonly provider: string; readonly id: string }
    }
  | { readonly version: 1; readonly id: string; readonly method: "thinking.list" }
  | {
      readonly version: 1
      readonly id: string
      readonly method: "thinking.select"
      readonly params: { readonly level: ThinkingLevel; readonly scope: SettingsScope }
    }

export type RpcMethod = RpcRequest["method"]
export type RpcProtocolErrorCode = "invalid_json" | "invalid_request" | "unknown_method" | "unsupported_version"

export class RpcRequestError extends Error {
  readonly code: RpcProtocolErrorCode
  readonly requestId: string | undefined

  constructor(code: RpcProtocolErrorCode, message: string, requestId?: string) {
    super(message)
    this.name = "RpcRequestError"
    this.code = code
    this.requestId = requestId
  }
}

export class RpcFramingError extends Error {
  constructor(message: string) {
    super(message)
    this.name = "RpcFramingError"
  }
}

export class RpcLineDecoder {
  readonly #decoder = new TextDecoder("utf-8", { fatal: true })
  #buffer = ""
  #bufferBytes = 0
  #closed = false

  push(chunk: Uint8Array): string[] {
    if (this.#closed) throw new RpcFramingError("RPC input is closed")
    let text: string
    try {
      text = this.#decoder.decode(chunk, { stream: true })
    } catch {
      this.#closed = true
      throw new RpcFramingError("RPC input must be valid UTF-8")
    }
    this.#buffer += text
    this.#bufferBytes += chunk.byteLength
    return this.#takeLines()
  }

  finish(): string[] {
    if (this.#closed) return []
    this.#closed = true
    try {
      this.#buffer += this.#decoder.decode()
    } catch {
      throw new RpcFramingError("RPC input must be valid UTF-8")
    }
    const lines = this.#takeLines()
    if (this.#buffer.length === 0) return lines
    if (this.#bufferBytes > maxRpcFrameBytes) throw oversizedFrame()
    lines.push(stripCarriageReturn(this.#buffer))
    this.#buffer = ""
    this.#bufferBytes = 0
    return lines
  }

  #takeLines(): string[] {
    const lines: string[] = []
    while (true) {
      const newline = this.#buffer.indexOf("\n")
      if (newline === -1) break
      const line = this.#buffer.slice(0, newline)
      const lineBytes = Buffer.byteLength(line)
      if (lineBytes > maxRpcFrameBytes) {
        this.#closed = true
        throw oversizedFrame()
      }
      lines.push(stripCarriageReturn(line))
      this.#buffer = this.#buffer.slice(newline + 1)
      this.#bufferBytes -= lineBytes + 1
    }
    if (this.#bufferBytes > maxRpcFrameBytes) {
      this.#closed = true
      throw oversizedFrame()
    }
    return lines
  }
}

export function decodeRpcRequest(value: unknown): RpcRequest {
  if (!isRecord(value)) throw new RpcRequestError("invalid_request", "RPC requests must be JSON objects")

  const requestId = validRequestId(value.id) ? value.id : undefined
  if (value.version !== rpcProtocolVersion) {
    throw new RpcRequestError(
      "unsupported_version",
      `Unsupported RPC protocol version: ${String(value.version)} (expected ${rpcProtocolVersion})`,
      requestId
    )
  }
  if (!requestId) {
    throw new RpcRequestError(
      "invalid_request",
      `RPC request id must be a non-empty string of at most ${maxRpcRequestIdBytes} bytes`
    )
  }
  if (typeof value.method !== "string") {
    throw new RpcRequestError("invalid_request", "RPC request method must be a string", requestId)
  }

  switch (value.method) {
    case "session.get_state":
    case "session.interrupt":
    case "command.list":
    case "model.list":
    case "thinking.list":
      requireKeys(value, ["version", "id", "method"], requestId)
      return { version: 1, id: requestId, method: value.method }
    case "session.get_messages": {
      requireKeys(value, ["version", "id", "method", "params"], requestId, true)
      const params =
        value.params === undefined ? {} : requireRecord(value.params, "session.get_messages params", requestId)
      requireKeys(params, ["start", "limit"], requestId, true)
      const start = params.start ?? 0
      const limit = params.limit ?? maxRpcMessagePageCount
      if (!isSafeInteger(start) || start < 0) {
        throw new RpcRequestError("invalid_request", "Message start must be a non-negative integer", requestId)
      }
      if (!isSafeInteger(limit) || limit < 1 || limit > maxRpcMessagePageCount) {
        throw new RpcRequestError(
          "invalid_request",
          `Message limit must be an integer from 1 through ${maxRpcMessagePageCount}`,
          requestId
        )
      }
      return { version: 1, id: requestId, method: "session.get_messages", params: { start, limit } }
    }
    case "session.await_idle": {
      requireKeys(value, ["version", "id", "method", "params"], requestId, true)
      if (value.params === undefined) return { version: 1, id: requestId, method: "session.await_idle" }
      const params = requireRecord(value.params, "session.await_idle params", requestId)
      requireKeys(params, ["completionId"], requestId)
      const completionId = boundedString(params.completionId, "Completion id", maxRpcCompletionIdBytes, requestId, true)
      return { version: 1, id: requestId, method: "session.await_idle", params: { completionId } }
    }
    case "session.prompt": {
      requireKeys(value, ["version", "id", "method", "params"], requestId)
      const params = requireRecord(value.params, "session.prompt params", requestId)
      requireKeys(params, ["delivery", "text", "completionId"], requestId, true)
      if (
        params.delivery !== "direct" &&
        params.delivery !== "steer" &&
        params.delivery !== "follow_up" &&
        params.delivery !== "continue"
      ) {
        throw new RpcRequestError(
          "invalid_request",
          "Prompt delivery must be direct, steer, follow_up, or continue",
          requestId
        )
      }
      const text = boundedString(params.text, "Prompt text", maxRpcInputTextBytes, requestId)
      const completionId =
        params.completionId === undefined
          ? undefined
          : boundedString(params.completionId, "Completion id", maxRpcCompletionIdBytes, requestId, true)
      return {
        version: 1,
        id: requestId,
        method: "session.prompt",
        params: { delivery: params.delivery, text, ...(completionId ? { completionId } : {}) }
      }
    }
    case "command.invoke": {
      requireKeys(value, ["version", "id", "method", "params"], requestId)
      const params = requireRecord(value.params, "command.invoke params", requestId)
      requireKeys(params, ["name", "arguments"], requestId)
      const name = boundedString(params.name, "Command name", maxRpcCommandNameBytes, requestId, true)
      if (!/^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$/.test(name)) {
        throw new RpcRequestError("invalid_request", "Command name must use lowercase kebab-case", requestId)
      }
      const commandArguments = boundedString(
        params.arguments,
        "Command arguments",
        maxRpcCommandArgumentsBytes,
        requestId
      )
      return { version: 1, id: requestId, method: "command.invoke", params: { name, arguments: commandArguments } }
    }
    case "connection.set_events": {
      requireKeys(value, ["version", "id", "method", "params"], requestId)
      const params = requireRecord(value.params, "connection.set_events params", requestId)
      requireKeys(params, ["mode"], requestId)
      if (params.mode !== "all" && params.mode !== "none" && params.mode !== "activity") {
        throw new RpcRequestError("invalid_request", "Event mode must be all, none, or activity", requestId)
      }
      return { version: 1, id: requestId, method: "connection.set_events", params: { mode: params.mode } }
    }
    case "model.select": {
      requireKeys(value, ["version", "id", "method", "params"], requestId)
      const params = requireRecord(value.params, "model.select params", requestId)
      requireKeys(params, ["provider", "id"], requestId)
      const provider = boundedString(params.provider, "Model provider", maxRpcRequestIdBytes, requestId, true)
      const id = boundedString(params.id, "Model id", maxRpcRequestIdBytes, requestId, true)
      return { version: 1, id: requestId, method: "model.select", params: { provider, id } }
    }
    case "thinking.select": {
      requireKeys(value, ["version", "id", "method", "params"], requestId)
      const params = requireRecord(value.params, "thinking.select params", requestId)
      requireKeys(params, ["level", "scope"], requestId, true)
      const level = thinkingLevel(params.level, requestId)
      const scope = params.scope ?? "global"
      if (scope !== "global" && scope !== "project") {
        throw new RpcRequestError("invalid_request", "Thinking scope must be global or project", requestId)
      }
      return { version: 1, id: requestId, method: "thinking.select", params: { level, scope } }
    }
    default:
      throw new RpcRequestError("unknown_method", `Unknown RPC method: ${value.method}`, requestId)
  }
}

function requireRecord(value: unknown, name: string, requestId: string): Record<string, unknown> {
  if (!isRecord(value)) throw new RpcRequestError("invalid_request", `${name} must be an object`, requestId)
  return value
}

function requireKeys(
  value: Record<string, unknown>,
  keys: readonly string[],
  requestId: string,
  optional = false
): void {
  const allowed = new Set(keys)
  if (Object.keys(value).some(key => !allowed.has(key))) {
    throw new RpcRequestError("invalid_request", "RPC request contains unknown fields", requestId)
  }
  if (!optional && keys.some(key => !(key in value))) {
    throw new RpcRequestError("invalid_request", "RPC request is missing required fields", requestId)
  }
}

function isSafeInteger(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value)
}

function validRequestId(value: unknown): value is string {
  return typeof value === "string" && value.length > 0 && Buffer.byteLength(value) <= maxRpcRequestIdBytes
}

function boundedString(value: unknown, name: string, maxBytes: number, requestId: string, nonEmpty = false): string {
  if (typeof value !== "string" || (nonEmpty && value.length === 0) || Buffer.byteLength(value) > maxBytes) {
    throw new RpcRequestError(
      "invalid_request",
      `${name} must be ${nonEmpty ? "a non-empty string" : "a string"} of at most ${maxBytes} bytes`,
      requestId
    )
  }
  return value
}

function thinkingLevel(value: unknown, requestId: string): ThinkingLevel {
  switch (value) {
    case "off":
    case "minimal":
    case "low":
    case "medium":
    case "high":
    case "xhigh":
    case "max":
      return value
    default:
      throw new RpcRequestError("invalid_request", "Unsupported thinking level", requestId)
  }
}

function stripCarriageReturn(value: string): string {
  return value.endsWith("\r") ? value.slice(0, -1) : value
}

function oversizedFrame(): RpcFramingError {
  return new RpcFramingError(`RPC input records cannot exceed ${maxRpcFrameBytes} bytes`)
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}
