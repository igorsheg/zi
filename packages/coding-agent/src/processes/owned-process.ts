import { spawn } from "node:child_process"
import { isAbsolute } from "node:path"
import { Readable, Writable } from "node:stream"

import type { ProcessScope, ProcessScopeRefreshResult, ProcessTreeTracker } from "./process-tree.js"

const maxCommandParts = 32
const maxCommandPartBytes = 4_096
const processExitSettleMs = 1_000

export interface OwnedProcessExit {
  readonly code: number | null
  readonly signal: NodeJS.Signals | null
  readonly error?: Error
}

interface OwnedProcessBase {
  readonly pid: number
  readonly input: Writable
  readonly stdout: Readable
  readonly stderr: Readable
  readonly exit: Promise<OwnedProcessExit>
  readonly admitted: Promise<void>
  readonly containmentFailure: Promise<never>
  refreshTree(): Promise<ProcessScopeRefreshResult>
  terminate(force: boolean): void
  terminateTree(): Promise<void>
  closeInput(): void
  dispose(): Promise<void>
}

export interface RawOwnedProcess extends OwnedProcessBase {
  readonly type: "raw"
}

export interface ProtocolOwnedProcess extends OwnedProcessBase {
  readonly type: "protocol"
  readonly protocol: Readable
}

export type OwnedProcess = RawOwnedProcess | ProtocolOwnedProcess

interface OwnedProcessRequestBase {
  readonly pipeAdapter: "direct" | "node"
  readonly command: readonly string[]
  readonly cwd: string
  readonly env: Readonly<Record<string, string | undefined>>
  readonly processTreeTracker: ProcessTreeTracker
}

export type OwnedProcessRequest =
  | (OwnedProcessRequestBase & { readonly type: "raw" })
  | (OwnedProcessRequestBase & { readonly type: "protocol" })

type BunChild = Bun.Subprocess<"pipe", "pipe", "pipe">
type NodeChild = ReturnType<typeof spawn>
type SpawnedChild =
  | { readonly type: "bun"; readonly process: BunChild }
  | { readonly type: "node"; readonly process: NodeChild }

export function spawnOwnedProcess(request: OwnedProcessRequest & { readonly type: "raw" }): RawOwnedProcess
export function spawnOwnedProcess(request: OwnedProcessRequest & { readonly type: "protocol" }): ProtocolOwnedProcess
export function spawnOwnedProcess(request: OwnedProcessRequest): OwnedProcess {
  validateCommand(request.command)
  const command = [...request.command]
  const child = spawnChild(request, command)
  const processPid = child.process.pid
  if (typeof processPid !== "number" || !Number.isInteger(processPid) || processPid <= 0) {
    releaseFailedSpawn(child)
    throw new Error("Owned process did not expose a valid process ID")
  }
  const pid = processPid

  let input: Writable
  let stdout: Readable
  let stderr: Readable
  let protocol: Readable | undefined
  try {
    if (child.type === "bun") {
      input = bunInput(child.process.stdin)
      stdout = Readable.from(child.process.stdout)
      stderr = Readable.from(child.process.stderr)
      if (request.type === "protocol") {
        const descriptor = child.process.stdio[3]
        if (typeof descriptor !== "number") throw new Error("Owned process did not expose its protocol pipe")
        protocol = Readable.from(Bun.file(descriptor).stream())
      }
    } else {
      const descriptor = child.process.stdio[3]
      if (!child.process.stdin || !child.process.stdout || !child.process.stderr) {
        throw new Error("Owned process did not expose all required pipes")
      }
      input = child.process.stdin
      stdout = child.process.stdout
      stderr = child.process.stderr
      if (request.type === "protocol") {
        if (!(descriptor instanceof Readable)) throw new Error("Owned process did not expose its protocol pipe")
        protocol = descriptor
      }
    }
  } catch (cause) {
    releaseFailedSpawn(child)
    throw cause
  }

  input.on("error", ignoreStreamError)
  input.once("close", () => input.off("error", ignoreStreamError))

  let rejectContainment!: (error: Error) => void
  const containmentFailure = new Promise<never>((_, reject) => {
    rejectContainment = reject
  })
  void containmentFailure.catch(ignoreStreamError)

  let scope: ProcessScope
  try {
    scope = request.processTreeTracker.track(pid, rejectContainment)
  } catch (cause) {
    input.destroy()
    stdout.destroy()
    stderr.destroy()
    protocol?.destroy()
    releaseFailedSpawn(child)
    throw cause
  }

  let settled = false
  let processError: Error | undefined
  let resolveExit!: (exit: OwnedProcessExit) => void
  const exit = new Promise<OwnedProcessExit>(resolve => {
    resolveExit = resolve
  })
  const finish = (code: number | null, signal: NodeJS.Signals | null): void => {
    if (settled) return
    settled = true
    resolveExit({ code, signal, ...(processError ? { error: processError } : {}) })
  }
  const stopObserving = observeExit(
    child,
    cause => {
      processError = cause
    },
    finish
  )
  let disposal: Promise<void> | undefined
  const base: OwnedProcessBase = {
    pid,
    input,
    stdout,
    stderr,
    exit,
    admitted: scope.admitted,
    containmentFailure,
    refreshTree: () => scope.refresh(),
    terminate(force) {
      if (settled) return
      signalTree(child, pid, force ? "SIGKILL" : "SIGTERM")
    },
    async terminateTree() {
      await scope.terminate()
    },
    closeInput() {
      input.end()
    },
    dispose() {
      if (disposal) return disposal
      disposal = (async () => {
        let scopeFailure: unknown
        try {
          await scope.dispose()
        } catch (cause) {
          scopeFailure = cause
        }
        input.destroy()
        stdout.destroy()
        stderr.destroy()
        protocol?.destroy()
        if (!settled && !(await settlesWithin(exit, processExitSettleMs))) {
          stopObserving()
          child.process.unref()
          if (child.type === "node") child.process.once("error", ignoreStreamError)
          processError ??= new Error("Process ownership ended before exit observation")
          finish(child.process.exitCode, child.process.signalCode)
        } else {
          stopObserving()
        }
        if (scopeFailure) throw scopeFailure
      })()
      return disposal
    }
  }

  return request.type === "protocol" ? { ...base, type: "protocol", protocol: protocol! } : { ...base, type: "raw" }
}

