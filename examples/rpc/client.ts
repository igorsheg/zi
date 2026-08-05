import { resolve as resolvePath } from "node:path"

export const rpcClientProtocolVersion = 1 as const
export const maxRpcClientFrameBytes = 16 * 1024 * 1024
export const maxRpcClientPromptBytes = 8 * 1024 * 1024
export const maxRpcClientPendingRequests = 32
export const maxRpcClientPendingWriteBytes = 16 * 1024 * 1024
export const maxRpcClientStderrBytes = 64 * 1024
export const maxRpcClientMessagePages = 1024
export const rpcClientReadyTimeoutMs = 10_000
export const rpcClientRequestTimeoutMs = 5 * 60_000
export const rpcClientCloseTimeoutMs = 5_000

interface RpcClientOptions {
  readonly command: readonly string[]
  readonly cwd?: string
  readonly env?: Readonly<Record<string, string | undefined>>
  readonly signal?: AbortSignal
  readonly onEvent?: (event: Readonly<Record<string, unknown>>) => void
}

export interface RpcPromptClientOptions extends RpcClientOptions {
  readonly prompt: string
}

export interface RpcCommandClientOptions extends RpcClientOptions {
  readonly name: string
  readonly arguments: string
}

type ClientState =
  | { readonly type: "starting" }
  | { readonly type: "ready" }
  | { readonly type: "failed"; readonly error: Error }
  | { readonly type: "closing"; readonly settled: Promise<void> }
  | { readonly type: "closed" }

interface PendingRequest {
  readonly method: string
  readonly resolve: (value: unknown) => void
  readonly reject: (cause: unknown) => void
  readonly timeout: ReturnType<typeof setTimeout>
}

interface MessagePage {
  readonly start: number
  readonly total: number
  readonly nextStart: number | null
  readonly messages: readonly unknown[]
}

/** A copyable one-shot client that demonstrates the supported process contract without private Zi imports. */
export async function runRpcPrompt(options: RpcPromptClientOptions): Promise<string> {
  validatePromptOptions(options)
  const client = new RpcClient(options)
  try {
    await client.ready()
    await client.request("session.prompt", { delivery: "direct", text: options.prompt })
    await client.request("session.await_idle")
    return await client.lastAssistantText()
  } finally {
    await client.close()
  }
}

/** Invoke one admitted extension command without parsing slash text. */
export async function runRpcCommand(options: RpcCommandClientOptions): Promise<string | undefined> {
  validateCommandOptions(options)
  const client = new RpcClient(options)
  try {
    await client.ready()
    const catalog = await client.request("command.list")
    if (!commandCatalogContains(catalog, options.name)) {
      throw new Error(`RPC command catalog omitted ${options.name}`)
    }
    const result = await client.request("command.invoke", { name: options.name, arguments: options.arguments })
    if (!isRecord(result) || (result.message !== undefined && typeof result.message !== "string")) {
      throw new Error("RPC command invocation returned an invalid result")
    }
    return result.message
  } finally {
    await client.close()
  }
}

class RpcClient {
  readonly #child: Bun.Subprocess<"pipe", "pipe", "pipe">
  readonly #exited: Promise<number>
  readonly #onEvent: RpcClientOptions["onEvent"]
  readonly #ready = deferred<void>()
  readonly #removeAbort: () => void
  readonly #pending = new Map<string, PendingRequest>()
  readonly #stdoutSettlement: Promise<void>
  readonly #stderrSettlement: Promise<void>
  #state: ClientState = { type: "starting" }
  #nextRequestId = 0
  #nextSequence = 1
  #writeTail = Promise.resolve()
  #pendingWriteBytes = 0
  #stderr = ""

