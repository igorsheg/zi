import type { ThinkingLevel } from "@earendil-works/pi-agent-core"
import { InvariantError, type InvariantRegistry } from "@with-zi/invariants"

import type {
  SessionEntry,
  SessionManager,
  SubagentEntry,
  SubagentEntryInput,
  SubagentWorkResultEntry
} from "../session-manager.js"
import type { ToolSurface } from "../tool-surface.js"
import {
  childCloseSettlementMs,
  SubagentChild,
  type ChildLifecycleState,
  type ChildSnapshot,
  type ChildTranscriptSnapshot,
  type CreateSubagentChildSession,
  type SubagentCompletion
} from "./child.js"
import { CompletionLedger, maxCompletionLedgerEntries, type CompletionDelivery } from "./completion-ledger.js"
import { SubagentInvariant } from "./invariant.js"
import { maxPeerAgents, maxPeerMessageBytes, type PeerAgent, type PeerRelay } from "./peer.js"
import { maxSubagentWorkResultEntryBytes, type SubagentWorkResultInput } from "./result.js"
import { clipUtf8 } from "./text.js"
import { defaultWaitTimeoutMs, isSubagentWaitTimeout, maxWaitTimeoutMs } from "./wait-policy.js"
import { defaultSubagentWorkTimeoutMs, isSubagentWorkTimeout } from "./work-policy.js"

export type { CompletionDelivery } from "./completion-ledger.js"
export { defaultWaitTimeoutMs, maxWaitTimeoutMs } from "./wait-policy.js"
export { defaultSubagentWorkTimeoutMs, maxSubagentWorkTimeoutMs } from "./work-policy.js"

export const maxLiveChildren = 4
export const maxRunningChildren = 2
export const maxRetainedSubagents = 32
export const maxSubagentReadyResults = maxCompletionLedgerEntries
export const maxMailboxCompletions = maxSubagentReadyResults
export const maxWaitNames = 16
export const maxSubagentPromptBytes = 8 * 1024 * 1024
export const maxSubagentNameBytes = 64
export const maxSubagentTaskBytes = 256
export const durablePreviewBytes = 8 * 1024
const maxSubagentResultTextJsonBytes = (maxSubagentWorkResultEntryBytes - 2 * 1024) / 2
export const subagentShutdownMs = 9_000
export const maxRetainedExitedTranscriptBytes = 16 * 1024 * 1024

export type SupervisorState = { readonly type: "open" } | { readonly type: "stopping" } | { readonly type: "closed" }

export interface SubagentSnapshot {
  readonly name: string
  readonly lifecycle: ChildSnapshot["lifecycle"]
  readonly workCycle?: number
  readonly capturedWorkCycle?: number
  readonly task?: string
  readonly elapsedMs?: number
  readonly sessionId?: string
  readonly completion?: SubagentCompletion
  readonly completionDelivery?: CompletionDelivery["type"]
}

export type SubagentTranscriptSnapshot = ChildTranscriptSnapshot

export interface SubagentStatus {
  readonly workingNames: readonly string[]
  readonly readyNames: readonly string[]
}

export interface SubagentCapacity {
  readonly live: number
  readonly maximum: number
}

export interface SubagentInterruptSettlement {
  readonly result: "interrupted" | "already_idle"
  readonly snapshot: SubagentSnapshot
}

interface LiveRecord {
  readonly child: SubagentChild
  readonly serial: PromiseQueue
  readonly createdAt: number
  lastWorkCycle: number
  task: string
  closing?: Promise<void>
}

interface ExitedRecord {
  readonly snapshot: ChildSnapshot
  readonly transcript?: SubagentTranscriptSnapshot
  readonly exitedAt: number
  readonly task?: string
}

interface UnpublishedCreation {
  readonly name: string
  readonly controller: AbortController
  readonly settlement: ReturnType<typeof deferredVoid>
  readonly externalCancellation?: { readonly signal: AbortSignal; readonly abort: () => void }
}

interface WaitTarget {
  readonly name: string
  readonly workCycle: number
  readonly admittedSnapshot: ChildSnapshot
}

export interface SubagentSpawnSelection {
  readonly profile?: string
  readonly model?: string
  readonly thinkingLevel?: ThinkingLevel
  readonly listedTask?: string
}

export interface SubagentSupervisorOptions {
  readonly createChildSession: CreateSubagentChildSession
  readonly selection: () => { readonly model: string; readonly thinkingLevel: ThinkingLevel; readonly apiKey?: string }
  readonly sessionManager: SessionManager
  readonly invariantRegistry: InvariantRegistry
  readonly waitTimeoutMs?: number
  readonly workTimeoutMs?: number
  readonly closeSettlementMs?: number
  readonly toolSurface?: ToolSurface
}

export type SubagentSupervisorEvent =
  | { readonly type: "changed"; readonly name: string }
  | { readonly type: "entry_appended"; readonly entry: SessionEntry }

export class SubagentSupervisor {
  readonly #createChildSession: CreateSubagentChildSession
  readonly #selection: () => { readonly model: string; readonly thinkingLevel: ThinkingLevel; readonly apiKey?: string }
  readonly #sessionManager: SessionManager
  readonly #toolSurface: ToolSurface
  readonly #creations = new Map<string, UnpublishedCreation>()
  readonly #listeners = new Set<(event: SubagentSupervisorEvent) => void>()
  readonly #names = new Set<string>()
  readonly #profiles = new Map<string, string>()
  readonly #live = new Map<string, LiveRecord>()
  readonly #queuedNames: string[] = []
  readonly #exited: ExitedRecord[] = []
  readonly #ledger: CompletionLedger
  readonly #invariant: SubagentInvariant
  readonly #waiters = new Set<() => void>()
  #resultSink:
    | ((
        result: SubagentWorkResultInput,
        persisted: (result: SubagentWorkResultEntry) => void
      ) => SubagentWorkResultEntry)
    | undefined
  readonly waitTimeoutMs: number
  readonly workTimeoutMs: number
  readonly closeSettlementMs: number
  #state: SupervisorState = { type: "open" }
  #shutdown: Promise<void> | undefined

