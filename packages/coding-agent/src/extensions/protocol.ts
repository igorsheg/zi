import { isAbsolute } from "node:path"
import type { Writable } from "node:stream"

import type { ExtensionShutdownReason, ExtensionStartReason } from "@with-zi/extension-api"

import {
  maxExtensionPathBytes,
  maxExtensionSources,
  type ExtensionLoadPlan,
  type ExtensionSource
} from "./discovery.js"

export const extensionProtocolVersion = 1
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
    | "lifecycle"
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
      readonly protocolVersion: 1
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
  | { readonly type: "stop"; readonly generation: number; readonly requestId: number }
  | { readonly type: "cancel"; readonly generation: number; readonly requestId: number }

export type WorkerMessage =
  | {
      readonly type: "ready"
      readonly protocolVersion: 1
      readonly generation: number
      readonly extensions: readonly ExtensionLoadResult[]
    }
  | { readonly type: "settled"; readonly generation: number; readonly requestId: number }
  | { readonly type: "diagnostic"; readonly generation: number; readonly diagnostic: ExtensionDiagnostic }
  | { readonly type: "fatal"; readonly generation: number; readonly diagnostic: ExtensionDiagnostic }

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
    case "stop":
    case "cancel":
      return Object.freeze({
        type: message.type,
        generation: positiveInteger(message.generation, "generation"),
        requestId: positiveInteger(message.requestId, "requestId")
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
      return Object.freeze({
        type: "ready",
        protocolVersion: protocolVersion(message.protocolVersion),
        generation: positiveInteger(message.generation, "generation"),
        extensions: Object.freeze(extensions.map(extensionLoadResult))
      })
    }
    case "settled":
      return Object.freeze({
        type: "settled",
        generation: positiveInteger(message.generation, "generation"),
        requestId: positiveInteger(message.requestId, "requestId")
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
    phase !== "lifecycle" &&
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

function protocolVersion(value: unknown): 1 {
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
