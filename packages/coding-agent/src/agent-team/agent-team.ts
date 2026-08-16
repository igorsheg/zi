import type { ZiPaths } from "../paths.js"
import { createSessionFork } from "../session-fork.js"
import { SessionManager, type CustomMessageEntry } from "../session-manager.js"
import { maxAgentRecords, replayAgentTeamJournal, type DurableAgentRecord, type SettledAgentStatus } from "./journal.js"
import type { AgentMailInput, AgentMailPublication } from "./mail.js"
import { childAgentPath, isAgentPathWithin, rootAgentPath, type AgentPath } from "./path.js"
import type { AgentTurnResult } from "./result.js"
import type { AgentSpawnSpec, AgentType } from "./spawn.js"

export const maxResidentAgents = 3
export const maxActiveAgentTurns = 3

export interface AgentTeamMailAdmission {
  readonly entry: CustomMessageEntry
  readonly duplicate: boolean
  readonly publication: AgentMailPublication
}

export interface AgentTeamSessionOwner {
  readonly sessionId: string
  startTurn(
    input: AgentMailInput,
    commit: (entry: CustomMessageEntry) => void
  ): { readonly entry: CustomMessageEntry; readonly settled: Promise<AgentTurnResult> }
  admitMail(input: AgentMailInput, publication: AgentMailPublication): AgentTeamMailAdmission
  interrupt(reason: "requested" | "turn_timeout" | "shutdown"): Promise<void>
  dispose(): Promise<void>
}

export interface AgentTeamRoot {
  readonly sessionId: string
  admitMail(input: AgentMailInput): AgentTeamMailAdmission
}

export interface AgentTeamSessionRequest {
  readonly team: AgentTeam
  readonly path: AgentPath
  readonly spec: AgentSpawnSpec
  readonly sessionManager: SessionManager
}

export type CreateAgentTeamSession = (request: AgentTeamSessionRequest) => Promise<AgentTeamSessionOwner>

export interface AgentTeamOptions {
  readonly paths: ZiPaths
  readonly rootSessionManager: SessionManager
  readonly createSession: CreateAgentTeamSession
  readonly turnTimeoutMs: number
  readonly shutdownTimeoutMs: number
}

export interface SpawnAgentRequest {
  readonly sender: AgentPath
  readonly taskName: string
  readonly message: string
  readonly spec: AgentSpawnSpec
}

export interface AgentSnapshot {
  readonly path: AgentPath
  readonly parentPath: AgentPath
  readonly sessionId: string
  readonly taskName: string
  readonly agentType: AgentType
  readonly generation: number
  readonly residency: "unloaded" | "loading" | "resident"
  readonly turn: "idle" | "starting" | "running" | "interrupting"
  readonly turnNumber: number
  readonly status: SettledAgentStatus
}

type OrdinaryAgentMail = AgentMailInput & { readonly kind: "message" | "task" }

type IdleTurn = { readonly type: "idle" }
type StartingTurn = {
  readonly type: "starting"
  readonly operationId: string
  readonly turn: number
  readonly mailId: string
  readonly applied: ReturnType<typeof deferred<void>>
}
type RunningTurn = {
  readonly type: "running" | "interrupting"
  readonly operationId: string
  readonly turn: number
  readonly applied: ReturnType<typeof deferred<void>>
  readonly timeout: ReturnType<typeof setTimeout>
}
type AgentTurnState = IdleTurn | StartingTurn | RunningTurn

type AgentRecordState =
  | { readonly type: "unloaded" }
  | { readonly type: "loading"; readonly operationId: number }
  | {
      readonly type: "resident"
      readonly owner: AgentTeamSessionOwner
      readonly sessionManager: SessionManager
      readonly turn: AgentTurnState
    }
  | { readonly type: "disposing"; readonly owner: AgentTeamSessionOwner; readonly settlement: Promise<void> }
  | { readonly type: "dispose_failed"; readonly owner: AgentTeamSessionOwner }

export interface AgentTeamChange {
  readonly revision: number
  readonly paths: readonly AgentPath[]
}

