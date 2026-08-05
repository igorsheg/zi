import { spawn } from "node:child_process"
import { isAbsolute } from "node:path"
import { Readable, type Writable } from "node:stream"

export interface CodeModeWorkerExit {
  readonly code: number | null
  readonly signal: NodeJS.Signals | null
  readonly error?: Error
}

export interface CodeModeWorkerProcess {
  readonly input: Writable
  readonly stdout: Readable
  readonly stderr: Readable
  readonly protocol: Readable
  readonly exited: Promise<CodeModeWorkerExit>
  closeInput(): void
  terminate(force: boolean): void
  dispose(): void
}

export function createCodeModeWorkerSpawner(command: readonly string[]): (cwd: string) => CodeModeWorkerProcess {
  if (
    command.length === 0 ||
    command.length > 16 ||
    !isAbsolute(command[0]!) ||
    command.some(part => part.length === 0 || part.includes("\0") || Buffer.byteLength(part) > 4_096)
  ) {
    throw new Error("Code-mode worker commands require an absolute executable and at most 15 bounded arguments")
  }
  const admitted = Object.freeze([...command])
  const environment = codeModeEnvironment()
  return cwd => {
    const child = spawn(admitted[0]!, [...admitted.slice(1), "--zi-internal-code-mode-worker"], {
      cwd,
      env: environment,
      stdio: ["pipe", "pipe", "pipe", "pipe"],
      windowsHide: true
    })
    const protocol = child.stdio[3]
    if (!child.stdin || !child.stdout || !child.stderr || !(protocol instanceof Readable)) {
      child.once("error", ignoreStreamError)
      child.kill("SIGKILL")
      child.unref()
      throw new Error("Code-mode worker did not expose all required pipes")
    }

    const input = child.stdin
    const stdout = child.stdout
    const stderr = child.stderr
    const releaseInputError = (): void => {
      input.off("error", ignoreStreamError)
    }
    input.on("error", ignoreStreamError)
    input.once("close", releaseInputError)

    let settled = false
    let processError: Error | undefined
    let resolveExit!: (exit: CodeModeWorkerExit) => void
    const exited = new Promise<CodeModeWorkerExit>(resolve => {
      resolveExit = resolve
    })
    const finish = (code: number | null, signal: NodeJS.Signals | null): void => {
      if (settled) return
      settled = true
      resolveExit({ code, signal, ...(processError ? { error: processError } : {}) })
    }
    const onError = (cause: Error): void => {
      processError = cause
    }
    const onClose = (code: number | null, signal: NodeJS.Signals | null): void => finish(code, signal)
    child.on("error", onError)
    child.on("close", onClose)
    const stopObserving = (): void => {
      child.off("error", onError)
      child.off("close", onClose)
    }

    return {
      input,
      stdout,
      stderr,
      protocol,
      exited,
      closeInput() {
        input.end()
      },
      terminate(force) {
        if (!settled) child.kill(force ? "SIGKILL" : "SIGTERM")
      },
      dispose() {
        input.destroy()
        stdout.destroy()
        stderr.destroy()
        protocol.destroy()
        if (settled) {
          stopObserving()
          return
        }
        child.unref()
        child.once("error", ignoreStreamError)
        processError ??= new Error("Code-mode process ownership ended before exit observation")
        finish(child.exitCode, child.signalCode)
        stopObserving()
      }
    }
  }
}

function ignoreStreamError(): void {}

function codeModeEnvironment(): Readonly<NodeJS.ProcessEnv> {
  const environment: NodeJS.ProcessEnv = {}
  for (const name of ["PATH", "SystemRoot", "WINDIR", "TMPDIR", "TMP", "TEMP", "LANG", "LC_ALL"]) {
    const value = process.env[name]
    if (value !== undefined) environment[name] = value
  }
  return Object.freeze(environment)
}
