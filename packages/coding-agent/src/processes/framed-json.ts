import type { Writable } from "node:stream"

export interface FramedJsonLimits {
  readonly maxFrameBytes: number
  readonly maxQueuedFrames: number
  readonly maxQueuedBytes: number
}

export class FramedJsonError extends Error {
  constructor(message: string, options?: ErrorOptions) {
    super(message, options)
    this.name = "FramedJsonError"
  }
}

type DecoderState =
  | { readonly type: "open" }
  | { readonly type: "failed"; readonly error: Error }
  | { readonly type: "ended" }

export class FramedJsonDecoder<T> {
  readonly #validate: (value: unknown) => T
  readonly #limits: FramedJsonLimits
  readonly #protocol: string
  #state: DecoderState = { type: "open" }
  #buffer = Buffer.alloc(0)

  constructor(validate: (value: unknown) => T, limits: FramedJsonLimits, protocol: string) {
    this.#validate = validate
    this.#limits = limits
    this.#protocol = protocol
  }

  push(chunk: Uint8Array): readonly T[] {
    if (this.#state.type === "failed") throw this.#state.error
    if (this.#state.type === "ended") {
      throw new FramedJsonError(`Cannot decode after ${this.#protocol} input ended`)
    }
    if (chunk.byteLength === 0) return []

    try {
      const incoming = Buffer.from(chunk.buffer, chunk.byteOffset, chunk.byteLength)
      const data = this.#buffer.byteLength === 0 ? incoming : Buffer.concat([this.#buffer, incoming])
      const messages: T[] = []
      let offset = 0

      while (data.byteLength - offset >= 4) {
        const length = data.readUInt32BE(offset)
        if (length === 0 || length > this.#limits.maxFrameBytes) {
          throw new FramedJsonError(`${this.#protocol} frames must contain 1 to ${this.#limits.maxFrameBytes} bytes`)
        }
        if (data.byteLength - offset - 4 < length) break
        const payload = data.subarray(offset + 4, offset + 4 + length)
        messages.push(this.#validate(parsePayload(payload, this.#protocol)))
        offset += 4 + length
      }

      this.#buffer = offset === data.byteLength ? Buffer.alloc(0) : Buffer.from(data.subarray(offset))
      return messages
    } catch (cause) {
      const error = asError(cause, this.#protocol)
      this.#state = { type: "failed", error }
      this.#buffer = Buffer.alloc(0)
      throw error
    }
  }

  end(): void {
    if (this.#state.type === "failed") throw this.#state.error
    if (this.#state.type === "ended") return
    if (this.#buffer.byteLength !== 0) {
      const error = new FramedJsonError(`${this.#protocol} input ended with a partial frame`)
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
  | { readonly type: "failed"; readonly error: FramedJsonError }
  | { readonly type: "disposed" }

export class FramedJsonWriter<T> {
  readonly #sink: Writable
  readonly #limits: FramedJsonLimits
  readonly #protocol: string
  readonly #queue: QueuedFrame[] = []
  readonly #onError: (cause: Error) => void
  readonly #onFailure: ((cause: Error) => void) | undefined
  #state: WriterState = { type: "idle" }
  #queuedBytes = 0

  constructor(sink: Writable, limits: FramedJsonLimits, protocol: string, onFailure?: (cause: Error) => void) {
    this.#sink = sink
    this.#limits = limits
    this.#protocol = protocol
    this.#onFailure = onFailure
    this.#onError = cause => this.#fail(cause)
    sink.on("error", this.#onError)
  }

  send(value: T): Promise<void> {
    if (this.#state.type === "failed") return Promise.reject(this.#state.error)
    if (this.#state.type === "disposed") {
      return Promise.reject(new FramedJsonError(`${this.#protocol} writer is disposed`))
    }

    let frame: Buffer
    try {
      frame = encodeFramedJson(value, this.#limits, this.#protocol)
    } catch (cause) {
      return Promise.reject(cause)
    }

    const count = this.#queue.length + (this.#state.type === "writing" ? 1 : 0)
    if (count >= this.#limits.maxQueuedFrames) {
      return Promise.reject(
        new FramedJsonError(`${this.#protocol} output queue cannot exceed ${this.#limits.maxQueuedFrames} frames`)
      )
    }
    if (frame.byteLength > this.#limits.maxQueuedBytes - this.#queuedBytes) {
      return Promise.reject(
        new FramedJsonError(`${this.#protocol} output queue cannot exceed ${this.#limits.maxQueuedBytes} bytes`)
      )
    }

    const promise = new Promise<void>((resolve, reject) => this.#queue.push({ frame, resolve, reject }))
    this.#queuedBytes += frame.byteLength
    if (this.#state.type === "idle") this.#writeNext()
    return promise
  }

  fail(cause: unknown): void {
    this.#fail(cause)
  }

  dispose(): void {
    if (this.#state.type === "disposed") return
    const error = new FramedJsonError(`${this.#protocol} writer disposed before output settled`)
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
    const error = asFramedJsonError(cause, this.#protocol)
    const current = this.#state.type === "writing" ? this.#state.current : undefined
    this.#state = { type: "failed", error }
    current?.reject(error)
    for (const frame of this.#queue.splice(0)) frame.reject(error)
    this.#queuedBytes = 0
    this.#onFailure?.(error)
  }
}

export function encodeFramedJson(value: unknown, limits: FramedJsonLimits, protocol: string): Buffer {
  let json: string | undefined
  try {
    json = JSON.stringify(value)
  } catch (cause) {
    throw new FramedJsonError(`${protocol} message could not be serialized`, { cause })
  }
  if (json === undefined) throw new FramedJsonError(`${protocol} messages must be JSON values`)

  const payload = Buffer.from(json)
  if (payload.byteLength === 0 || payload.byteLength > limits.maxFrameBytes) {
    throw new FramedJsonError(`${protocol} frames must contain 1 to ${limits.maxFrameBytes} bytes`)
  }
  const frame = Buffer.allocUnsafe(4 + payload.byteLength)
  frame.writeUInt32BE(payload.byteLength, 0)
  payload.copy(frame, 4)
  return frame
}

function parsePayload(payload: Uint8Array, protocol: string): unknown {
  let text: string
  try {
    text = new TextDecoder("utf-8", { fatal: true }).decode(payload)
  } catch (cause) {
    throw new FramedJsonError(`${protocol} payload is not valid UTF-8`, { cause })
  }
  try {
    return JSON.parse(text)
  } catch (cause) {
    throw new FramedJsonError(`${protocol} payload is not valid JSON`, { cause })
  }
}

function asError(cause: unknown, protocol: string): Error {
  return cause instanceof Error
    ? cause
    : new FramedJsonError(`${protocol} decoding failed: ${String(cause)}`, { cause })
}

function asFramedJsonError(cause: unknown, protocol: string): FramedJsonError {
  return cause instanceof FramedJsonError
    ? cause
    : new FramedJsonError(cause instanceof Error ? cause.message : `${protocol} output failed`, { cause })
}
