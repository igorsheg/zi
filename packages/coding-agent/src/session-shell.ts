import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process"
import { createWriteStream, mkdirSync, mkdtempSync, rmSync, type WriteStream } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { DEFAULT_MAX_BYTES, DEFAULT_MAX_LINES, truncateTail, type TruncationResult } from "./tools/truncate.js"

export const defaultShellLimits: ShellLimits = Object.freeze({
  maxOutputFileBytes: 64 * 1024 * 1024,
  maxRetainedOutputBytes: 128 * 1024 * 1024,
  maxBackgroundTasks: 8,
  maxCompletedTasks: 100,
  completedTaskTtlMs: 5 * 60 * 1_000,
  maxRuntimeMs: 30 * 60 * 1_000,
  killGraceMs: 1_000,
  disposeTimeoutMs: 5_000
})

const outputUpdateIntervalMs = 100

export interface ShellLimits {
  readonly maxOutputFileBytes: number
  readonly maxRetainedOutputBytes: number
  readonly maxBackgroundTasks: number
  readonly maxCompletedTasks: number
  readonly completedTaskTtlMs: number
  readonly maxRuntimeMs: number
  readonly killGraceMs: number
  readonly disposeTimeoutMs: number
}

export interface SessionShellOptions {
  readonly cwd: string
  readonly sessionId: string
  readonly limits?: ShellLimits
  readonly outputRoot?: string
}

export interface ShellRunRequest {
  readonly command: string
  readonly timeoutMs: number
  readonly background: boolean
}

export type ShellStopReason = "abort" | "timeout" | "killed" | "output-limit" | "output-error" | "dispose"

export type ShellTaskOutcome =
  | { readonly type: "exited"; readonly exitCode: number }
  | { readonly type: "signaled"; readonly signal: string }
  | { readonly type: "aborted" }
  | { readonly type: "timed_out" }
  | { readonly type: "killed" }
  | { readonly type: "output_limit" }
  | { readonly type: "disposed" }
  | { readonly type: "failed"; readonly message: string }

export type ShellFullOutput =
  | { readonly type: "available"; readonly path: string; readonly bytes: number; readonly truncated: boolean }
  | { readonly type: "evicted"; readonly bytes: number; readonly truncated: boolean }

export interface ShellTaskOutputSnapshot {
  readonly text: string
  readonly truncation: TruncationResult
  readonly fullOutput: ShellFullOutput
}

interface ShellTaskIdentity {
  readonly taskId: string
  readonly toolCallId: string
  readonly command: string
  readonly cwd: string
  readonly startedAt: number
}

export type ShellTaskSnapshot =
  | (ShellTaskIdentity & {
      readonly type: "starting"
      readonly placement: "foreground" | "background"
      readonly output: ShellTaskOutputSnapshot
    })
  | (ShellTaskIdentity & { readonly type: "foreground"; readonly output: ShellTaskOutputSnapshot })
  | (ShellTaskIdentity & { readonly type: "background"; readonly output: ShellTaskOutputSnapshot })
  | (ShellTaskIdentity & {
      readonly type: "stopping"
      readonly reason: ShellStopReason
      readonly output: ShellTaskOutputSnapshot
    })
  | (ShellTaskIdentity & {
      readonly type: "settling"
      readonly outcome: ShellTaskOutcome
      readonly output: ShellTaskOutputSnapshot
    })
  | (ShellTaskIdentity & {
      readonly type: "completed"
      readonly outcome: ShellTaskOutcome
      readonly output: ShellTaskOutputSnapshot
      readonly completedAt: number
      readonly expiresAt: number
    })

export type ShellRunResult =
  | { readonly type: "completed"; readonly task: Extract<ShellTaskSnapshot, { type: "completed" }> }
  | { readonly type: "backgrounded"; readonly task: Extract<ShellTaskSnapshot, { type: "background" }> }

export class ShellRunAdmissionError extends Error {
  constructor(
    readonly reason: "invalid-command" | "invalid-timeout" | "foreground-busy" | "background-capacity",
    message: string
  ) {
    super(message)
  }
}

export type ShellDemotionResult =
  | { readonly type: "none" }
  | { readonly type: "capacity_exceeded" }
  | { readonly type: "backgrounded"; readonly task: Extract<ShellTaskSnapshot, { type: "background" }> }