  constructor(options: SubagentSupervisorOptions) {
    this.#createChildSession = options.createChildSession
    this.#selection = options.selection
    this.#sessionManager = options.sessionManager
    const results = this.#sessionManager.subagentWorkResults()
    this.#ledger = CompletionLedger.restore(results, this.#sessionManager.subagentEntries(), maxMailboxCompletions)
    for (const result of results) {
      if (result.profile) this.#profiles.set(result.name, result.profile)
    }
    this.#toolSurface = options.toolSurface ?? "direct-and-code"
    this.waitTimeoutMs = options.waitTimeoutMs ?? defaultWaitTimeoutMs
    if (!isSubagentWaitTimeout(this.waitTimeoutMs)) throw new Error("Invalid subagent wait timeout")
    this.workTimeoutMs = options.workTimeoutMs ?? defaultSubagentWorkTimeoutMs
    if (!isSubagentWorkTimeout(this.workTimeoutMs)) throw new Error("Invalid subagent work timeout")
    this.closeSettlementMs = options.closeSettlementMs ?? childCloseSettlementMs
    if (
      !Number.isSafeInteger(this.closeSettlementMs) ||
      this.closeSettlementMs <= 0 ||
      this.closeSettlementMs >= subagentShutdownMs
    ) {
      throw new Error("Invalid child close settlement bound")
    }
    this.#recover()
    this.#invariant = new SubagentInvariant(options.invariantRegistry)
    this.#assertInvariants()
  }

  get state(): SupervisorState {
    return this.#state
  }

