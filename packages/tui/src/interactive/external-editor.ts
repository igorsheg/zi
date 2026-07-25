import { spawn, type ChildProcess } from "node:child_process"
import { closeSync, mkdtempSync, openSync, readSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

export const maxExternalEditorContentBytes = 1024 * 1024
const externalEditorShutdownGraceMs = 1_000

export interface ExternalEditorRequest {
  readonly command: string
  readonly content: string
  readonly cwd: string
}

export type ExternalEditorResult =
  | { readonly type: "complete"; readonly content: string }
  | { readonly type: "failed"; readonly message: string }

export interface ExternalEditor {
  edit(request: ExternalEditorRequest): Promise<ExternalEditorResult>
  dispose(): void
}

interface ExternalEditorTerminal {
  readonly isDestroyed: boolean
  suspend(): void
  resume(): void
  requestRender(): void
}

type ExternalEditorState =
  | { readonly type: "idle" }
  | { readonly type: "launching"; readonly directory: string }
  | { readonly type: "editing"; readonly directory: string; readonly child: ChildProcess }
  | { readonly type: "disposed" }

type ChildOutcome =
  | { readonly type: "exited"; readonly code: number | null; readonly signal: NodeJS.Signals | null }
  | { readonly type: "failed"; readonly cause: unknown }

/** Owns the temporary prompt file, inherited terminal lease, and editor subprocess. */
export class SystemExternalEditor implements ExternalEditor {
  readonly #terminal: ExternalEditorTerminal
  #state: ExternalEditorState = { type: "idle" }
  #forceKillTimer: ReturnType<typeof setTimeout> | undefined

  constructor(terminal: ExternalEditorTerminal) {
    this.#terminal = terminal
  }

  async edit(request: ExternalEditorRequest): Promise<ExternalEditorResult> {
    if (this.#state.type === "disposed") return { type: "failed", message: "External editor is unavailable" }
    if (this.#state.type !== "idle") return { type: "failed", message: "External editor is already open" }
    if (Buffer.byteLength(request.content) > maxExternalEditorContentBytes) {
      return { type: "failed", message: "Prompt exceeds the 1 MiB external editor limit" }
    }

    const [editor, ...editorArgs] = request.command.trim().split(/\s+/)
    if (!editor) return { type: "failed", message: "External editor command is empty" }

    const directory = mkdtempSync(join(tmpdir(), "zi-editor-"))
    const file = join(directory, "prompt.md")
    try {
      writeFileSync(file, request.content, "utf8")
      this.#terminal.suspend()
      this.#state = { type: "launching", directory }

      const child = spawn(editor, [...editorArgs, file], {
        cwd: request.cwd,
        stdio: "inherit",
        shell: process.platform === "win32"
      })
      this.#state = { type: "editing", directory, child }
      const outcome = await childOutcome(child)
      if (outcome.type === "failed") return { type: "failed", message: errorMessage(outcome.cause) }
      if (outcome.code !== 0) {
        const reason = outcome.signal ? `signal ${outcome.signal}` : `code ${outcome.code ?? "unknown"}`
        return { type: "failed", message: `External editor exited with ${reason}` }
      }

      return { type: "complete", content: readBoundedFile(file).replace(/\n$/, "") }
    } catch (cause) {
      return { type: "failed", message: errorMessage(cause) }
    } finally {
      this.#clearForceKill()
      try {
        rmSync(directory, { recursive: true, force: true })
      } catch {
        // The editor result is more useful than a best-effort temporary-directory cleanup failure.
      }
      this.#finishOperation()
    }
  }

  dispose(): void {
    const state = this.#state
    if (state.type === "disposed") return
    this.#state = { type: "disposed" }
    if (state.type === "editing") this.#stopChild(state.child)
    if (state.type === "launching" || state.type === "editing") this.#resumeTerminal()
  }

  #stopChild(child: ChildProcess): void {
    if (child.exitCode !== null || child.signalCode !== null) return
    child.kill()
    this.#forceKillTimer = setTimeout(() => child.kill("SIGKILL"), externalEditorShutdownGraceMs)
    this.#forceKillTimer.unref()
    child.once("close", () => this.#clearForceKill())
  }

  #clearForceKill(): void {
    if (!this.#forceKillTimer) return
    clearTimeout(this.#forceKillTimer)
    this.#forceKillTimer = undefined
  }

  #finishOperation(): void {
    switch (this.#state.type) {
      case "launching":
      case "editing":
        this.#resumeTerminal()
        this.#state = { type: "idle" }
        return
      case "idle":
      case "disposed":
        return
    }
  }

  #resumeTerminal(): void {
    if (this.#terminal.isDestroyed) return
    this.#terminal.resume()
    this.#terminal.requestRender()
  }
}

function childOutcome(child: ChildProcess): Promise<ChildOutcome> {
  return new Promise(resolve => {
    let settled = false
    const finish = (outcome: ChildOutcome) => {
      if (settled) return
      settled = true
      resolve(outcome)
    }
    child.once("error", cause => finish({ type: "failed", cause }))
    child.once("close", (code, signal) => finish({ type: "exited", code, signal }))
  })
}

function readBoundedFile(path: string): string {
  const file = openSync(path, "r")
  try {
    const buffer = Buffer.allocUnsafe(maxExternalEditorContentBytes + 1)
    let bytesRead = 0
    while (bytesRead < buffer.length) {
      const read = readSync(file, buffer, bytesRead, buffer.length - bytesRead, null)
      if (read === 0) break
      bytesRead += read
    }
    if (bytesRead > maxExternalEditorContentBytes) throw new Error("Edited prompt exceeds the 1 MiB limit")
    return buffer.toString("utf8", 0, bytesRead)
  } finally {
    closeSync(file)
  }
}

function errorMessage(cause: unknown): string {
  return cause instanceof Error ? cause.message : String(cause)
}
