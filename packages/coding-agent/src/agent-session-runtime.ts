import type { Api, Model } from "@earendil-works/pi-ai"

import { resolveZiPath } from "./paths.js"
import {
  snapshotAgentRuntimeOptions,
  type AgentRuntimeSessionIntent,
  type CreateAgentRuntimeOptions
} from "./runtime-options.js"
import { createAgentRuntime, type AgentRuntime } from "./runtime.js"
import { SessionManager, type SessionListResult } from "./session-manager.js"

export type AgentRuntimeFactory = (options: CreateAgentRuntimeOptions) => Promise<AgentRuntime>

export type SessionReplacementCancellation =
  | { readonly type: "none"; readonly settled: Promise<void> }
  | { readonly type: "cancelled"; readonly settled: Promise<void> }
  | { readonly type: "settling"; readonly settled: Promise<void> }
  | { readonly type: "disposed"; readonly settled: Promise<void> }

type RuntimeState =
  | { readonly type: "ready"; readonly current: AgentRuntime }
  | {
      readonly type: "replacing"
      readonly current: AgentRuntime
      readonly operationId: number
      readonly settled: Promise<void>
    }
  | {
      readonly type: "cancelling"
      readonly current: AgentRuntime
      readonly operationId: number
      readonly settled: Promise<void>
    }
  | {
      readonly type: "settling"
      readonly current: AgentRuntime
      readonly operationId: number
      readonly settled: Promise<void>
    }
  | { readonly type: "disposed"; readonly settled: Promise<void> }

interface SessionListFlight {
  readonly current: AgentRuntime
  readonly promise: Promise<SessionListResult>
  readonly settled: Promise<void>
}

/** Owns replacement and final disposal of one current cwd-bound AgentRuntime. */
export class AgentSessionRuntime {
  readonly #options: CreateAgentRuntimeOptions
  readonly #createRuntime: AgentRuntimeFactory
  #state: RuntimeState
  #nextOperationId = 0
  #sessionList: SessionListFlight | undefined
  #sessionListTail: Promise<void> = Promise.resolve()
  #retired: Promise<void> = Promise.resolve()
  #cleanupFailure: { readonly cause: unknown } | undefined

  constructor(initial: AgentRuntime, options: CreateAgentRuntimeOptions, createRuntime: AgentRuntimeFactory) {
    this.#state = { type: "ready", current: initial }
    this.#options = snapshotAgentRuntimeOptions({ ...options, agentDir: initial.services.paths.globalDir })
    this.#createRuntime = createRuntime
  }

  get session(): AgentRuntime["session"] {
    return this.#current().session
  }

  get services(): AgentRuntime["services"] {
    return this.#current().services
  }

  get projectTrust(): AgentRuntime["projectTrust"] {
    return this.#current().projectTrust
  }

  get bootstrapDiagnostic(): AgentRuntime["bootstrapDiagnostic"] {
    return this.#current().bootstrapDiagnostic
  }

  listSessions(): Promise<SessionListResult> {
    const current = this.#requireReady()
    if (this.#sessionList?.current === current) return this.#sessionList.promise

    const promise = this.#sessionListTail.then(() => {
      if (this.#current() !== current) throw new Error("Session changed before its catalog could be loaded")
      return SessionManager.list(current.services.paths)
    })
    const settled = promise.then(
      () => undefined,
      () => undefined
    )
    const flight = { current, promise, settled }
    this.#sessionList = flight
    this.#sessionListTail = settled
    void settled.then(() => this.#clearSessionList(flight))
    return promise
  }

  newSession(): Promise<AgentRuntime> {
    const current = this.#requireReady()
    const persisted = current.session.sessionManager.file !== undefined
    const model = replacementModel(this.#options, current)
    return this.#replace(
      runtimeOptions(this.#options, {
        cwd: current.services.paths.cwd,
        sessionDir: current.services.paths.sessionDir,
        session: { type: "new", persist: persisted },
        ...(model ? { model } : {})
      }),
      true
    )
  }

