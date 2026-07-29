import { spawn } from "node:child_process"
import { isAbsolute } from "node:path"
import { Readable, Writable } from "node:stream"

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

type SpawnedChild =
  | { readonly type: "bun"; readonly process: Bun.Subprocess<"pipe", "pipe", "pipe"> }
  | { readonly type: "node"; readonly process: ReturnType<typeof spawn> }

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
    const args = [...admitted.slice(1), "--zi-internal-code-mode-worker"]
    const child: SpawnedChild =
      process.platform === "win32"
        ? {
            type: "node",
            process: spawn(admitted[0]!, args, {
              cwd,
              env: environment,
              stdio: ["pipe", "pipe", "pipe", "pipe"],
              windowsHide: true
            })
          }
        : {
            type: "bun",
            process: Bun.spawn([admitted[0]!, ...args], {
              cwd,
              env: environment,
              stdio: ["pipe", "pipe", "pipe", "pipe"],
              windowsHide: true
            })
          }

    let input: Writable
    let stdout: Readable
    let stderr: Readable
    let protocol: Readable
    try {
      if (child.type === "bun") {
        const descriptor = child.process.stdio[3]
        if (typeof descriptor !== "number") throw new Error("Code-mode worker did not expose its protocol pipe")
        input = bunInput(child.process.stdin)
        stdout = Readable.from(child.process.stdout)
        stderr = Readable.from(child.process.stderr)
        protocol = Readable.from(Bun.file(descriptor).stream())
      } else {
        const descriptor = child.process.stdio[3]
        if (
          !child.process.stdin ||
          !child.process.stdout ||
          !child.process.stderr ||
          !(descriptor instanceof Readable)
        ) {
          throw new Error("Code-mode worker did not expose all required pipes")
        }
        input = child.process.stdin
        stdout = child.process.stdout
        stderr = child.process.stderr
        protocol = descriptor
      }
    } catch (cause) {
      if (child.type === "node") child.process.once("error", () => {})
      child.process.kill("SIGKILL")
      child.process.unref()
      throw cause
    }

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
    let stopObserving: (() => void) | undefined
    if (child.type === "bun") {
      const process = child.process
      void process.exited.then(
        code => finish(code, process.signalCode),
        cause => {
          processError = cause instanceof Error ? cause : new Error("Code-mode worker process failed")
          finish(process.exitCode, process.signalCode)
        }
      )
    } else {
      const process = child.process
      const onError = (cause: Error): void => {
        processError = cause
      }
      const onClose = (code: number | null, signal: NodeJS.Signals | null): void => finish(code, signal)
      process.on("error", onError)
      process.on("close", onClose)
      stopObserving = () => {
        process.off("error", onError)
        process.off("close", onClose)
      }
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
        if (!settled) child.process.kill(force ? "SIGKILL" : "SIGTERM")
      },
      dispose() {
        input.destroy()
        stdout.destroy()
        stderr.destroy()
        protocol.destroy()
        if (settled) {
          stopObserving?.()
          return
        }
        child.process.unref()
        if (child.type === "node") child.process.once("error", () => {})
        processError ??= new Error("Code-mode process ownership ended before exit observation")
        finish(child.process.exitCode, child.process.signalCode)
        stopObserving?.()
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

function bunInput(sink: Bun.FileSink): Writable {
  let ended = false
  return new Writable({
    write(chunk: Buffer, _encoding, callback) {
      void writeBunInput(sink, chunk, callback)
    },
    final(callback) {
      ended = true
      void closeBunInput(sink, undefined, callback)
    },
    destroy(cause, callback) {
      if (ended) {
        callback(cause)
        return
      }
      ended = true
      void closeBunInput(sink, cause ?? undefined, callback)
    }
  })
}

async function writeBunInput(
  sink: Bun.FileSink,
  chunk: Buffer,
  callback: (error?: Error | null) => void
): Promise<void> {
  try {
    await sink.write(chunk)
    await sink.flush()
    callback()
  } catch (cause) {
    callback(cause instanceof Error ? cause : new Error("Could not write code-mode worker input"))
  }
}

async function closeBunInput(
  sink: Bun.FileSink,
  cause: Error | undefined,
  callback: (error?: Error | null) => void
): Promise<void> {
  try {
    await sink.end()
    callback(cause)
  } catch (closeCause) {
    const closeError = closeCause instanceof Error ? closeCause : new Error("Could not close code-mode worker input")
    callback(cause ? new Error(`${cause.message}; ${closeError.message}`, { cause }) : closeError)
  }
}
