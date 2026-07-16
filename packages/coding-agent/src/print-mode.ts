import type { AgentMessage } from "@earendil-works/pi-agent-core"

import type { AgentSession, AgentSessionEvent } from "./agent-session.js"
import type { SessionHeader } from "./session-manager.js"

export const maxPrintPromptCount = 128
export const maxPrintPromptBytes = 8 * 1024 * 1024
export const maxPrintOutputBytes = 8 * 1024 * 1024
export const maxPrintOutputChunks = 1024
export const maxJsonlRecordBytes = 16 * 1024 * 1024
export const maxPendingJsonlBytes = 32 * 1024 * 1024
export const maxPendingJsonlRecords = 1024

export interface PrintWriter {
  write(chunk: string): void | Promise<void>
}

export interface PrintModeOptions {
  readonly output: "text" | "json"
  readonly prompts: readonly string[]
  readonly writer: PrintWriter
}

export type PrintModeResult =
  | { readonly type: "success" }
  | { readonly type: "provider_error"; readonly message: string }
  | { readonly type: "aborted"; readonly message: string }
  | { readonly type: "missing_model"; readonly message: string }
  | { readonly type: "invalid_input"; readonly message: string }
  | { readonly type: "output_error"; readonly message: string }

export async function runPrintMode(session: AgentSession, options: PrintModeOptions): Promise<PrintModeResult> {
  const invalid = validateInput(options)
  if (invalid) return invalid
  if (session.modelState.type === "unselected") {
    return { type: "missing_model", message: "No model selected. Use /login, then /model." }
  }

  const jsonl =
    options.output === "json"
      ? new JsonlSink(options.writer, () => {
          try {
            void session.abort().catch(() => {})
          } catch {}
        })
      : undefined
  jsonl?.enqueue(session.sessionManager.header)
  const headerFailure = await jsonl?.settle()
  if (headerFailure) return { type: "output_error", message: headerFailure }
  const unsubscribe = jsonl ? session.subscribe(event => jsonl.enqueue(event)) : undefined

  let result: PrintModeResult
  try {
    try {
      // Prompts share one transcript and must settle in caller order.
      // oxlint-disable-next-line no-await-in-loop
      for (const prompt of options.prompts) await session.prompt(prompt)
      result = resultFromLastMessage(session.messages.at(-1))
      if (result.type === "success" && options.output === "text") {
        result = await writeText(session.messages.at(-1), options.writer)
      }
    } catch (cause) {
      result = { type: "provider_error", message: cause instanceof Error ? cause.message : "Print request failed" }
    }
  } finally {
    unsubscribe?.()
  }

  const jsonlFailure = await jsonl?.settle()
  return jsonlFailure ? { type: "output_error", message: jsonlFailure } : result
}

function validateInput(options: PrintModeOptions): PrintModeResult | undefined {
  if (options.output !== "text" && options.output !== "json") {
    return { type: "invalid_input", message: `Invalid print output: ${String(options.output)}` }
  }
  if (options.prompts.length === 0) {
    return { type: "invalid_input", message: "Print mode requires at least one prompt" }
  }
  if (options.prompts.length > maxPrintPromptCount) {
    return { type: "invalid_input", message: `Print mode accepts at most ${maxPrintPromptCount} prompts` }
  }
  let promptBytes = 0
  for (const prompt of options.prompts) {
    if (typeof prompt !== "string") return { type: "invalid_input", message: "Print prompts must be strings" }
    promptBytes += Buffer.byteLength(prompt)
    if (promptBytes > maxPrintPromptBytes) {
      return { type: "invalid_input", message: `Print prompts cannot exceed ${maxPrintPromptBytes} bytes` }
    }
  }
  return undefined
}