interface AgentRecord {
  metadata: DurableAgentRecord
  state: AgentRecordState
  tail: Promise<void>
  memorySession?: SessionManager
}

export class AgentTeam {
  readonly #paths: ZiPaths
  readonly #rootSessionManager: SessionManager
  readonly #createSession: CreateAgentTeamSession
  readonly #turnTimeoutMs: number
  readonly #shutdownTimeoutMs: number
  readonly #records = new Map<AgentPath, AgentRecord>()
  readonly #reservedPaths = new Set<AgentPath>()
  readonly #settlements = new Set<Promise<void>>()
  readonly #listeners = new Set<(change: AgentTeamChange) => void>()
  #root: AgentTeamRoot | undefined
  #revision = 0
  #state: "open" | "stopping" | "closed" = "open"
  #shutdown: Promise<void> | undefined
  #nextLoadOperationId = 0

  private constructor(options: AgentTeamOptions) {
    this.#paths = options.paths
    this.#rootSessionManager = options.rootSessionManager
    this.#createSession = options.createSession
    this.#turnTimeoutMs = positiveDuration(options.turnTimeoutMs, "Agent turn timeout")
    this.#shutdownTimeoutMs = positiveDuration(options.shutdownTimeoutMs, "Agent shutdown timeout")
    const restored = replayAgentTeamJournal(options.rootSessionManager.agentTeamEntries())
    for (const metadata of restored.records.values()) {
      const expectedParentSessionId =
        metadata.parentPath === rootAgentPath
          ? options.rootSessionManager.sessionId
          : restored.records.get(metadata.parentPath)?.sessionId
      if (metadata.parentSessionId !== expectedParentSessionId) {
        throw new Error(`Agent parent session does not match its lineage: ${metadata.path}`)
      }
      this.#records.set(metadata.path, { metadata, state: { type: "unloaded" }, tail: Promise.resolve() })
    }
  }

  static async create(options: AgentTeamOptions): Promise<AgentTeam> {
    let restored = replayAgentTeamJournal(options.rootSessionManager.agentTeamEntries())
    for (const reservation of restored.spawnReservations.values()) {
      SessionManager.discardAgentFork(options.paths, reservation.parentSessionId, reservation.sessionId)
      options.rootSessionManager.appendAgentTeam({
        type: "agent_spawn_aborted",
        operationId: reservation.operationId,
        reason: "session_restored"
      })
    }
    restored = replayAgentTeamJournal(options.rootSessionManager.agentTeamEntries())
    for (const turn of restored.pendingTurns.values()) {
      options.rootSessionManager.appendAgentTeam({
        type: "agent_turn_settled",
        operationId: turn.operationId,
        path: turn.path,
        turn: turn.turn,
        result: interruptedResult("restart")
      })
    }
    return new AgentTeam(options)
  }

  get state(): "open" | "stopping" | "closed" {
    return this.#state
  }

  subscribe(listener: (change: AgentTeamChange) => void): () => void {
    this.#listeners.add(listener)
    return () => this.#listeners.delete(listener)
  }