  bindSubagentWorkResultSink(
    sink: (
      result: SubagentWorkResultInput,
      persisted: (result: SubagentWorkResultEntry) => void
    ) => SubagentWorkResultEntry
  ): void {
    if (this.#resultSink) throw new Error("Subagent work result sink is already bound")
    this.#resultSink = sink
    this.#pumpMailbox()
  }

  subscribe(listener: (event: SubagentSupervisorEvent) => void): () => void {
    this.#listeners.add(listener)
    return () => this.#listeners.delete(listener)
  }

  snapshots(): readonly SubagentSnapshot[] {
    return Object.freeze([
      ...[...this.#live.values()].map(record => this.#snapshot(record.child.snapshot(), record.task)),
      ...this.#exited.map(record => this.#snapshot(record.snapshot, record.task))
    ])
  }

  transcript(name: string): SubagentTranscriptSnapshot | undefined {
    validateSubagentName(name)
    const live = this.#live.get(name)
    if (live) return live.child.transcript()
    return this.#exited.find(record => record.snapshot.name === name)?.transcript
  }

  capacity(): SubagentCapacity {
    return Object.freeze({ live: this.#live.size + this.#creations.size, maximum: maxLiveChildren })
  }

  runningCount(): number {
    let count = 0
    for (const record of this.#live.values()) {
      if (record.child.state.type === "running" || record.child.state.type === "interrupting") count++
    }
    return count
  }

  status(): SubagentStatus {
    const workingNames = [...this.#live.values()]
      .filter(record => isWorkingLifecycle(record.child.state.type))
      .map(record => record.child.name)
    return Object.freeze({ workingNames: Object.freeze(workingNames), readyNames: this.#ledger.readyNames() })
  }

  deliverCompletions(deliver: (completion: SubagentCompletion) => void): void {
    this.#pumpMailbox()
    for (const delivery of this.#ledger.deliveries()) {
      if (delivery.type !== "durable") continue
      deliver(delivery.completion)
      this.acknowledgeCompletion(delivery.completion.name, delivery.completion.workCycle)
    }
  }

  acknowledgeCompletion(name: string, workCycle: number): void {
    if (!this.#ledger.acknowledge(name, workCycle)) return
    this.#changed(name)
    try {
      this.#append({ event: "work_cycle_delivered", name, workCycle })
    } catch {
      // The parent result is already durable; restoration can infer delivery from it.
    }
  }

  releaseCompletionClaims(claimIdPrefix?: string): void {
    for (const name of this.#ledger.releaseClaims(claimIdPrefix)) this.#changed(name)
  }

  async spawn(
    name: string,
    prompt: string,
    signal?: AbortSignal,
    requestedSelection: SubagentSpawnSelection = {}
  ): Promise<string> {
    this.#assertOpen()
    validateSubagentName(name)
    validateText(prompt, "Subagent prompt", maxSubagentPromptBytes)
    if (this.#live.size + this.#creations.size >= maxLiveChildren) {
      throw new Error(
        `Subagent capacity exceeded: at most ${maxLiveChildren} live children. Close a child you no longer need before spawning another.`
      )
    }
    if (this.#names.has(name)) throw new Error(`Subagent name already in use: ${name}`)
    const inheritedSelection = this.#selection()
    const listedTask = requestedSelection.listedTask ?? prompt
    validateText(listedTask, "Subagent listed task", maxSubagentPromptBytes)
    const task = clipUtf8(listedTask, maxSubagentTaskBytes).text
    const selection = {
      model: requestedSelection.model ?? inheritedSelection.model,
      thinkingLevel: requestedSelection.thinkingLevel ?? inheritedSelection.thinkingLevel,
      ...(requestedSelection.model === undefined || requestedSelection.model === inheritedSelection.model
        ? { apiKey: inheritedSelection.apiKey }
        : {})
    }
    validateText(selection.model, "Subagent model", 4_096)
    if (selection.apiKey) validateText(selection.apiKey, "Subagent API key", 64 * 1024)
    this.#reserveCompletion(name, 1)
    const creation = this.#beginCreation(name, signal)
    this.#names.add(name)
    try {
      this.#append({ event: "starting", name })
    } catch (cause) {
      this.#ledger.cancelReservation(name, 1)
      this.#names.delete(name)
      this.#finishCreation(creation)
      throw cause
    }
    this.#invariant.introduce(name)
    if (requestedSelection.profile) this.#profiles.set(name, requestedSelection.profile)

    let owner: Awaited<ReturnType<CreateSubagentChildSession>>
    try {
      owner = await this.#createChildSession({
        name,
        model: selection.model,
        thinkingLevel: selection.thinkingLevel,
        ...(selection.apiKey ? { apiKey: selection.apiKey } : {}),
        toolSurface: this.#toolSurface,
        peerRelay: this.#peerRelay(name),
        signal: creation.controller.signal
      })
    } catch (cause) {
      try {
        this.#retainCreationFailure(name, task, cause)
      } finally {
        this.#finishCreation(creation)
      }
      throw cause
    }
    if (this.#state.type !== "open" || creation.controller.signal.aborted) {
      let cause: Error = spawnCancellation(name)
      try {
        await owner.dispose("quit")
      } catch (cleanupCause) {
        const cleanupMessage = cleanupCause instanceof Error ? cleanupCause.message : String(cleanupCause)
        cause = new Error(`${cause.message}; cleanup failed: ${cleanupMessage}`, { cause: cleanupCause })
      }
      try {
        this.#retainCreationFailure(name, task, cause)
      } finally {
        this.#finishCreation(creation)
      }
      throw cause
    }

    let child: SubagentChild
    try {
      child = new SubagentChild({
        name,
        owner,
        workTimeoutMs: this.workTimeoutMs,
        closeSettlementMs: this.closeSettlementMs,
        onStateChange: () => this.#childChanged(name),
        onCompletion: completion => this.#completion(completion),
        onPresentationChange: () => this.#presentationChanged(name)
      })
    } catch (cause) {
      let failure = cause
      try {
        await owner.dispose("quit")
      } catch (cleanupCause) {
        const message = cause instanceof Error ? cause.message : String(cause)
        const cleanupMessage = cleanupCause instanceof Error ? cleanupCause.message : String(cleanupCause)
        failure = new Error(`${message}; cleanup failed: ${cleanupMessage}`, { cause: cleanupCause })
      }
      try {
        this.#retainCreationFailure(name, task, failure)
      } finally {
        this.#finishCreation(creation)
      }
      throw failure
    }
    const record: LiveRecord = { child, serial: new PromiseQueue(), createdAt: Date.now(), lastWorkCycle: 0, task }
    this.#live.set(name, record)
    const abort = (): void => {
      void this.close(name, "startup_cancelled").catch(() => {})
    }
    signal?.addEventListener("abort", abort, { once: true })
    this.#finishCreation(creation)
    this.#changed(name)
    try {
      this.#assertSpawnAdmission(name, record, signal)
      this.#append({ event: "ready", name, sessionId: owner.session.sessionId })
      this.#appendWorkCycleStarted(record, name, 1)
      child.queueCycle(prompt)
      this.#queuedNames.push(name)
      this.#pumpQueued()
      this.#assertSpawnAdmission(name, record, signal)
      this.#assertInvariants()
      return name
    } catch (cause) {
      if (this.#live.get(name) === record) await this.close(name, "startup_failed").catch(() => {})
      if (record.lastWorkCycle === 0) this.#ledger.cancelReservation(name, 1)
      throw cause
    } finally {
      signal?.removeEventListener("abort", abort)
    }
  }

  async send(name: string, text: string): Promise<void> {
    this.#assertOpen()
    validateSubagentName(name)
    validateText(text, "Subagent message", maxSubagentPromptBytes)
    const record = this.#requireLive(name)
    await record.serial.run(() => record.child.send(text))
    this.#pumpMailbox()
  }

  async continue(name: string, text: string): Promise<"started_turn" | "follow_up"> {
    this.#assertOpen()
    validateSubagentName(name)
    validateText(text, "Subagent message", maxSubagentPromptBytes)
    const record = this.#requireLive(name)
    const delivery = await record.serial.run(async () => {
      const snapshot = record.child.snapshot()
      const nextCycle = (snapshot.workCycle ?? 0) + 1
      const startedTurn = snapshot.lifecycle === "idle"
      if (startedTurn) this.#reserveCompletion(name, nextCycle)
      const previousTask = record.task
      let cycleStarted = false
      try {
        if (startedTurn) {
          record.task = clipUtf8(text, maxSubagentTaskBytes).text
          this.#appendWorkCycleStarted(record, name, nextCycle)
          cycleStarted = true
        }
        const admission = record.child.assign(text)
        if (admission === "queued") {
          this.#queuedNames.push(name)
          this.#pumpQueued()
        }
      } catch (cause) {
        if (!cycleStarted) {
          record.task = previousTask
          if (startedTurn) this.#ledger.cancelReservation(name, nextCycle)
        } else if (record.child.snapshot().lifecycle === "idle") {
          this.#completion({
            name,
            workCycle: nextCycle,
            status: "failed",
            text: "",
            originalBytes: 0,
            omittedBytes: 0,
            truncated: false,
            durationMs: record.child.snapshot().elapsedMs ?? 0,
            reason: "assignment_failed",
            error: clipUtf8(cause instanceof Error ? cause.message : String(cause), durablePreviewBytes).text
          })
        }
        throw cause
      }
      return startedTurn ? "started_turn" : "follow_up"
    })
    this.#pumpMailbox()
    this.#assertInvariants()
    return delivery
  }

  async interrupt(name: string): Promise<"interrupted" | "already_idle"> {
    this.#assertOpen()
    validateSubagentName(name)
    const record = this.#requireLive(name)
    return record.serial.run(() => this.#interruptRecord(name, record))
  }

  async interruptAndWait(name: string, signal?: AbortSignal): Promise<SubagentInterruptSettlement> {
    return this.#interruptAndWait(name, signal, "consume")
  }

  async interruptAndWaitForTool(
    name: string,
    signal?: AbortSignal,
    claimId?: string
  ): Promise<SubagentInterruptSettlement> {
    return this.#interruptAndWait(name, signal, "claim", claimId)
  }

  async close(name: string, reason = "close"): Promise<SubagentSnapshot> {
    validateSubagentName(name)
    const record = this.#live.get(name)
    if (!record) return this.#snapshotFor(name)
    await this.#closeRecord(name, record, reason)
    this.#assertInvariants()
    return this.#snapshotFor(name)
  }

  async closeAndDeliver(name: string): Promise<SubagentSnapshot> {
    return this.#closeAndDeliver(name, "consume")
  }

  async closeAndDeliverForTool(name: string, claimId?: string): Promise<SubagentSnapshot> {
    return this.#closeAndDeliver(name, "claim", claimId)
  }

  async wait(
    names: readonly string[],
    timeoutMs = this.waitTimeoutMs,
    signal?: AbortSignal
  ): Promise<SubagentSnapshot[]> {
    return this.#wait(names, timeoutMs, signal, "consume")
  }

  async waitForTool(
    names: readonly string[],
    timeoutMs = this.waitTimeoutMs,
    signal?: AbortSignal,
    claimId?: string
  ): Promise<SubagentSnapshot[]> {
    this.#validateWaitNames(names, signal)
    this.#pumpMailbox()
    throwIfWaitCancelled(signal)
    const targets = this.#captureWaitTargets(names, "ready")
    const boundedTimeout = Math.min(Math.max(0, timeoutMs), maxWaitTimeoutMs)
    const deadline = Date.now() + boundedTimeout

    while (true) {
      this.#pumpMailbox()
      throwIfWaitCancelled(signal)
      const received = targets
        .filter(target => this.#waitTargetReady(target.name, target.workCycle))
        .map(target =>
          this.#settleDelivery(target.name, target.workCycle, target.admittedSnapshot, "claim", false, claimId)
        )
        .filter(snapshot => snapshot.completion !== undefined)
      if (received.length > 0 || Date.now() >= deadline) return received

      // oxlint-disable-next-line no-await-in-loop -- one bounded mailbox receive owner
      await this.#waitPulse(Math.min(100, deadline - Date.now()), signal)
      throwIfWaitCancelled(signal)
    }
  }

  async #wait(
    names: readonly string[],
    timeoutMs: number,
    signal: AbortSignal | undefined,
    deliveryMode: "consume" | "claim",
    claimId?: string
  ): Promise<SubagentSnapshot[]> {
    this.#validateWaitNames(names, signal)
    const targets = this.#captureWaitTargets(names, "durable")
    const boundedTimeout = Math.min(Math.max(0, timeoutMs), maxWaitTimeoutMs)
    const deadline = Date.now() + boundedTimeout
    this.#pumpMailbox()
    throwIfWaitCancelled(signal)
    while (Date.now() < deadline && !targets.every(target => this.#waitTargetSettled(target.name, target.workCycle))) {
      // oxlint-disable-next-line no-await-in-loop -- one bounded semantic wait owner
      await this.#waitPulse(Math.min(100, deadline - Date.now()), signal)
      throwIfWaitCancelled(signal)
      this.#pumpMailbox()
      throwIfWaitCancelled(signal)
    }
    return targets.map(target =>
      this.#settleDelivery(target.name, target.workCycle, target.admittedSnapshot, deliveryMode, false, claimId)
    )
  }

  #validateWaitNames(names: readonly string[], signal?: AbortSignal): void {
    this.#assertOpen()
    if (names.length === 0 || names.length > maxWaitNames) {
      throw new Error(`Subagent wait requires 1 through ${maxWaitNames} names`)
    }
    if (new Set(names).size !== names.length) throw new Error("Subagent wait rejects duplicate names")
    for (const name of names) {
      validateSubagentName(name)
      this.#requireKnown(name)
    }
    throwIfWaitCancelled(signal)
  }

  #captureWaitTargets(names: readonly string[], availability: "ready" | "durable"): readonly WaitTarget[] {
    return names.map(name => {
      const available = availability === "ready" ? this.#oldestReadyDelivery(name) : this.#oldestDurableDelivery(name)
      const workCycle = available?.completion.workCycle ?? this.#currentWorkCycle(name)
      return { name, workCycle, admittedSnapshot: this.#childSnapshotFor(name) }
    })
  }

  async #interruptAndWait(
    name: string,
    signal: AbortSignal | undefined,
    deliveryMode: "consume" | "claim",
    claimId?: string
  ): Promise<SubagentInterruptSettlement> {
    this.#assertOpen()
    validateSubagentName(name)
    const record = this.#requireLive(name)
    const settlement = record.serial.run(async () => {
      const admittedSnapshot = record.child.snapshot()
      const workCycle = admittedSnapshot.workCycle ?? record.lastWorkCycle
      const result = await this.#interruptRecord(name, record)
      throwIfWaitCancelled(signal)
      if (result === "already_idle") {
        return {
          result,
          snapshot: this.#settleDelivery(name, workCycle, admittedSnapshot, deliveryMode, true, claimId)
        }
      }
      const snapshot = await this.#waitForWorkCycle(name, workCycle, admittedSnapshot, deliveryMode, signal, claimId)
      return { result, snapshot }
    })
    return raceWithWaitCancellation(settlement, signal)
  }

  async #closeAndDeliver(name: string, deliveryMode: "consume" | "claim", claimId?: string): Promise<SubagentSnapshot> {
    validateSubagentName(name)
    this.#requireKnown(name)
    const admittedSnapshot = this.#childSnapshotFor(name)
    const workCycle = this.#currentWorkCycle(name)
    await this.close(name)
    return this.#settleDelivery(name, workCycle, admittedSnapshot, deliveryMode, true, claimId)
  }

  shutdown(): Promise<void> {
    if (this.#shutdown) return this.#shutdown
    if (this.#state.type === "closed") return Promise.resolve()
    this.#state = { type: "stopping" }
    const creations = [...this.#creations.values()]
    for (const creation of creations) creation.controller.abort(spawnCancellation(creation.name))
    const closeAll = Promise.all([
      ...[...this.#live.keys()].map(name => this.#closeImmediately(name, "session_disposed").catch(() => {})),
      ...creations.map(creation => creation.settlement.promise)
    ])
    this.#shutdown = settleWithin(
      closeAll.then(() => undefined),
      subagentShutdownMs
    ).then(() => {
      this.#pumpMailbox()
      this.#assertInvariants()
      if (this.#ledger.pendingPersistence().length > 0) {
        throw new Error("Could not persist subagent work results")
      }
      this.#invariant.shutdownSucceeded()
      this.#state = { type: "closed" }
      this.#notifyWaiters()
      this.#listeners.clear()
      this.#invariant.dispose()
      return undefined
    })
    return this.#shutdown
  }

  async #closeImmediately(name: string, reason: string): Promise<void> {
    const record = this.#live.get(name)
    if (!record) return
    if (record.child.state.type === "queued") await record.child.interrupt()
    await this.#closeRecord(name, record, reason)
  }

  #closeRecord(name: string, record: LiveRecord, reason: string): Promise<void> {
    if (record.closing) return record.closing
    const closing = (async (): Promise<void> => {
      try {
        this.#append({ event: "closing", name, reason })
      } catch {
        // Child cleanup and the in-memory terminal result must survive journal failure.
      }
      try {
        await record.child.close(reason)
      } finally {
        this.#retainExit(name, record)
      }
    })()
    record.closing = closing
    return closing
  }

  #beginCreation(name: string, signal?: AbortSignal): UnpublishedCreation {
    const controller = new AbortController()
    const externalAbort = (): void => controller.abort(spawnCancellation(name))
    const creation: UnpublishedCreation = {
      name,
      controller,
      settlement: deferredVoid(),
      ...(signal ? { externalCancellation: { signal, abort: externalAbort } } : {})
    }
    this.#creations.set(name, creation)
    if (signal?.aborted) externalAbort()
    else signal?.addEventListener("abort", externalAbort, { once: true })
    return creation
  }

  #finishCreation(creation: UnpublishedCreation): void {
    if (this.#creations.get(creation.name) === creation) this.#creations.delete(creation.name)
    const externalCancellation = creation.externalCancellation
    externalCancellation?.signal.removeEventListener("abort", externalCancellation.abort)
    creation.settlement.resolve()
  }

  #retainCreationFailure(name: string, task: string, cause: unknown): void {
    this.#ledger.cancelReservation(name, 1)
    const message = cause instanceof Error ? cause.message : String(cause)
    this.#retainExited({ snapshot: { name, lifecycle: "exited" }, exitedAt: Date.now(), task })
    this.#invariant.exit(name)
    try {
      this.#append({ event: "exited", name, outcome: clipUtf8(message, durablePreviewBytes).text })
    } finally {
      this.#changed(name)
    }
  }

  #completion(completion: SubagentCompletion): void {
    const retained = retainCompletion(completion)
    this.#invariant.settleWork(retained.name, retained.workCycle)
    if (this.#ledger.admit(retained) !== "accepted") return
    this.#pumpMailbox()
  }

  #pumpMailbox(): void {
    const changed = new Set<string>()
    while (true) {
      const pending = this.#ledger.pendingPersistence()[0]
      if (!pending) break
      const completion = pending.completion
      const preview = clipUtf8(completion.text, durablePreviewBytes)
      try {
        if (!this.#resultSink) break
        this.#resultSink(subagentResult(completion, this.#profiles.get(completion.name), preview), entry => {
          this.#ledger.commitPersistence(completion.name, completion.workCycle, entry.id)
          this.#invariant.persistResult(completion.name, completion.workCycle)
          changed.add(completion.name)
        })
      } catch (cause) {
        if (cause instanceof InvariantError) throw cause
        break
      }
    }
    for (const name of changed) this.#changed(name)
    this.#notifyWaiters()
  }

  #recover(): void {
    const latest = new Map<string, SubagentEntry>()
    const tasks = new Map<string, string>()
    const workCycles = new Map<string, number>()
    for (const entry of this.#sessionManager.subagentEntries()) {
      latest.delete(entry.name)
      latest.set(entry.name, entry)
      while (latest.size > maxRetainedSubagents) {
        const oldest = latest.keys().next().value
        if (oldest === undefined) break
        latest.delete(oldest)
        tasks.delete(oldest)
        workCycles.delete(oldest)
      }
      if (entry.event === "starting") {
        if (this.#names.has(entry.name)) throw new Error(`Duplicate subagent name in session journal: ${entry.name}`)
        this.#names.add(entry.name)
      }
      if (entry.event === "work_cycle_started") {
        workCycles.set(entry.name, entry.workCycle)
        if (entry.task) tasks.set(entry.name, entry.task)
      }
    }
    for (const [name, entry] of latest) {
      if (entry.event !== "exited" && entry.event !== "lost") {
        this.#append({ event: "lost", name, reason: "session_restored" })
      }
      const task = tasks.get(name)
      const workCycle = workCycles.get(name)
      this.#retainExited({
        snapshot: { name, lifecycle: "exited", ...(workCycle !== undefined ? { workCycle } : {}) },
        exitedAt: Date.parse(entry.timestamp),
        ...(task ? { task } : {})
      })
    }
  }

  #childChanged(name: string): void {
    const record = this.#live.get(name)
    const snapshot = record?.child.snapshot()
    if (record && snapshot?.workCycle !== undefined) record.lastWorkCycle = snapshot.workCycle
    if (record?.child.state.type === "exited") this.#retainExit(name, record)
    this.#removeQueuedNameUnlessQueued(name)
    this.#changed(name)
    this.#pumpQueued()
  }