function validateCommand(command: readonly string[]): void {
  if (
    command.length === 0 ||
    command.length > maxCommandParts ||
    !isAbsolute(command[0]!) ||
    command.some(part => part.length === 0 || part.includes("\0") || Buffer.byteLength(part) > maxCommandPartBytes)
  ) {
    throw new Error("Owned process commands require an absolute executable and at most 31 bounded arguments")
  }
}

function spawnChild(request: OwnedProcessRequest, command: string[]): SpawnedChild {
  const stdio: ["pipe", "pipe", "pipe", ..."pipe"[]] =
    request.type === "protocol" ? ["pipe", "pipe", "pipe", "pipe"] : ["pipe", "pipe", "pipe"]
  return process.platform === "win32" || request.pipeAdapter === "node"
    ? {
        type: "node",
        process: spawn(command[0]!, command.slice(1), {
          cwd: request.cwd,
          env: { ...request.env },
          stdio: [...stdio],
          detached: process.platform !== "win32",
          windowsHide: true
        })
      }
    : {
        type: "bun",
        process: Bun.spawn(command, { cwd: request.cwd, env: request.env, stdio, detached: true, windowsHide: true })
      }
}

function observeExit(
  child: SpawnedChild,
  onError: (error: Error) => void,
  finish: (code: number | null, signal: NodeJS.Signals | null) => void
): () => void {
  if (child.type === "node") {
    const onNodeError = (error: Error): void => {
      onError(error)
      finish(child.process.exitCode, child.process.signalCode)
    }
    const onExit = (code: number | null, signal: NodeJS.Signals | null): void => finish(code, signal)
    child.process.on("error", onNodeError)
    child.process.on("exit", onExit)
    return () => {
      child.process.off("error", onNodeError)
      child.process.off("exit", onExit)
    }
  }

  let observing = true
  void child.process.exited.then(
    () => {
      if (observing) finish(child.process.exitCode, child.process.signalCode)
      return undefined
    },
    cause => {
      if (!observing) return undefined
      onError(cause instanceof Error ? cause : new Error("Could not observe owned process exit"))
      finish(child.process.exitCode, child.process.signalCode)
      return undefined
    }
  )
  return () => {
    observing = false
  }
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
    callback(cause instanceof Error ? cause : new Error("Could not write owned process input"))
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
    const closeError = closeCause instanceof Error ? closeCause : new Error("Could not close owned process input")
    callback(cause ? new Error(`${cause.message}; ${closeError.message}`, { cause }) : closeError)
  }
}

function signalTree(child: SpawnedChild, pid: number, signal: NodeJS.Signals): void {
  if (process.platform === "win32") {
    void taskkill(pid)
    return
  }
  try {
    process.kill(-pid, signal)
  } catch {
    if (child.process.exitCode === null && child.process.signalCode === null) child.process.kill(signal)
  }
}

function taskkill(pid: number): Promise<void> {
  return new Promise(resolve => {
    const killer = spawn("taskkill", ["/pid", String(pid), "/t", "/f"], { stdio: "ignore", windowsHide: true })
    killer.once("error", () => resolve())
    killer.once("close", () => resolve())
  })
}

function releaseFailedSpawn(child: SpawnedChild): void {
  if (child.type === "node") child.process.once("error", ignoreStreamError)
  child.process.kill("SIGKILL")
  child.process.unref()
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

function ignoreStreamError(): void {}
