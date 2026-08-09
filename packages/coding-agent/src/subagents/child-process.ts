/**
 * One ChildZiProcess owns exactly one spawned Zi RPC child, its stdin write tail,
 * stdout reader, protocol validation, diagnostics, and termination.
 *
 * Adapted from examples/rpc/client.ts; no private Zi imports.
 */

import { spawn } from "node:child_process"
import { Readable, Writable } from "node:stream"

import { isRecord } from "../guards.js"
import type { ProcessScope, ProcessTreeTracker } from "../processes/process-tree.js"
import {
  decodePeerRequestFrame,
  maxPeerRequests,
  peerFailureFrame,
  peerResponseFrame,
  type PeerRequest,
  type PeerResult
} from "./peer-protocol.js"
import { defaultSubagentWorkTimeoutMs, isSubagentWorkTimeout } from "./work-policy.js"

export const rpcProtocolVersion = 1 as const
export const maxRpcFrameBytes = 16 * 1024 * 1024
export const maxRpcPendingRequests = 32
export const maxRpcPendingWriteBytes = 16 * 1024 * 1024
export const maxRpcStderrBytes = 64 * 1024
export const rpcReadyTimeoutMs = 10_000
export const rpcResponseTimeoutMs = 30_000
export const workTimeoutSettlementMs = 10_000
export const interruptSettlementMs = 10_000
export const rpcCloseGraceMs = 5_000
export const rpcCloseForceMs = 5_000
export const maxChildSessionEvents = 256
export const maxChildSessionEventBytes = 256 * 1024
export const maxChildSessionEventBufferBytes = 1024 * 1024

export type ChildLifecycleState =
  | { readonly type: "starting"; readonly startedAt: number }
  | { readonly type: "idle"; readonly nextWorkCycle: number }
  | { readonly type: "spawn_admitting"; readonly workCycle: number; readonly startedAt: number }
  | { readonly type: "running"; readonly workCycle: number; readonly startedAt: number }
  | {
      readonly type: "interrupting"
      readonly workCycle: number
      readonly requestedAt: number
      readonly reason: "requested" | "work_timeout"
    }
  | { readonly type: "closing"; readonly reason: string; readonly requestedAt: number }
  | { readonly type: "exited"; readonly outcome: ChildExitOutcome }

export type ChildExitOutcome =
  | { readonly type: "closed"; readonly code: number | null }
  | { readonly type: "failed"; readonly message: string; readonly code: number | null }
  | { readonly type: "killed"; readonly message: string }

export type SubagentCompletionStatus = "completed" | "failed" | "cancelled"

export type SubagentCompletion = {
  readonly name: string
  readonly workCycle: number
  readonly status: SubagentCompletionStatus
  readonly text: string
  readonly originalBytes: number
  readonly omittedBytes: number
  readonly truncated: boolean
  readonly durationMs: number
  readonly reason?: string | undefined
  readonly error?: string | undefined
}

export type ChildSnapshot = {
  readonly name: string
  readonly lifecycle: ChildLifecycleState["type"]
  readonly workCycle?: number | undefined
  readonly elapsedMs?: number | undefined
  readonly sessionId?: string | undefined
  readonly completion?: SubagentCompletion | undefined
}

export type ChildSerializableSessionEvent = Readonly<Record<string, unknown>> & { readonly type: string }

export type ChildSessionEvent = {
  readonly sequence: number
  readonly rpcSequence: number
  readonly receivedAt: number
  readonly workCycle?: number | undefined
  readonly event: ChildSerializableSessionEvent
}

export type ChildSessionEventsSnapshot = {
  readonly name: string
  readonly events: readonly ChildSessionEvent[]
  readonly omittedEvents: number
  readonly omittedBytes: number
}

type PendingRequest = {
  readonly method: string
  readonly resolve: (value: unknown) => void
  readonly reject: (cause: unknown) => void
  readonly timeout?: ReturnType<typeof setTimeout>
}

type WorkDeadlineState =
  | { readonly type: "none" }
  | { readonly type: "running"; readonly workCycle: number; readonly timer: ReturnType<typeof setTimeout> }
  | { readonly type: "settling"; readonly workCycle: number; readonly timer: ReturnType<typeof setTimeout> }

type InterruptDeadlineState =
  | { readonly type: "none" }
  | { readonly type: "settling"; readonly workCycle: number; readonly timer: ReturnType<typeof setTimeout> }

type IdleWatchState = {
  readonly token: object
  readonly revision: number
  readonly phase: "waiting" | "resolved"
  readonly promise: Promise<void>
}

type ProcessExit = { readonly code: number | null; readonly signal: NodeJS.Signals | null }

type SpawnedRpcProcess = {
  readonly pid: number
  readonly input: Writable
  readonly stdout: Readable
  readonly stderr: Readable
  readonly exited: Promise<ProcessExit>
  kill(signal: NodeJS.Signals): void
}

export type ChildZiProcessOptions = {
  readonly name: string
  readonly command: readonly string[]
  readonly cwd: string
  readonly env: Readonly<Record<string, string | undefined>>
  readonly processTreeTracker: ProcessTreeTracker
  readonly workTimeoutMs?: number
  readonly responseTimeoutMs?: number
  readonly workTimeoutSettlementMs?: number
  readonly interruptSettlementMs?: number
  readonly onStateChange?: () => void
  readonly onCompletion?: (completion: SubagentCompletion) => void
  readonly onSessionEvent?: () => void
  readonly onPeerRequest?: (request: PeerRequest) => Promise<PeerResult>
  readonly onFatal?: (error: Error) => void
}

export class ChildZiProcess {
  readonly name: string
  readonly #child: SpawnedRpcProcess
  readonly #exited: Promise<ProcessExit>
  readonly #onStateChange: (() => void) | undefined
  readonly #onCompletion: ((completion: SubagentCompletion) => void) | undefined
  readonly #onSessionEvent: (() => void) | undefined
  readonly #onPeerRequest: ((request: PeerRequest) => Promise<PeerResult>) | undefined
  readonly #onFatal: ((error: Error) => void) | undefined
  readonly #workTimeoutMs: number
  readonly #responseTimeoutMs: number
  readonly #workTimeoutSettlementMs: number
  readonly #interruptSettlementMs: number
  readonly #ready = deferred<void>()
  readonly #pending = new Map<string, PendingRequest>()
  readonly #stdoutSettlement: Promise<void>
  readonly #stderrSettlement: Promise<void>
  readonly #processScope: ProcessScope
  #state: ChildLifecycleState
  #sessionId: string | undefined
  #completionId: string | undefined
  #completionRevision = 0
  #admissionRevision = 0
  #pendingCycleAdmission = 0
  #idleWatch: IdleWatchState | undefined
  #interruptInFlight = false
  #nextRequestId = 0
  #nextSequence = 1
  #writeTail = Promise.resolve()
  #closeSettlement: Promise<void> | undefined
  #pendingWriteBytes = 0
  #stderr = ""
  #latestCompletion: SubagentCompletion | undefined
  #sessionEvents: ChildSessionEvent[] = []
  #sessionEventBytes = 0
  #omittedSessionEvents = 0
  #omittedSessionEventBytes = 0
  #nextSessionEventSequence = 1
  readonly #peerRequests = new Set<Promise<void>>()
  readonly #peerRequestIds = new Set<string>()
  #cycleStartedAt = 0
  #workDeadline: WorkDeadlineState = { type: "none" }
  #interruptDeadline: InterruptDeadlineState = { type: "none" }