  constructor(options: RpcClientOptions) {
    this.#onEvent = options.onEvent
    this.#child = Bun.spawn([...options.command, "--mode", "rpc"], {
      ...(options.cwd ? { cwd: options.cwd } : {}),
      ...(options.env ? { env: options.env } : {}),
      stdin: "pipe",
      stdout: "pipe",
      stderr: "pipe",
      windowsHide: true
    })
    // Bun's exited accessor can touch released OS handles, so capture it before shutdown starts.
    this.#exited = this.#child.exited
    this.#stdoutSettlement = this.#consumeStdout().catch(cause => this.#fail(cause))
    this.#stderrSettlement = this.#consumeStderr().catch(cause => this.#fail(cause))
    this.#removeAbort = listenForAbort(options.signal, () => this.#fail(new Error("RPC client was cancelled")))
  }

  async ready(): Promise<void> {
    const reached = await settleWithin(this.#ready.promise, rpcClientReadyTimeoutMs)
    if (!reached) {
      const error = new Error(`Zi RPC did not become ready within ${rpcClientReadyTimeoutMs}ms`)
      this.#fail(error)
      throw error
    }
  }

  request(method: string, params?: Readonly<Record<string, unknown>>): Promise<unknown> {
    if (this.#state.type !== "ready") throw this.#notReadyError()
    if (this.#pending.size >= maxRpcClientPendingRequests) {
      throw new Error(`RPC client accepts at most ${maxRpcClientPendingRequests} pending requests`)
    }

    const id = String(++this.#nextRequestId)
    const line = `${JSON.stringify({ version: rpcClientProtocolVersion, id, method, ...(params ? { params } : {}) })}\n`
    const bytes = Buffer.byteLength(line)
    if (bytes > maxRpcClientFrameBytes)
      throw new Error(`RPC client requests cannot exceed ${maxRpcClientFrameBytes} bytes`)
    if (this.#pendingWriteBytes + bytes > maxRpcClientPendingWriteBytes) {
      throw new Error(`RPC client pending writes cannot exceed ${maxRpcClientPendingWriteBytes} bytes`)
    }

    const settlement = deferred<unknown>()
    const timeout = setTimeout(() => {
      const pending = this.#pending.get(id)
      if (!pending) return
      this.#pending.delete(id)
      const error = new Error(`RPC request ${method} did not settle within ${rpcClientRequestTimeoutMs}ms`)
      pending.reject(error)
      this.#fail(error)
    }, rpcClientRequestTimeoutMs)
    this.#pending.set(id, { method, resolve: settlement.resolve, reject: settlement.reject, timeout })
    this.#enqueueWrite(line, bytes)
    return settlement.promise
  }

  async lastAssistantText(): Promise<string> {
    let start = 0
    let latest: { readonly text: string; readonly stopReason: string; readonly error?: string } | undefined

    for (let pageIndex = 0; pageIndex < maxRpcClientMessagePages; pageIndex++) {
      // Pages are intentionally sequential so one total/next cursor owns the snapshot walk.
      // oxlint-disable-next-line no-await-in-loop
      const result = await this.request("session.get_messages", { start, limit: 100 })
      const page = messagePage(result)
      for (const message of page.messages) {
        const assistant = assistantText(message)
        if (assistant) latest = assistant
      }
      if (page.nextStart === null) {
        if (!latest) throw new Error("RPC session completed without an assistant message")
        if (latest.stopReason === "error" || latest.stopReason === "aborted") {
          throw new Error(latest.error ?? `RPC assistant stopped with ${latest.stopReason}`)
        }
        return latest.text
      }
      if (page.nextStart <= start) throw new Error("RPC message pagination did not advance")
      start = page.nextStart
    }
    throw new Error(`RPC message pagination cannot exceed ${maxRpcClientMessagePages} pages`)
  }

  close(): Promise<void> {
    const state = this.#state
    if (state.type === "closed") return Promise.resolve()
    if (state.type === "closing") return state.settled
    const ignoreExitFailure = state.type === "failed"
    const settled = Promise.resolve().then(() => this.#closeConnection(ignoreExitFailure))
    this.#state = { type: "closing", settled }
    return settled
  }

  async #consumeStdout(): Promise<void> {
    const reader = this.#child.stdout.getReader()
    const decoder = new JsonLineDecoder()
    try {
      while (true) {
        // One reader owns frame order and the connection byte bound.
        // oxlint-disable-next-line no-await-in-loop
        const next = await reader.read()
        if (next.done) break
        for (const line of decoder.push(next.value)) this.#receive(line)
      }
      for (const line of decoder.finish()) this.#receive(line)
      if (this.#state.type === "starting" || this.#state.type === "ready") {
        throw new Error("Zi RPC stdout closed before the client")
      }
    } finally {
      reader.releaseLock()
    }
  }

  async #consumeStderr(): Promise<void> {
    const reader = this.#child.stderr.getReader()
    const decoder = new TextDecoder("utf-8", { fatal: true })
    let bytes = 0
    try {
      while (true) {
        // One reader owns the bounded diagnostic tail.
        // oxlint-disable-next-line no-await-in-loop
        const next = await reader.read()
        if (next.done) break
        bytes += next.value.byteLength
        if (bytes > maxRpcClientStderrBytes) {
          throw new Error(`Zi RPC stderr cannot exceed ${maxRpcClientStderrBytes} bytes`)
        }
        this.#stderr += decoder.decode(next.value, { stream: true })
      }
      this.#stderr += decoder.decode()
    } catch (cause) {
      if (cause instanceof TypeError) throw new Error("Zi RPC stderr must be valid UTF-8", { cause })
      throw cause
    } finally {
      reader.releaseLock()
    }
  }

  #receive(line: string): void {
    let frame: unknown
    try {
      frame = JSON.parse(line)
    } catch {
      throw new Error("Zi RPC emitted invalid JSONL")
    }
    if (!isRecord(frame) || frame.version !== 1 || !Number.isSafeInteger(frame.sequence)) {
      throw new Error("Zi RPC emitted an invalid server frame")
    }
    if (frame.sequence !== this.#nextSequence) {
      throw new Error(`RPC server sequence gap: expected ${this.#nextSequence}, received ${String(frame.sequence)}`)
    }
    this.#nextSequence++

    switch (frame.type) {
      case "ready":
        if (this.#state.type !== "starting" || !isRecord(frame.state)) {
          throw new Error("Zi RPC emitted an invalid ready transition")
        }
        this.#state = { type: "ready" }
        this.#ready.resolve()
        return
      case "session_event":
        if (this.#state.type !== "ready" || !isRecord(frame.event)) {
          throw new Error("Zi RPC emitted an invalid session event")
        }
        this.#onEvent?.(frame.event)
        return
      case "response":
        this.#receiveResponse(frame)
        return
      case "protocol_error":
        throw new Error(
          `Zi RPC rejected the reference client request: ${typeof frame.message === "string" ? frame.message : "protocol error"}`
        )
      default:
        throw new Error(`Zi RPC emitted an unknown frame type: ${String(frame.type)}`)
    }
  }

  #receiveResponse(frame: Record<string, unknown>): void {
    if (this.#state.type !== "ready" || typeof frame.id !== "string" || typeof frame.method !== "string") {
      throw new Error("Zi RPC emitted an invalid response")
    }
    const pending = this.#pending.get(frame.id)
    if (!pending) throw new Error(`Zi RPC responded to unknown request ${frame.id}`)
    if (pending.method !== frame.method) {
      throw new Error(`Zi RPC response method mismatch: expected ${pending.method}, received ${frame.method}`)
    }
    clearTimeout(pending.timeout)
    this.#pending.delete(frame.id)
    if (frame.ok === true) {
      pending.resolve(frame.result)
      return
    }
    if (frame.ok !== false || !isRecord(frame.error) || typeof frame.error.message !== "string") {
      throw new Error("Zi RPC emitted an invalid failure response")
    }
    pending.reject(new Error(frame.error.message))
  }

  #enqueueWrite(line: string, bytes: number): void {
    this.#pendingWriteBytes += bytes
    const write = this.#writeTail.then(async () => {
      if (this.#state.type !== "ready") throw this.#notReadyError()
      await this.#child.stdin.write(line)
      await this.#child.stdin.flush()
      return undefined
    })
    this.#writeTail = write.then(
      () => {
        this.#pendingWriteBytes -= bytes
        return undefined
      },
      cause => {
        this.#pendingWriteBytes -= bytes
        this.#fail(cause)
        return undefined
      }
    )
  }

  async #closeConnection(ignoreExitFailure: boolean): Promise<void> {
    this.#removeAbort()
    this.#rejectPending(new Error("RPC client closed"))
    const gracefulEndsAt = Date.now() + rpcClientCloseTimeoutMs
    await settleWithin(
      Promise.allSettled([this.#writeTail]).then(() => undefined),
      remainingMs(gracefulEndsAt)
    )
    await settleWithin(
      Promise.resolve()
        .then(() => this.#child.stdin.end())
        .then(() => undefined)
        .catch(() => undefined),
      remainingMs(gracefulEndsAt)
    )
    let forced = false
    let exitCode = await settleValueWithin(this.#exited, remainingMs(gracefulEndsAt))
    const forceEndsAt = Date.now() + rpcClientCloseTimeoutMs
    if (exitCode === timeoutValue) {
      forced = true
      try {
        this.#child.kill("SIGKILL")
      } catch {
        // The process exited at the force boundary.
      }
      exitCode = await settleValueWithin(this.#exited, remainingMs(forceEndsAt))
    }
    const streamsSettled = await settleWithin(
      Promise.allSettled([this.#stdoutSettlement, this.#stderrSettlement]).then(() => undefined),
      remainingMs(forceEndsAt)
    )
    this.#state = { type: "closed" }

    if (exitCode === timeoutValue) throw new Error(`Zi RPC did not exit within ${rpcClientCloseTimeoutMs}ms`)
    if (!streamsSettled) throw new Error(`Zi RPC output did not settle within ${rpcClientCloseTimeoutMs}ms`)
    if (typeof exitCode !== "number") throw new Error("Zi RPC returned an invalid exit status")
    const forceKilled = forced && this.#child.signalCode === "SIGKILL"
    if (!ignoreExitFailure && !forceKilled && exitCode !== 0) {
      const detail = this.#stderr.trim()
      throw new Error(`Zi RPC exited with ${exitCode}${detail ? `: ${detail}` : ""}`)
    }
  }

  #fail(cause: unknown): void {
    if (this.#state.type === "failed" || this.#state.type === "closing" || this.#state.type === "closed") return
    const error = cause instanceof Error ? cause : new Error("Zi RPC client failed")
    const wasStarting = this.#state.type === "starting"
    this.#state = { type: "failed", error }
    if (wasStarting) this.#ready.reject(error)
    this.#rejectPending(error)
    try {
      this.#child.kill("SIGKILL")
    } catch {}
  }

  #rejectPending(cause: Error): void {
    for (const pending of this.#pending.values()) {
      clearTimeout(pending.timeout)
      pending.reject(cause)
    }
    this.#pending.clear()
  }

  #notReadyError(): Error {
    return this.#state.type === "failed" ? this.#state.error : new Error(`RPC client is ${this.#state.type}`)
  }
}

class JsonLineDecoder {
  readonly #decoder = new TextDecoder("utf-8", { fatal: true })
  #buffer = ""
  #bufferBytes = 0

  push(chunk: Uint8Array): string[] {
    try {
      this.#buffer += this.#decoder.decode(chunk, { stream: true })
    } catch {
      throw new Error("Zi RPC stdout must be valid UTF-8")
    }
    this.#bufferBytes += chunk.byteLength
    return this.#takeLines()
  }

  finish(): string[] {
    try {
      this.#buffer += this.#decoder.decode()
    } catch {
      throw new Error("Zi RPC stdout must be valid UTF-8")
    }
    const lines = this.#takeLines()
    if (this.#buffer.length > 0) lines.push(this.#takeFinalLine())
    return lines
  }

  #takeLines(): string[] {
    const lines: string[] = []
    while (true) {
      const newline = this.#buffer.indexOf("\n")
      if (newline === -1) break
      const line = this.#buffer.slice(0, newline)
      const bytes = Buffer.byteLength(line)
      if (bytes > maxRpcClientFrameBytes) throw new Error(`Zi RPC frames cannot exceed ${maxRpcClientFrameBytes} bytes`)
      lines.push(line.endsWith("\r") ? line.slice(0, -1) : line)
      this.#buffer = this.#buffer.slice(newline + 1)
      this.#bufferBytes -= bytes + 1
    }
    if (this.#bufferBytes > maxRpcClientFrameBytes) {
      throw new Error(`Zi RPC frames cannot exceed ${maxRpcClientFrameBytes} bytes`)
    }
    return lines
  }

  #takeFinalLine(): string {
    if (this.#bufferBytes > maxRpcClientFrameBytes) {
      throw new Error(`Zi RPC frames cannot exceed ${maxRpcClientFrameBytes} bytes`)
    }
    const line = this.#buffer.endsWith("\r") ? this.#buffer.slice(0, -1) : this.#buffer
    this.#buffer = ""
    this.#bufferBytes = 0
    return line
  }
}

function messagePage(value: unknown): MessagePage {
  if (
    !isRecord(value) ||
    !isNonNegativeInteger(value.start) ||
    !isNonNegativeInteger(value.total) ||
    (value.nextStart !== null && !isNonNegativeInteger(value.nextStart)) ||
    !Array.isArray(value.messages)
  ) {
    throw new Error("Zi RPC emitted an invalid message page")
  }
  return { start: value.start, total: value.total, nextStart: value.nextStart, messages: value.messages }
}

function assistantText(
  value: unknown
): { readonly text: string; readonly stopReason: string; readonly error?: string } | undefined {
  if (!isRecord(value) || value.role !== "assistant" || !Array.isArray(value.content)) return undefined
  let text = ""
  let textBytes = 0
  for (const part of value.content) {
    if (!isRecord(part) || part.type !== "text" || typeof part.text !== "string") continue
    text += part.text
    textBytes += Buffer.byteLength(part.text)
    if (textBytes > maxRpcClientPromptBytes) {
      throw new Error(`RPC assistant text cannot exceed ${maxRpcClientPromptBytes} bytes`)
    }
  }
  return {
    text,
    stopReason: typeof value.stopReason === "string" ? value.stopReason : "unknown",
    ...(typeof value.errorMessage === "string" ? { error: value.errorMessage } : {})
  }
}

function validatePromptOptions(options: RpcPromptClientOptions): void {
  validateClientOptions(options)
  if (typeof options.prompt !== "string" || Buffer.byteLength(options.prompt) > maxRpcClientPromptBytes) {
    throw new Error(`RPC client prompt cannot exceed ${maxRpcClientPromptBytes} bytes`)
  }
}

function validateCommandOptions(options: RpcCommandClientOptions): void {
  validateClientOptions(options)
  if (typeof options.name !== "string" || !/^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$/.test(options.name)) {
    throw new Error("RPC command name must use lowercase kebab-case")
  }
  if (Buffer.byteLength(options.name) > 64) throw new Error("RPC command name cannot exceed 64 bytes")
  if (typeof options.arguments !== "string" || Buffer.byteLength(options.arguments) > 256 * 1024) {
    throw new Error("RPC command arguments cannot exceed 262144 bytes")
  }
}

function validateClientOptions(options: RpcClientOptions): void {
  if (
    options.command.length === 0 ||
    options.command.length > 128 ||
    options.command.some(part => typeof part !== "string" || part.length === 0)
  ) {
    throw new Error("RPC client command must contain from 1 through 128 non-empty arguments")
  }
  if (Buffer.byteLength(options.command.join("\0")) > 64 * 1024) {
    throw new Error("RPC client command cannot exceed 65536 bytes")
  }
}

function commandCatalogContains(value: unknown, name: string): boolean {
  if (!isRecord(value) || !Array.isArray(value.commands)) throw new Error("RPC command catalog is invalid")
  return value.commands.some(command => isRecord(command) && command.name === name)
}

async function settleWithin(operation: Promise<void>, timeoutMs: number): Promise<boolean> {
  return (
    (await settleValueWithin(
      operation.then(() => true),
      timeoutMs
    )) !== timeoutValue
  )
}

function settleValueWithin<T>(operation: Promise<T>, timeoutMs: number): Promise<T | typeof timeoutValue> {
  let timeout: ReturnType<typeof setTimeout> | undefined
  return Promise.race([
    operation,
    new Promise<typeof timeoutValue>(resolveTimeout => {
      timeout = setTimeout(() => resolveTimeout(timeoutValue), timeoutMs)
    })
  ]).finally(() => {
    if (timeout) clearTimeout(timeout)
  })
}

function remainingMs(endsAt: number): number {
  return Math.max(0, endsAt - Date.now())
}

function listenForAbort(signal: AbortSignal | undefined, listener: () => void): () => void {
  if (!signal) return () => {}
  if (signal.aborted) {
    listener()
    return () => {}
  }
  signal.addEventListener("abort", listener, { once: true })
  return () => signal.removeEventListener("abort", listener)
}

function isNonNegativeInteger(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}

function deferred<T>() {
  let resolve!: (value: T | PromiseLike<T>) => void
  let reject!: (cause?: unknown) => void
  const promise = new Promise<T>((resolvePromise, rejectPromise) => {
    resolve = resolvePromise
    reject = rejectPromise
  })
  return { promise, resolve, reject }
}

const timeoutValue: unique symbol = Symbol("timeout")

if (import.meta.main) {
  const prompt = process.argv.slice(2).join(" ").trim()
  if (!prompt) throw new Error("Usage: bun examples/rpc/client.ts <prompt>")
  const executable = Bun.which("zi") ?? "zi"
  const result = await runRpcPrompt({
    command: [executable, "--no-session", "--cwd", resolvePath(process.cwd())],
    prompt,
    cwd: process.cwd(),
    env: process.env
  })
  await Bun.stdout.write(`${result}\n`)
}
