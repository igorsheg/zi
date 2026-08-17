import { existsSync } from "node:fs"

import type { Api, Model } from "@earendil-works/pi-ai"

import { isRecord } from "./guards.js"
import { resolveZiPath } from "./paths.js"
import { ProjectTrustStore, type ProjectTrustSelection } from "./project-trust.js"
import {
  snapshotAgentRuntimeOptions,
  type AgentRuntimeSessionIntent,
  type CreateAgentRuntimeOptions
} from "./runtime-options.js"
import { createUnboundAgentRuntime, type AgentRuntime } from "./runtime.js"
import { SessionManager, type SessionListResult } from "./session-manager.js"

// Replacement factories return an unbound session; AgentSessionRuntime owns lifecycle commit ordering.
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
      "new",
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
      }),
      "resume"
    )
  }

  decideProjectTrust(selection: ProjectTrustSelection): Promise<AgentRuntime> {
    const current = this.#requireReady()
    if (current.projectTrust.type !== "unresolved") {
      throw new Error("Project trust is already resolved for this session")
    }
    validateProjectTrustSelection(selection)
    const cwd = current.projectTrust.cwd
    const session = trustReplacementSession(current)
    const model = replacementModel(this.#options, current)
    const options = snapshotAgentRuntimeOptions({
      ...runtimeOptions(this.#options, {
        cwd: current.services.paths.cwd,
        session,
        ...(session.type === "new" || this.#options.sessionDir
          ? { sessionDir: current.services.paths.sessionDir }
          : {}),
        ...(model ? { model } : {})
      }),
      projectTrust: { type: selection.type, cwd, source: "interactive" }
    })
    const remember =
      selection.persistence === "saved"
        ? () => new ProjectTrustStore(current.services.paths).update([{ type: selection.type, cwd }])
        : undefined
    return this.#replace(options, "reload", false, remember)
  }

  cancelReplacement(): SessionReplacementCancellation {
    const state = this.#state
    if (state.type === "replacing") {
      this.#transition({ ...state, type: "cancelling" })
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
    this.#transition({ type: "disposed", settled })
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

  async #replace(
    options: CreateAgentRuntimeOptions,
    reason: "new" | "resume" | "reload",
    discardFile = false,
    prepare?: () => Promise<void>
  ): Promise<AgentRuntime> {
    const current = this.#requireReady()
    current.session.assertReplaceable()
    const operationId = ++this.#nextOperationId
    const operation = deferred()
    this.#transition({ type: "replacing", current, operationId, settled: operation.settled })

    let next: AgentRuntime
    try {
      if (prepare) {
        await prepare()
        const prepared = this.#readState()
        if (!isOperation(prepared, operationId) || prepared.type === "cancelling") {
          throw new Error("Session replacement was cancelled before runtime construction")
        }
      }
      next = await this.#createRuntime(options)
    } catch (cause) {
      const state = this.#readState()
      if (isOperation(state, operationId)) this.#transition({ type: "ready", current })
      operation.resolve()
      if (state.type === "cancelling") throw new Error("Session replacement was cancelled", { cause })
      if (state.type === "disposed") throw new Error("AgentSessionRuntime is disposed", { cause })
      throw cause
    }

    const state = this.#readState()
    if (state.type === "disposed" || !isOperation(state, operationId) || state.type === "cancelling") {
      await this.#discard(next, discardFile, reason)
      if (isOperation(this.#readState(), operationId)) this.#transition({ type: "ready", current })
      operation.resolve()
      throw new Error(
        state.type === "disposed" ? "AgentSessionRuntime is disposed" : "Session replacement was cancelled"
      )
    }

    try {
      next.session.assertLifecycleUnbound()
    } catch (cause) {
      await this.#discard(next, discardFile, reason)
      if (isOperation(this.#readState(), operationId)) this.#transition({ type: "ready", current })
      operation.resolve()
      throw cause
    }

    try {
      current.session.assertReplaceable()
    } catch (cause) {
      await this.#discard(next, discardFile, reason)
      if (isOperation(this.#readState(), operationId)) this.#transition({ type: "ready", current })
      operation.resolve()
      throw cause
    }

    current.session.dispose(reason)
    this.#retire(current.session.waitForIdle())
    this.#transition({ type: "settling", current: next, operationId, settled: operation.settled })
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

    try {
      await next.session.activate(reason)
    } catch (cause) {
      await this.#discard(next, discardFile, reason)
      const failed = this.#readState()
      if (isOperation(failed, operationId)) {
        const terminal = settleAll([
          Promise.reject(cause),
          this.#cleanupSettlement(),
          this.#sessionListTail,
          this.#retired,
          next.session.waitForIdle()
        ])
        this.#transition({ type: "disposed", settled: terminal })
        void terminal.catch(() => {})
      }
      operation.resolve()
      if (failed.type === "disposed") throw new Error("AgentSessionRuntime is disposed", { cause })
      throw cause
    }
    const activated = this.#readState()
    if (activated.type === "disposed") {
      operation.resolve()
      throw new Error("AgentSessionRuntime is disposed")
    }
    if (!isOperation(activated, operationId)) {
      operation.resolve()
      throw new Error("Session replacement was superseded")
    }
    this.#transition({ type: "ready", current: next })
    operation.resolve()
    return next
  }

  async #discard(runtime: AgentRuntime, discardFile: boolean, reason: "new" | "resume" | "reload"): Promise<void> {
    const discardPersistence = discardFile && runtime.session.sessionManager.file !== undefined
    runtime.session.dispose(reason)
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

  #transition(next: RuntimeState): void {
    const current = this.#state
    if (!isRuntimeTransition(current, next)) {
      throw new Error(`Invalid AgentSessionRuntime transition: ${current.type} -> ${next.type}`)
    }
    if ("operationId" in next && next.operationId !== this.#nextOperationId) {
      throw new Error("AgentSessionRuntime transition has a stale operation id")
    }
    if (
      "operationId" in current &&
      "operationId" in next &&
      (current.operationId !== next.operationId || current.settled !== next.settled)
    ) {
      throw new Error("AgentSessionRuntime transition changed active operation identity")
    }
    this.#state = next
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
  createRuntime: AgentRuntimeFactory = createUnboundAgentRuntime
): Promise<AgentSessionRuntime> {
  const snapshot = snapshotAgentRuntimeOptions(options)
  const initial = await createRuntime(snapshot)
  try {
    await initial.session.activate("startup")
    return new AgentSessionRuntime(initial, snapshot, createRuntime)
  } catch (cause) {
    initial.session.dispose()
    await initial.session.waitForIdle()
    throw cause
  }
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

function trustReplacementSession(current: AgentRuntime): AgentRuntimeSessionIntent {
  const file = current.session.sessionManager.file
  if (file && existsSync(file)) return { type: "resume", file }
  return { type: "new", persist: file !== undefined }
}

function validateProjectTrustSelection(selection: unknown): asserts selection is ProjectTrustSelection {
  if (!isRecord(selection)) throw new Error("Project trust selections must be objects")
  if (selection.type !== "trusted" && selection.type !== "untrusted") {
    throw new Error(`Unknown project trust selection: ${String(selection.type)}`)
  }
  if (selection.persistence !== "session" && selection.persistence !== "saved") {
    throw new Error(`Unknown project trust persistence: ${String(selection.persistence)}`)
  }
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

function isRuntimeTransition(current: RuntimeState, next: RuntimeState): boolean {
  if (next.type === "disposed") return current.type !== "disposed"
  switch (current.type) {
    case "ready":
      return next.type === "replacing" && next.current === current.current
    case "replacing":
      if (next.type === "settling") return next.current !== current.current
      return (next.type === "cancelling" || next.type === "ready") && next.current === current.current
    case "cancelling":
      return next.type === "ready" && next.current === current.current
    case "settling":
      return next.type === "ready" && next.current === current.current
    case "disposed":
      return false
    default:
      return assertNever(current)
  }
}

function assertNever(value: never): never {
  throw new Error(`Unexpected AgentSessionRuntime state: ${String(value)}`)
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