  async bindRoot(root: AgentTeamRoot): Promise<void> {
    this.#assertOpen()
    if (this.#root) throw new Error("AgentTeam root is already bound")
    if (root.sessionId !== this.#rootSessionManager.sessionId) throw new Error("AgentTeam root session does not match")
    this.#root = root
    await this.#retryPendingRootMail(root)
    await this.retryPendingCompletions()
  }

  snapshots(prefix?: AgentPath): readonly AgentSnapshot[] {
    return [...this.#records.values()]
      .filter(record => prefix === undefined || isAgentPathWithin(record.metadata.path, prefix))
      .toSorted((left, right) => left.metadata.path.localeCompare(right.metadata.path))
      .map(record => snapshot(record))
  }

  async spawn(request: SpawnAgentRequest): Promise<AgentSnapshot> {
    this.#assertOpen()
    const parentRecord = request.sender === rootAgentPath ? undefined : this.#requireRecord(request.sender)
    const parentManager =
      parentRecord === undefined ? this.#rootSessionManager : this.#residentSessionManager(parentRecord)
    const path = childAgentPath(request.sender, request.taskName)
    if (this.#records.has(path) || this.#reservedPaths.has(path)) throw new Error(`Agent path already exists: ${path}`)
    if (this.#records.size + this.#reservedPaths.size === maxAgentRecords) {
      throw new Error(`Agent tree cannot exceed ${maxAgentRecords} records`)
    }
    if (this.#activeTurns() + this.#reservedPaths.size >= maxActiveAgentTurns) {
      throw new Error("Agent turn capacity reached")
    }
    this.#reservedPaths.add(path)
    const operationId = crypto.randomUUID()
    const sessionId = crypto.randomUUID()
    const checkpoint = parentManager.captureForkCheckpoint()
    const generation = parentRecord === undefined ? 1 : parentRecord.metadata.generation + 1
    let committed = false
    try {
      this.#rootSessionManager.appendAgentTeam({
        type: "agent_spawn_reserved",
        operationId,
        path,
        parentPath: request.sender,
        sessionId,
        parentSessionId: checkpoint.sessionId,
        parentEntryId: checkpoint.leafId,
        generation,
        taskName: request.taskName,
        agentType: request.spec.agentType,
        forkTurns: request.spec.forkTurns,
        execution: request.spec.execution
      })
      const childManager = await createSessionFork(parentManager, this.#paths, {
        path,
        rootSessionId: this.#rootSessionManager.sessionId,
        sessionId,
        forkTurns: request.spec.forkTurns,
        checkpoint
      })
      this.#rootSessionManager.appendAgentTeam({ type: "agent_spawn_committed", operationId })
      committed = true
      const restored = replayAgentTeamJournal(this.#rootSessionManager.agentTeamEntries()).records.get(path)
      if (!restored) throw new Error(`Committed agent record is missing: ${path}`)
      const record: AgentRecord = {
        metadata: restored,
        state: { type: "unloaded" },
        tail: Promise.resolve(),
        ...(childManager.file === undefined ? { memorySession: childManager } : {})
      }
      this.#records.set(path, record)
      this.#publishChange([path])
      await this.#withRecord(record, async () => {
        await this.#ensureResident(record, childManager)
        await this.#startTurn(record, request.sender, request.message)
      })
      return snapshot(record)
    } catch (cause) {
      if (!committed) {
        SessionManager.discardAgentFork(this.#paths, checkpoint.sessionId, sessionId)
        try {
          this.#rootSessionManager.appendAgentTeam({
            type: "agent_spawn_aborted",
            operationId,
            reason: boundedError(cause)
          })
        } catch {
          // The durable reservation remains private and recovery resolves it.
        }
      }
      throw cause
    } finally {
      this.#reservedPaths.delete(path)
    }
  }

  async sendMessage(sender: AgentPath, target: AgentPath, text: string): Promise<void> {
    this.#assertOpen()
    if (target === rootAgentPath) {
      const mail = this.#queueOrdinaryMail(target, sender, "message", text)
      const root = this.#root
      if (root) this.#deliverRootMail(root, mail)
      return
    }
    const record = this.#requireRecord(target)
    const mail = this.#queueOrdinaryMail(target, sender, "message", text)
    this.#publishChange([target])
    await this.#withRecord(record, async () => {
      if (record.state.type === "resident") this.#deliverQueuedMail(record, record.state.owner, mail)
    })
  }

  async followupTask(sender: AgentPath, target: AgentPath, text: string): Promise<"started" | "joined"> {
    this.#assertOpen()
    if (target === rootAgentPath) throw new Error("Follow-up tasks cannot target the root")
    const record = this.#requireRecord(target)
    return this.#withRecord(record, async () => {
      const owner = await this.#ensureResident(record)
      if (record.state.type !== "resident") throw new Error(`Agent is not resident: ${target}`)
      if (record.state.turn.type !== "idle") {
        await this.#deliverOrdinaryMail(record, owner, sender, "task", text)
        this.#publishChange([target])
        return "joined"
      }
      await this.#startTurn(record, sender, text)
      return "started"
    })
  }

  async interrupt(target: AgentPath): Promise<"interrupted" | "idle"> {
    this.#assertOpen()
    const record = this.#requireRecord(target)
    return this.#withRecord(record, async () => {
      const state = record.state
      if (state.type !== "resident" || state.turn.type === "idle") return "idle"
      if (state.turn.type === "interrupting") return "interrupted"
      if (state.turn.type === "starting") throw new Error(`Agent turn is still starting: ${target}`)
      record.state = { ...state, turn: { ...state.turn, type: "interrupting" } }
      this.#publishChange([target])
      await state.owner.interrupt("requested")
      return "interrupted"
    })
  }

  async waitForIdle(path: AgentPath): Promise<void> {
    const record = this.#requireRecord(path)
    const state = record.state
    if (state.type === "resident" && state.turn.type !== "idle") await state.turn.applied.promise
  }

  async retryPendingCompletions(): Promise<void> {
    const root = this.#root
    if (!root) throw new Error("AgentTeam root is not bound")
    const restored = replayAgentTeamJournal(this.#rootSessionManager.agentTeamEntries())
    for (const completion of restored.pendingCompletions.values()) {
      if (completion.parentPath !== rootAgentPath) continue
      const input = completionMail(completion.path, rootAgentPath, completion.turn, completion.result)
      const admission = root.admitMail(input)
      this.#rootSessionManager.appendAgentTeam({
        type: "agent_completion_delivered",
        path: completion.path,
        turn: completion.turn,
        targetEntryId: admission.entry.id
      })
    }
  }

  shutdown(): Promise<void> {
    if (this.#state === "closed") return Promise.resolve()
    if (this.#shutdown) return this.#shutdown
    this.#state = "stopping"
    const shutdown = this.#performShutdown()
    this.#shutdown = shutdown
    void shutdown.catch(() => {
      if (this.#state !== "closed" && this.#shutdown === shutdown) this.#shutdown = undefined
    })
    return shutdown
  }

  async #performShutdown(): Promise<void> {
    let failure: unknown
    try {
      await withTimeout(
        Promise.all(
          [...this.#records.values()].map(record =>
            this.#withRecord(record, async () => {
              const state = record.state
              if (state.type !== "resident" || state.turn.type === "idle") return
              if (state.turn.type === "starting") {
                throw new Error(`Agent turn is still starting: ${record.metadata.path}`)
              }
              if (state.turn.type !== "interrupting") {
                record.state = { ...state, turn: { ...state.turn, type: "interrupting" } }
              }
              await state.owner.interrupt("shutdown")
            })
          )
        ),
        this.#shutdownTimeoutMs
      )
      await withTimeout(Promise.allSettled(this.#settlements), this.#shutdownTimeoutMs)
    } catch (cause) {
      failure = cause
    }

    const disposals = await Promise.allSettled([...this.#records.values()].map(record => this.#disposeRecord(record)))
    const disposalFailure = disposals.find(outcome => outcome.status === "rejected")
    if (disposalFailure?.status === "rejected") failure ??= disposalFailure.reason
    const retainedOwner = [...this.#records.values()].some(record => record.state.type !== "unloaded")
    this.#state = retainedOwner ? "stopping" : "closed"
    if (failure) throw failure
  }

  async #disposeRecord(record: AgentRecord): Promise<void> {
    const state = record.state
    if (state.type === "unloaded" || state.type === "loading") return
    if (state.type === "disposing") {
      await withTimeout(state.settlement, this.#shutdownTimeoutMs)
      return
    }

    const owner = state.owner
    let settlement: Promise<void>
    try {
      settlement = owner.dispose()
    } catch (cause) {
      record.state = { type: "dispose_failed", owner }
      throw cause
    }
    let tracked: Promise<void>
    tracked = settlement.then(
      () => {
        if (record.state.type === "disposing" && record.state.settlement === tracked) {
          record.state = { type: "unloaded" }
        }
        return undefined
      },
      cause => {
        if (record.state.type === "disposing" && record.state.settlement === tracked) {
          record.state = { type: "dispose_failed", owner }
        }
        throw cause
      }
    )
    record.state = { type: "disposing", owner, settlement: tracked }
    await withTimeout(tracked, this.#shutdownTimeoutMs)
  }

  async #ensureResident(record: AgentRecord, prepared?: SessionManager): Promise<AgentTeamSessionOwner> {
    if (record.state.type === "resident") return record.state.owner
    if (record.state.type !== "unloaded") throw new Error(`Agent is not available for loading: ${record.metadata.path}`)
    const resident = [...this.#records.values()].filter(candidate => candidate.state.type !== "unloaded").length
    if (resident === maxResidentAgents) throw new Error("Agent residency capacity reached")

    const operationId = ++this.#nextLoadOperationId
    record.state = { type: "loading", operationId }
    try {
      const manager =
        prepared ??
        record.memorySession ??
        SessionManager.openAgent(
          this.#paths,
          record.metadata.sessionId,
          lineage(record.metadata, this.#rootSessionManager.sessionId)
        )
      const owner = await this.#createSession({
        team: this,
        path: record.metadata.path,
        spec: {
          agentType: record.metadata.agentType,
          forkTurns: record.metadata.forkTurns,
          execution: record.metadata.execution
        },
        sessionManager: manager
      })
      if (owner.sessionId !== record.metadata.sessionId) {
        await owner.dispose()
        throw new Error(`Loaded agent session does not match: ${record.metadata.path}`)
      }
      if (record.state.type !== "loading" || record.state.operationId !== operationId || this.#state !== "open") {
        await owner.dispose()
        throw new Error(`Agent load became stale: ${record.metadata.path}`)
      }
      record.state = { type: "resident", owner, sessionManager: manager, turn: { type: "idle" } }
      await this.#retryPendingMail(record, owner)
      await this.#retryPendingCompletions(record, owner)
      return owner
    } catch (cause) {
      if (record.state.type === "loading" && record.state.operationId === operationId) {
        record.state = { type: "unloaded" }
      }
      throw cause
    }
  }

  async #startTurn(record: AgentRecord, sender: AgentPath, text: string): Promise<void> {
    if (record.state.type !== "resident" || record.state.turn.type !== "idle") {
      throw new Error(`Agent is not idle: ${record.metadata.path}`)
    }
    const otherReservedSpawns = this.#reservedPaths.size - Number(this.#reservedPaths.has(record.metadata.path))
    if (this.#activeTurns() + otherReservedSpawns >= maxActiveAgentTurns) {
      throw new Error("Agent turn capacity reached")
    }

    const owner = record.state.owner
    const sessionManager = record.state.sessionManager
    const operationId = crypto.randomUUID()
    const mailId = crypto.randomUUID()
    const turn = record.metadata.nextTurn
    const applied = deferred<void>()
    record.state = {
      type: "resident",
      owner,
      sessionManager,
      turn: { type: "starting", operationId, turn, mailId, applied }
    }
    let reserved = false
    try {
      this.#rootSessionManager.appendAgentTeam({
        type: "agent_turn_reserved",
        operationId,
        path: record.metadata.path,
        turn,
        mailId
      })
      reserved = true
      const input: AgentMailInput = { deliveryId: mailId, sender, target: record.metadata.path, kind: "task", text }
      const admission = owner.startTurn(input, entry => {
        this.#rootSessionManager.appendAgentTeam({ type: "agent_turn_started", operationId, inputEntryId: entry.id })
      })
      const timeout = setTimeout(() => {
        void this.#withRecord(record, async () => {
          if (
            record.state.type !== "resident" ||
            record.state.turn.type !== "running" ||
            record.state.turn.operationId !== operationId
          ) {
            return
          }
          record.state = { ...record.state, turn: { ...record.state.turn, type: "interrupting" } }
          this.#publishChange([record.metadata.path])
          await owner.interrupt("turn_timeout")
        })
      }, this.#turnTimeoutMs)
      timeout.unref()
      record.state = {
        type: "resident",
        owner,
        sessionManager,
        turn: { type: "running", operationId, turn, applied, timeout }
      }
      this.#publishChange([record.metadata.path])
      const settlement = this.#settleTurn(record, operationId, turn, admission.settled, applied)
      this.#settlements.add(settlement)
      void settlement.finally(() => this.#settlements.delete(settlement)).catch(() => {})
    } catch (cause) {
      if (!reserved) {
        record.state = { type: "resident", owner, sessionManager, turn: { type: "idle" } }
        applied.resolve()
        throw cause
      }
      const result = failedResult(cause)
      this.#rootSessionManager.appendAgentTeam({
        type: "agent_turn_settled",
        operationId,
        path: record.metadata.path,
        turn,
        result
      })
      record.metadata = { ...record.metadata, nextTurn: turn + 1, status: "failed" }
      record.state = { type: "resident", owner, sessionManager, turn: { type: "idle" } }
      this.#publishChange([record.metadata.path])
      await this.#deliverCompletion(record, turn, result)
      await this.#evictSettledRecord(record, turn)
      applied.resolve()
      throw cause
    }
  }

  async #settleTurn(
    record: AgentRecord,
    operationId: string,
    turn: number,
    settlement: Promise<AgentTurnResult>,
    applied: ReturnType<typeof deferred<void>>
  ): Promise<void> {
    let result: AgentTurnResult
    try {
      result = await settlement
    } catch (cause) {
      result = failedResult(cause)
    }
    await this.#commitTurnSettlement(record, operationId, turn, result, applied, 1)
  }

  async #commitTurnSettlement(
    record: AgentRecord,
    operationId: string,
    turn: number,
    result: AgentTurnResult,
    applied: ReturnType<typeof deferred<void>>,
    attempt: number
  ): Promise<void> {
    try {
      await this.#withRecord(record, async () => {
        const state = record.state
        if (
          state.type !== "resident" ||
          (state.turn.type !== "running" && state.turn.type !== "interrupting") ||
          state.turn.operationId !== operationId ||
          state.turn.turn !== turn
        ) {
          applied.resolve()
          return
        }
        this.#rootSessionManager.appendAgentTeam({
          type: "agent_turn_settled",
          operationId,
          path: record.metadata.path,
          turn,
          result
        })
        clearTimeout(state.turn.timeout)
        record.metadata = { ...record.metadata, nextTurn: turn + 1, status: result.status }
        record.state = { ...state, turn: { type: "idle" } }
        this.#publishChange([record.metadata.path])
        await this.#deliverCompletion(record, turn, result)
      })
    } catch (cause) {
      if (attempt === 3) {
        this.#state = "stopping"
        applied.reject(cause)
        throw cause
      }
      await delay(25)
      await this.#commitTurnSettlement(record, operationId, turn, result, applied, attempt + 1)
      return
    }

    try {
      await this.#withRecord(record, () => this.#evictSettledRecord(record, turn))
      applied.resolve()
    } catch (cause) {
      this.#state = "stopping"
      applied.reject(cause)
      throw cause
    }
  }

  async #evictSettledRecord(record: AgentRecord, turn: number): Promise<void> {
    if (
      record.state.type !== "resident" ||
      record.state.turn.type !== "idle" ||
      record.metadata.nextTurn !== turn + 1
    ) {
      return
    }
    await this.#disposeRecord(record)
    this.#publishChange([record.metadata.path])
  }

  async #deliverCompletion(record: AgentRecord, turn: number, result: AgentTurnResult): Promise<void> {
    const target = record.metadata.parentPath
    try {
      const input = completionMail(record.metadata.path, target, turn, result)
      const parent = target === rootAgentPath ? undefined : this.#requireRecord(target)
      const admission =
        target === rootAgentPath
          ? this.#root?.admitMail(input)
          : parent?.state.type === "resident"
            ? parent.state.owner.admitMail(input, parent.state.turn.type === "idle" ? "append" : "boundary")
            : undefined
      if (!admission) return
      this.#rootSessionManager.appendAgentTeam({
        type: "agent_completion_delivered",
        path: record.metadata.path,
        turn,
        targetEntryId: admission.entry.id
      })
    } catch {
      // The durable settlement remains pending until the direct parent is resident again.
    }
  }

  async #retryPendingCompletions(record: AgentRecord, owner: AgentTeamSessionOwner): Promise<void> {
    const restored = replayAgentTeamJournal(this.#rootSessionManager.agentTeamEntries())
    for (const completion of restored.pendingCompletions.values()) {
      if (completion.parentPath !== record.metadata.path) continue
      const admission = owner.admitMail(
        completionMail(completion.path, record.metadata.path, completion.turn, completion.result),
        "append"
      )
      this.#rootSessionManager.appendAgentTeam({
        type: "agent_completion_delivered",
        path: completion.path,
        turn: completion.turn,
        targetEntryId: admission.entry.id
      })
    }
  }

  async #retryPendingRootMail(root: AgentTeamRoot): Promise<void> {
    const restored = replayAgentTeamJournal(this.#rootSessionManager.agentTeamEntries())
    for (const mail of restored.pendingMail.values()) {
      if (mail.target !== rootAgentPath) continue
      this.#deliverRootMail(root, {
        deliveryId: mail.mailId,
        sender: mail.sender,
        target: mail.target,
        kind: mail.kind,
        text: mail.text
      })
    }
  }

  #deliverRootMail(root: AgentTeamRoot, mail: AgentMailInput): void {
    const admission = root.admitMail(mail)
    this.#rootSessionManager.appendAgentTeam({
      type: "agent_mail_delivered",
      mailId: mail.deliveryId,
      targetEntryId: admission.entry.id
    })
  }

  async #retryPendingMail(record: AgentRecord, owner: AgentTeamSessionOwner): Promise<void> {
    const restored = replayAgentTeamJournal(this.#rootSessionManager.agentTeamEntries())
    for (const mail of restored.pendingMail.values()) {
      if (mail.target !== record.metadata.path) continue
      const admission = owner.admitMail(
        { deliveryId: mail.mailId, sender: mail.sender, target: mail.target, kind: mail.kind, text: mail.text },
        "append"
      )
      this.#rootSessionManager.appendAgentTeam({
        type: "agent_mail_delivered",
        mailId: mail.mailId,
        targetEntryId: admission.entry.id
      })
    }
  }

  async #deliverOrdinaryMail(
    record: AgentRecord,
    owner: AgentTeamSessionOwner,
    sender: AgentPath,
    kind: "message" | "task",
    text: string
  ): Promise<void> {
    this.#deliverQueuedMail(record, owner, this.#queueOrdinaryMail(record.metadata.path, sender, kind, text))
  }

  #queueOrdinaryMail(target: AgentPath, sender: AgentPath, kind: "message" | "task", text: string): OrdinaryAgentMail {
    const mail: OrdinaryAgentMail = { deliveryId: crypto.randomUUID(), sender, target, kind, text }
    this.#rootSessionManager.appendAgentTeam({
      type: "agent_mail_queued",
      mailId: mail.deliveryId,
      sender: mail.sender,
      target: mail.target,
      kind: mail.kind,
      text: mail.text
    })
    return mail
  }

  #deliverQueuedMail(record: AgentRecord, owner: AgentTeamSessionOwner, mail: AgentMailInput): void {
    const publication: AgentMailPublication =
      record.state.type === "resident" && record.state.turn.type !== "idle" ? "boundary" : "append"
    const admission = owner.admitMail(mail, publication)
    try {
      this.#rootSessionManager.appendAgentTeam({
        type: "agent_mail_delivered",
        mailId: mail.deliveryId,
        targetEntryId: admission.entry.id
      })
    } catch {
      // Target admission is durable; restoration can acknowledge the still-pending root mail.
    }
  }

  #activeTurns(): number {
    let active = 0
    for (const record of this.#records.values()) {
      if (record.state.type === "resident" && record.state.turn.type !== "idle") active++
    }
    return active
  }

  #requireRecord(path: AgentPath): AgentRecord {
    const record = this.#records.get(path)
    if (!record) throw new Error(`Unknown agent path: ${path}`)
    return record
  }

  #residentSessionManager(record: AgentRecord): SessionManager {
    if (record.state.type !== "resident") throw new Error(`Agent is not resident: ${record.metadata.path}`)
    return record.state.sessionManager
  }

  #withRecord<Value>(record: AgentRecord, operation: () => Promise<Value>): Promise<Value> {
    const result = record.tail.then(operation, operation)
    record.tail = result.then(
      () => undefined,
      () => undefined
    )
    return result
  }

  #publishChange(paths: readonly AgentPath[]): void {
    const change = Object.freeze({ revision: ++this.#revision, paths: Object.freeze([...new Set(paths)]) })
    for (const listener of this.#listeners) {
      try {
        listener(change)
      } catch {
        // Observation cannot own AgentTeam transitions.
      }
    }
  }

  #assertOpen(): void {
    if (this.#state !== "open") throw new Error(`AgentTeam is ${this.#state}`)
  }
}