export type ShellKillResult =
  | { readonly type: "not_found" }
  | { readonly type: "already_completed"; readonly task: Extract<ShellTaskSnapshot, { type: "completed" }> }
  | { readonly type: "settling"; readonly task: Extract<ShellTaskSnapshot, { type: "settling" }> }
  | { readonly type: "stopping"; readonly task: Extract<ShellTaskSnapshot, { type: "stopping" }> }

type ShellOwnerState =
  | { readonly type: "open" }
  | { readonly type: "disposing"; readonly settled: Promise<void> }
  | { readonly type: "disposed"; readonly settled: Promise<void> }

interface TaskDeferred<T> {
  readonly promise: Promise<T>
  readonly settled: boolean
  resolve(value: T): void
  reject(cause: unknown): void
}

interface TaskResources {
  readonly output: TaskOutput
  readonly processSettled: TaskDeferred<Extract<ShellTaskSnapshot, { type: "completed" }>>
  readonly toolSettled: TaskDeferred<ShellRunResult>
  readonly onUpdate: ((task: ShellTaskSnapshot) => void) | undefined
}

type StartingTask = ShellTaskIdentity &
  TaskResources & { readonly type: "starting"; readonly placement: "foreground" | "background" }

type ForegroundTask = ShellTaskIdentity &
  TaskResources & {
    readonly type: "foreground"
    readonly child: ChildProcessWithoutNullStreams
    readonly timeout: ReturnType<typeof setTimeout>
    readonly removeAbort: (() => void) | undefined
  }

type BackgroundTask = ShellTaskIdentity &
  TaskResources & {
    readonly type: "background"
    readonly child: ChildProcessWithoutNullStreams
    readonly timeout: ReturnType<typeof setTimeout>
    readonly removeAbort: undefined
  }

type RunningTask = ForegroundTask | BackgroundTask

type StoppingTask = ShellTaskIdentity &
  TaskResources & {
    readonly type: "stopping"
    readonly child: ChildProcessWithoutNullStreams
    readonly reason: ShellStopReason
    readonly failure: string | undefined
    readonly killTimer: ReturnType<typeof setTimeout>
  }

type SettlingTask = ShellTaskIdentity &
  TaskResources & { readonly type: "settling"; readonly outcome: ShellTaskOutcome }

type CompletedTask = ShellTaskIdentity & {
  readonly type: "completed"
  readonly output: TaskOutput
  readonly outcome: ShellTaskOutcome
  readonly completedAt: number
  readonly expiresAt: number
}

type ShellTask = StartingTask | RunningTask | StoppingTask | SettlingTask | CompletedTask

export class SessionShell {
  readonly cwd: string
  readonly sessionId: string
  readonly limits: ShellLimits

  readonly #outputRoot: string
  readonly #tasks = new Map<string, ShellTask>()
  readonly #listeners = new Set<(taskId: string) => void>()
  readonly #updateTimers = new Map<string, ReturnType<typeof setTimeout>>()
  readonly #lastUpdates = new Map<string, number>()
  #state: ShellOwnerState = { type: "open" }
  #outputDir: string | undefined
  #retainedOutputBytes = 0
  #evictionTimer: ReturnType<typeof setTimeout> | undefined

  constructor({ cwd, sessionId, limits = defaultShellLimits, outputRoot = tmpdir() }: SessionShellOptions) {
    assertLimits(limits)
    this.cwd = cwd
    this.sessionId = sessionId
    this.limits = limits
    this.#outputRoot = outputRoot
  }

  subscribe(listener: (taskId: string) => void): () => void {
    this.#assertOpen()
    this.#listeners.add(listener)
    return () => this.#listeners.delete(listener)
  }