  #retainExit(name: string, record: LiveRecord): void {
    if (this.#live.get(name) !== record) return
    this.#live.delete(name)
    this.#removeQueuedName(name)
    const state = record.child.state
    if (record.lastWorkCycle > 0 && !this.#delivery(name, record.lastWorkCycle)) {
      const failure =
        state.type === "exited" && state.outcome.type !== "closed"
          ? {
              reason:
                state.outcome.type === "forced" ? ("child_forced_settlement" as const) : ("child_failed" as const),
              error: clipUtf8(state.outcome.message, durablePreviewBytes).text
            }
          : { reason: "child_exited" as const }
      this.#completion({
        name,
        workCycle: record.lastWorkCycle,
        status: "failed",
        text: "",
        originalBytes: 0,
        omittedBytes: 0,
        truncated: false,
        durationMs: Math.max(0, Date.now() - record.createdAt),
        ...failure
      })
    }
    const snapshot = record.child.snapshot()
    this.#retainExited({
      snapshot:
        snapshot.workCycle === undefined && record.lastWorkCycle > 0
          ? { ...snapshot, workCycle: record.lastWorkCycle }
          : snapshot,
      transcript: record.child.transcript(),
      exitedAt: Date.now(),
      task: record.task
    })
    this.#invariant.exit(name)
    try {
      const exitDescription = state.type === "exited" ? JSON.stringify(state.outcome) : snapshot.lifecycle
      this.#append({ event: "exited", name, outcome: clipUtf8(exitDescription, durablePreviewBytes).text })
    } catch {
      // The exited snapshot and any pending completion remain addressable in memory.
    } finally {
      this.#changed(name)
    }
  }

  #retainExited(record: ExitedRecord): void {
    const existing = this.#exited.findIndex(value => value.snapshot.name === record.snapshot.name)
    if (existing >= 0) this.#exited.splice(existing, 1)
    this.#exited.push(record)
    while (this.#exited.length > maxRetainedSubagents) this.#exited.shift()
    this.#boundExitedTranscripts()
  }

  #boundExitedTranscripts(): void {
    let retainedBytes = 0
    for (let index = this.#exited.length - 1; index >= 0; index--) {
      const record = this.#exited[index]
      if (!record?.transcript) continue
      const bytes = Buffer.byteLength(JSON.stringify(record.transcript))
      if (retainedBytes + bytes <= maxRetainedExitedTranscriptBytes) {
        retainedBytes += bytes
        continue
      }
      this.#exited[index] = {
        snapshot: record.snapshot,
        exitedAt: record.exitedAt,
        ...(record.task ? { task: record.task } : {})
      }
    }
  }

  #snapshot(snapshot: ChildSnapshot, task?: string): SubagentSnapshot {
    const delivery = this.#oldestDurableDelivery(snapshot.name) ?? this.#latestDelivery(snapshot.name)
    const elapsedMs = snapshot.elapsedMs ?? delivery?.completion.durationMs
    return Object.freeze({
      name: snapshot.name,
      lifecycle: snapshot.lifecycle,
      ...(snapshot.workCycle !== undefined ? { workCycle: snapshot.workCycle } : {}),
      ...(task ? { task } : {}),
      ...(elapsedMs !== undefined ? { elapsedMs } : {}),
      ...(snapshot.sessionId ? { sessionId: snapshot.sessionId } : {}),
      ...(delivery?.type === "pending" || delivery?.type === "durable" || delivery?.type === "delivered"
        ? { completion: delivery.completion }
        : {}),
      ...(delivery ? { completionDelivery: delivery.type } : {})
    })
  }

  #snapshotFor(name: string): SubagentSnapshot {
    const live = this.#live.get(name)
    if (live) return this.#snapshot(live.child.snapshot(), live.task)
    const exited = this.#exited.find(value => value.snapshot.name === name)
    if (!exited) throw new Error(`Unknown subagent: ${name}`)
    return this.#snapshot(exited.snapshot, exited.task)
  }

  #waitSnapshotFor(name: string, workCycle: number, admittedSnapshot: ChildSnapshot): SubagentSnapshot {
    const live = this.#live.get(name)
    const retained = this.#exited.find(value => value.snapshot.name === name)
    const snapshot =
      live?.child.snapshot() ??
      retained?.snapshot ??
      Object.freeze({ ...admittedSnapshot, lifecycle: "exited" as const })
    const task = live?.task ?? retained?.task
    const delivery = this.#delivery(name, workCycle)
    const elapsedMs = snapshot.elapsedMs ?? delivery?.completion.durationMs
    return Object.freeze({
      name,
      lifecycle: snapshot.lifecycle,
      ...(snapshot.workCycle !== undefined ? { workCycle: snapshot.workCycle } : {}),
      capturedWorkCycle: workCycle,
      ...(task ? { task } : {}),
      ...(elapsedMs !== undefined ? { elapsedMs } : {}),
      ...(snapshot.sessionId ? { sessionId: snapshot.sessionId } : {}),
      ...(delivery?.type === "pending" || delivery?.type === "durable" || delivery?.type === "delivered"
        ? { completion: delivery.completion }
        : {}),
      ...(delivery ? { completionDelivery: delivery.type } : {})
    })
  }

  #claimedSnapshotFor(
    name: string,
    workCycle: number,
    admittedSnapshot: ChildSnapshot,
    claimId: string
  ): SubagentSnapshot {
    const snapshot = this.#waitSnapshotFor(name, workCycle, admittedSnapshot)
    const delivery = this.#delivery(name, workCycle)
    if (delivery?.type !== "claimed" || delivery.claimId !== claimId) return snapshot
    return Object.freeze({ ...snapshot, completion: delivery.completion, completionDelivery: "claimed" as const })
  }

  #terminalSnapshotFor(name: string, workCycle: number, admittedSnapshot: ChildSnapshot): SubagentSnapshot {
    const snapshot = this.#waitSnapshotFor(name, workCycle, admittedSnapshot)
    const delivery = this.#delivery(name, workCycle)
    return delivery ? Object.freeze({ ...snapshot, completion: delivery.completion }) : snapshot
  }

  #waitSnapshotWithoutCompletion(name: string, workCycle: number, admittedSnapshot: ChildSnapshot): SubagentSnapshot {
    const snapshot = this.#waitSnapshotFor(name, workCycle, admittedSnapshot)
    const { completion: _completion, completionDelivery: _completionDelivery, ...status } = snapshot
    return Object.freeze(status)
  }

  #childSnapshotFor(name: string): ChildSnapshot {
    const live = this.#live.get(name)
    if (live) return live.child.snapshot()
    const exited = this.#exited.find(value => value.snapshot.name === name)
    if (!exited) throw new Error(`Unknown subagent: ${name}`)
    return exited.snapshot
  }

  #delivery(name: string, workCycle: number): CompletionDelivery | undefined {
    return this.#ledger.delivery(name, workCycle)
  }

  #oldestReadyDelivery(name: string): Extract<CompletionDelivery, { type: "pending" | "durable" }> | undefined {
    return this.#ledger.oldestReady(name)
  }

  #oldestDurableDelivery(name: string): Extract<CompletionDelivery, { type: "durable" }> | undefined {
    return this.#ledger.oldestDurable(name)
  }

  #latestDelivery(name: string): CompletionDelivery | undefined {
    return this.#ledger.latest(name)
  }

  #waitTargetReady(name: string, workCycle: number): boolean {
    const delivery = this.#delivery(name, workCycle)
    return delivery?.type === "pending" || delivery?.type === "durable"
  }

  #waitTargetSettled(name: string, workCycle: number): boolean {
    const delivery = this.#delivery(name, workCycle)
    if (delivery) return true
    return workCycle === 0 && !this.#live.has(name)
  }

  async #waitForWorkCycle(
    name: string,
    workCycle: number,
    admittedSnapshot: ChildSnapshot,
    deliveryMode: "consume" | "claim",
    signal?: AbortSignal,
    claimId?: string
  ): Promise<SubagentSnapshot> {
    const deadline = Date.now() + this.waitTimeoutMs
    this.#pumpMailbox()
    throwIfWaitCancelled(signal)
    while (Date.now() < deadline && !this.#waitTargetSettled(name, workCycle)) {
      // oxlint-disable-next-line no-await-in-loop -- one bounded semantic wait owner
      await this.#waitPulse(Math.min(100, deadline - Date.now()), signal)
      throwIfWaitCancelled(signal)
      this.#pumpMailbox()
    }
    return this.#settleDelivery(name, workCycle, admittedSnapshot, deliveryMode, true, claimId)
  }

  #settleDelivery(
    name: string,
    workCycle: number,
    admittedSnapshot: ChildSnapshot,
    deliveryMode: "consume" | "claim",
    requireTerminalEvidence = false,
    claimId?: string
  ): SubagentSnapshot {
    const delivery = this.#delivery(name, workCycle)
    if (delivery?.type === "pending" || delivery?.type === "durable") {
      if (deliveryMode === "consume") {
        const snapshot = this.#waitSnapshotFor(name, workCycle, admittedSnapshot)
        if (delivery.type === "durable") {
          this.#markDelivered(name, workCycle)
          if (requireTerminalEvidence) return this.#terminalSnapshotFor(name, workCycle, admittedSnapshot)
        }
        return snapshot
      }
      const owner = claimId ?? crypto.randomUUID()
      if (this.#ledger.claim(name, workCycle, owner)) {
        this.#changed(name)
        return this.#claimedSnapshotFor(name, workCycle, admittedSnapshot, owner)
      }
    }
    if (delivery?.type === "delivered" && !requireTerminalEvidence) {
      return this.#waitSnapshotWithoutCompletion(name, workCycle, admittedSnapshot)
    }
    if (delivery?.type === "claimed" && !requireTerminalEvidence) {
      return this.#waitSnapshotWithoutCompletion(name, workCycle, admittedSnapshot)
    }
    return requireTerminalEvidence
      ? this.#terminalSnapshotFor(name, workCycle, admittedSnapshot)
      : this.#waitSnapshotFor(name, workCycle, admittedSnapshot)
  }

  #currentWorkCycle(name: string): number {
    const live = this.#live.get(name)
    if (live) return live.child.snapshot().workCycle ?? live.lastWorkCycle
    return this.#latestDelivery(name)?.completion.workCycle ?? 0
  }

  #markDelivered(name: string, workCycle: number): void {
    const entry = this.#sessionManager.appendSubagent({ event: "work_cycle_delivered", name, workCycle })
    if (!this.#ledger.markDelivered(name, workCycle)) {
      throw new Error("Subagent completion changed before its delivery commit")
    }
    this.#emit({ type: "entry_appended", entry })
    this.#changed(name)
  }

  #reserveCompletion(name: string, workCycle: number): void {
    this.#ledger.reserve(name, workCycle)
  }

  #append(data: SubagentEntryInput): SubagentEntry {
    const entry = this.#sessionManager.appendSubagent(data)
    this.#emit({ type: "entry_appended", entry })
    return entry
  }

  #appendWorkCycleStarted(record: LiveRecord, name: string, workCycle: number): void {
    const entry = this.#sessionManager.appendSubagent({
      event: "work_cycle_started",
      name,
      workCycle,
      task: record.task
    })
    record.lastWorkCycle = workCycle
    this.#invariant.startWork(name, workCycle)
    this.#emit({ type: "entry_appended", entry })
  }

  async #interruptRecord(name: string, record: LiveRecord): Promise<"interrupted" | "already_idle"> {
    const snapshot = record.child.snapshot()
    const workCycle = snapshot.workCycle
    const admitted = workCycle !== undefined && snapshot.lifecycle === "running"
    if (admitted) this.#invariant.admitInterrupt(name, workCycle)
    try {
      const result = await record.child.interrupt()
      this.#removeQueuedNameUnlessQueued(name)
      this.#pumpQueued()
      this.#assertInvariants()
      return result
    } catch (cause) {
      const state = record.child.state
      if (admitted && state.type === "running") {
        this.#invariant.rejectInterrupt(name, workCycle)
      }
      this.#assertInvariants()
      throw cause
    }
  }

  #pumpQueued(): void {
    if (this.#state.type !== "open") return
    while (this.runningCount() < maxRunningChildren) {
      const name = this.#queuedNames.shift()
      if (!name) return
      const record = this.#live.get(name)
      if (!record || record.child.state.type !== "queued") continue
      record.child.startQueuedCycle()
    }
  }

  #removeQueuedNameUnlessQueued(name: string): void {
    if (this.#live.get(name)?.child.state.type === "queued") return
    this.#removeQueuedName(name)
  }

  #removeQueuedName(name: string): void {
    const index = this.#queuedNames.indexOf(name)
    if (index >= 0) this.#queuedNames.splice(index, 1)
  }

  #peerRelay(sender: string): PeerRelay {
    return this.#relayPeer.bind(this, sender)
  }

  async #relayPeer(
    sender: string,
    request:
      | { readonly operation: "list" }
      | { readonly operation: "send"; readonly target: string; readonly text: string },
    signal?: AbortSignal
  ): Promise<{ readonly peers: readonly PeerAgent[] } | { readonly delivered: true }> {
    this.#assertOpen()
    throwIfPeerCancelled(signal)
    this.#requirePeerSender(sender)
    if (request.operation === "list") {
      const peers: PeerAgent[] = []
      for (const [name, record] of this.#live) {
        if (name === sender || record.child.state.type === "closing" || record.child.state.type === "exited") continue
        const lifecycle = record.child.state.type
        if (lifecycle !== "idle" && lifecycle !== "queued" && lifecycle !== "running" && lifecycle !== "interrupting") {
          continue
        }
        peers.push(Object.freeze({ name, lifecycle }))
        if (peers.length === maxPeerAgents) break
      }
      return Object.freeze({ peers: Object.freeze(peers) })
    }
    validateSubagentName(request.target)
    validateText(request.text, "Peer message", maxPeerMessageBytes)
    if (request.target === sender) throw new Error("A subagent cannot send a peer message to itself")
    const target = this.#live.get(request.target)
    if (!target || target.child.state.type === "closing" || target.child.state.type === "exited") {
      throw new Error(`Unknown live peer subagent: ${request.target}`)
    }
    await target.serial.run(async () => {
      this.#requirePeerSender(sender)
      if (this.#live.get(request.target) !== target || !isPeerLifecycle(target.child.state.type)) {
        throw new Error(`Unknown live peer subagent: ${request.target}`)
      }
      await target.child.send(`[Peer message from ${sender}]\n${request.text}`)
    })
    return Object.freeze({ delivered: true })
  }

  #assertSpawnAdmission(name: string, record: LiveRecord, signal?: AbortSignal): void {
    this.#assertOpen()
    if (
      signal?.aborted ||
      this.#live.get(name) !== record ||
      record.child.state.type === "closing" ||
      record.child.state.type === "exited"
    ) {
      throw new Error(`Subagent ${name} spawn admission was cancelled`)
    }
  }

  #requirePeerSender(name: string): void {
    const record = this.#live.get(name)
    if (!record || !isPeerLifecycle(record.child.state.type)) {
      throw new Error(`Unknown live peer sender: ${name}`)
    }
  }

  #requireLive(name: string): LiveRecord {
    const record = this.#live.get(name)
    if (!record) throw new Error(`Unknown live subagent: ${name}`)
    return record
  }

  #requireKnown(name: string): void {
    if (!this.#live.has(name) && !this.#exited.some(value => value.snapshot.name === name)) {
      throw new Error(`Unknown subagent: ${name}`)
    }
  }

  #assertOpen(): void {
    if (this.#state.type !== "open") throw new Error(`Subagent supervisor is ${this.#state.type}`)
  }

  #assertInvariants(): void {
    this.#ledger.assertInvariants()
    if (
      this.#live.size + this.#creations.size > maxLiveChildren ||
      this.#exited.length > maxRetainedSubagents ||
      this.runningCount() > maxRunningChildren ||
      this.#queuedNames.length > maxLiveChildren
    ) {
      throw new Error("Subagent supervisor invariant violated: retained state exceeds its bound")
    }
    const retained = new Set<string>()
    for (const name of this.#live.keys()) retained.add(name)
    for (const record of this.#exited) {
      if (retained.has(record.snapshot.name)) {
        throw new Error("Subagent supervisor invariant violated: subagent has multiple lifecycle owners")
      }
      retained.add(record.snapshot.name)
    }
    for (const creation of this.#creations.values()) {
      if (retained.has(creation.name)) {
        throw new Error("Subagent supervisor invariant violated: subagent has multiple lifecycle owners")
      }
      retained.add(creation.name)
    }
    for (const name of retained) {
      if (!this.#names.has(name))
        throw new Error("Subagent supervisor invariant violated: retained subagent is unnamed")
    }
    for (const completion of this.#ledger.identities()) {
      if (!this.#names.has(completion.name)) {
        throw new Error("Subagent supervisor invariant violated: completion belongs to an unknown subagent")
      }
    }
    const queued = new Set<string>()
    for (const name of this.#queuedNames) {
      if (queued.has(name) || this.#live.get(name)?.child.state.type !== "queued") {
        throw new Error("Subagent supervisor invariant violated: FIFO does not name unique queued children")
      }
      queued.add(name)
    }
    for (const [name, record] of this.#live) {
      if (record.child.state.type === "queued" && !queued.has(name)) {
        throw new Error("Subagent supervisor invariant violated: queued child is absent from FIFO")
      }
    }
  }

  #changed(name: string): void {
    this.#emit({ type: "changed", name })
    this.#notifyWaiters()
  }

  #presentationChanged(name: string): void {
    this.#emit({ type: "changed", name })
  }

  #emit(event: SubagentSupervisorEvent): void {
    for (const listener of this.#listeners) {
      try {
        listener(event)
      } catch {
        // Observer failure cannot interrupt supervisor transitions or delivery commits.
      }
    }
  }

  #notifyWaiters(): void {
    for (const waiter of this.#waiters) waiter()
  }

  #waitPulse(ms: number, signal?: AbortSignal): Promise<void> {
    if (ms <= 0 || signal?.aborted) return Promise.resolve()
    const settlement = deferredVoid()
    const finish = (): void => {
      clearTimeout(timer)
      signal?.removeEventListener("abort", finish)
      this.#waiters.delete(finish)
      settlement.resolve()
    }
    const timer = setTimeout(finish, ms)
    signal?.addEventListener("abort", finish, { once: true })
    this.#waiters.add(finish)
    return settlement.promise
  }
}

