import { StreamableHTTPClientTransport, type FetchLike, type ReconnectionScheduler } from "@modelcontextprotocol/client"

import { maxMcpHttpHeaderBytes, type McpResolvedHttpServer } from "./config.js"

export const maxMcpHttpBodyBytes = 1024 * 1024
export const maxMcpSseLineBytes = 64 * 1024
export const maxMcpSseEventBytes = 1024 * 1024
export const minMcpSseRetryMs = 100
export const maxMcpSseRetryMs = 5_000
export const maxMcpSseRetries = 2

type McpHttpFailure = "network" | "headers" | "body" | "sse_line" | "sse_event"

export type McpHttpStreamEvidence =
  | { readonly type: "transient"; readonly message: string }
  | { readonly type: "terminal"; readonly message: string }
  | { readonly type: "retry_exhausted"; readonly message: string }

export class McpHttpTransportError extends Error {
  readonly failure: McpHttpFailure

  constructor(failure: McpHttpFailure) {
    super(httpFailureMessage(failure))
    this.name = "McpHttpTransportError"
    this.failure = failure
  }
}

export function mcpHttpStreamEvidence(error: Error): McpHttpStreamEvidence {
  const message = clipHttpMessage(error.message)
  if (error.message === `Maximum reconnection attempts (${maxMcpSseRetries}) exceeded.`) {
    return Object.freeze({ type: "retry_exhausted", message })
  }
  if (
    error.message.includes(httpFailureMessage("body")) ||
    error.message.includes(httpFailureMessage("sse_line")) ||
    error.message.includes(httpFailureMessage("sse_event"))
  ) {
    return Object.freeze({ type: "terminal", message })
  }
  return Object.freeze({ type: "transient", message })
}

export class OwnedHttpTransport {
  readonly transport: StreamableHTTPClientTransport
  readonly #scheduler = new ReconnectionTimerOwner()
  #closed = false

  constructor(plan: McpResolvedHttpServer, fetch_: typeof fetch = globalThis.fetch) {
    this.transport = new StreamableHTTPClientTransport(new URL(plan.url), {
      requestInit: { headers: plan.headers },
      fetch: boundedFetch(fetch_),
      reconnectionOptions: {
        initialReconnectionDelay: minMcpSseRetryMs,
        maxReconnectionDelay: maxMcpSseRetryMs,
        reconnectionDelayGrowFactor: 2,
        maxRetries: maxMcpSseRetries
      },
      reconnectionScheduler: this.#scheduler.schedule
    })
  }

  close(): Promise<void> {
    if (this.#closed) return Promise.resolve()
    this.#closed = true
    this.#scheduler.dispose()
    return this.transport.close()
  }
}

class ReconnectionTimerOwner {
  readonly #timers = new Set<ReturnType<typeof setTimeout>>()
  #disposed = false

