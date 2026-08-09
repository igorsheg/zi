import type { Writable } from "node:stream"

import { isRecord } from "../guards.js"

export const codeModeProtocolVersion = 4
export const codeModeWorkerArgument = "--zi-internal-code-mode-worker"

export const maxCodeBytes = 256 * 1024
export const maxCodeModeCalls = 64
export const maxCodeModeToolNames = 128
export const maxCodeModeFrameBytes = 9 * 1024 * 1024
export const maxCodeModeQueuedFrames = 128
export const maxCodeModeQueuedBytes = 18 * 1024 * 1024
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

type DecoderState =
  | { readonly type: "open" }
  | { readonly type: "failed"; readonly error: CodeModeProtocolError }
  | { readonly type: "ended" }

export class CodeModeProtocolDecoder<T> {
  readonly #validate: (value: unknown) => T
  #state: DecoderState = { type: "open" }
  #buffer = Buffer.alloc(0)

  constructor(validate: (value: unknown) => T) {
    this.#validate = validate
  }

  push(chunk: Uint8Array): readonly T[] {
    if (this.#state.type === "failed") throw this.#state.error
    if (this.#state.type === "ended") throw new CodeModeProtocolError("Cannot decode after code-mode input ended")
    if (chunk.byteLength === 0) return []

    try {
      const incoming = Buffer.from(chunk.buffer, chunk.byteOffset, chunk.byteLength)
      const data = this.#buffer.byteLength === 0 ? incoming : Buffer.concat([this.#buffer, incoming])
      const messages: T[] = []
      let offset = 0
      while (data.byteLength - offset >= 4) {
        const length = data.readUInt32BE(offset)
        if (length === 0 || length > maxCodeModeFrameBytes) {
          throw new CodeModeProtocolError(`Code-mode frames must contain 1 to ${maxCodeModeFrameBytes} bytes`)
        }
        if (data.byteLength - offset - 4 < length) break
        messages.push(this.#validate(parsePayload(data.subarray(offset + 4, offset + 4 + length))))
        offset += 4 + length
      }
      this.#buffer = offset === data.byteLength ? Buffer.alloc(0) : Buffer.from(data.subarray(offset))
      return messages
    } catch (cause) {
      const error = protocolError(cause)
      this.#state = { type: "failed", error }
      this.#buffer = Buffer.alloc(0)
      throw error
    }
  }

  end(): void {
    if (this.#state.type === "failed") throw this.#state.error
    if (this.#state.type === "ended") return
    if (this.#buffer.byteLength !== 0) {
      const error = new CodeModeProtocolError("Code-mode input ended with a partial frame")
      this.#state = { type: "failed", error }
      this.#buffer = Buffer.alloc(0)
      throw error
    }
    this.#state = { type: "ended" }
  }
}

interface QueuedFrame {
  readonly frame: Buffer
  resolve(): void
  reject(cause: unknown): void
}

type WriterState =
  | { readonly type: "idle" }
  | { readonly type: "writing"; readonly current: QueuedFrame }
  | { readonly type: "failed"; readonly error: CodeModeProtocolError }
  | { readonly type: "disposed" }

export class CodeModeProtocolWriter {
  readonly #sink: Writable
  readonly #queue: QueuedFrame[] = []
  readonly #onError: (cause: Error) => void
  #state: WriterState = { type: "idle" }
  #queuedBytes = 0

  constructor(sink: Writable) {
    this.#sink = sink
    this.#onError = cause => this.#fail(cause)
    sink.on("error", this.#onError)
  }

  send(value: CodeModeHostMessage): Promise<void> {
    if (this.#state.type === "failed") return Promise.reject(this.#state.error)
    if (this.#state.type === "disposed") {
      return Promise.reject(new CodeModeProtocolError("Code-mode writer is disposed"))
    }

    let frame: Buffer
    try {
      frame = encodeCodeModeFrame(value)
    } catch (cause) {
      return Promise.reject(cause)
    }
    const count = this.#queue.length + (this.#state.type === "writing" ? 1 : 0)
    if (count >= maxCodeModeQueuedFrames || frame.byteLength > maxCodeModeQueuedBytes - this.#queuedBytes) {
      return Promise.reject(new CodeModeProtocolError("Code-mode output queue exceeded its bound"))
    }
    const promise = new Promise<void>((resolve, reject) => this.#queue.push({ frame, resolve, reject }))
    this.#queuedBytes += frame.byteLength
    if (this.#state.type === "idle") this.#writeNext()
    return promise
  }

  dispose(): void {
    if (this.#state.type === "disposed") return
    const error = new CodeModeProtocolError("Code-mode writer disposed before output settled")
    const current = this.#state.type === "writing" ? this.#state.current : undefined
    this.#state = { type: "disposed" }
    current?.reject(error)
    for (const frame of this.#queue.splice(0)) frame.reject(error)
    this.#queuedBytes = 0
    this.#sink.off("error", this.#onError)
  }

  #writeNext(): void {
    const next = this.#queue.shift()
    if (!next) {
      this.#state = { type: "idle" }
      return
    }
    this.#state = { type: "writing", current: next }
    try {
      this.#sink.write(next.frame, error => {
        if (this.#state.type !== "writing" || this.#state.current !== next) return
        if (error) {
          this.#fail(error)
          return
        }
        this.#queuedBytes -= next.frame.byteLength
        this.#state = { type: "idle" }
        next.resolve()
        this.#writeNext()
      })
    } catch (cause) {
      this.#fail(cause)
    }
  }

  #fail(cause: unknown): void {
    if (this.#state.type === "failed" || this.#state.type === "disposed") return
    const error = protocolError(cause)
    const current = this.#state.type === "writing" ? this.#state.current : undefined
    this.#state = { type: "failed", error }
    current?.reject(error)
    for (const frame of this.#queue.splice(0)) frame.reject(error)
    this.#queuedBytes = 0
  }
}

export function encodeCodeModeFrame(value: unknown): Buffer {
  let json: string
  try {
    json = JSON.stringify(value)
  } catch (cause) {
    throw new CodeModeProtocolError("Code-mode frame is not JSON serializable", { cause })
  }
  const payload = Buffer.from(json)
  if (payload.byteLength === 0 || payload.byteLength > maxCodeModeFrameBytes) {
    throw new CodeModeProtocolError(`Code-mode frames must contain 1 to ${maxCodeModeFrameBytes} bytes`)
  }
  const frame = Buffer.allocUnsafe(4 + payload.byteLength)
  frame.writeUInt32BE(payload.byteLength)
  payload.copy(frame, 4)
  return frame
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

function parsePayload(payload: Uint8Array): unknown {
  try {
    return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(payload))
  } catch (cause) {
    throw new CodeModeProtocolError("Code-mode frame contains invalid JSON or UTF-8", { cause })
  }
}

function protocolError(cause: unknown): CodeModeProtocolError {
  return cause instanceof CodeModeProtocolError
    ? cause
    : new CodeModeProtocolError(cause instanceof Error ? cause.message : "Code-mode protocol failed", { cause })
}