class PromiseQueue {
  #tail = Promise.resolve()

  run<T>(operation: () => Promise<T>): Promise<T> {
    const result = this.#tail.then(operation, operation)
    this.#tail = result.then(
      () => undefined,
      () => undefined
    )
    return result
  }
}

function validateSubagentName(name: string): void {
  validateText(name, "Subagent name", maxSubagentNameBytes)
  if (!/^[a-z][a-z0-9_-]*$/.test(name)) {
    throw new Error("Subagent names must start with a letter and contain only lowercase letters, numbers, _ or -")
  }
}

function validateText(value: string, label: string, maxBytes: number): void {
  if (value.length === 0 || value.includes("\0") || Buffer.byteLength(value) > maxBytes) {
    throw new Error(`${label} must contain 1 through ${maxBytes} UTF-8 bytes without NUL`)
  }
}

function retainCompletion(completion: SubagentCompletion): SubagentCompletion {
  if (completion.status !== "failed") return Object.freeze({ ...completion })
  return Object.freeze({
    ...completion,
    ...(completion.error ? { error: clipUtf8(completion.error, durablePreviewBytes).text } : {})
  })
}

function subagentResult(
  completion: SubagentCompletion,
  profile: string | undefined,
  preview: ReturnType<typeof clipUtf8>
): SubagentWorkResultInput {
  const boundedPreview = clipJsonString(preview.text, maxSubagentResultTextJsonBytes)
  const common = {
    name: completion.name,
    workCycle: completion.workCycle,
    ...(profile ? { profile } : {}),
    durationMs: completion.durationMs,
    preview: boundedPreview.text,
    originalBytes: completion.originalBytes,
    omittedBytes: completion.omittedBytes + preview.omittedBytes + boundedPreview.omittedBytes,
    truncated: completion.truncated || preview.omittedBytes > 0 || boundedPreview.omittedBytes > 0
  }
  if (completion.status === "failed") {
    const errorMessage = completion.error
      ? clipJsonString(completion.error, maxSubagentResultTextJsonBytes).text
      : undefined
    return { ...common, result: "failed", errorCode: completion.reason, ...(errorMessage ? { errorMessage } : {}) }
  }
  return { ...common, result: completion.status === "completed" ? "succeeded" : "cancelled" }
}