  readonly schedule: ReconnectionScheduler = (reconnect, delay, attemptCount) => {
    if (this.#disposed || attemptCount >= maxMcpSseRetries) return undefined
    const boundedDelay = clampRetry(delay)
    const timer = setTimeout(() => {
      this.#timers.delete(timer)
      if (!this.#disposed) reconnect()
    }, boundedDelay)
    timer.unref?.()
    this.#timers.add(timer)
    return () => {
      if (this.#timers.delete(timer)) clearTimeout(timer)
    }
  }

  dispose(): void {
    if (this.#disposed) return
    this.#disposed = true
    for (const timer of this.#timers) clearTimeout(timer)
    this.#timers.clear()
  }
}

function boundedFetch(fetch_: typeof fetch): FetchLike {
  return async (url, init) => {
    let response: Response
    try {
      response = await fetch_(url, init)
    } catch (cause) {
      if (init?.signal?.aborted) throw cause
      throw new McpHttpTransportError("network")
    }

    if (responseHeaderBytes(response.headers) > maxMcpHttpHeaderBytes) {
      await response.body?.cancel().catch(() => undefined)
      throw new McpHttpTransportError("headers")
    }
    if (!response.body) return response

    const contentType = response.headers.get("content-type")?.toLowerCase()
    const bounded = contentType?.startsWith("text/event-stream")
      ? response.body.pipeThrough(sseBounds())
      : response.body.pipeThrough(bodyBounds())
    return new Response(captureStreamErrors(bounded), {
      status: response.status,
      statusText: response.statusText,
      headers: response.headers
    })
  }
}

function captureStreamErrors(stream: ReadableStream<Uint8Array>): ReadableStream<Uint8Array> {
  const reader = stream.getReader()
  return new ReadableStream({
    async pull(controller) {
      try {
        const next = await reader.read()
        if (next.done) controller.close()
        else controller.enqueue(next.value)
      } catch (cause) {
        controller.error(cause instanceof McpHttpTransportError ? cause : new McpHttpTransportError("network"))
      }
    },
    cancel(reason) {
      return reader.cancel(reason)
    }
  })
}

function responseHeaderBytes(headers: Headers): number {
  let bytes = 0
  for (const [name, value] of headers) bytes += Buffer.byteLength(name) + Buffer.byteLength(value) + 4
  return bytes
}

function bodyBounds(): TransformStream<Uint8Array, Uint8Array> {
  let bytes = 0
  return new TransformStream({
    transform(chunk, controller) {
      bytes += chunk.byteLength
      if (bytes > maxMcpHttpBodyBytes) {
        controller.error(new McpHttpTransportError("body"))
        return
      }
      controller.enqueue(chunk)
    }
  })
}

function sseBounds(): TransformStream<Uint8Array, Uint8Array> {
  let line: number[] = []
  let eventBytes = 0
  let pendingCr = false

  const emitLine = (ending: Uint8Array, controller: TransformStreamDefaultController<Uint8Array>): void => {
    eventBytes += line.length + ending.byteLength
    if (eventBytes > maxMcpSseEventBytes) throw new McpHttpTransportError("sse_event")
    const blank = line.length === 0
    controller.enqueue(rewriteRetry(Uint8Array.from(line)))
    if (ending.byteLength > 0) controller.enqueue(ending)
    line = []
    if (blank) eventBytes = 0
  }

  const append = (byte: number): void => {
    line.push(byte)
    if (line.length > maxMcpSseLineBytes) throw new McpHttpTransportError("sse_line")
  }

  return new TransformStream({
    transform(chunk, controller) {
      try {
        for (const byte of chunk) {
          if (pendingCr) {
            pendingCr = false
            if (byte === 10) {
              emitLine(crlf, controller)
              continue
            }
            emitLine(cr, controller)
          }
          if (byte === 13) {
            pendingCr = true
          } else if (byte === 10) {
            emitLine(lf, controller)
          } else {
            append(byte)
          }
        }
      } catch (cause) {
        controller.error(cause)
      }
    },
    flush(controller) {
      try {
        if (pendingCr) emitLine(cr, controller)
        else if (line.length > 0) emitLine(empty, controller)
      } catch (cause) {
        controller.error(cause)
      }
    }
  })
}

const empty = new Uint8Array()
const lf = Uint8Array.of(10)
const cr = Uint8Array.of(13)
const crlf = Uint8Array.of(13, 10)
const retryPrefix = new TextEncoder().encode("retry:")

function rewriteRetry(line: Uint8Array): Uint8Array {
  if (line.byteLength < retryPrefix.byteLength) return line
  for (let index = 0; index < retryPrefix.byteLength; index++) {
    if (line[index] !== retryPrefix[index]) return line
  }
  const value = new TextDecoder().decode(line.subarray(retryPrefix.byteLength)).trim()
  if (!/^\d+$/.test(value)) return line
  const parsed = Number(value)
  return new TextEncoder().encode(`retry: ${clampRetry(parsed)}`)
}

function clampRetry(delay: number): number {
  if (!Number.isFinite(delay)) return maxMcpSseRetryMs
  return Math.min(maxMcpSseRetryMs, Math.max(minMcpSseRetryMs, Math.trunc(delay)))
}

function clipHttpMessage(message: string): string {
  const safe = message.replace(/https?:\/\/\S+/giu, "[endpoint]")
  if (Buffer.byteLength(safe) <= maxMcpSseLineBytes) return safe
  return Buffer.from(safe)
    .subarray(0, maxMcpSseLineBytes)
    .toString("utf8")
    .replace(/\uFFFD$/u, "")
}

function httpFailureMessage(failure: McpHttpFailure): string {
  switch (failure) {
    case "network":
      return "MCP HTTP request failed"
    case "headers":
      return `MCP HTTP response headers exceed ${maxMcpHttpHeaderBytes} bytes`
    case "body":
      return `MCP HTTP response body exceeds ${maxMcpHttpBodyBytes} bytes`
    case "sse_line":
      return `MCP SSE line exceeds ${maxMcpSseLineBytes} bytes`
    case "sse_event":
      return `MCP SSE event exceeds ${maxMcpSseEventBytes} bytes`
    default:
      return assertNever(failure)
  }
}

function assertNever(value: never): never {
  throw new Error(`Unknown MCP HTTP failure: ${String(value)}`)
}
