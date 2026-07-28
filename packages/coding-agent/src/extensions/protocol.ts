import { isAbsolute } from "node:path"
import type { Writable } from "node:stream"

import type {
  ExtensionCustomEntry,
  ExtensionCustomMessage,
  ExtensionMessageDelivery,
  ExtensionShutdownReason,
  ExtensionStartReason
} from "@with-zi/extension-api"

import {
  maxCustomJsonBytes,
  maxCustomStateEntries,
  validateCustomMessageInput,
  validateCustomType
} from "../session-manager.js"
import {
  maxExtensionPathBytes,
  maxExtensionSources,
  type ExtensionLoadPlan,
  type ExtensionSource
} from "./discovery.js"

export const extensionProtocolVersion = 3
export const maxExtensionProtocolFrameBytes = 4 * 1024 * 1024
export const maxExtensionPendingRequests = 128
export const maxExtensionQueuedWriteBytes = 8 * 1024 * 1024
export const maxExtensionQueuedWrites = 1024
export const maxExtensionDiagnostics = 256
export const maxExtensionDiagnosticMessageBytes = 16 * 1024
export const maxExtensionDiagnosticStackBytes = 64 * 1024
export const maxExtensionLoadDiagnosticMessageBytes = 2 * 1024
export const maxExtensionIdBytes = 256
export const maxExtensionLogBytesPerStream = 256 * 1024
export const extensionStartupTimeoutMs = 30_000
export const extensionLifecycleTimeoutMs = 10_000
export const extensionShutdownTimeoutMs = 3_000
export const extensionToolTimeoutMs = 30_000
export const extensionToolCancellationTimeoutMs = 1_000
export const maxExtensionTools = 64
export const maxExtensionToolCatalogBytes = 512 * 1024
export const maxExtensionToolNameBytes = 64
export const maxExtensionToolLabelBytes = 256
export const maxExtensionToolDescriptionBytes = 4 * 1024
export const maxExtensionToolSchemaBytes = 16 * 1024
export const maxExtensionToolArgumentsBytes = 256 * 1024
export const maxExtensionToolResultBytes = 256 * 1024
export const maxExtensionJsonDepth = 32
export const maxExtensionJsonNodes = 4096
export const maxExtensionJsonKeyBytes = 4 * 1024

export type { ExtensionShutdownReason, ExtensionStartReason } from "@with-zi/extension-api"

export interface ExtensionDiagnostic {
  readonly extensionId?: string
  readonly path?: string
  readonly phase:
    | "discovery"
    | "trust"
    | "spawn"
    | "handshake"
    | "resolve"
    | "import"
    | "factory"
    | "registration"
    | "lifecycle"
    | "tool"
    | "protocol"
    | "shutdown"
  readonly severity: "warning" | "error"
  readonly message: string
  readonly stack?: string
}

export interface ExtensionLoadResult {
  readonly source: ExtensionSource
  readonly status: "loaded" | "failed"
  readonly diagnostic?: ExtensionDiagnostic
}

export type HostMessage =
  | {
      readonly type: "initialize"
      readonly protocolVersion: 3
      readonly generation: number
      readonly plan: ExtensionLoadPlan
    }
  | {
      readonly type: "session_start"
      readonly generation: number
      readonly requestId: number
      readonly reason: ExtensionStartReason
    }
  | {
      readonly type: "session_shutdown"
      readonly generation: number
      readonly requestId: number
      readonly reason: ExtensionShutdownReason
    }
  | {
      readonly type: "tool_invoke"
      readonly generation: number
      readonly requestId: number
      readonly name: string
      readonly arguments: Readonly<Record<string, JsonValue>>
    }
  | { readonly type: "stop"; readonly generation: number; readonly requestId: number }
  | { readonly type: "cancel"; readonly generation: number; readonly requestId: number }
  | {
      readonly type: "custom_entries_result"
      readonly generation: number
      readonly requestId: number
      readonly entries: readonly ExtensionCustomEntry[]
    }
  | {
      readonly type: "custom_entry_result"
      readonly generation: number
      readonly requestId: number
      readonly entry: ExtensionCustomEntry
    }
  | { readonly type: "custom_message_result"; readonly generation: number; readonly requestId: number }
  | {
      readonly type: "session_operation_error"
      readonly generation: number
      readonly requestId: number
      readonly message: string
    }