function clipJsonString(value: string, maximumBytes: number): ReturnType<typeof clipUtf8> {
  let low = 0
  let high = Math.min(Buffer.byteLength(value), maximumBytes)
  while (low < high) {
    const middle = Math.ceil((low + high) / 2)
    const candidate = clipUtf8(value, middle)
    if (Buffer.byteLength(JSON.stringify(candidate.text)) <= maximumBytes) low = middle
    else high = middle - 1
  }
  return clipUtf8(value, low)
}

function spawnCancellation(name: string): Error {
  return new Error(`Subagent ${name} spawn was cancelled`)
}

function deferredVoid(): { readonly promise: Promise<void>; resolve(): void } {
  let settled = false
  let resolvePromise!: () => void
  const promise = new Promise<void>(resolve => {
    resolvePromise = resolve
  })
  return {
    promise,
    resolve() {
      if (settled) return
      settled = true
      resolvePromise()
    }
  }
}

async function raceWithWaitCancellation<T>(operation: Promise<T>, signal?: AbortSignal): Promise<T> {
  if (!signal) return operation
  if (signal.aborted) throw waitCancellationError()
  let rejectCancellation!: (cause: Error) => void
  const cancellation = new Promise<never>((_, reject) => {
    rejectCancellation = reject
  })
  const abort = (): void => rejectCancellation(waitCancellationError())
  signal.addEventListener("abort", abort, { once: true })
  try {
    return await Promise.race([operation, cancellation])
  } finally {
    signal.removeEventListener("abort", abort)
  }
}