  switchSession(sessionFile: string): Promise<AgentRuntime> {
    const current = this.#requireReady()
    const resolvedSessionFile = resolveZiPath(sessionFile, current.services.paths.cwd)
    if (current.session.sessionManager.file === resolvedSessionFile) return Promise.resolve(current)
    const model = replacementModel(this.#options, current)
    return this.#replace(
      runtimeOptions(this.#options, {
        cwd: current.services.paths.cwd,
        session: { type: "resume", file: resolvedSessionFile },
        ...(this.#options.sessionDir ? { sessionDir: this.#options.sessionDir } : {}),
        ...(model ? { model } : {})
      })
    )
  }

  cancelReplacement(): SessionReplacementCancellation {
    const state = this.#state
    if (state.type === "replacing") {
      this.#state = { ...state, type: "cancelling" }
      return { type: "cancelled", settled: state.settled }
    }
    if (state.type === "cancelling") return { type: "cancelled", settled: state.settled }
    if (state.type === "settling") return { type: "settling", settled: state.settled }
    if (state.type === "disposed") return { type: "disposed", settled: state.settled }
    return { type: "none", settled: Promise.resolve() }
  }

  dispose(): void {
    const state = this.#state
    if (state.type === "disposed") return

    const current = state.current
    current.session.dispose()
    const operations = [this.#cleanupSettlement(), this.#sessionListTail, this.#retired, current.session.waitForIdle()]
    if (state.type !== "ready") operations.push(state.settled)
    const settled = settleAll(operations)
    this.#state = { type: "disposed", settled }
    void settled.catch(() => {})
  }

  waitForIdle(): Promise<void> {
    const state = this.#state
    if (state.type === "disposed") return state.settled
    if (state.type === "ready") {
      return settleAll([
        this.#cleanupSettlement(),
        this.#sessionListTail,
        this.#retired,
        state.current.session.waitForIdle()
      ])
    }
    return settleAll([
      this.#cleanupSettlement(),
      this.#sessionListTail,
      this.#retired,
      state.current.session.waitForIdle(),
      state.settled
    ])
  }

  async #replace(options: CreateAgentRuntimeOptions, discardFile = false): Promise<AgentRuntime> {
    const current = this.#requireReady()
    current.session.assertReplaceable()
    const operationId = ++this.#nextOperationId
    const operation = deferred()
    this.#state = { type: "replacing", current, operationId, settled: operation.settled }

    let next: AgentRuntime
    try {
      next = await this.#createRuntime(options)
    } catch (cause) {
      const state = this.#readState()
      if (isOperation(state, operationId)) this.#state = { type: "ready", current }
      operation.resolve()
      if (state.type === "cancelling") throw new Error("Session replacement was cancelled", { cause })
      if (state.type === "disposed") throw new Error("AgentSessionRuntime is disposed", { cause })
      throw cause
    }

    const state = this.#readState()
    if (state.type === "disposed" || !isOperation(state, operationId) || state.type === "cancelling") {
      await this.#discard(next, discardFile)
      if (isOperation(this.#readState(), operationId)) this.#state = { type: "ready", current }
      operation.resolve()
      throw new Error(
        state.type === "disposed" ? "AgentSessionRuntime is disposed" : "Session replacement was cancelled"
      )
    }

    try {
      current.session.assertReplaceable()
    } catch (cause) {
      await this.#discard(next, discardFile)
      if (isOperation(this.#readState(), operationId)) this.#state = { type: "ready", current }
      operation.resolve()
      throw cause
    }

    current.session.dispose()
    this.#retire(current.session.waitForIdle())
    this.#state = { type: "settling", current: next, operationId, settled: operation.settled }
    await this.#finishRetired()

    const settled = this.#readState()
    if (settled.type === "disposed") {
      operation.resolve()
      throw new Error("AgentSessionRuntime is disposed")
    }
    if (!isOperation(settled, operationId)) {
      operation.resolve()
      throw new Error("Session replacement was superseded")
    }
    this.#state = { type: "ready", current: next }
    operation.resolve()
    return next
  }

  async #discard(runtime: AgentRuntime, discardFile: boolean): Promise<void> {
    const discardPersistence = discardFile && runtime.session.sessionManager.file !== undefined
    runtime.session.dispose()
    try {
      await runtime.session.waitForIdle()
    } catch (cause) {
      this.#cleanupFailure ??= { cause }
    }
    if (!discardPersistence) return
    try {
      await runtime.session.sessionManager.discardPersistence()
    } catch (cause) {
      this.#cleanupFailure ??= { cause }
    }
  }

  #retire(settled: Promise<void>): void {
    this.#retired = settled
    void settled.catch(() => {})
  }

  async #finishRetired(): Promise<void> {
    const retired = this.#retired
    try {
      await retired
    } catch (cause) {
      this.#cleanupFailure ??= { cause }
    } finally {
      if (this.#retired === retired) this.#retired = Promise.resolve()
    }
  }

  #cleanupSettlement(): Promise<void> {
    return this.#cleanupFailure ? Promise.reject(this.#cleanupFailure.cause) : Promise.resolve()
  }

  #readState(): RuntimeState {
    return this.#state
  }