export type WorkerMessage =
  | {
      readonly type: "ready"
      readonly protocolVersion: 3
      readonly generation: number
      readonly extensions: readonly ExtensionLoadResult[]
      readonly tools: readonly ExtensionToolRegistration[]
    }
  | { readonly type: "settled"; readonly generation: number; readonly requestId: number }
  | { readonly type: "tool_result"; readonly generation: number; readonly requestId: number; readonly content: string }
  | { readonly type: "tool_error"; readonly generation: number; readonly requestId: number; readonly message: string }
  | { readonly type: "tool_cancelled"; readonly generation: number; readonly requestId: number }
  | {
      readonly type: "custom_entries_get"
      readonly generation: number
      readonly requestId: number
      readonly extensionId: string
      readonly customType: string
    }
  | {
      readonly type: "custom_entry_append"
      readonly generation: number
      readonly requestId: number
      readonly extensionId: string
      readonly customType: string
      readonly data?: JsonValue
    }
  | {
      readonly type: "custom_message_send"
      readonly generation: number
      readonly requestId: number
      readonly extensionId: string
      readonly message: ExtensionCustomMessage
      readonly delivery: ExtensionMessageDelivery
    }
  | { readonly type: "diagnostic"; readonly generation: number; readonly diagnostic: ExtensionDiagnostic }
  | { readonly type: "fatal"; readonly generation: number; readonly diagnostic: ExtensionDiagnostic }

export type JsonValue = null | boolean | number | string | readonly JsonValue[] | { readonly [key: string]: JsonValue }

export type ExtensionSessionRequest = Extract<
  WorkerMessage,
  { readonly type: "custom_entries_get" | "custom_entry_append" | "custom_message_send" }
>
export type ExtensionSessionResponse = Extract<
  HostMessage,
  {
    readonly type: "custom_entries_result" | "custom_entry_result" | "custom_message_result" | "session_operation_error"
  }
>

export interface ExtensionToolRegistration {
  readonly source: ExtensionSource
  readonly name: string
  readonly label: string
  readonly description: string
  readonly parameters: Readonly<Record<string, JsonValue>>
}

export class ExtensionProtocolError extends Error {
  constructor(message: string, options?: ErrorOptions) {
    super(message, options)
    this.name = "ExtensionProtocolError"
  }
}

type DecoderState =
  | { readonly type: "open" }
  | { readonly type: "failed"; readonly error: Error }
  | { readonly type: "ended" }

export class ExtensionProtocolDecoder<T> {
  readonly #validate: (value: unknown) => T
  #state: DecoderState = { type: "open" }
  #buffer = Buffer.alloc(0)

  constructor(validate: (value: unknown) => T) {
    this.#validate = validate
  }