function throwIfWaitCancelled(signal?: AbortSignal): void {
  if (signal?.aborted) throw waitCancellationError()
}

function throwIfPeerCancelled(signal?: AbortSignal): void {
  if (!signal?.aborted) return
  if (signal.reason instanceof Error) throw signal.reason
  const error = new Error("Peer operation was cancelled")
  error.name = "AbortError"
  throw error
}

function waitCancellationError(): Error {
  const error = new Error("Subagent wait was cancelled")
  error.name = "AbortError"
  return error
}

function isWorkingLifecycle(lifecycle: ChildLifecycleState["type"]): boolean {
  return lifecycle === "queued" || lifecycle === "running" || lifecycle === "interrupting"
}

function isPeerLifecycle(lifecycle: ChildLifecycleState["type"]): lifecycle is PeerAgent["lifecycle"] {
  return lifecycle === "idle" || lifecycle === "queued" || lifecycle === "running" || lifecycle === "interrupting"
}

async function settleWithin(operation: Promise<void>, timeoutMs: number): Promise<void> {
  let timeout: ReturnType<typeof setTimeout> | undefined
  await Promise.race([
    operation,
    new Promise<void>(resolve => {
      timeout = setTimeout(resolve, timeoutMs)
    })
  ])
  if (timeout) clearTimeout(timeout)
}