function snapshot(record: AgentRecord): AgentSnapshot {
  const state = record.state
  const turn = state.type === "resident" ? state.turn : undefined
  const residency = state.type === "disposing" || state.type === "dispose_failed" ? "resident" : state.type
  return Object.freeze({
    path: record.metadata.path,
    parentPath: record.metadata.parentPath,
    sessionId: record.metadata.sessionId,
    taskName: record.metadata.taskName,
    agentType: record.metadata.agentType,
    generation: record.metadata.generation,
    residency,
    turn: turn?.type ?? "idle",
    turnNumber: turn && turn.type !== "idle" ? turn.turn : record.metadata.nextTurn - 1,
    status: record.metadata.status
  })
}

function lineage(record: DurableAgentRecord, rootSessionId: string) {
  return {
    rootSessionId,
    parentSessionId: record.parentSessionId,
    parentEntryId: record.parentEntryId,
    path: record.path,
    generation: record.generation
  }
}

function completionMail(path: AgentPath, target: AgentPath, turn: number, result: AgentTurnResult): AgentMailInput {
  const summary = result.status === "completed" ? result.text : `${result.status}: ${result.text}`
  return { deliveryId: `completion:${path}:${turn}`, sender: path, target, kind: "completion", text: summary }
}

function interruptedResult(reason: "restart" | "shutdown" | "requested" | "turn_timeout"): AgentTurnResult {
  return { status: "interrupted", reason, durationMs: 0, text: "", originalBytes: 0, omittedBytes: 0, truncated: false }
}