  constructor(options: ChildZiProcessOptions) {
    this.name = options.name
    this.#onStateChange = options.onStateChange
    this.#onCompletion = options.onCompletion
    this.#onSessionEvent = options.onSessionEvent
    this.#onPeerRequest = options.onPeerRequest
    this.#onFatal = options.onFatal
    this.#workTimeoutMs = options.workTimeoutMs ?? defaultSubagentWorkTimeoutMs
    this.#responseTimeoutMs = options.responseTimeoutMs ?? rpcResponseTimeoutMs
    this.#workTimeoutSettlementMs = options.workTimeoutSettlementMs ?? workTimeoutSettlementMs
    this.#interruptSettlementMs = options.interruptSettlementMs ?? interruptSettlementMs
    if (!isSubagentWorkTimeout(this.#workTimeoutMs)) throw new Error("Invalid subagent work timeout")
    if (!isPositiveTimeout(this.#responseTimeoutMs)) throw new Error("Invalid RPC response timeout")
    if (!isPositiveTimeout(this.#workTimeoutSettlementMs)) throw new Error("Invalid work-timeout settlement bound")
    if (!isPositiveTimeout(this.#interruptSettlementMs)) throw new Error("Invalid interrupt settlement bound")
    this.#state = { type: "starting", startedAt: Date.now() }
    const executable = options.command[0]
    if (!executable) throw new Error("Subagent command cannot be empty")
    this.#child = spawnRpcProcess(executable, options.command.slice(1), options.cwd, options.env, cause =>
      this.#fail(cause)
    )
    this.#exited = this.#child.exited
    this.#processScope = createChildProcessScope(this.#child.pid, this.#child, options.processTreeTracker, cause =>
      this.#fail(cause)
    )
    this.#stdoutSettlement = this.#consumeStdout().catch(cause => this.#fail(cause))
    this.#stderrSettlement = this.#consumeStderr().catch(cause => this.#fail(cause))
    void this.#exited.then(async exit => {
      await settleWithin(this.#stderrSettlement, 1_000)
      if (this.#state.type !== "closing" && this.#state.type !== "exited") {
        const diagnostic = this.#stderr.trim()
        const status = exit.signal ? `signal ${exit.signal}` : `code ${String(exit.code)}`
        this.#fail(
          new Error(`Subagent ${this.name} exited unexpectedly with ${status}${diagnostic ? `: ${diagnostic}` : ""}`)
        )
      }
      return undefined
    })
  }

  get state(): ChildLifecycleState {
    return this.#state
  }

  snapshot(): ChildSnapshot {
    const state = this.#state
    const activeSince =
      state.type === "starting" || state.type === "spawn_admitting" || state.type === "running"
        ? state.startedAt
        : state.type === "interrupting"
          ? this.#cycleStartedAt
          : undefined
    return {
      name: this.name,
      lifecycle: state.type,
      ...(state.type === "running" ||
      state.type === "spawn_admitting" ||
      state.type === "interrupting" ||
      state.type === "idle"
        ? {
            workCycle:
              state.type === "idle"
                ? Math.max(0, state.nextWorkCycle - 1)
                : "workCycle" in state
                  ? state.workCycle
                  : undefined
          }
        : {}),
      ...(activeSince !== undefined
        ? { elapsedMs: Math.max(0, Date.now() - activeSince) }
        : this.#latestCompletion
          ? { elapsedMs: this.#latestCompletion.durationMs }
          : {}),
      ...(this.#sessionId ? { sessionId: this.#sessionId } : {}),
      ...(this.#latestCompletion ? { completion: this.#latestCompletion } : {})
    }
  }

  sessionEvents(): ChildSessionEventsSnapshot {
    return Object.freeze({
      name: this.name,
      events: Object.freeze([...this.#sessionEvents]),
      omittedEvents: this.#omittedSessionEvents,
      omittedBytes: this.#omittedSessionEventBytes
    })
  }

  async start(): Promise<void> {
    const reached = await settleWithin(
      Promise.all([this.#ready.promise, this.#processScope.admitted]).then(() => undefined),
      rpcReadyTimeoutMs
    )
    if (!reached) {
      const error = new Error(`Subagent ${this.name} did not become ready within ${rpcReadyTimeoutMs}ms`)
      this.#fail(error)
      throw error
    }
    await this.#request("connection.set_events", { mode: "activity" }, this.#responseTimeoutMs)
    const state = await this.#request("session.get_state", undefined, this.#responseTimeoutMs)
    if (isRecord(state) && typeof state.sessionId === "string") this.#sessionId = state.sessionId
    this.#transition({ type: "idle", nextWorkCycle: 1 })
  }

  async spawnAdmit(prompt: string): Promise<void> {
    const state = this.#state
    if (state.type !== "idle") throw new Error(`Subagent ${this.name} cannot spawn-admit while ${state.type}`)
    const workCycle = state.nextWorkCycle
    this.#transition({ type: "spawn_admitting", workCycle, startedAt: Date.now() })
    this.#completionId = String(workCycle)
    this.#completionRevision = 0
    this.#beginCycleAdmission()
    try {
      const result = await this.#request(
        "session.prompt",
        { delivery: "direct", text: prompt, completionId: this.#completionId },
        this.#responseTimeoutMs
      )
      this.#acceptCompletionAdmission(result)
    } catch (cause) {
      this.#endCycleAdmission()
      throw cause
    }
    this.#endCycleAdmission()
    const admitted = this.#state
    if (admitted.type === "idle" && admitted.nextWorkCycle === workCycle + 1) return
    if (admitted.type === "interrupting" && admitted.workCycle === workCycle) {
      this.#watchIdle(this.#admissionRevision)
      return
    }
    if (admitted.type !== "spawn_admitting" || admitted.workCycle !== workCycle) {
      throw new Error(`Subagent ${this.name} changed state during spawn admission`)
    }
    this.#cycleStartedAt = Date.now()
    this.#transition({ type: "running", workCycle, startedAt: this.#cycleStartedAt })
    this.#armWorkDeadline(workCycle)
    this.#watchIdle(this.#admissionRevision)
  }

  async sendFollowUp(text: string): Promise<void> {
    const state = this.#state
    if (state.type === "interrupting" && state.reason === "work_timeout") {
      throw new Error(`Subagent ${this.name} work cycle deadline has expired`)
    }
    if (state.type !== "idle" && state.type !== "running" && state.type !== "interrupting") {
      throw new Error(`Subagent ${this.name} cannot accept send while ${state.type}`)
    }
    if (state.type === "interrupting") {
      throw new Error(`Subagent ${this.name} cannot accept send while interrupting`)
    }
    const running = state.type === "running"
    if (running) this.#beginCycleAdmission()
    try {
      const result = await this.#request(
        "session.prompt",
        { delivery: "follow_up", text, ...(running && this.#completionId ? { completionId: this.#completionId } : {}) },
        this.#responseTimeoutMs
      )
      if (running) this.#acceptCompletionAdmission(result, true)
    } catch (cause) {
      if (running) {
        this.#endCycleAdmission()
        this.#watchIdle(this.#admissionRevision)
      }
      throw cause
    }
    if (running) {
      this.#endCycleAdmission()
      this.#watchIdle(this.#admissionRevision)
    }
  }

  async continueWith(text: string): Promise<void> {
    const state = this.#state
    if (state.type === "interrupting" && state.reason === "work_timeout") {
      throw new Error(`Subagent ${this.name} work cycle deadline has expired`)
    }
    if (state.type === "idle") {
      const workCycle = state.nextWorkCycle
      this.#transition({ type: "running", workCycle, startedAt: Date.now() })
      this.#completionId = String(workCycle)
      this.#completionRevision = 0
      this.#beginCycleAdmission()
      try {
        const result = await this.#request(
          "session.prompt",
          { delivery: "continue", text, completionId: this.#completionId },
          this.#responseTimeoutMs
        )
        this.#acceptCompletionAdmission(result)
      } catch (cause) {
        this.#endCycleAdmission()
        // Failed continue after idle transition: recover via get_state.
        await this.#recoverAfterFailedContinue()
        throw cause
      }
      this.#endCycleAdmission()
      this.#cycleStartedAt = Date.now()
      this.#armWorkDeadline(workCycle)
      this.#watchIdle(this.#admissionRevision)
      return
    }
    if (state.type !== "running") {
      throw new Error(`Subagent ${this.name} cannot continue while ${state.type}`)
    }
    this.#beginCycleAdmission()
    try {
      const result = await this.#request(
        "session.prompt",
        { delivery: "continue", text, ...(this.#completionId ? { completionId: this.#completionId } : {}) },
        this.#responseTimeoutMs
      )
      this.#acceptCompletionAdmission(result)
    } catch (cause) {
      this.#endCycleAdmission()
      this.#watchIdle(this.#admissionRevision)
      throw cause
    }
    this.#endCycleAdmission()
    this.#watchIdle(this.#admissionRevision)
  }

  async interrupt(): Promise<"interrupted" | "already_idle"> {
    const state = this.#state
    if (state.type === "idle") return "already_idle"
    if (state.type === "interrupting") return "interrupted"
    if (state.type !== "running" && state.type !== "spawn_admitting") {
      throw new Error(`Subagent ${this.name} cannot interrupt while ${state.type}`)
    }
    if (this.#interruptInFlight) return "interrupted"
    const workCycle = state.workCycle
    if (state.type === "spawn_admitting") this.#cycleStartedAt = Date.now()
    this.#clearWorkDeadline(workCycle)
    this.#transition({ type: "interrupting", workCycle, requestedAt: Date.now(), reason: "requested" })
    this.#armInterruptDeadline(workCycle)
    this.#beginCycleAdmission()
    this.#interruptInFlight = true
    try {
      await this.#request("session.interrupt", undefined, undefined)
    } catch (cause) {
      this.#interruptInFlight = false
      this.#endCycleAdmission()
      this.#clearInterruptDeadline(workCycle)
      const current = this.#state
      if (current.type === "interrupting" && current.workCycle === workCycle && current.reason === "requested") {
        if (state.type === "spawn_admitting") {
          this.#transition(state)
        } else {
          this.#transition({ type: "running", workCycle, startedAt: this.#cycleStartedAt })
          this.#armWorkDeadline(workCycle)
          this.#watchIdle(this.#admissionRevision)
        }
      }
      throw cause
    }
    this.#interruptInFlight = false
    this.#endCycleAdmission()
    this.#watchIdle(this.#admissionRevision)
    return "interrupted"
  }

  async close(reason = "close", graceMs = rpcCloseGraceMs, forceMs = rpcCloseForceMs): Promise<void> {
    const state = this.#state
    if (state.type === "interrupting" && state.reason === "work_timeout") {
      this.#publishWorkTimeoutFailure(
        state.workCycle,
        new Error(`Subagent ${this.name} work cycle ${state.workCycle} exceeded ${this.#workTimeoutMs}ms`)
      )
    }
    this.#clearWorkDeadline()
    this.#clearInterruptDeadline()
    if (state.type === "exited") return
    if (this.#closeSettlement) {
      await this.#closeSettlement
      return
    }
    const settlement = Promise.resolve().then(() => this.#settleClose(graceMs, forceMs))
    this.#closeSettlement = settlement
    this.#transition({ type: "closing", reason, requestedAt: Date.now() })
    this.#peerRequests.clear()
    this.#peerRequestIds.clear()
    this.#rejectPending(new Error(`Subagent ${this.name} is closing`))
    await settlement
  }

  #request(
    method: string,
    params: Readonly<Record<string, unknown>> | undefined,
    timeoutMs: number | undefined
  ): Promise<unknown> {
    if (this.#state.type === "closing" || this.#state.type === "exited") {
      return Promise.reject(new Error(`Subagent ${this.name} is ${this.#state.type}`))
    }
    if (this.#state.type === "starting" && method !== "connection.set_events" && method !== "session.get_state") {
      // Only startup methods before ready transition to idle.
    }
    if (this.#pending.size >= maxRpcPendingRequests) {
      return Promise.reject(new Error(`Subagent ${this.name} has too many pending RPC requests`))
    }
    const id = String(++this.#nextRequestId)
    const line = `${JSON.stringify({ version: rpcProtocolVersion, id, method, ...(params ? { params } : {}) })}\n`
    const bytes = Buffer.byteLength(line)
    if (bytes > maxRpcFrameBytes) {
      return Promise.reject(new Error(`RPC request exceeds ${maxRpcFrameBytes} bytes`))
    }
    if (this.#pendingWriteBytes + bytes > maxRpcPendingWriteBytes) {
      return Promise.reject(new Error(`RPC pending writes exceed ${maxRpcPendingWriteBytes} bytes`))
    }
    const settlement = deferred<unknown>()
    const timeout =
      timeoutMs === undefined
        ? undefined
        : setTimeout(() => {
            const pending = this.#pending.get(id)
            if (!pending) return
            this.#pending.delete(id)
            const error = new Error(`RPC request ${method} timed out`)
            pending.reject(error)
            this.#fail(error)
          }, timeoutMs)
    timeout?.unref?.()
    this.#pending.set(id, {
      method,
      resolve: settlement.resolve,
      reject: settlement.reject,
      ...(timeout ? { timeout } : {})
    })
    this.#enqueueWrite(line, bytes)
    return settlement.promise
  }

  #acceptCompletionAdmission(value: unknown, allowUnchanged = false): void {
    const revision = isRecord(value) ? value.completionRevision : undefined
    if (typeof revision !== "number" || !Number.isSafeInteger(revision)) {
      const error = new Error("Invalid RPC completion admission")
      this.#fail(error)
      throw error
    }
    if (allowUnchanged && revision === this.#completionRevision) return
    if (revision !== this.#completionRevision + 1) {
      const error = new Error("RPC completion admission revision did not advance")
      this.#fail(error)
      throw error
    }
    this.#completionRevision = revision
  }

  #beginCycleAdmission(): void {
    this.#admissionRevision++
    this.#pendingCycleAdmission++
    const watch = this.#idleWatch
    if (!watch) return
    if (watch.phase === "waiting") {
      this.#idleWatch = { ...watch, revision: this.#admissionRevision }
      return
    }
    this.#idleWatch = undefined
    const state = this.#state
    if (state.type === "running" && this.#workDeadline.type === "none") this.#armWorkDeadline(state.workCycle)
  }

  #endCycleAdmission(): void {
    this.#pendingCycleAdmission = Math.max(0, this.#pendingCycleAdmission - 1)
  }

  #armWorkDeadline(workCycle: number): void {
    this.#clearWorkDeadline()
    const remainingMs = Math.max(0, this.#cycleStartedAt + this.#workTimeoutMs - Date.now())
    const timer = setTimeout(() => this.#expireWorkCycle(workCycle), remainingMs)
    timer.unref?.()
    this.#workDeadline = { type: "running", workCycle, timer }
  }

  #expireWorkCycle(workCycle: number): void {
    const deadline = this.#workDeadline
    const state = this.#state
    if (deadline.type !== "running" || deadline.workCycle !== workCycle) return
    if (state.type !== "running" || state.workCycle !== workCycle) return

    const timer = setTimeout(() => {
      const error = new Error(
        `Subagent ${this.name} work cycle ${workCycle} exceeded ${this.#workTimeoutMs}ms and did not settle within ${this.#workTimeoutSettlementMs}ms`
      )
      this.#publishWorkTimeoutFailure(workCycle, error)
      this.#fail(error)
    }, this.#workTimeoutSettlementMs)
    timer.unref?.()
    this.#workDeadline = { type: "settling", workCycle, timer }
    this.#transition({ type: "interrupting", workCycle, requestedAt: Date.now(), reason: "work_timeout" })
    this.#beginCycleAdmission()
    const revision = this.#admissionRevision
    this.#interruptInFlight = true
    void this.#request("session.interrupt", undefined, undefined).then(
      () => {
        this.#interruptInFlight = false
        this.#endCycleAdmission()
        const current = this.#state
        if (current.type === "interrupting" && current.workCycle === workCycle && current.reason === "work_timeout") {
          this.#watchIdle(revision)
        }
        return undefined
      },
      cause => {
        this.#interruptInFlight = false
        this.#endCycleAdmission()
        const detail = cause instanceof Error ? cause.message : String(cause)
        const error = new Error(
          `Subagent ${this.name} work cycle ${workCycle} exceeded ${this.#workTimeoutMs}ms; interruption failed: ${detail}`,
          { cause }
        )
        this.#publishWorkTimeoutFailure(workCycle, error)
        this.#fail(error)
        return undefined
      }
    )
  }

  #clearWorkDeadline(workCycle?: number): void {
    const deadline = this.#workDeadline
    if (deadline.type === "none" || (workCycle !== undefined && deadline.workCycle !== workCycle)) return
    clearTimeout(deadline.timer)
    this.#workDeadline = { type: "none" }
  }

  #armInterruptDeadline(workCycle: number): void {
    this.#clearInterruptDeadline()
    const timer = setTimeout(() => {
      const state = this.#state
      if (state.type !== "interrupting" || state.reason !== "requested" || state.workCycle !== workCycle) return
      const error = new Error(
        `Subagent ${this.name} interruption did not settle within ${this.#interruptSettlementMs}ms`
      )
      this.#publishInterruptSettlementFailure(workCycle, error, "interrupt_settlement_timeout")
      this.#fail(error)
    }, this.#interruptSettlementMs)
    timer.unref?.()
    this.#interruptDeadline = { type: "settling", workCycle, timer }
  }

  #clearInterruptDeadline(workCycle?: number): void {
    const deadline = this.#interruptDeadline
    if (deadline.type === "none" || (workCycle !== undefined && deadline.workCycle !== workCycle)) return
    clearTimeout(deadline.timer)
    this.#interruptDeadline = { type: "none" }
  }

  #watchIdle(revision: number): void {
    const current = this.#idleWatch
    if (current?.phase === "waiting") {
      this.#idleWatch = { ...current, revision }
      return
    }
    const token = {}
    const completionId = this.#completionId
    if (!completionId) {
      this.#fail(new Error(`Subagent ${this.name} has no active completion watch`))
      return
    }
    const promise = this.#request("session.await_idle", { completionId }, undefined)
      .then((result): Promise<void> => {
        const watch = this.#idleWatch
        if (!watch || watch.token !== token) return Promise.resolve()
        this.#idleWatch = { ...watch, phase: "resolved" }
        return this.#onIdle(this.#idleWatch.revision, result)
      })
      .catch(cause => {
        if (this.#state.type === "closing" || this.#state.type === "exited") return
        this.#fail(cause)
      })
    this.#idleWatch = { token, revision, phase: "waiting", promise }
  }

  async #onIdle(revision: number, result: unknown): Promise<void> {
    if (this.#idleWatch?.revision !== revision) return
    if (this.#pendingCycleAdmission > 0) return
    if (this.#admissionRevision !== revision) return
    const state = this.#state
    if (state.type !== "running" && state.type !== "interrupting") return
    const workCycle = state.workCycle
    const durationMs = Math.max(0, Date.now() - this.#cycleStartedAt)
    const observed = completionFromIdleResult(this.name, workCycle, durationMs, result)
    if (observed.completionRevision !== this.#completionRevision) {
      this.#idleWatch = undefined
      this.#watchIdle(this.#admissionRevision)
      return
    }
    if (state.type === "running") this.#clearWorkDeadline(workCycle)

    // Settled work is a containment admission barrier for background processes started during the cycle.
    if ((await this.#processScope.refresh()).type === "overflow") {
      throw new Error("Subagent process scope exceeded tracked descendant capacity")
    }
    if (!this.#ownsIdleCompletion(revision, workCycle)) return
    this.#clearWorkDeadline(workCycle)
    this.#clearInterruptDeadline(workCycle)
    const terminal = this.#state
    const timedOut = terminal.type === "interrupting" && terminal.reason === "work_timeout"
    const completion = timedOut
      ? {
          ...observed.completion,
          status: "failed" as const,
          reason: "work_cycle_timeout",
          error: `Subagent work cycle exceeded ${this.#workTimeoutMs}ms`
        }
      : observed.completion
    this.#publishCompletion(completion)
    this.#idleWatch = undefined
    this.#transition({ type: "idle", nextWorkCycle: workCycle + 1 })
  }

  #ownsIdleCompletion(revision: number, workCycle: number): boolean {
    if (this.#idleWatch?.revision !== revision || this.#pendingCycleAdmission > 0) return false
    if (this.#admissionRevision !== revision) return false
    const state = this.#state
    return (state.type === "running" || state.type === "interrupting") && state.workCycle === workCycle
  }

  #publishWorkTimeoutFailure(workCycle: number, error: Error): void {
    if (this.#latestCompletion?.workCycle === workCycle) return
    const completion = {
      ...baseCompletion(
        this.name,
        workCycle,
        Math.max(0, Date.now() - this.#cycleStartedAt),
        "failed",
        "",
        "work_cycle_timeout"
      ),
      error: error.message
    }
    this.#clearWorkDeadline(workCycle)
    this.#publishCompletion(completion)
  }

  #publishInterruptSettlementFailure(workCycle: number, error: Error, reason: string): void {
    if (this.#latestCompletion?.workCycle === workCycle) return
    this.#clearInterruptDeadline(workCycle)
    this.#publishCompletion({
      ...baseCompletion(this.name, workCycle, Math.max(0, Date.now() - this.#cycleStartedAt), "failed", "", reason),
      error: error.message
    })
  }

  #publishCompletion(completion: SubagentCompletion): void {
    this.#latestCompletion = completion
    try {
      this.#onCompletion?.(completion)
    } catch {
      // Process ownership cannot cross into an observer.
    }
  }

  async #recoverAfterFailedContinue(): Promise<void> {
    try {
      const state = await this.#request("session.get_state", undefined, this.#responseTimeoutMs)
      const activity = isRecord(state) && isRecord(state.activity) ? state.activity.type : undefined
      if (activity === "idle") {
        const current = this.#state
        const workCycle =
          current.type === "running" || current.type === "interrupting" || current.type === "spawn_admitting"
            ? current.workCycle
            : 0
        this.#clearWorkDeadline(workCycle)
        this.#transition({ type: "idle", nextWorkCycle: workCycle + 1 })
        return
      }
      this.#watchIdle(this.#admissionRevision)
    } catch (cause) {
      this.#fail(cause)
    }
  }

  async #consumeStdout(): Promise<void> {
    const decoder = new JsonLineDecoder()
    for await (const chunk of this.#child.stdout) {
      for (const line of decoder.push(chunk)) this.#receive(line)
    }
    for (const line of decoder.finish()) this.#receive(line)
  }

  async #consumeStderr(): Promise<void> {
    const decoder = new TextDecoder("utf-8", { fatal: true })
    let bytes = 0
    try {
      for await (const chunk of this.#child.stderr) {
        bytes += chunk.byteLength
        if (bytes > maxRpcStderrBytes) throw new Error(`Subagent stderr exceeded ${maxRpcStderrBytes} bytes`)
        this.#stderr += decoder.decode(chunk, { stream: true })
      }
      this.#stderr += decoder.decode()
    } catch (cause) {
      if (cause instanceof TypeError) throw new Error("Subagent stderr must be valid UTF-8", { cause })
      throw cause
    }
  }

  #receive(line: string): void {
    let frame: unknown
    try {
      frame = JSON.parse(line)
    } catch {
      throw new Error("Subagent RPC emitted invalid JSONL")
    }
    if (!isRecord(frame) || frame.version !== 1 || !Number.isSafeInteger(frame.sequence)) {
      throw new Error("Subagent RPC emitted an invalid server frame")
    }
    if (frame.sequence !== this.#nextSequence) {
      throw new Error(`RPC sequence gap: expected ${this.#nextSequence}, received ${String(frame.sequence)}`)
    }
    this.#nextSequence++

    switch (frame.type) {
      case "ready":
        if (this.#state.type !== "starting" || !isRecord(frame.state)) {
          throw new Error("Subagent RPC emitted an invalid ready frame")
        }
        if (typeof frame.state.sessionId === "string") this.#sessionId = frame.state.sessionId
        this.#ready.resolve()
        return
      case "session_event":
        this.#receiveSessionEvent(frame)
        return
      case "peer_request":
        this.#receivePeerRequest(frame)
        return
      case "response":
        this.#receiveResponse(frame)
        return
      case "protocol_error":
        throw new Error(
          `Subagent RPC protocol error: ${typeof frame.message === "string" ? frame.message : "protocol error"}`
        )
      default:
        throw new Error(`Subagent RPC unknown frame type: ${String(frame.type)}`)
    }
  }

  #receiveSessionEvent(frame: Record<string, unknown>): void {
    const event = cloneRpcSessionEvent(frame.event)
    const rpcSequence = frame.sequence
    if (typeof rpcSequence !== "number" || !Number.isSafeInteger(rpcSequence) || !event) {
      throw new Error("Subagent RPC emitted an invalid session event")
    }
    const serialized = JSON.stringify(event)
    const bytes = Buffer.byteLength(serialized)
    if (bytes > maxChildSessionEventBytes) {
      this.#omittedSessionEvents++
      this.#omittedSessionEventBytes += bytes
      this.#notifySessionEvent()
      return
    }
    this.#sessionEvents.push({
      sequence: this.#nextSessionEventSequence++,
      rpcSequence,
      receivedAt: Date.now(),
      ...currentWorkCycle(this.#state),
      event
    })
    this.#sessionEventBytes += bytes
    while (
      this.#sessionEvents.length > maxChildSessionEvents ||
      this.#sessionEventBytes > maxChildSessionEventBufferBytes
    ) {
      const removed = this.#sessionEvents.shift()
      if (!removed) break
      const removedBytes = Buffer.byteLength(JSON.stringify(removed.event))
      this.#sessionEventBytes = Math.max(0, this.#sessionEventBytes - removedBytes)
      this.#omittedSessionEvents++
      this.#omittedSessionEventBytes += removedBytes
    }
    this.#notifySessionEvent()
  }

  #receivePeerRequest(frame: Record<string, unknown>): void {
    const request = decodePeerRequestFrame(frame)
    if (this.#state.type === "starting" || this.#state.type === "closing" || this.#state.type === "exited") {
      throw new Error(`Subagent ${this.name} emitted a peer request while ${this.#state.type}`)
    }
    if (this.#peerRequestIds.has(request.id)) throw new Error(`Duplicate peer request id: ${request.id}`)
    const handler = this.#onPeerRequest
    if (!handler) {
      this.#sendPeerFrame(peerFailureFrame(request, "Peer messaging is unavailable"))
      return
    }
    if (this.#peerRequests.size >= maxPeerRequests) {
      this.#sendPeerFrame(peerFailureFrame(request, `At most ${maxPeerRequests} peer requests may be active`))
      return
    }
    this.#peerRequestIds.add(request.id)
    const operation = handler(request)
      .then(
        result => this.#sendPeerFrame(peerResponseFrame(request, result)),
        cause => this.#sendPeerFrame(peerFailureFrame(request, cause instanceof Error ? cause.message : String(cause)))
      )
      .catch(cause => this.#fail(cause))
      .finally(() => {
        this.#peerRequests.delete(operation)
        this.#peerRequestIds.delete(request.id)
      })
    this.#peerRequests.add(operation)
  }

  #sendPeerFrame(frame: Readonly<Record<string, unknown>>): void {
    if (this.#state.type === "closing" || this.#state.type === "exited") return
    const line = `${JSON.stringify(frame)}\n`
    const bytes = Buffer.byteLength(line)
    if (bytes > maxRpcFrameBytes) throw new Error(`Peer response exceeds ${maxRpcFrameBytes} bytes`)
    if (this.#pendingWriteBytes + bytes > maxRpcPendingWriteBytes) {
      throw new Error(`RPC pending writes exceed ${maxRpcPendingWriteBytes} bytes`)
    }
    this.#enqueueWrite(line, bytes)
  }

  #notifySessionEvent(): void {
    try {
      this.#onSessionEvent?.()
    } catch {
      // Process ownership cannot cross into an observer.
    }
  }

  #receiveResponse(frame: Record<string, unknown>): void {
    if (typeof frame.id !== "string" || typeof frame.method !== "string") {
      throw new Error("Subagent RPC emitted an invalid response")
    }
    const pending = this.#pending.get(frame.id)
    if (!pending) throw new Error(`Subagent RPC responded to unknown request ${frame.id}`)
    if (pending.method !== frame.method) {
      throw new Error(`Subagent RPC method mismatch: expected ${pending.method}, received ${frame.method}`)
    }
    if (pending.timeout) clearTimeout(pending.timeout)
    this.#pending.delete(frame.id)
    if (frame.ok === true) {
      pending.resolve(frame.result)
      return
    }
    if (frame.ok !== false || !isRecord(frame.error) || typeof frame.error.message !== "string") {
      throw new Error("Subagent RPC emitted an invalid failure response")
    }
    pending.reject(new Error(frame.error.message))
  }

  #enqueueWrite(line: string, bytes: number): void {
    this.#pendingWriteBytes += bytes
    const write = this.#writeTail.then(() => writeNodeInput(this.#child.input, line))
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

  #fail(cause: unknown): void {
    const state = this.#state
    if (state.type === "exited" || state.type === "closing") return
    const error = cause instanceof Error ? cause : new Error(String(cause))
    if (state.type === "interrupting") {
      if (state.reason === "work_timeout") {
        this.#publishWorkTimeoutFailure(
          state.workCycle,
          new Error(
            `Subagent ${this.name} work cycle ${state.workCycle} exceeded ${this.#workTimeoutMs}ms; settlement failed: ${error.message}`,
            { cause: error }
          )
        )
      } else {
        this.#publishInterruptSettlementFailure(
          state.workCycle,
          new Error(`Subagent ${this.name} interruption settlement failed: ${error.message}`, { cause: error }),
          "interrupt_settlement_failed"
        )
      }
    }
    this.#clearWorkDeadline()
    this.#clearInterruptDeadline()
    if (this.#state.type === "starting") this.#ready.reject(error)
    this.#rejectPending(error)
    const settlement = Promise.resolve().then(() => this.#settleClose(rpcCloseForceMs, rpcCloseForceMs, error))
    this.#closeSettlement = settlement
    this.#transition({ type: "closing", reason: "fatal", requestedAt: Date.now() })
    try {
      this.#child.kill("SIGKILL")
    } catch {
      // already dead
    }
    try {
      this.#onFatal?.(error)
    } catch {
      // Process ownership cannot cross into an observer.
    }
    void settlement
  }

  async #settleClose(graceMs: number, forceMs: number, failure?: Error): Promise<void> {
    const gracefulEndsAt = Date.now() + graceMs
    if (!failure) {
      await settleWithin(
        Promise.allSettled([this.#writeTail]).then(() => undefined),
        deadlineRemainingMs(gracefulEndsAt)
      )
      await settleWithin(
        Promise.resolve()
          .then(() => endNodeInput(this.#child.input))
          .then(() => undefined)
          .catch(() => undefined),
        deadlineRemainingMs(gracefulEndsAt)
      )
    }
    let exitCode = await settleValueWithin(this.#exited, failure ? forceMs : deadlineRemainingMs(gracefulEndsAt))
    if (exitCode === timeoutValue) {
      try {
        this.#child.kill("SIGKILL")
      } catch {
        // The process exited at the force boundary.
      }
      exitCode = await settleValueWithin(this.#exited, forceMs)
    }
    await this.#processScope.terminate().catch(() => {})
    await settleWithin(
      Promise.allSettled([this.#writeTail, this.#stdoutSettlement, this.#stderrSettlement]).then(() => undefined),
      1_000
    )
    if (this.#state.type === "exited") return
    if (failure) {
      this.#transition({
        type: "exited",
        outcome: { type: "failed", message: failure.message, code: exitCode === timeoutValue ? null : exitCode.code }
      })
      return
    }
    if (exitCode === timeoutValue) {
      this.#transition({
        type: "exited",
        outcome: { type: "killed", message: `Subagent ${this.name} did not exit within close bounds` }
      })
      return
    }
    if (exitCode.signal) {
      this.#transition({
        type: "exited",
        outcome: { type: "killed", message: `Subagent ${this.name} exited after ${exitCode.signal}` }
      })
      return
    }
    const code = exitCode.code
    this.#transition({
      type: "exited",
      outcome: code === 0 ? { type: "closed", code } : { type: "failed", message: this.#stderr.trim(), code }
    })
  }

  #rejectPending(cause: Error): void {
    for (const pending of this.#pending.values()) {
      if (pending.timeout) clearTimeout(pending.timeout)
      pending.reject(cause)
    }
    this.#pending.clear()
  }

  #transition(next: ChildLifecycleState): void {
    this.#state = next
    try {
      this.#onStateChange?.()
    } catch {
      // Process ownership cannot cross into an observer.
    }
  }
}

function spawnRpcProcess(
  executable: string,
  args: readonly string[],
  cwd: string,
  env: Readonly<Record<string, string | undefined>>,
  onFailure: (error: Error) => void
): SpawnedRpcProcess {
  if (process.platform === "win32") {
    const child = spawn(executable, args, { cwd, env: { ...env }, stdio: ["pipe", "pipe", "pipe"], windowsHide: true })
    const pid = child.pid
    if (pid === undefined || !child.stdin || !child.stdout || !child.stderr) {
      child.once("error", ignoreStreamError)
      child.kill("SIGKILL")
      throw new Error("Subagent process did not expose all required pipes")
    }
    const input = child.stdin
    input.on("error", ignoreStreamError)
    input.once("close", () => input.off("error", ignoreStreamError))
    child.on("error", onFailure)
    const exited = new Promise<ProcessExit>(resolveExit => {
      child.once("close", (code, signal) => resolveExit({ code, signal }))
    })
    return {
      pid,
      input,
      stdout: child.stdout,
      stderr: child.stderr,
      exited,
      kill(signal) {
        child.kill(signal)
      }
    }
  }

  // Bun's Node adapter can fail while materializing pipes under Linux load. Direct Bun pipes are stable on POSIX,
  // but its exited accessor can touch released handles, so status polling owns exit observation instead.
  const child = Bun.spawn([executable, ...args], {
    cwd,
    env,
    stdin: "pipe",
    stdout: "pipe",
    stderr: "pipe",
    detached: true,
    windowsHide: true
  })
  const input = bunProcessInput(child.stdin)
  input.on("error", ignoreStreamError)
  input.once("close", () => input.off("error", ignoreStreamError))
  return {
    pid: child.pid,
    input,
    stdout: Readable.from(child.stdout),
    stderr: Readable.from(child.stderr),
    exited: observeBunExit(child),
    kill(signal) {
      child.kill(signal)
    }
  }
}

async function observeBunExit(child: Bun.Subprocess<"pipe", "pipe", "pipe">): Promise<ProcessExit> {
  while (child.exitCode === null && child.signalCode === null) {
    // Exit status has no event API independent of Bun's unsafe exited accessor.
    // oxlint-disable-next-line no-await-in-loop
    await sleep(10)
  }
  return { code: child.exitCode, signal: child.signalCode }
}

function bunProcessInput(sink: Bun.FileSink): Writable {
  let ended = false
  return new Writable({
    write(chunk: Buffer, _encoding, callback) {
      void writeBunSink(sink, chunk, callback)
    },
    final(callback) {
      ended = true
      void closeBunSink(sink, undefined, callback)
    },
    destroy(cause, callback) {
      if (ended) {
        callback(cause)
        return
      }
      ended = true
      void closeBunSink(sink, cause ?? undefined, callback)
    }
  })
}

async function writeBunSink(
  sink: Bun.FileSink,
  chunk: Buffer,
  callback: (error?: Error | null) => void
): Promise<void> {
  try {
    await sink.write(chunk)
    await sink.flush()
    callback()
  } catch (cause) {
    callback(cause instanceof Error ? cause : new Error("Could not write subagent input"))
  }
}

async function closeBunSink(
  sink: Bun.FileSink,
  cause: Error | undefined,
  callback: (error?: Error | null) => void
): Promise<void> {
  try {
    await sink.end()
    callback(cause)
  } catch (closeCause) {
    const closeError = closeCause instanceof Error ? closeCause : new Error("Could not close subagent input")
    callback(cause ? new Error(`${cause.message}; ${closeError.message}`, { cause }) : closeError)
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise(resolve => setTimeout(resolve, ms))
}

function createChildProcessScope(
  workerPid: number,
  child: SpawnedRpcProcess,
  processTreeTracker: ProcessTreeTracker,
  onFailure: (error: Error) => void
): ProcessScope {
  try {
    return processTreeTracker.track(workerPid, onFailure)
  } catch (cause) {
    try {
      child.kill("SIGKILL")
    } catch {
      // The process already exited while containment was being admitted.
    }
    throw cause
  }
}

function baseCompletion(
  name: string,
  workCycle: number,
  durationMs: number,
  status: SubagentCompletionStatus,
  text: string,
  reason?: string
): SubagentCompletion {
  const originalBytes = Buffer.byteLength(text)
  return {
    name,
    workCycle,
    status,
    text,
    originalBytes,
    omittedBytes: 0,
    truncated: false,
    durationMs,
    ...(reason ? { reason } : {})
  }
}

export function clipUtf8(
  text: string,
  maxBytes: number
): { readonly text: string; readonly originalBytes: number; readonly omittedBytes: number } {
  const encoded = Buffer.from(text)
  const originalBytes = encoded.byteLength
  if (originalBytes <= maxBytes) return { text, originalBytes, omittedBytes: 0 }
  let end = Math.max(0, Math.min(maxBytes, originalBytes))
  while (end > 0 && (encoded[end]! & 0xc0) === 0x80) end--
  const clipped = encoded.subarray(0, end).toString("utf8")
  return { text: clipped, originalBytes, omittedBytes: originalBytes - end }
}

function completionFromIdleResult(
  name: string,
  workCycle: number,
  durationMs: number,
  value: unknown
): { readonly completionRevision: number; readonly completion: SubagentCompletion } {
  if (
    !isRecord(value) ||
    !Number.isSafeInteger(value.completionRevision) ||
    !Number.isSafeInteger(value.messageCount)
  ) {
    throw new Error("Invalid RPC idle completion result")
  }
  const completionRevision = value.completionRevision
  if (typeof completionRevision !== "number" || completionRevision < 1) {
    throw new Error("Invalid RPC idle completion result")
  }
  if (value.completion === null) {
    return {
      completionRevision,
      completion: baseCompletion(name, workCycle, durationMs, "failed", "", "missing_assistant")
    }
  }
  if (!isRecord(value.completion)) throw new Error("Invalid RPC idle completion result")
  const completion = value.completion
  if (
    typeof completion.text !== "string" ||
    typeof completion.stopReason !== "string" ||
    !Number.isSafeInteger(completion.originalBytes) ||
    !Number.isSafeInteger(completion.omittedBytes)
  ) {
    throw new Error("Invalid RPC idle completion result")
  }
  const originalBytes = completion.originalBytes
  const omittedBytes = completion.omittedBytes
  if (
    typeof originalBytes !== "number" ||
    typeof omittedBytes !== "number" ||
    originalBytes < 0 ||
    omittedBytes < 0 ||
    Buffer.byteLength(completion.text) + omittedBytes !== originalBytes ||
    (completion.error !== undefined && typeof completion.error !== "string")
  ) {
    throw new Error("Invalid RPC idle completion result")
  }
  const fields = { originalBytes, omittedBytes, truncated: completion.stopReason === "length" || omittedBytes > 0 }
  if (completion.stopReason === "aborted") {
    return {
      completionRevision,
      completion: { ...baseCompletion(name, workCycle, durationMs, "cancelled", completion.text), ...fields }
    }
  }
  if (completion.stopReason === "error") {
    return {
      completionRevision,
      completion: {
        ...baseCompletion(name, workCycle, durationMs, "failed", completion.text, "provider_error"),
        ...(typeof completion.error === "string" ? { error: completion.error } : {}),
        ...fields
      }
    }
  }
  if (completion.stopReason === "toolUse") {
    return {
      completionRevision,
      completion: {
        ...baseCompletion(name, workCycle, durationMs, "failed", completion.text, "missing_final_answer"),
        ...fields
      }
    }
  }
  if (completion.stopReason === "pending") {
    return {
      completionRevision,
      completion: {
        ...baseCompletion(name, workCycle, durationMs, "failed", completion.text, "incomplete_final_answer"),
        ...fields
      }
    }
  }
  return {
    completionRevision,
    completion: { ...baseCompletion(name, workCycle, durationMs, "completed", completion.text), ...fields }
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
      throw new Error("Subagent RPC stdout must be valid UTF-8")
    }
    this.#bufferBytes += chunk.byteLength
    return this.#takeLines()
  }

  finish(): string[] {
    try {
      this.#buffer += this.#decoder.decode()
    } catch {
      throw new Error("Subagent RPC stdout must be valid UTF-8")
    }
    const lines = this.#takeLines()
    if (this.#buffer.length > 0) {
      lines.push(this.#buffer.endsWith("\r") ? this.#buffer.slice(0, -1) : this.#buffer)
      this.#buffer = ""
      this.#bufferBytes = 0
    }
    return lines
  }

  #takeLines(): string[] {
    const lines: string[] = []
    while (true) {
      const newline = this.#buffer.indexOf("\n")
      if (newline === -1) break
      const line = this.#buffer.slice(0, newline)
      const bytes = Buffer.byteLength(line)
      if (bytes > maxRpcFrameBytes) throw new Error(`RPC frame exceeds ${maxRpcFrameBytes} bytes`)
      lines.push(line.endsWith("\r") ? line.slice(0, -1) : line)
      this.#buffer = this.#buffer.slice(newline + 1)
      this.#bufferBytes -= bytes + 1
    }
    if (this.#bufferBytes > maxRpcFrameBytes) throw new Error(`RPC frame exceeds ${maxRpcFrameBytes} bytes`)
    return lines
  }
}

function ignoreStreamError(): void {}

function writeNodeInput(input: Writable, chunk: string): Promise<void> {
  return new Promise((resolveWrite, rejectWrite) => {
    input.write(chunk, cause => {
      if (cause) rejectWrite(cause)
      else resolveWrite()
    })
  })
}

function endNodeInput(input: Writable): Promise<void> {
  return new Promise((resolveEnd, rejectEnd) => {
    const onError = (cause: Error): void => {
      input.off("error", onError)
      rejectEnd(cause)
    }
    input.once("error", onError)
    input.end(() => {
      input.off("error", onError)
      resolveEnd()
    })
  })
}

function deadlineRemainingMs(endsAt: number): number {
  return Math.max(0, endsAt - Date.now())
}

function currentWorkCycle(state: ChildLifecycleState): { readonly workCycle?: number } {
  switch (state.type) {
    case "spawn_admitting":
    case "running":
    case "interrupting":
      return { workCycle: state.workCycle }
    case "idle":
      return { workCycle: Math.max(0, state.nextWorkCycle - 1) }
    case "starting":
    case "closing":
    case "exited":
      return {}
    default:
      return assertNever(state)
  }
}

function isPositiveTimeout(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value > 0
}

function cloneRpcSessionEvent(value: unknown): ChildSerializableSessionEvent | undefined {
  if (!isRecord(value) || typeof value.type !== "string") return undefined
  try {
    const copy: unknown = JSON.parse(JSON.stringify(value))
    if (!isRecord(copy) || typeof copy.type !== "string") return undefined
    const event: ChildSerializableSessionEvent = { ...copy, type: copy.type }
    return deepFreeze(event)
  } catch {
    return undefined
  }
}

function deepFreeze<T>(value: T): T {
  if (Array.isArray(value)) {
    for (const item of value) deepFreeze(item)
    return Object.freeze(value)
  }
  if (!isRecord(value)) return value
  for (const item of Object.values(value)) deepFreeze(item)
  return Object.freeze(value)
}

function assertNever(value: never): never {
  throw new Error(`Unexpected child lifecycle: ${String(value)}`)
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