function resultFromLastMessage(message: AgentMessage | undefined): PrintModeResult {
  if (message?.role !== "assistant") {
    return { type: "provider_error", message: "Print mode completed without an assistant response" }
  }
  if (message.stopReason === "error") {
    return { type: "provider_error", message: message.errorMessage ?? "Request failed" }
  }
  if (message.stopReason === "aborted") {
    return { type: "aborted", message: message.errorMessage ?? "Request aborted" }
  }
  return { type: "success" }
}

async function writeText(message: AgentMessage | undefined, writer: PrintWriter): Promise<PrintModeResult> {
  if (message?.role !== "assistant") {
    return { type: "provider_error", message: "Print mode completed without an assistant response" }
  }
  let outputBytes = 0
  let outputChunks = 0
  for (const content of message.content) {
    if (content.type !== "text") continue
    outputChunks++
    if (outputChunks > maxPrintOutputChunks) {
      return { type: "output_error", message: `Print output cannot exceed ${maxPrintOutputChunks} chunks` }
    }
    outputBytes += Buffer.byteLength(content.text) + 1
    if (outputBytes > maxPrintOutputBytes) {
      return { type: "output_error", message: `Print output cannot exceed ${maxPrintOutputBytes} bytes` }
    }
  }
  try {
    for (const content of message.content) {
      // Await each write to preserve order and bound outstanding backpressure.
      // oxlint-disable-next-line no-await-in-loop
      if (content.type === "text") await writer.write(`${content.text}\n`)
    }
  } catch {
    return { type: "output_error", message: "Could not write print output" }
  }
  return { type: "success" }
}

class JsonlSink {
  readonly #writer: PrintWriter
  readonly #onFailure: () => void
  #queue: Array<{ readonly line: string; readonly bytes: number }> = []
  #head = 0
  #pendingBytes = 0
  #running: Promise<void> | undefined
  #failure: string | undefined

  constructor(writer: PrintWriter, onFailure: () => void) {
    this.#writer = writer
    this.#onFailure = onFailure
  }

  enqueue(record: SessionHeader | AgentSessionEvent): void {
    if (this.#failure) return
    let json: string | undefined
    try {
      json = JSON.stringify(record)
    } catch {
      this.#fail("Could not serialize JSONL output")
      return
    }
    if (json === undefined) {
      this.#fail("Could not serialize JSONL output")
      return
    }

    const line = `${json}\n`
    const bytes = Buffer.byteLength(line)
    if (bytes > maxJsonlRecordBytes) {
      this.#fail(`JSONL records cannot exceed ${maxJsonlRecordBytes} bytes`)
      return
    }
    if (
      this.#queue.length - this.#head >= maxPendingJsonlRecords ||
      this.#pendingBytes + bytes > maxPendingJsonlBytes
    ) {
      this.#fail("JSONL output exceeded its pending-write bound")
      return
    }

    this.#queue.push({ line, bytes })
    this.#pendingBytes += bytes
    this.#running ??= this.#drain()
  }

  async settle(): Promise<string | undefined> {
    await this.#running
    return this.#failure
  }

  async #drain(): Promise<void> {
    while (!this.#failure && this.#head < this.#queue.length) {
      const item = this.#queue[this.#head]
      if (!item) break
      try {
        // One drain owns writer order and never accumulates concurrent writes.
        // oxlint-disable-next-line no-await-in-loop
        await this.#writer.write(item.line)
      } catch {
        this.#fail("Could not write JSONL output")
        break
      }
      if (this.#failure) break
      this.#head++
      this.#pendingBytes -= item.bytes
      if (this.#head === this.#queue.length) {
        this.#queue = []
        this.#head = 0
      } else if (this.#head >= 256 && this.#head * 2 >= this.#queue.length) {
        this.#queue = this.#queue.slice(this.#head)
        this.#head = 0
      }
    }
    this.#running = undefined
  }

  #fail(message: string): void {
    if (this.#failure) return
    this.#failure = message
    this.#queue = []
    this.#head = 0
    this.#pendingBytes = 0
    this.#onFailure()
  }
}
