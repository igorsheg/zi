import {
  deserializeMessage,
  serializeMessage,
  type JSONRPCMessage,
  type Transport,
  type TransportSendOptions
} from "@modelcontextprotocol/client"

import { spawnOwnedProcess, type RawOwnedProcess } from "../processes/owned-process.js"
import type { ProcessTreeTracker } from "../processes/process-tree.js"

export const maxMcpProtocolMessageBytes = 1024 * 1024
export const maxMcpStderrBytes = 50 * 1024

const gracefulCloseMs = 250
const terminateCloseMs = 250
const killCloseMs = 250

export interface OwnedStdioTransportPlan {
  readonly command: readonly string[]
  readonly cwd: string
  readonly environment: Readonly<Record<string, string | undefined>>
  readonly pipeAdapter?: "direct" | "node"
}

type TransportState =
  | { readonly type: "constructed" }
  | { readonly type: "starting"; readonly process: RawOwnedProcess; readonly settled: Promise<void> }
  | { readonly type: "running"; readonly process: RawOwnedProcess }
  | { readonly type: "closing"; readonly settled: Promise<void> }
  | { readonly type: "closed" }

export class OwnedStdioTransport implements Transport {
  onclose?: () => void
  onerror?: (error: Error) => void
  // oxlint-disable-next-line typescript/no-unnecessary-type-parameters -- matches the SDK Transport callback contract
  onmessage?: <T extends JSONRPCMessage>(message: T) => void

  readonly #plan: OwnedStdioTransportPlan
  readonly #processTreeTracker: ProcessTreeTracker
  #state: TransportState = { type: "constructed" }
  #stdout = Buffer.alloc(0)
  #stderr = Buffer.alloc(0)
  #closePublished = false