function failedResult(cause: unknown): AgentTurnResult {
  const message = boundedError(cause)
  return {
    status: "failed",
    code: "assignment_failed",
    message,
    durationMs: 0,
    text: "",
    originalBytes: 0,
    omittedBytes: 0,
    truncated: false
  }
}

function boundedError(cause: unknown): string {
  const message = cause instanceof Error ? cause.message : String(cause)
  return Buffer.from(message)
    .subarray(0, 8 * 1024)
    .toString("utf8")
}

function positiveDuration(value: number, name: string): number {
  if (!Number.isFinite(value) || value <= 0) throw new Error(`${name} must be positive`)
  return value
}

async function withTimeout<Value>(promise: Promise<Value>, timeoutMs: number): Promise<Value> {
  let timeout: ReturnType<typeof setTimeout> | undefined
  try {
    return await Promise.race([
      promise,
      new Promise<never>((_resolve, reject) => {
        timeout = setTimeout(() => reject(new Error("AgentTeam shutdown timed out")), timeoutMs)
        timeout.unref()
      })
    ])
  } finally {
    if (timeout) clearTimeout(timeout)
  }
}

function delay(ms: number): Promise<void> {
  return new Promise(resolve => {
    const timeout = setTimeout(resolve, ms)
    timeout.unref()
  })
}

function deferred<Value>() {
  let resolve!: (value: Value | PromiseLike<Value>) => void
  let reject!: (cause?: unknown) => void
  const promise = new Promise<Value>((resolvePromise, rejectPromise) => {
    resolve = resolvePromise
    reject = rejectPromise
  })
  return { promise, resolve, reject }
}
