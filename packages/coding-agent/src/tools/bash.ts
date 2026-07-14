import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process"
import { createWriteStream, mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type { AgentTool } from "@earendil-works/pi-agent-core"
import { Type } from "@earendil-works/pi-ai"

import { DEFAULT_MAX_BYTES, DEFAULT_MAX_LINES, truncateTail, type TruncationResult } from "./truncate.js"

const DEFAULT_TIMEOUT_SECONDS = 120
const MAX_TIMEOUT_SECONDS = 2_147_483_647 / 1_000
const UPDATE_INTERVAL_MS = 100

const parameters = Type.Object({
  command: Type.String({ description: "Bash command to execute" }),
  timeout: Type.Optional(Type.Number({ exclusiveMinimum: 0, description: "Timeout in seconds" }))
})

export interface BashToolDetails {
  truncation?: TruncationResult
  fullOutputPath?: string
}

export function createBashTool(cwd: string): AgentTool<typeof parameters, BashToolDetails | undefined> {
  return {
    name: "bash",
    label: "bash",
    description:
      "Execute a shell command in the working directory. Output is limited to the last 2,000 lines or 50 KiB; full truncated output is saved to a temporary file.",
    parameters,
    executionMode: "sequential",
    async execute(_id, input, signal, onUpdate) {
      const timeout = input.timeout ?? DEFAULT_TIMEOUT_SECONDS
      if (!Number.isFinite(timeout) || timeout <= 0 || timeout > MAX_TIMEOUT_SECONDS) {
        throw new Error(`Timeout must be between 0 and ${MAX_TIMEOUT_SECONDS} seconds`)
      }

      const capture = new OutputCapture()
      const child = spawnShell(input.command, cwd)
      let lastUpdate = 0
      let timer: ReturnType<typeof setTimeout> | undefined

      const update = () => {
        if (!onUpdate) return
        const elapsed = Date.now() - lastUpdate
        if (elapsed >= UPDATE_INTERVAL_MS) {
          lastUpdate = Date.now()
          onUpdate(capture.result(false))
          return
        }
        timer ??= setTimeout(() => {
          timer = undefined
          lastUpdate = Date.now()
          onUpdate(capture.result(false))
        }, UPDATE_INTERVAL_MS - elapsed)
      }

      capture.pipe(child.stdout, update)
      capture.pipe(child.stderr, update)
      let outcome: Awaited<ReturnType<typeof wait>>
      try {
        outcome = await wait(child, signal, timeout * 1_000)
      } catch (error) {
        if (timer) clearTimeout(timer)
        await capture.finish()
        capture.result(true)
        throw error
      }
      if (timer) clearTimeout(timer)
      await capture.finish()

      const result = capture.result(true)
      if (outcome === "aborted") throw new Error(withStatus(result.content[0]?.text ?? "", "Command aborted"))
      if (outcome === "timeout")
        throw new Error(withStatus(result.content[0]?.text ?? "", `Command timed out after ${timeout} seconds`))
      if (outcome !== 0)
        throw new Error(withStatus(result.content[0]?.text ?? "", `Command exited with code ${outcome}`))
      return result
    }
  }
}

class OutputCapture {
  readonly #dir = mkdtempSync(join(tmpdir(), "openzi-bash-"))
  readonly #path = join(this.#dir, "output.log")
  readonly #file = createWriteStream(this.#path)
  #tail = Buffer.alloc(0)
  #bytes = 0
  #newlines = 0
  #endsWithNewline = false
  #error: Error | undefined

  constructor() {
    this.#file.on("error", error => (this.#error = error))
  }

  pipe(source: NodeJS.ReadableStream, changed: () => void): void {
    source.on("data", (chunk: Buffer) => {
      this.#bytes += chunk.length
      this.#newlines += countByte(chunk, 10)
      this.#endsWithNewline = chunk.at(-1) === 10
      this.#tail = Buffer.concat([this.#tail, chunk])
      if (this.#tail.length > DEFAULT_MAX_BYTES * 2) {
        let tailStart = this.#tail.length - DEFAULT_MAX_BYTES * 2
        while (tailStart < this.#tail.length && (this.#tail[tailStart]! & 0xc0) === 0x80) tailStart++
        this.#tail = this.#tail.subarray(tailStart)
      }
      if (!this.#file.write(chunk)) {
        source.pause()
        this.#file.once("drain", () => source.resume())
      }
      changed()
    })
  }

  result(cleanup: boolean): { content: [{ type: "text"; text: string }]; details: BashToolDetails | undefined } {
    const totalLines = this.#newlines + (this.#bytes > 0 && !this.#endsWithNewline ? 1 : 0)
    const truncation = truncateTail(this.#tail.toString(), DEFAULT_MAX_LINES, DEFAULT_MAX_BYTES)
    const truncated = this.#bytes > DEFAULT_MAX_BYTES || totalLines > DEFAULT_MAX_LINES
    const details = truncated
      ? {
          truncation: { ...truncation, truncated: true, totalBytes: this.#bytes, totalLines },
          fullOutputPath: this.#path
        }
      : undefined
    let text = truncation.content || "(no output)"
    if (details) text += `\n\n[Output truncated. Full output: ${this.#path}]`
    if (cleanup && !truncated) rmSync(this.#dir, { recursive: true, force: true })
    return { content: [{ type: "text", text }], details }
  }

  finish(): Promise<void> {
    return new Promise((resolve, reject) => {
      this.#file.end(() => {
        if (this.#error) {
          reject(this.#error)
          return
        }
        resolve()
      })
    })
  }
}

function spawnShell(command: string, cwd: string): ChildProcessWithoutNullStreams {
  if (process.platform === "win32") {
    return spawn(process.env.ComSpec ?? "cmd.exe", ["/d", "/s", "/c", command], { cwd, windowsHide: true })
  }
  return spawn(process.env.SHELL ?? "/bin/bash", ["-lc", command], { cwd, detached: true })
}

function wait(child: ChildProcessWithoutNullStreams, signal: AbortSignal | undefined, timeoutMs: number) {
  return new Promise<number | "aborted" | "timeout">((resolve, reject) => {
    let reason: "aborted" | "timeout" | undefined
    let killTimer: ReturnType<typeof setTimeout> | undefined
    const stop = (next: "aborted" | "timeout") => {
      reason = next
      kill(child, "SIGTERM")
      if (process.platform !== "win32") killTimer = setTimeout(() => kill(child, "SIGKILL"), 1_000)
    }
    const timeout = setTimeout(() => stop("timeout"), timeoutMs)
    const abort = () => stop("aborted")
    const cleanup = () => {
      clearTimeout(timeout)
      if (killTimer) clearTimeout(killTimer)
      signal?.removeEventListener("abort", abort)
    }
    signal?.addEventListener("abort", abort, { once: true })
    child.once("error", error => {
      cleanup()
      reject(error)
    })
    child.once("close", code => {
      cleanup()
      resolve(reason ?? code ?? 1)
    })
    if (signal?.aborted) stop("aborted")
  })
}

function kill(child: ChildProcessWithoutNullStreams, signal: NodeJS.Signals): void {
  if (!child.pid) return
  if (process.platform === "win32") {
    spawn("taskkill", ["/pid", String(child.pid), "/t", "/f"], { stdio: "ignore", windowsHide: true })
    return
  }
  try {
    process.kill(-child.pid, signal)
  } catch {}
}

function withStatus(output: string, status: string): string {
  return output && output !== "(no output)" ? `${output}\n\n${status}` : status
}

function countByte(buffer: Buffer, byte: number): number {
  let count = 0
  for (const value of buffer) if (value === byte) count++
  return count
}