  push(chunk: Uint8Array): readonly T[] {
    if (this.#state.type === "failed") throw this.#state.error
    if (this.#state.type === "ended") throw new ExtensionProtocolError("Cannot decode after protocol input ended")
    if (chunk.byteLength === 0) return []

    try {
      const incoming = Buffer.from(chunk.buffer, chunk.byteOffset, chunk.byteLength)
      const data = this.#buffer.byteLength === 0 ? incoming : Buffer.concat([this.#buffer, incoming])
      const messages: T[] = []
      let offset = 0

      while (data.byteLength - offset >= 4) {
        const length = data.readUInt32BE(offset)
        if (length === 0) throw new ExtensionProtocolError("Extension protocol frames cannot be empty")
        if (length > maxExtensionProtocolFrameBytes) {
          throw new ExtensionProtocolError(
            `Extension protocol frames cannot exceed ${maxExtensionProtocolFrameBytes} bytes`
          )
        }
        if (data.byteLength - offset - 4 < length) break
        const payload = data.subarray(offset + 4, offset + 4 + length)
        messages.push(this.#validate(parsePayload(payload)))
        offset += 4 + length
      }

      this.#buffer = offset === data.byteLength ? Buffer.alloc(0) : Buffer.from(data.subarray(offset))
      return messages
    } catch (cause) {
      const error = protocolError(cause)
      this.#buffer = Buffer.alloc(0)
      this.#state = { type: "failed", error }
      throw error
    }
  }

  end(): void {
    if (this.#state.type === "failed") throw this.#state.error
    if (this.#state.type === "ended") return
    if (this.#buffer.byteLength !== 0) {
      const error = new ExtensionProtocolError("Extension protocol input ended with a partial frame")
      this.#buffer = Buffer.alloc(0)
      this.#state = { type: "failed", error }
      throw error
    }
    this.#state = { type: "ended" }
  }
}

interface QueuedWrite {
  readonly frame: Buffer
  resolve(): void
  reject(cause: unknown): void
}

type WriterState =
  | { readonly type: "idle" }
  | { readonly type: "writing"; readonly write: QueuedWrite }
  | { readonly type: "failed"; readonly error: Error }
  | { readonly type: "disposed" }

export class ExtensionProtocolWriter {
  readonly #sink: Writable
  readonly #queue: QueuedWrite[] = []
  readonly #onError: (cause: Error) => void
  readonly #onFailure: ((cause: Error) => void) | undefined
  #state: WriterState = { type: "idle" }
  #queuedBytes = 0

  constructor(sink: Writable, onFailure?: (cause: Error) => void) {
    this.#sink = sink
    this.#onFailure = onFailure
    this.#onError = cause => this.#fail(cause)
    sink.on("error", this.#onError)
  }

  send(value: unknown): Promise<void> {
    if (this.#state.type === "failed") return Promise.reject(this.#state.error)
    if (this.#state.type === "disposed")
      return Promise.reject(new ExtensionProtocolError("Protocol writer is disposed"))

    let frame: Buffer
    try {
      frame = encodeExtensionProtocolFrame(value)
    } catch (cause) {
      return Promise.reject(cause)
    }
    const writeCount = this.#queue.length + (this.#state.type === "writing" ? 1 : 0)
    if (writeCount >= maxExtensionQueuedWrites) {
      return Promise.reject(
        new ExtensionProtocolError(
          `Extension protocol writers cannot queue more than ${maxExtensionQueuedWrites} frames`
        )
      )
    }
    if (frame.byteLength > maxExtensionQueuedWriteBytes - this.#queuedBytes) {
      return Promise.reject(
        new ExtensionProtocolError(
          `Extension protocol writers cannot queue more than ${maxExtensionQueuedWriteBytes} bytes`
        )
      )
    }

    const promise = new Promise<void>((resolve, reject) => {
      this.#queue.push({ frame, resolve, reject })
    })
    this.#queuedBytes += frame.byteLength
    if (this.#state.type === "idle") this.#writeNext()
    return promise
  }

  fail(cause: unknown): void {
    this.#fail(cause)
  }

  dispose(): void {
    if (this.#state.type === "disposed") return
    const error = new ExtensionProtocolError("Protocol writer was disposed before queued output settled")
    const active = this.#state.type === "writing" ? this.#state.write : undefined
    this.#state = { type: "disposed" }
    this.#queuedBytes = 0
    active?.reject(error)
    for (const write of this.#queue.splice(0)) write.reject(error)
    this.#sink.off("error", this.#onError)
  }

  #writeNext(): void {
    const write = this.#queue.shift()
    if (!write) {
      this.#state = { type: "idle" }
      return
    }
    this.#state = { type: "writing", write }
    try {
      this.#sink.write(write.frame, error => {
        if (this.#state.type !== "writing" || this.#state.write !== write) return
        if (error) {
          this.#fail(error)
          return
        }
        this.#queuedBytes -= write.frame.byteLength
        this.#state = { type: "idle" }
        write.resolve()
        this.#writeNext()
      })
    } catch (cause) {
      this.#fail(cause)
    }
  }

  #fail(cause: unknown): void {
    if (this.#state.type === "failed" || this.#state.type === "disposed") return
    const error = protocolError(cause)
    const active = this.#state.type === "writing" ? this.#state.write : undefined
    this.#state = { type: "failed", error }
    this.#queuedBytes = 0
    active?.reject(error)
    for (const write of this.#queue.splice(0)) write.reject(error)
    this.#onFailure?.(error)
  }
}

export function encodeExtensionProtocolFrame(value: unknown): Buffer {
  let serialized: string | undefined
  try {
    serialized = JSON.stringify(value)
  } catch (cause) {
    throw new ExtensionProtocolError("Extension protocol message could not be serialized", { cause })
  }
  if (serialized === undefined) throw new ExtensionProtocolError("Extension protocol messages must be JSON values")
  const payload = Buffer.from(serialized)
  if (payload.byteLength === 0 || payload.byteLength > maxExtensionProtocolFrameBytes) {
    throw new ExtensionProtocolError(
      `Extension protocol frames must contain 1 to ${maxExtensionProtocolFrameBytes} bytes`
    )
  }
  const frame = Buffer.allocUnsafe(4 + payload.byteLength)
  frame.writeUInt32BE(payload.byteLength, 0)
  payload.copy(frame, 4)
  return frame
}

export function validateHostMessage(value: unknown): HostMessage {
  const message = protocolRecord(value)
  switch (message.type) {
    case "initialize":
      return Object.freeze({
        type: "initialize",
        protocolVersion: protocolVersion(message.protocolVersion),
        generation: positiveInteger(message.generation, "generation"),
        plan: extensionLoadPlan(message.plan)
      })
    case "session_start":
      return Object.freeze({
        type: "session_start",
        generation: positiveInteger(message.generation, "generation"),
        requestId: positiveInteger(message.requestId, "requestId"),
        reason: startReason(message.reason)
      })
    case "session_shutdown":
      return Object.freeze({
        type: "session_shutdown",
        generation: positiveInteger(message.generation, "generation"),
        requestId: positiveInteger(message.requestId, "requestId"),
        reason: shutdownReason(message.reason)
      })
    case "tool_invoke":
      return Object.freeze({
        type: "tool_invoke",
        generation: positiveInteger(message.generation, "generation"),
        requestId: positiveInteger(message.requestId, "requestId"),
        name: toolName(message.name),
        arguments: jsonRecord(message.arguments, "tool arguments", maxExtensionToolArgumentsBytes)
      })
    case "stop":
    case "cancel":
    case "custom_message_result":
      return Object.freeze({
        type: message.type,
        generation: positiveInteger(message.generation, "generation"),
        requestId: positiveInteger(message.requestId, "requestId")
      })
    case "custom_entries_result": {
      const entries = protocolArray(message.entries, "custom entries")
      if (entries.length > maxCustomStateEntries) {
        throw new ExtensionProtocolError(`Custom entries cannot exceed ${maxCustomStateEntries}`)
      }
      return Object.freeze({
        type: "custom_entries_result",
        generation: positiveInteger(message.generation, "generation"),
        requestId: positiveInteger(message.requestId, "requestId"),
        entries: Object.freeze(entries.map(extensionCustomEntry))
      })
    }
    case "custom_entry_result":
      return Object.freeze({
        type: "custom_entry_result",
        generation: positiveInteger(message.generation, "generation"),
        requestId: positiveInteger(message.requestId, "requestId"),
        entry: extensionCustomEntry(message.entry)
      })
    case "session_operation_error":
      return Object.freeze({
        type: "session_operation_error",
        generation: positiveInteger(message.generation, "generation"),
        requestId: positiveInteger(message.requestId, "requestId"),
        message: boundedRequiredText(message.message, "session operation error", maxExtensionDiagnosticMessageBytes)
      })
    default:
      throw new ExtensionProtocolError("Unknown host protocol message")
  }
}

export function validateWorkerMessage(value: unknown): WorkerMessage {
  const message = protocolRecord(value)
  switch (message.type) {
    case "ready": {
      const extensions = protocolArray(message.extensions, "extensions")
      if (extensions.length > maxExtensionSources) {
        throw new ExtensionProtocolError(`Extension results cannot exceed ${maxExtensionSources}`)
      }
      const admittedTools = validateExtensionToolCatalog(message.tools)
      return Object.freeze({
        type: "ready",
        protocolVersion: protocolVersion(message.protocolVersion),
        generation: positiveInteger(message.generation, "generation"),
        extensions: Object.freeze(extensions.map(extensionLoadResult)),
        tools: Object.freeze(admittedTools)
      })
    }
    case "settled":
    case "tool_cancelled":
      return Object.freeze({
        type: message.type,
        generation: positiveInteger(message.generation, "generation"),
        requestId: positiveInteger(message.requestId, "requestId")
      })
    case "tool_result":
      return Object.freeze({
        type: "tool_result",
        generation: positiveInteger(message.generation, "generation"),
        requestId: positiveInteger(message.requestId, "requestId"),
        content: boundedString(message.content, "tool result", maxExtensionToolResultBytes)
      })
    case "tool_error":
      return Object.freeze({
        type: "tool_error",
        generation: positiveInteger(message.generation, "generation"),
        requestId: positiveInteger(message.requestId, "requestId"),
        message: boundedRequiredText(message.message, "tool error", maxExtensionDiagnosticMessageBytes)
      })
    case "custom_entries_get":
      return Object.freeze({
        type: "custom_entries_get",
        generation: positiveInteger(message.generation, "generation"),
        requestId: positiveInteger(message.requestId, "requestId"),
        extensionId: boundedRequiredText(message.extensionId, "extension id", maxExtensionIdBytes),
        customType: customType(message.customType)
      })
    case "custom_entry_append":
      return Object.freeze({
        type: "custom_entry_append",
        generation: positiveInteger(message.generation, "generation"),
        requestId: positiveInteger(message.requestId, "requestId"),
        extensionId: boundedRequiredText(message.extensionId, "extension id", maxExtensionIdBytes),
        customType: customType(message.customType),
        ...(message.data === undefined
          ? {}
          : { data: jsonValue(message.data, "custom entry data", maxCustomJsonBytes) })
      })
    case "custom_message_send":
      return Object.freeze({
        type: "custom_message_send",
        generation: positiveInteger(message.generation, "generation"),
        requestId: positiveInteger(message.requestId, "requestId"),
        extensionId: boundedRequiredText(message.extensionId, "extension id", maxExtensionIdBytes),
        message: extensionCustomMessage(message.message),
        delivery: extensionMessageDelivery(message.delivery)
      })
    case "diagnostic":
    case "fatal":
      return Object.freeze({
        type: message.type,
        generation: positiveInteger(message.generation, "generation"),
        diagnostic: extensionDiagnostic(message.diagnostic)
      })
    default:
      throw new ExtensionProtocolError("Unknown worker protocol message")
  }
}

export function validateExtensionToolRegistration(value: unknown): ExtensionToolRegistration {
  return extensionToolRegistration(value)
}

export function validateExtensionToolCatalog(value: unknown): readonly ExtensionToolRegistration[] {
  const tools = protocolArray(value, "tools")
  if (tools.length > maxExtensionTools) {
    throw new ExtensionProtocolError(`Extension tools cannot exceed ${maxExtensionTools}`)
  }
  const admitted = tools.map(extensionToolRegistration)
  const names = new Set<string>()
  for (const tool of admitted) {
    if (names.has(tool.name)) throw new ExtensionProtocolError(`Extension tool names must be unique: ${tool.name}`)
    names.add(tool.name)
  }
  if (Buffer.byteLength(JSON.stringify(admitted)) > maxExtensionToolCatalogBytes) {
    throw new ExtensionProtocolError(`Extension tool catalog cannot exceed ${maxExtensionToolCatalogBytes} bytes`)
  }
  return Object.freeze(admitted)
}

export function validateExtensionToolArguments(value: unknown): Readonly<Record<string, JsonValue>> {
  return jsonRecord(value, "tool arguments", maxExtensionToolArgumentsBytes)
}

export function validateExtensionToolResult(value: unknown): string {
  return boundedString(value, "tool result", maxExtensionToolResultBytes)
}

export function boundedExtensionToolError(cause: unknown): string {
  return boundedOperationError(cause, "Extension tool failed")
}

export function boundedExtensionSessionOperationError(cause: unknown): string {
  return boundedOperationError(cause, "Extension session operation failed")
}

function boundedOperationError(cause: unknown, fallback: string): string {
  try {
    const error = cause instanceof Error ? cause : new Error(String(cause))
    return boundedText(error.message || error.name || fallback, maxExtensionDiagnosticMessageBytes)
  } catch {
    return fallback
  }
}

export function boundedExtensionDiagnostic(diagnostic: ExtensionDiagnostic): ExtensionDiagnostic {
  return extensionDiagnostic({
    ...(diagnostic.extensionId === undefined
      ? {}
      : { extensionId: boundedText(diagnostic.extensionId, maxExtensionIdBytes) }),
    ...(diagnostic.path === undefined ? {} : { path: boundedText(diagnostic.path, maxExtensionPathBytes) }),
    phase: diagnostic.phase,
    severity: diagnostic.severity,
    message: boundedText(diagnostic.message, maxExtensionDiagnosticMessageBytes),
    ...(diagnostic.stack === undefined
      ? {}
      : { stack: boundedText(diagnostic.stack, maxExtensionDiagnosticStackBytes) })
  })
}

export function boundedExtensionLoadDiagnostic(diagnostic: ExtensionDiagnostic): ExtensionDiagnostic {
  return extensionDiagnostic({
    ...(diagnostic.extensionId === undefined
      ? {}
      : { extensionId: boundedText(diagnostic.extensionId, maxExtensionIdBytes) }),
    ...(diagnostic.path === undefined ? {} : { path: boundedText(diagnostic.path, maxExtensionPathBytes) }),
    phase: diagnostic.phase,
    severity: diagnostic.severity,
    message: boundedText(diagnostic.message, maxExtensionLoadDiagnosticMessageBytes)
  })
}

function parsePayload(payload: Buffer): unknown {
  let text: string
  try {
    text = new TextDecoder("utf-8", { fatal: true }).decode(payload)
  } catch (cause) {
    throw new ExtensionProtocolError("Extension protocol payload is not valid UTF-8", { cause })
  }
  try {
    return JSON.parse(text)
  } catch (cause) {
    throw new ExtensionProtocolError("Extension protocol payload is not valid JSON", { cause })
  }
}

function extensionLoadPlan(value: unknown): ExtensionLoadPlan {
  const plan = protocolRecord(value)
  const cwd = pathText(plan.cwd, "plan cwd")
  if (!isAbsolute(cwd)) throw new ExtensionProtocolError("Extension plan cwd must be absolute")
  const sources = protocolArray(plan.sources, "sources")
  if (sources.length > maxExtensionSources) {
    throw new ExtensionProtocolError(`Extension sources cannot exceed ${maxExtensionSources}`)
  }
  return Object.freeze({ cwd, sources: Object.freeze(sources.map(extensionSource)) })
}

function extensionSource(value: unknown): ExtensionSource {
  const source = protocolRecord(value)
  const declaredPath = pathText(source.declaredPath, "declaredPath")
  const entryPath = pathText(source.entryPath, "entryPath")
  if (!isAbsolute(declaredPath) || !isAbsolute(entryPath)) {
    throw new ExtensionProtocolError("Extension source paths must be absolute")
  }
  const id = boundedRequiredText(source.id, "extension id", maxExtensionIdBytes)
  const scope = source.scope
  if (scope !== "global" && scope !== "project" && scope !== "temporary") {
    throw new ExtensionProtocolError("Unknown extension scope")
  }
  const origin = source.origin
  if (origin !== "directory" && origin !== "package" && origin !== "cli") {
    throw new ExtensionProtocolError("Unknown extension origin")
  }
  return Object.freeze({ id, declaredPath, entryPath, scope, origin })
}

function extensionLoadResult(value: unknown): ExtensionLoadResult {
  const result = protocolRecord(value)
  const source = extensionSource(result.source)
  if (result.status === "loaded") {
    if (result.diagnostic !== undefined) {
      throw new ExtensionProtocolError("Loaded extensions cannot include a failure diagnostic")
    }
    return Object.freeze({ source, status: "loaded" })
  }
  if (result.status === "failed") {
    if (result.diagnostic === undefined) {
      throw new ExtensionProtocolError("Failed extensions require a diagnostic")
    }
    return Object.freeze({ source, status: "failed", diagnostic: extensionDiagnostic(result.diagnostic) })
  }
  throw new ExtensionProtocolError("Unknown extension load status")
}

function extensionToolRegistration(value: unknown): ExtensionToolRegistration {
  const tool = protocolRecord(value)
  const name = toolName(tool.name)
  const label = boundedRequiredText(tool.label, "tool label", maxExtensionToolLabelBytes)
  const description = boundedRequiredText(tool.description, "tool description", maxExtensionToolDescriptionBytes)
  const parameters = jsonRecord(tool.parameters, "tool parameters", maxExtensionToolSchemaBytes)
  if (parameters.type !== "object") {
    throw new ExtensionProtocolError("Extension tool parameters must be an object schema")
  }
  validateToolSchema(parameters, "parameters")
  return Object.freeze({ source: extensionSource(tool.source), name, label, description, parameters })
}

function validateToolSchema(value: JsonValue, path: string): void {
  if (!isProtocolRecord(value)) throw new ExtensionProtocolError(`Extension tool schema ${path} must be an object`)
  if (Object.hasOwn(value, "const")) return
  const type = value.type
  if (type === "string" || type === "number" || type === "integer" || type === "boolean") return
  if (type === "array") {
    if (!("items" in value)) throw new ExtensionProtocolError(`Extension tool array schema ${path} requires items`)
    validateToolSchema(value.items, `${path}.items`)
    return
  }
  if (type === "object") {
    const properties = value.properties
    if (!isProtocolRecord(properties)) {
      throw new ExtensionProtocolError(`Extension tool object schema ${path} requires properties`)
    }
    for (const [name, property] of Object.entries(properties)) {
      validateToolSchema(property, `${path}.properties.${name}`)
    }
    if (value.required !== undefined) {
      if (
        !Array.isArray(value.required) ||
        value.required.some(name => typeof name !== "string" || !(name in properties))
      ) {
        throw new ExtensionProtocolError(`Extension tool object schema ${path} has invalid required properties`)
      }
    }
    return
  }
  throw new ExtensionProtocolError(`Extension tool schema ${path} has an unsupported type`)
}

function extensionCustomEntry(value: unknown): ExtensionCustomEntry {
  const entry = protocolRecord(value)
  const customTypeValue = customType(entry.customType)
  const timestamp = boundedRequiredText(entry.timestamp, "custom entry timestamp", 128)
  if (!Number.isFinite(Date.parse(timestamp))) {
    throw new ExtensionProtocolError("Extension custom entry timestamps must be valid dates")
  }
  return Object.freeze({
    id: boundedRequiredText(entry.id, "custom entry id", maxExtensionIdBytes),
    timestamp,
    customType: customTypeValue,
    ...(entry.data === undefined ? {} : { data: jsonValue(entry.data, "custom entry data", maxCustomJsonBytes) })
  })
}

function extensionCustomMessage(value: unknown): ExtensionCustomMessage {
  const admitted = jsonValue(value, "custom message", maxExtensionProtocolFrameBytes)
  try {
    validateCustomMessageInput(admitted)
  } catch (cause) {
    throw new ExtensionProtocolError("Invalid extension custom message", { cause })
  }
  return Object.freeze({
    customType: admitted.customType,
    content: admitted.content,
    display: admitted.display,
    ...(admitted.details === undefined ? {} : { details: admitted.details })
  })
}

function extensionMessageDelivery(value: unknown): ExtensionMessageDelivery {
  if (
    value !== "append" &&
    value !== "trigger_turn" &&
    value !== "steer" &&
    value !== "follow_up" &&
    value !== "next_turn"
  ) {
    throw new ExtensionProtocolError("Unknown extension custom message delivery")
  }
  return value
}

function customType(value: unknown): string {
  try {
    validateCustomType(value)
    return value
  } catch (cause) {
    throw new ExtensionProtocolError("Invalid extension custom type", { cause })
  }
}

function toolName(value: unknown): string {
  const name = boundedRequiredText(value, "tool name", maxExtensionToolNameBytes)
  if (!/^[a-z][a-z0-9_]*$/.test(name)) {
    throw new ExtensionProtocolError("Extension tool names must start with a lowercase letter and use a-z, 0-9, or _")
  }
  return name
}

function jsonRecord(value: unknown, field: string, maxBytes: number): Readonly<Record<string, JsonValue>> {
  const admitted = jsonValue(value, field, maxBytes)
  if (!isProtocolRecord(admitted)) throw new ExtensionProtocolError(`Extension protocol ${field} must be an object`)
  return admitted
}

function jsonValue(value: unknown, field: string, maxBytes: number): JsonValue {
  let serialized: string | undefined
  try {
    serialized = JSON.stringify(value)
  } catch (cause) {
    throw new ExtensionProtocolError(`Extension protocol ${field} must be JSON`, { cause })
  }
  if (serialized === undefined || Buffer.byteLength(serialized) > maxBytes) {
    throw new ExtensionProtocolError(`Extension protocol ${field} cannot exceed ${maxBytes} bytes`)
  }
  const state = { nodes: 0 }
  return copyJsonValue(value, field, 0, state)
}

function copyJsonValue(value: unknown, field: string, depth: number, state: { nodes: number }): JsonValue {
  state.nodes++
  if (state.nodes > maxExtensionJsonNodes) {
    throw new ExtensionProtocolError(`Extension protocol ${field} cannot exceed ${maxExtensionJsonNodes} JSON nodes`)
  }
  if (depth > maxExtensionJsonDepth) {
    throw new ExtensionProtocolError(`Extension protocol ${field} cannot exceed depth ${maxExtensionJsonDepth}`)
  }
  if (value === null || typeof value === "string" || typeof value === "boolean") return value
  if (typeof value === "number") {
    if (!Number.isFinite(value)) throw new ExtensionProtocolError(`Extension protocol ${field} numbers must be finite`)
    return value
  }
  if (Array.isArray(value)) {
    return Object.freeze(value.map(item => copyJsonValue(item, field, depth + 1, state)))
  }
  if (isProtocolRecord(value)) {
    const entries = Object.entries(value).map(([key, item]) => {
      if (Buffer.byteLength(key) > maxExtensionJsonKeyBytes) {
        throw new ExtensionProtocolError(
          `Extension protocol ${field} object keys cannot exceed ${maxExtensionJsonKeyBytes} bytes`
        )
      }
      return [key, copyJsonValue(item, field, depth + 1, state)] as const
    })
    return Object.freeze(Object.fromEntries(entries))
  }
  throw new ExtensionProtocolError(`Extension protocol ${field} contains a non-JSON value`)
}

function extensionDiagnostic(value: unknown): ExtensionDiagnostic {
  const diagnostic = protocolRecord(value)
  const phase = diagnostic.phase
  if (
    phase !== "discovery" &&
    phase !== "trust" &&
    phase !== "spawn" &&
    phase !== "handshake" &&
    phase !== "resolve" &&
    phase !== "import" &&
    phase !== "factory" &&
    phase !== "registration" &&
    phase !== "lifecycle" &&
    phase !== "tool" &&
    phase !== "protocol" &&
    phase !== "shutdown"
  ) {
    throw new ExtensionProtocolError("Unknown extension diagnostic phase")
  }
  const severity = diagnostic.severity
  if (severity !== "warning" && severity !== "error") {
    throw new ExtensionProtocolError("Unknown extension diagnostic severity")
  }
  return Object.freeze({
    ...(diagnostic.extensionId === undefined
      ? {}
      : { extensionId: boundedRequiredText(diagnostic.extensionId, "extensionId", maxExtensionIdBytes) }),
    ...(diagnostic.path === undefined
      ? {}
      : { path: boundedRequiredText(diagnostic.path, "diagnostic path", maxExtensionPathBytes) }),
    phase,
    severity,
    message: boundedRequiredText(diagnostic.message, "diagnostic message", maxExtensionDiagnosticMessageBytes),
    ...(diagnostic.stack === undefined
      ? {}
      : { stack: boundedRequiredText(diagnostic.stack, "diagnostic stack", maxExtensionDiagnosticStackBytes) })
  })
}

function protocolRecord(value: unknown): Record<string, unknown> {
  if (!isProtocolRecord(value)) throw new ExtensionProtocolError("Extension protocol messages must be objects")
  return value
}

function isProtocolRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}

function protocolArray(value: unknown, field: string): readonly unknown[] {
  if (!Array.isArray(value)) throw new ExtensionProtocolError(`Extension protocol ${field} must be an array`)
  return value
}

function protocolVersion(value: unknown): 3 {
  if (value !== extensionProtocolVersion) throw new ExtensionProtocolError("Unsupported extension protocol version")
  return extensionProtocolVersion
}

function positiveInteger(value: unknown, field: string): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value <= 0) {
    throw new ExtensionProtocolError(`Extension protocol ${field} must be a positive safe integer`)
  }
  return value
}

function pathText(value: unknown, field: string): string {
  return boundedRequiredText(value, field, maxExtensionPathBytes)
}

function boundedString(value: unknown, field: string, maxBytes: number): string {
  if (typeof value !== "string" || Buffer.byteLength(value) > maxBytes) {
    throw new ExtensionProtocolError(`Extension protocol ${field} cannot exceed ${maxBytes} bytes`)
  }
  return value
}

function boundedRequiredText(value: unknown, field: string, maxBytes: number): string {
  if (typeof value !== "string" || value.length === 0 || Buffer.byteLength(value) > maxBytes) {
    throw new ExtensionProtocolError(`Extension protocol ${field} must contain 1 to ${maxBytes} bytes`)
  }
  return value
}

function boundedText(value: string, maxBytes: number): string {
  if (Buffer.byteLength(value) <= maxBytes) return value
  const buffer = Buffer.from(value)
  let end = maxBytes
  while (end > 0 && (buffer[end]! & 0xc0) === 0x80) end--
  return buffer.toString("utf8", 0, end)
}

function startReason(value: unknown): ExtensionStartReason {
  if (value !== "startup" && value !== "reload" && value !== "new" && value !== "resume" && value !== "fork") {
    throw new ExtensionProtocolError("Unknown extension start reason")
  }
  return value
}

function shutdownReason(value: unknown): ExtensionShutdownReason {
  if (value !== "quit" && value !== "reload" && value !== "new" && value !== "resume" && value !== "fork") {
    throw new ExtensionProtocolError("Unknown extension shutdown reason")
  }
  return value
}

function protocolError(cause: unknown): ExtensionProtocolError {
  if (cause instanceof ExtensionProtocolError) return cause
  return new ExtensionProtocolError(cause instanceof Error ? cause.message : String(cause), { cause })
}