  #current(): AgentRuntime {
    const state = this.#state
    if (state.type === "disposed") throw new Error("AgentSessionRuntime is disposed")
    return state.current
  }

  #requireReady(): AgentRuntime {
    const state = this.#state
    if (state.type === "disposed") throw new Error("AgentSessionRuntime is disposed")
    if (state.type !== "ready") throw new Error("Session replacement is already active")
    return state.current
  }

  #clearSessionList(flight: SessionListFlight): void {
    if (this.#sessionList === flight) this.#sessionList = undefined
  }
}

export async function createAgentSessionRuntime(
  options: CreateAgentRuntimeOptions,
  createRuntime: AgentRuntimeFactory = createAgentRuntime
): Promise<AgentSessionRuntime> {
  const snapshot = snapshotAgentRuntimeOptions(options)
  const initial = await createRuntime(snapshot)
  return new AgentSessionRuntime(initial, snapshot, createRuntime)
}

function runtimeOptions(
  base: CreateAgentRuntimeOptions,
  replacement: {
    readonly cwd: string
    readonly session: AgentRuntimeSessionIntent
    readonly sessionDir?: string
    readonly model?: string
  }
): CreateAgentRuntimeOptions {
  const options = { ...base, ...replacement }
  if (replacement.sessionDir === undefined) delete options.sessionDir
  if (replacement.model === undefined) delete options.model
  return snapshotAgentRuntimeOptions(options)
}

function replacementModel(options: CreateAgentRuntimeOptions, current: AgentRuntime): string | undefined {
  if (options.model) return options.model
  if (!options.apiKey || current.session.modelState.type === "unselected") return undefined
  return modelReference(current.session.modelState.model)
}

function modelReference(model: Model<Api>): string {
  return `${model.provider}/${model.id}`
}

function isOperation(
  state: RuntimeState,
  operationId: number
): state is Extract<RuntimeState, { operationId: number }> {
  return "operationId" in state && state.operationId === operationId
}

function deferred(): { readonly settled: Promise<void>; resolve(): void } {
  let resolve!: () => void
  const settled = new Promise<void>(resolvePromise => {
    resolve = resolvePromise
  })
  return { settled, resolve }
}

async function settleAll(operations: readonly Promise<void>[]): Promise<void> {
  const outcomes = await Promise.allSettled(operations)
  const failure = outcomes.find((outcome): outcome is PromiseRejectedResult => outcome.status === "rejected")
  if (failure) throw failure.reason
}