  constructor(plan: OwnedStdioTransportPlan, processTreeTracker: ProcessTreeTracker) {
    this.#plan = Object.freeze({
      command: Object.freeze([...plan.command]),
      cwd: plan.cwd,
      environment: Object.freeze({ ...plan.environment }),
      ...(plan.pipeAdapter ? { pipeAdapter: plan.pipeAdapter } : {})
    })
    this.#processTreeTracker = processTreeTracker
  }

  start(): Promise<void> {
    if (this.#state.type !== "constructed") throw new Error("MCP stdio transport can only be started once")

    let process: RawOwnedProcess
    try {
      process = spawnOwnedProcess({
        type: "raw",
        pipeAdapter: this.#plan.pipeAdapter ?? "direct",
        command: this.#plan.command,
        cwd: this.#plan.cwd,
        env: this.#plan.environment,
        processTreeTracker: this.#processTreeTracker
      })
    } catch (cause) {
      this.#state = { type: "closed" }
      this.#publishClose()
      throw cause
    }

    process.stdout.pause()
    process.stdout.on("data", chunk => this.#consumeStdout(process, Buffer.from(chunk)))
    process.stdout.once("end", () => this.#stdoutEnded(process))
    process.stdout.once("error", cause => this.#fail(process, toError(cause, "MCP server stdout failed")))
    process.stderr.on("data", chunk => this.#retainStderr(Buffer.from(chunk)))
    process.stderr.once("error", cause => this.#fail(process, toError(cause, "MCP server stderr failed")))
    void process.exit.then(exit => {
      const detail = exit.error
        ? `: ${exit.error.message}`
        : exit.signal
          ? ` after ${exit.signal}`
          : exit.code === null
            ? ""
            : ` with code ${exit.code}`
      this.#fail(process, new Error(`MCP stdio server exited${detail}`))
      return undefined
    })
    void process.containmentFailure.catch(cause => {
      this.#fail(process, toError(cause, "MCP stdio process containment failed"))
    })

    const settled = this.#finishStart(process)
    this.#state = { type: "starting", process, settled }
    return settled
  }

  send(message: JSONRPCMessage, _options?: TransportSendOptions): Promise<void> {
    const state = this.#state
    if (state.type !== "running") return Promise.reject(new Error("MCP stdio transport is not running"))
    const serialized = serializeMessage(message)
    if (Buffer.byteLength(serialized) > maxMcpProtocolMessageBytes) {
      return Promise.reject(
        new Error(`MCP protocol messages cannot exceed ${maxMcpProtocolMessageBytes} encoded bytes`)
      )
    }
    return write(state.process, serialized)
  }

  close(): Promise<void> {
    const state = this.#state
    switch (state.type) {
      case "constructed":
        this.#state = { type: "closed" }
        this.#publishClose()
        return Promise.resolve()
      case "starting":
      case "running":
        return this.#beginClose(state.process)
      case "closing":
        return state.settled
      case "closed":
        return Promise.resolve()
      default:
        return assertNever(state)
    }
  }

  stderrTail(): string {
    return this.#stderr.toString("utf8")
  }

  async #finishStart(process: RawOwnedProcess): Promise<void> {
    try {
      await Promise.race([
        process.admitted,
        process.exit.then(exit => {
          const detail =
            exit.error?.message ?? exit.signal ?? (exit.code === null ? "unknown exit" : `code ${exit.code}`)
          throw new Error(`MCP stdio server exited during startup: ${detail}`)
        }),
        process.containmentFailure
      ])
    } catch (cause) {
      const error = toError(cause, "MCP stdio transport could not start")
      this.#fail(process, error)
      const state = this.#state
      if (state.type === "closing") await state.settled
      throw error
    }

    const state = this.#state
    if (state.type !== "starting" || state.process !== process) {
      if (state.type === "closing") await state.settled
      throw new Error("MCP stdio transport closed during startup")
    }
    this.#state = { type: "running", process }
    process.stdout.resume()
  }

  #consumeStdout(process: RawOwnedProcess, chunk: Buffer): void {
    const state = this.#state
    if (state.type !== "running" || state.process !== process) return

    let offset = 0
    while (offset < chunk.length) {
      const newline = chunk.indexOf(0x0a, offset)
      const end = newline === -1 ? chunk.length : newline
      const segment = chunk.subarray(offset, end)
      if (this.#stdout.length + segment.length > maxMcpProtocolMessageBytes) {
        this.#fail(
          process,
          new Error(`MCP protocol messages cannot exceed ${maxMcpProtocolMessageBytes} encoded bytes`)
        )
        return
      }
      if (segment.length > 0) this.#stdout = Buffer.concat([this.#stdout, segment])
      if (newline === -1) return

      const line = this.#stdout.length > 0 && this.#stdout.at(-1) === 0x0d ? this.#stdout.subarray(0, -1) : this.#stdout
      this.#stdout = Buffer.alloc(0)
      try {
        const text = new TextDecoder("utf-8", { fatal: true }).decode(line)
        const message = deserializeMessage(text)
        const current = this.#state
        if (current.type !== "running" || current.process !== process) return
        this.onmessage?.(message)
      } catch (cause) {
        this.#fail(process, toError(cause, "MCP server emitted an invalid protocol message"))
        return
      }
      offset = newline + 1
    }
  }

  #stdoutEnded(process: RawOwnedProcess): void {
    const state = this.#state
    if ((state.type !== "starting" && state.type !== "running") || state.process !== process) return
    this.#fail(
      process,
      new Error(
        this.#stdout.length > 0
          ? "MCP server stdout ended with an unterminated protocol message"
          : "MCP server stdout closed"
      )
    )
  }

  #retainStderr(chunk: Buffer): void {
    if (chunk.length >= maxMcpStderrBytes) {
      this.#stderr = Buffer.from(chunk.subarray(chunk.length - maxMcpStderrBytes))
      return
    }
    const retained = Math.min(this.#stderr.length, maxMcpStderrBytes - chunk.length)
    this.#stderr = Buffer.concat([this.#stderr.subarray(this.#stderr.length - retained), chunk])
  }

  #fail(process: RawOwnedProcess, error: Error): void {
    const state = this.#state
    if ((state.type !== "starting" && state.type !== "running") || state.process !== process) return
    try {
      this.onerror?.(error)
    } finally {
      void this.#beginClose(process).catch(() => {})
    }
  }

  #beginClose(process: RawOwnedProcess): Promise<void> {
    const current = this.#state
    if (current.type === "closing") return current.settled
    if (current.type === "closed") return Promise.resolve()
    if ((current.type !== "starting" && current.type !== "running") || current.process !== process) {
      return Promise.resolve()
    }

    const settled = this.#shutdown(process)
    this.#state = { type: "closing", settled }
    return settled
  }

  async #shutdown(process: RawOwnedProcess): Promise<void> {
    try {
      process.closeInput()
      if (!(await settlesWithin(process.exit, gracefulCloseMs))) {
        process.terminate(false)
        if (!(await settlesWithin(process.exit, terminateCloseMs))) {
          process.terminate(true)
          await settlesWithin(process.exit, killCloseMs)
        }
      }
      await process.dispose()
    } finally {
      this.#stdout = Buffer.alloc(0)
      this.#state = { type: "closed" }
      this.#publishClose()
    }
  }

  #publishClose(): void {
    if (this.#closePublished) return
    this.#closePublished = true
    this.onclose?.()
  }
}

function write(process: RawOwnedProcess, serialized: string): Promise<void> {
  return new Promise((resolve, reject) => {
    process.input.write(serialized, cause => {
      if (cause) reject(cause)
      else resolve()
    })
  })
}

function settlesWithin<T>(operation: Promise<T>, timeoutMs: number): Promise<boolean> {
  let timer: ReturnType<typeof setTimeout> | undefined
  return Promise.race([
    operation.then(() => true),
    new Promise<boolean>(resolve => {
      timer = setTimeout(() => resolve(false), timeoutMs)
      timer.unref?.()
    })
  ]).finally(() => {
    if (timer) clearTimeout(timer)
  })
}

function toError(cause: unknown, message: string): Error {
  return cause instanceof Error ? new Error(`${message}: ${cause.message}`, { cause }) : new Error(message, { cause })
}

function assertNever(value: never): never {
  throw new Error(`Unknown MCP stdio transport state: ${String(value)}`)
}