  snapshots(): readonly ShellTaskSnapshot[] {
    this.#evictExpired()
    return Object.freeze([...this.#tasks.values()].map(task => Object.freeze(this.#snapshot(task))))
  }

  snapshot(taskId: string): ShellTaskSnapshot | undefined {
    this.#evictExpired()
    const task = this.#tasks.get(taskId)
    return task ? Object.freeze(this.#snapshot(task)) : undefined
  }

  run(
    toolCallId: string,
    request: ShellRunRequest,
    signal?: AbortSignal,
    onUpdate?: (task: ShellTaskSnapshot) => void
  ): Promise<ShellRunResult> {
    this.#assertOpen()
    this.#evictExpired()
    assertRunRequest(request, this.limits)
    if (signal?.aborted) throw new Error("Command aborted")
    if (!request.background && this.#foregroundTask()) {
      throw new ShellRunAdmissionError("foreground-busy", "Another foreground shell command is running")
    }
    if (request.background && this.#backgroundCount() >= this.limits.maxBackgroundTasks) {
      throw new ShellRunAdmissionError(
        "background-capacity",
        `Background task capacity exceeded (maximum ${this.limits.maxBackgroundTasks})`
      )
    }

    const taskId = crypto.randomUUID()
    const identity: ShellTaskIdentity = {
      taskId,
      toolCallId,
      command: request.command,
      cwd: this.cwd,
      startedAt: Date.now()
    }
    const processSettled = createDeferred<Extract<ShellTaskSnapshot, { type: "completed" }>>()
    const toolSettled = createDeferred<ShellRunResult>()
    const output = new TaskOutput({
      path: this.#outputPath(taskId),
      maxBytes: this.limits.maxOutputFileBytes,
      reserve: bytes => this.#reserveOutput(bytes),
      release: bytes => (this.#retainedOutputBytes -= bytes),
      changed: () => this.#scheduleUpdate(taskId),
      limitReached: () => this.#stop(taskId, "output-limit"),
      failed: cause => this.#stop(taskId, "output-error", cause.message)
    })
    const starting: StartingTask = {
      ...identity,
      type: "starting",
      placement: request.background ? "background" : "foreground",
      output,
      processSettled,
      toolSettled,
      onUpdate
    }
    this.#tasks.set(taskId, starting)
    this.#emit(taskId)

    let child: ChildProcessWithoutNullStreams
    try {
      child = spawnShell(request.command, this.cwd)
    } catch (cause) {
      this.#beginSettlement(starting, { type: "failed", message: errorMessage(cause) })
      return toolSettled.promise
    }

    const timeout = setTimeout(() => this.#stop(taskId, "timeout"), request.timeoutMs)
    const removeAbort = request.background || !signal ? undefined : bindAbort(signal, () => this.#stop(taskId, "abort"))
    const running: RunningTask = request.background
      ? {
          ...identity,
          type: "background",
          child,
          timeout,
          removeAbort: undefined,
          output,
          processSettled,
          toolSettled,
          onUpdate
        }
      : { ...identity, type: "foreground", child, timeout, removeAbort, output, processSettled, toolSettled, onUpdate }
    this.#tasks.set(taskId, running)
    output.pipe(child.stdout)
    output.pipe(child.stderr)
    child.once("error", cause => this.#onProcessError(taskId, cause))
    child.once("close", (code, processSignal) => this.#onProcessClose(taskId, code, processSignal))

    if (running.type === "background") {
      toolSettled.resolve({ type: "backgrounded", task: this.#snapshot(running) })
    } else {
      running.onUpdate?.(this.#snapshot(running))
      if (signal?.aborted) this.#stop(taskId, "abort")
    }
    this.#emit(taskId)
    return toolSettled.promise
  }

  demoteForeground(): ShellDemotionResult {
    this.#assertOpen()
    const task = this.#foregroundTask()
    if (!task) return { type: "none" }
    if (this.#backgroundCount() >= this.limits.maxBackgroundTasks) return { type: "capacity_exceeded" }

    task.removeAbort?.()
    const background: BackgroundTask = { ...task, type: "background", removeAbort: undefined }
    this.#tasks.set(task.taskId, background)
    const snapshot = this.#snapshot(background)
    task.toolSettled.resolve({ type: "backgrounded", task: snapshot })
    this.#emit(task.taskId)
    return { type: "backgrounded", task: snapshot }
  }

  async wait(taskId: string, timeoutMs: number, signal?: AbortSignal): Promise<ShellTaskSnapshot | undefined> {
    this.#assertOpen()
    if (!Number.isFinite(timeoutMs) || timeoutMs < 0 || timeoutMs > this.limits.maxRuntimeMs) {
      throw new Error(`Task wait must be between 0 and ${this.limits.maxRuntimeMs} milliseconds`)
    }
    const task = this.#tasks.get(taskId)
    if (!task) return undefined
    if (task.type === "completed" || timeoutMs === 0) return this.#snapshot(task)
    return waitForTask(task.processSettled.promise, timeoutMs, signal)
  }

  async kill(taskId: string): Promise<ShellKillResult> {
    this.#assertOpen()
    const task = this.#tasks.get(taskId)
    if (!task) return { type: "not_found" }
    if (task.type === "completed") return { type: "already_completed", task: this.#snapshot(task) }
    if (task.type === "settling") return { type: "settling", task: this.#snapshot(task) }
    if (task.type === "stopping") return { type: "stopping", task: this.#snapshot(task) }
    if (task.type === "starting") return { type: "not_found" }
    this.#stop(taskId, "killed")
    const stopping = this.#tasks.get(taskId)
    return stopping?.type === "stopping" ? { type: "stopping", task: this.#snapshot(stopping) } : { type: "not_found" }
  }

  dispose(): Promise<void> {
    if (this.#state.type !== "open") return this.#state.settled

    const disposal = createDeferred<void>()
    this.#state = { type: "disposing", settled: disposal.promise }
    void this.#dispose().then(
      () => {
        this.#state = { type: "disposed", settled: disposal.promise }
        disposal.resolve(undefined)
        return undefined
      },
      cause => {
        this.#state = { type: "disposed", settled: disposal.promise }
        disposal.reject(cause)
        return undefined
      }
    )
    return disposal.promise
  }

  async #dispose(): Promise<void> {
    if (this.#evictionTimer) clearTimeout(this.#evictionTimer)
    this.#evictionTimer = undefined
    for (const timer of this.#updateTimers.values()) clearTimeout(timer)
    this.#updateTimers.clear()

    const pending: Promise<unknown>[] = []
    for (const task of this.#tasks.values()) {
      if (task.type === "starting" || task.type === "settling" || task.type === "completed") {
        if (task.type === "starting" || task.type === "settling") pending.push(task.processSettled.promise)
        continue
      }
      pending.push(task.processSettled.promise)
      this.#stop(task.taskId, "dispose")
    }

    let failure: Error | undefined
    if (pending.length > 0) {
      const completed = await settleWithin(
        Promise.allSettled(pending).then(() => undefined),
        this.limits.disposeTimeoutMs
      )
      if (!completed) {
        failure = new Error("Shell process shutdown timed out")
        for (const task of this.#tasks.values()) {
          if (task.type !== "completed") this.#forceDisposed(task)
        }
      }
    }

    for (const task of this.#tasks.values()) task.output.evict()
    this.#tasks.clear()
    if (this.#outputDir) rmSync(this.#outputDir, { recursive: true, force: true })
    this.#listeners.clear()
    if (failure) throw failure
  }

  #foregroundTask(): ForegroundTask | undefined {
    for (const task of this.#tasks.values()) if (task.type === "foreground") return task
    return undefined
  }

  #backgroundCount(): number {
    let count = 0
    for (const task of this.#tasks.values()) {
      if (task.type === "background" || (task.type === "starting" && task.placement === "background")) count++
    }
    return count
  }

  #stop(taskId: string, reason: ShellStopReason, failure?: string): boolean {
    const task = this.#tasks.get(taskId)
    if (!task || (task.type !== "foreground" && task.type !== "background")) return false
    clearTimeout(task.timeout)
    task.removeAbort?.()
    kill(task.child, "SIGTERM")
    const killTimer = setTimeout(() => kill(task.child, "SIGKILL"), this.limits.killGraceMs)
    const stopping: StoppingTask = { ...task, type: "stopping", reason, failure, killTimer }
    this.#tasks.set(taskId, stopping)
    this.#emit(taskId)
    return true
  }

  #onProcessError(taskId: string, cause: Error): void {
    const task = this.#tasks.get(taskId)
    if (!task || task.type === "settling" || task.type === "completed") return
    this.#beginSettlement(task, { type: "failed", message: cause.message })
  }

  #onProcessClose(taskId: string, code: number | null, processSignal: NodeJS.Signals | null): void {
    const task = this.#tasks.get(taskId)
    if (!task || task.type === "settling" || task.type === "completed") return
    const outcome =
      task.type === "stopping"
        ? stopOutcome(task)
        : processSignal
          ? ({ type: "signaled", signal: processSignal } as const)
          : ({ type: "exited", exitCode: code ?? 1 } as const)
    this.#beginSettlement(task, outcome)
  }

  #beginSettlement(task: Exclude<ShellTask, CompletedTask | SettlingTask>, outcome: ShellTaskOutcome): void {
    if (task.type === "foreground" || task.type === "background") {
      clearTimeout(task.timeout)
      task.removeAbort?.()
    } else if (task.type === "stopping") {
      clearTimeout(task.killTimer)
    }
    const settling: SettlingTask = { ...task, type: "settling", outcome }
    this.#tasks.set(task.taskId, settling)
    this.#emit(task.taskId)
    void this.#finishSettlement(settling)
  }

  #forceDisposed(task: Exclude<ShellTask, CompletedTask>): void {
    if (task.type === "foreground" || task.type === "background") {
      clearTimeout(task.timeout)
      task.removeAbort?.()
      kill(task.child, "SIGKILL")
    } else if (task.type === "stopping") {
      clearTimeout(task.killTimer)
      kill(task.child, "SIGKILL")
    }
    task.output.abandon()
    const completedAt = Date.now()
    const completed: CompletedTask = {
      taskId: task.taskId,
      toolCallId: task.toolCallId,
      command: task.command,
      cwd: task.cwd,
      startedAt: task.startedAt,
      type: "completed",
      output: task.output,
      outcome: { type: "disposed" },
      completedAt,
      expiresAt: completedAt
    }
    this.#tasks.set(task.taskId, completed)
    const snapshot = this.#snapshot(completed)
    task.processSettled.resolve(snapshot)
    task.toolSettled.resolve({ type: "completed", task: snapshot })
  }

  async #finishSettlement(task: SettlingTask): Promise<void> {
    let outcome = task.outcome
    try {
      await task.output.finish()
    } catch (cause) {
      outcome = { type: "failed", message: errorMessage(cause) }
    }
    const current = this.#tasks.get(task.taskId)
    if (current !== task) return

    const completedAt = Date.now()
    const completed: CompletedTask = {
      taskId: task.taskId,
      toolCallId: task.toolCallId,
      command: task.command,
      cwd: task.cwd,
      startedAt: task.startedAt,
      type: "completed",
      output: task.output,
      outcome,
      completedAt,
      expiresAt: completedAt + this.limits.completedTaskTtlMs
    }
    this.#tasks.set(task.taskId, completed)
    const snapshot = this.#snapshot(completed)
    task.processSettled.resolve(snapshot)
    task.toolSettled.resolve({ type: "completed", task: snapshot })
    this.#enforceCompletedLimit()
    this.#scheduleEviction()
    this.#emit(task.taskId)
  }

  #snapshot(task: StartingTask): Extract<ShellTaskSnapshot, { type: "starting" }>
  #snapshot(task: ForegroundTask): Extract<ShellTaskSnapshot, { type: "foreground" }>
  #snapshot(task: BackgroundTask): Extract<ShellTaskSnapshot, { type: "background" }>
  #snapshot(task: StoppingTask): Extract<ShellTaskSnapshot, { type: "stopping" }>
  #snapshot(task: SettlingTask): Extract<ShellTaskSnapshot, { type: "settling" }>
  #snapshot(task: CompletedTask): Extract<ShellTaskSnapshot, { type: "completed" }>
  #snapshot(task: ShellTask): ShellTaskSnapshot
  #snapshot(task: ShellTask): ShellTaskSnapshot {
    const identity = {
      taskId: task.taskId,
      toolCallId: task.toolCallId,
      command: task.command,
      cwd: task.cwd,
      startedAt: task.startedAt,
      output: task.output.snapshot()
    }
    switch (task.type) {
      case "starting":
        return { ...identity, type: task.type, placement: task.placement }
      case "foreground":
      case "background":
        return { ...identity, type: task.type }
      case "stopping":
        return { ...identity, type: task.type, reason: task.reason }
      case "settling":
        return { ...identity, type: task.type, outcome: task.outcome }
      case "completed":
        return {
          ...identity,
          type: task.type,
          outcome: task.outcome,
          completedAt: task.completedAt,
          expiresAt: task.expiresAt
        }
      default:
        return assertNever(task)
    }
  }

  #scheduleUpdate(taskId: string): void {
    if (this.#state.type !== "open") return
    const now = Date.now()
    const elapsed = now - (this.#lastUpdates.get(taskId) ?? 0)
    if (elapsed >= outputUpdateIntervalMs) {
      this.#flushUpdate(taskId)
      return
    }
    if (this.#updateTimers.has(taskId)) return
    const timer = setTimeout(() => {
      this.#updateTimers.delete(taskId)
      this.#flushUpdate(taskId)
    }, outputUpdateIntervalMs - elapsed)
    timer.unref?.()
    this.#updateTimers.set(taskId, timer)
  }

  #flushUpdate(taskId: string): void {
    const task = this.#tasks.get(taskId)
    if (!task) return
    this.#lastUpdates.set(taskId, Date.now())
    if (task.type === "foreground") task.onUpdate?.(this.#snapshot(task))
    this.#emit(taskId)
  }

  #emit(taskId: string): void {
    for (const listener of this.#listeners) {
      try {
        listener(taskId)
      } catch {
        // A session observer cannot own process settlement.
      }
    }
  }

  #reserveOutput(requested: number): number {
    if (requested <= 0) return 0
    if (this.#retainedOutputBytes + requested > this.limits.maxRetainedOutputBytes) {
      for (const task of this.#completedByAge()) {
        if (task.output.available) {
          task.output.evict()
          this.#emit(task.taskId)
        }
        if (this.#retainedOutputBytes + requested <= this.limits.maxRetainedOutputBytes) break
      }
    }
    const available = Math.max(0, this.limits.maxRetainedOutputBytes - this.#retainedOutputBytes)
    const admitted = Math.min(requested, available)
    this.#retainedOutputBytes += admitted
    return admitted
  }

  #completedByAge(): CompletedTask[] {
    return [...this.#tasks.values()]
      .filter((task): task is CompletedTask => task.type === "completed")
      .toSorted((left, right) => left.completedAt - right.completedAt)
  }

  #enforceCompletedLimit(): void {
    const completed = this.#completedByAge()
    for (const task of completed.slice(0, Math.max(0, completed.length - this.limits.maxCompletedTasks))) {
      task.output.evict()
      this.#tasks.delete(task.taskId)
      this.#emit(task.taskId)
    }
  }

  #evictExpired(): void {
    if (this.#state.type !== "open") return
    const now = Date.now()
    for (const task of this.#completedByAge()) {
      if (task.expiresAt > now) break
      task.output.evict()
      this.#tasks.delete(task.taskId)
      this.#emit(task.taskId)
    }
    this.#scheduleEviction()
  }

  #scheduleEviction(): void {
    if (this.#evictionTimer) clearTimeout(this.#evictionTimer)
    this.#evictionTimer = undefined
    if (this.#state.type !== "open") return
    const next = this.#completedByAge()[0]
    if (!next) return
    this.#evictionTimer = setTimeout(() => this.#evictExpired(), Math.max(0, next.expiresAt - Date.now()))
    this.#evictionTimer.unref?.()
  }

  #outputPath(taskId: string): string {
    if (!this.#outputDir) {
      mkdirSync(this.#outputRoot, { recursive: true })
      const safeSession = this.sessionId.replaceAll(/[^A-Za-z0-9_-]/g, "_").slice(0, 32) || "session"
      this.#outputDir = mkdtempSync(join(this.#outputRoot, `zi-shell-${safeSession}-`))
    }
    return join(this.#outputDir, `${taskId}.log`)
  }

  #assertOpen(): void {
    if (this.#state.type !== "open") throw new Error("SessionShell is disposed")
  }
}

interface TaskOutputOptions {
  readonly path: string
  readonly maxBytes: number
  readonly reserve: (bytes: number) => number
  readonly release: (bytes: number) => void
  readonly changed: () => void
  readonly limitReached: () => void
  readonly failed: (cause: Error) => void
}

class TaskOutput {
  readonly path: string
  readonly #maxBytes: number
  readonly #reserve: (bytes: number) => number
  readonly #release: (bytes: number) => void
  readonly #changed: () => void
  readonly #limitReached: () => void
  readonly #failed: (cause: Error) => void
  readonly #file: WriteStream
  readonly #sources = new Map<NodeJS.ReadableStream, (chunk: Buffer) => void>()
  #tail = Buffer.alloc(0)
  #totalBytes = 0
  #newlines = 0
  #endsWithNewline = false
  #retainedBytes = 0
  #limitNotified = false
  #error: Error | undefined
  #finish: Promise<void> | undefined
  #evicted = false

  constructor(options: TaskOutputOptions) {
    this.path = options.path
    this.#maxBytes = options.maxBytes
    this.#reserve = options.reserve
    this.#release = options.release
    this.#changed = options.changed
    this.#limitReached = options.limitReached
    this.#failed = options.failed
    this.#file = createWriteStream(this.path)
    this.#file.on("error", cause => {
      this.#error = cause
      this.#failed(cause)
    })
  }

  get available(): boolean {
    return !this.#evicted
  }

  pipe(source: NodeJS.ReadableStream): void {
    const listener = (chunk: Buffer) => {
      this.#totalBytes += chunk.length
      this.#newlines += countByte(chunk, 10)
      if (chunk.length > 0) this.#endsWithNewline = chunk[chunk.length - 1] === 10
      this.#tail = Buffer.concat([this.#tail, chunk])
      if (this.#tail.length > DEFAULT_MAX_BYTES * 2) {
        let tailStart = this.#tail.length - DEFAULT_MAX_BYTES * 2
        while (tailStart < this.#tail.length && (this.#tail[tailStart]! & 0xc0) === 0x80) tailStart++
        this.#tail = this.#tail.subarray(tailStart)
      }

      const taskAvailable = Math.max(0, this.#maxBytes - this.#retainedBytes)
      const admitted = this.#reserve(Math.min(taskAvailable, chunk.length))
      if (admitted > 0) {
        this.#retainedBytes += admitted
        if (!this.#file.write(chunk.subarray(0, admitted))) {
          source.pause()
          this.#file.once("drain", () => source.resume())
        }
      }
      if (admitted < chunk.length && !this.#limitNotified) {
        this.#limitNotified = true
        this.#limitReached()
      }
      this.#changed()
    }
    this.#sources.set(source, listener)
    source.on("data", listener)
  }

  snapshot(): ShellTaskOutputSnapshot {
    const totalLines = this.#totalBytes === 0 ? 0 : this.#newlines + (this.#endsWithNewline ? 0 : 1)
    const base = truncateTail(this.#tail.toString(), DEFAULT_MAX_LINES, DEFAULT_MAX_BYTES)
    const truncated = this.#totalBytes > DEFAULT_MAX_BYTES || totalLines > DEFAULT_MAX_LINES
    const truncation: TruncationResult = {
      ...base,
      truncated,
      truncatedBy: truncated ? (totalLines > DEFAULT_MAX_LINES ? "lines" : "bytes") : null,
      totalBytes: this.#totalBytes,
      totalLines
    }
    const fullOutput = this.#evicted
      ? ({ type: "evicted", bytes: this.#retainedBytes, truncated: this.#limitNotified } as const)
      : ({ type: "available", path: this.path, bytes: this.#retainedBytes, truncated: this.#limitNotified } as const)
    return { text: truncation.content || "(no output)", truncation, fullOutput }
  }

  finish(): Promise<void> {
    if (this.#finish) return this.#finish
    this.#detachSources()
    this.#finish = new Promise<void>((resolve, reject) => {
      this.#file.end(() => {
        if (this.#error) reject(this.#error)
        else resolve()
      })
    })
    return this.#finish
  }

  evict(): void {
    if (this.#evicted) return
    this.#evicted = true
    this.#release(this.#retainedBytes)
    rmSync(this.path, { force: true })
  }

  abandon(): void {
    this.#detachSources()
    this.#file.destroy()
    this.evict()
  }

  #detachSources(): void {
    for (const [source, listener] of this.#sources) source.off("data", listener)
    this.#sources.clear()
  }
}

function stopOutcome(task: StoppingTask): ShellTaskOutcome {
  switch (task.reason) {
    case "abort":
      return { type: "aborted" }
    case "timeout":
      return { type: "timed_out" }
    case "killed":
      return { type: "killed" }
    case "output-limit":
      return { type: "output_limit" }
    case "dispose":
      return { type: "disposed" }
    case "output-error":
      return { type: "failed", message: task.failure ?? "Could not retain command output" }
    default:
      return assertNever(task.reason)
  }
}

function spawnShell(command: string, cwd: string): ChildProcessWithoutNullStreams {
  if (process.platform === "win32") {
    return spawn(process.env.ComSpec ?? "cmd.exe", ["/d", "/s", "/c", command], { cwd, windowsHide: true })
  }
  return spawn(process.env.SHELL ?? "/bin/bash", ["-lc", command], { cwd, detached: true })
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

function bindAbort(signal: AbortSignal, abort: () => void): () => void {
  signal.addEventListener("abort", abort, { once: true })
  return () => signal.removeEventListener("abort", abort)
}

function createDeferred<T>(): TaskDeferred<T> {
  let settled = false
  let resolvePromise!: (value: T) => void
  let rejectPromise!: (cause: unknown) => void
  const promise = new Promise<T>((resolve, reject) => {
    resolvePromise = resolve
    rejectPromise = reject
  })
  return {
    promise,
    get settled() {
      return settled
    },
    resolve(value) {
      if (settled) return
      settled = true
      resolvePromise(value)
    },
    reject(cause) {
      if (settled) return
      settled = true
      rejectPromise(cause)
    }
  }
}

function waitForTask(
  settlement: Promise<Extract<ShellTaskSnapshot, { type: "completed" }>>,
  timeoutMs: number,
  signal?: AbortSignal
): Promise<ShellTaskSnapshot> {
  if (signal?.aborted) return Promise.reject(new Error("Task wait aborted"))
  let timeout: ReturnType<typeof setTimeout> | undefined
  let removeAbort: (() => void) | undefined
  const wait = new Promise<never>((_, reject) => {
    timeout = setTimeout(() => reject(new Error(`Task wait timed out after ${timeoutMs} milliseconds`)), timeoutMs)
    if (signal) {
      const abort = () => reject(new Error("Task wait aborted"))
      signal.addEventListener("abort", abort, { once: true })
      removeAbort = () => signal.removeEventListener("abort", abort)
    }
  })
  return Promise.race([settlement, wait]).finally(() => {
    if (timeout) clearTimeout(timeout)
    removeAbort?.()
  })
}

async function settleWithin(operation: Promise<void>, timeoutMs: number): Promise<boolean> {
  let timeout: ReturnType<typeof setTimeout> | undefined
  const result = await Promise.race([
    operation.then(() => true),
    new Promise<false>(resolve => {
      timeout = setTimeout(() => resolve(false), timeoutMs)
    })
  ])
  if (timeout) clearTimeout(timeout)
  return result
}

function assertRunRequest(request: ShellRunRequest, limits: ShellLimits): void {
  if (!request.command) throw new ShellRunAdmissionError("invalid-command", "Command cannot be empty")
  if (!Number.isFinite(request.timeoutMs) || request.timeoutMs <= 0 || request.timeoutMs > limits.maxRuntimeMs) {
    throw new ShellRunAdmissionError(
      "invalid-timeout",
      `Command timeout must be between 0 and ${limits.maxRuntimeMs} milliseconds`
    )
  }
}

function assertLimits(limits: ShellLimits): void {
  for (const [name, value] of Object.entries(limits)) {
    if (!Number.isSafeInteger(value) || value <= 0) throw new Error(`Shell limit ${name} must be a positive integer`)
  }
  if (limits.maxOutputFileBytes > limits.maxRetainedOutputBytes) {
    throw new Error("Shell maxOutputFileBytes cannot exceed maxRetainedOutputBytes")
  }
}

function countByte(buffer: Buffer, byte: number): number {
  let count = 0
  for (const value of buffer) if (value === byte) count++
  return count
}

function errorMessage(cause: unknown): string {
  return cause instanceof Error ? cause.message : String(cause)
}

function assertNever(value: never): never {
  throw new Error(`Unexpected shell state: ${String(value)}`)
}
