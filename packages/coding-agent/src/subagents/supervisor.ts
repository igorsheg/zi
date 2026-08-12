import { isAbsolute } from "node:path"

import type { ThinkingLevel } from "@earendil-works/pi-agent-core"

import {
  projectSessionOutcomes,
  subagentWorkCycleOperationId,
  type OperationOutcomeEntryInput
} from "../operation-outcomes.js"
import type { ProcessTreeTracker } from "../processes/process-tree.js"
import type { SessionEntry, SessionManager, SubagentEntry, SubagentEntryInput } from "../session-manager.js"
import type { ToolSurface } from "../tool-surface.js"
import {
  ChildZiProcess,
  clipUtf8,
  type ChildSessionEventsSnapshot,
  type ChildSnapshot,
  type ChildTranscriptSnapshot,
  type SubagentCompletion
} from "./child-process.js"
import { CompletionLedger, maxCompletionLedgerEntries, type CompletionDelivery } from "./completion-ledger.js"
import { internalSubagentApiKeyEnvironment } from "./invocation.js"
import type { PeerAgent, PeerRequest, PeerResult } from "./peer-protocol.js"
import { defaultWaitTimeoutMs, isSubagentWaitTimeout, maxWaitTimeoutMs } from "./wait-policy.js"
import { defaultSubagentWorkTimeoutMs, isSubagentWorkTimeout } from "./work-policy.js"

export type { CompletionDelivery } from "./completion-ledger.js"
export { defaultWaitTimeoutMs, maxWaitTimeoutMs } from "./wait-policy.js"
export { defaultSubagentWorkTimeoutMs, maxSubagentWorkTimeoutMs } from "./work-policy.js"

export const maxLiveChildren = 4
export const maxRetainedSubagents = 32
export const maxSubagentReadyResults = maxCompletionLedgerEntries
export const maxMailboxCompletions = maxSubagentReadyResults
export const maxWaitNames = 16
export const maxSubagentPromptBytes = 8 * 1024 * 1024
export const maxSubagentNameBytes = 64
export const maxSubagentTaskBytes = 256
export const durablePreviewBytes = 8 * 1024
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

export type SubagentSessionEvents = ChildSessionEventsSnapshot
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
  readonly child: ChildZiProcess
  readonly serial: PromiseQueue
  readonly createdAt: number
  lastWorkCycle: number
  task: string
  closing?: Promise<void>
}

interface ExitedRecord {
  readonly snapshot: ChildSnapshot
  readonly sessionEvents?: SubagentSessionEvents
  readonly transcript?: SubagentTranscriptSnapshot
  readonly exitedAt: number
  readonly task?: string
}

interface WaitTarget {
  readonly name: string
  readonly workCycle: number
  readonly admittedSnapshot: ChildSnapshot
  readonly admittedDelivery: CompletionDelivery["type"] | undefined
}

export interface SubagentSpawnSelection {
  readonly profile?: string
  readonly model?: string
  readonly thinkingLevel?: ThinkingLevel
  readonly listedTask?: string
}

export interface SubagentSupervisorOptions {
  readonly command: readonly string[]
  readonly cwd: string
  readonly env: Readonly<Record<string, string | undefined>>
  readonly selection: () => { readonly model: string; readonly thinkingLevel: ThinkingLevel; readonly apiKey?: string }
  readonly sessionManager: SessionManager
  readonly processTreeTracker: ProcessTreeTracker
  readonly waitTimeoutMs?: number
  readonly workTimeoutMs?: number
  readonly toolSurface?: ToolSurface
}

export type SubagentSupervisorEvent =
  | { readonly type: "changed"; readonly name: string }
  | { readonly type: "entry_appended"; readonly entry: SessionEntry }

export class SubagentSupervisor {
  readonly #command: readonly string[]
  readonly #cwd: string
  readonly #env: Readonly<Record<string, string | undefined>>
  readonly #selection: () => { readonly model: string; readonly thinkingLevel: ThinkingLevel; readonly apiKey?: string }
  readonly #sessionManager: SessionManager
  readonly #processTreeTracker: ProcessTreeTracker
  readonly #toolSurface: ToolSurface
  readonly #listeners = new Set<(event: SubagentSupervisorEvent) => void>()
  readonly #names = new Set<string>()
  readonly #profiles = new Map<string, string>()
  readonly #live = new Map<string, LiveRecord>()
  readonly #exited: ExitedRecord[] = []
  readonly #ledger: CompletionLedger
  readonly #waiters = new Set<() => void>()
  readonly waitTimeoutMs: number
  readonly workTimeoutMs: number
  #state: SupervisorState = { type: "open" }
  #shutdown: Promise<void> | undefined

  constructor(options: SubagentSupervisorOptions) {
    this.#command = validateCommand(options.command)
    if (!isAbsolute(options.cwd)) throw new Error("Subagent cwd must be absolute")
    this.#cwd = options.cwd
    this.#env = validateEnvironment(options.env)
    this.#selection = options.selection
    this.#sessionManager = options.sessionManager
    const outcomes = projectSessionOutcomes(this.#sessionManager.entries()).filter(
      outcome => outcome.capability === "subagent"
    )
    this.#ledger = CompletionLedger.restore(outcomes, this.#sessionManager.subagentEntries(), maxMailboxCompletions)
    for (const outcome of outcomes) {
      if (outcome.profile) this.#profiles.set(outcome.name, outcome.profile)
    }
    this.#processTreeTracker = options.processTreeTracker
    this.#toolSurface = options.toolSurface ?? "direct-and-code"
    this.waitTimeoutMs = options.waitTimeoutMs ?? defaultWaitTimeoutMs
    if (!isSubagentWaitTimeout(this.waitTimeoutMs)) throw new Error("Invalid subagent wait timeout")
    this.workTimeoutMs = options.workTimeoutMs ?? defaultSubagentWorkTimeoutMs
    if (!isSubagentWorkTimeout(this.workTimeoutMs)) throw new Error("Invalid subagent work timeout")
    this.#recover()
    this.#assertInvariants()
  }

  get state(): SupervisorState {
    return this.#state
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

  sessionEvents(name: string): SubagentSessionEvents | undefined {
    validateSubagentName(name)
    const live = this.#live.get(name)
    if (live) return live.child.sessionEvents()
    return this.#exited.find(record => record.snapshot.name === name)?.sessionEvents
  }

  transcript(name: string): SubagentTranscriptSnapshot | undefined {
    validateSubagentName(name)
    const live = this.#live.get(name)
    if (live) return live.child.transcript()
    return this.#exited.find(record => record.snapshot.name === name)?.transcript
  }

  capacity(): SubagentCapacity {
    return Object.freeze({ live: this.#live.size, maximum: maxLiveChildren })
  }

  runningCount(): number {
    let count = 0
    for (const record of this.#live.values()) {
      if (record.child.state.type !== "idle" && record.child.state.type !== "exited") count++
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
      // Parent evidence is already durable; restoration can infer delivery from that evidence.
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
    if (this.#live.size >= maxLiveChildren) {
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
    try {
      this.#append({ event: "starting", name })
    } catch (cause) {
      this.#ledger.cancelReservation(name, 1)
      throw cause
    }
    this.#names.add(name)
    if (requestedSelection.profile) this.#profiles.set(name, requestedSelection.profile)

    const command = [
      ...this.#command,
      "--mode",
      "rpc",
      "--no-session",
      "--cwd",
      this.#cwd,
      "--model",
      selection.model,
      "--thinking",
      selection.thinkingLevel,
      ...(this.#toolSurface === "code-only" ? ["--code-only"] : [])
    ]
    const environment = selection.apiKey
      ? Object.freeze({ ...this.#env, [internalSubagentApiKeyEnvironment]: selection.apiKey })
      : this.#env
    let child: ChildZiProcess
    try {
      child = new ChildZiProcess({
        name,
        command,
        cwd: this.#cwd,
        env: environment,
        processTreeTracker: this.#processTreeTracker,
        workTimeoutMs: this.workTimeoutMs,
        onStateChange: () => this.#childChanged(name),
        onCompletion: completion => this.#completion(completion),
        onSessionEvent: () => this.#presentationChanged(name),
        onPeerRequest: request => this.#routePeerRequest(name, request)
      })
    } catch (cause) {
      this.#ledger.cancelReservation(name, 1)
      const message = cause instanceof Error ? cause.message : String(cause)
      const snapshot = Object.freeze({ name, lifecycle: "exited" as const })
      this.#retainExited({ snapshot, exitedAt: Date.now(), task })
      try {
        this.#append({ event: "exited", name, outcome: clipUtf8(message, durablePreviewBytes).text })
      } finally {
        this.#changed(name)
      }
      throw cause
    }
    const record: LiveRecord = { child, serial: new PromiseQueue(), createdAt: Date.now(), lastWorkCycle: 0, task }
    this.#live.set(name, record)
    this.#changed(name)

    const abort = (): void => {
      void this.close(name, "startup_cancelled").catch(() => {})
    }
    if (signal?.aborted) {
      abort()
      throw new Error(`Subagent ${name} spawn was cancelled`)
    }
    signal?.addEventListener("abort", abort, { once: true })
    try {
      await child.start()
      this.#assertSpawnAdmission(name, record, signal)
      const sessionId = child.snapshot().sessionId
      this.#append({ event: "ready", name, ...(sessionId ? { sessionId } : {}) })
      this.#appendWorkCycleStarted(record, name, 1)
      await child.spawnAdmit(prompt)
      this.#assertSpawnAdmission(name, record, signal)
      signal?.removeEventListener("abort", abort)
      this.#assertInvariants()
      return name
    } catch (cause) {
      signal?.removeEventListener("abort", abort)
      if (
        this.#state.type === "open" &&
        !signal?.aborted &&
        this.#live.get(name) === record &&
        record.child.state.type !== "closing" &&
        record.child.state.type !== "exited"
      ) {
        await this.close(name, "startup_failed").catch(() => {})
      }
      if (record.lastWorkCycle === 0) this.#ledger.cancelReservation(name, 1)
      throw cause
    }
  }

  // Behavioral provenance: Codex 0bdce9f4 derives the sender from the active session and lets the
  // shared control owner route queue-only mail. Zi keeps that invariant in the parent supervisor.
  async #routePeerRequest(sender: string, request: PeerRequest): Promise<PeerResult> {
    this.#assertOpen()
    if (!this.#live.has(sender)) throw new Error(`Unknown peer sender: ${sender}`)
    if (request.operation === "list") {
      const peers: PeerAgent[] = []
      for (const [name, record] of this.#live) {
        if (name === sender) continue
        const lifecycle = record.child.state.type
        if (lifecycle === "closing" || lifecycle === "exited") continue
        peers.push(Object.freeze({ name, lifecycle }))
      }
      return Object.freeze({ peers: Object.freeze(peers) })
    }
    if (request.target === sender) throw new Error("A subagent cannot send a peer message to itself")
    const target = this.#requireLive(request.target)
    const message = `[Peer message from ${sender}]\n${request.text}`
    await target.serial.run(() => target.child.sendFollowUp(message))
    this.#pumpMailbox()
    return Object.freeze({ delivered: true })
  }

  async send(name: string, text: string): Promise<void> {
    this.#assertOpen()
    validateSubagentName(name)
    validateText(text, "Subagent message", maxSubagentPromptBytes)
    const record = this.#requireLive(name)
    await record.serial.run(() => record.child.sendFollowUp(text))
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
        await record.child.continueWith(text)
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
    return record.serial.run(() => record.child.interrupt())
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

  async close(name: string, reason = "close", graceMs?: number, forceMs?: number): Promise<SubagentSnapshot> {
    validateSubagentName(name)
    const record = this.#live.get(name)
    if (!record) return this.#snapshotFor(name)
    await this.#closeRecord(name, record, reason, graceMs, forceMs)
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
          this.#settleDelivery(
            target.name,
            target.workCycle,
            target.admittedSnapshot,
            target.admittedDelivery,
            "claim",
            false,
            claimId
          )
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
      this.#settleDelivery(
        target.name,
        target.workCycle,
        target.admittedSnapshot,
        target.admittedDelivery,
        deliveryMode,
        false,
        claimId
      )
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
      return {
        name,
        workCycle,
        admittedSnapshot: this.#childSnapshotFor(name),
        admittedDelivery: this.#delivery(name, workCycle)?.type
      }
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
      const admittedDelivery = this.#delivery(name, workCycle)?.type
      const result = await record.child.interrupt()
      throwIfWaitCancelled(signal)
      if (result === "already_idle") {
        return {
          result,
          snapshot: this.#settleDelivery(
            name,
            workCycle,
            admittedSnapshot,
            admittedDelivery,
            deliveryMode,
            true,
            claimId
          )
        }
      }
      const snapshot = await this.#waitForWorkCycle(
        name,
        workCycle,
        admittedSnapshot,
        admittedDelivery,
        deliveryMode,
        signal,
        claimId
      )
      return { result, snapshot }
    })
    return raceWithWaitCancellation(settlement, signal)
  }

  async #closeAndDeliver(name: string, deliveryMode: "consume" | "claim", claimId?: string): Promise<SubagentSnapshot> {
    validateSubagentName(name)
    this.#requireKnown(name)
    const admittedSnapshot = this.#childSnapshotFor(name)
    const workCycle = this.#currentWorkCycle(name)
    const admittedDelivery = this.#delivery(name, workCycle)?.type
    await this.close(name)
    return this.#settleDelivery(name, workCycle, admittedSnapshot, admittedDelivery, deliveryMode, true, claimId)
  }

  shutdown(): Promise<void> {
    if (this.#shutdown) return this.#shutdown
    if (this.#state.type === "closed") return Promise.resolve()
    this.#state = { type: "stopping" }
    const closeAll = Promise.all(
      [...this.#live.keys()].map(name => this.#closeImmediately(name, "session_disposed", 3_500, 3_500).catch(() => {}))
    )
    this.#shutdown = settleWithin(
      closeAll.then(() => undefined),
      subagentShutdownMs
    ).then(() => {
      this.#state = { type: "closed" }
      this.#assertInvariants()
      this.#notifyWaiters()
      this.#listeners.clear()
      return undefined
    })
    return this.#shutdown
  }

  async #closeImmediately(name: string, reason: string, graceMs: number, forceMs: number): Promise<void> {
    const record = this.#live.get(name)
    if (!record) return
    await this.#closeRecord(name, record, reason, graceMs, forceMs)
  }

  #closeRecord(name: string, record: LiveRecord, reason: string, graceMs?: number, forceMs?: number): Promise<void> {
    if (record.closing) return record.closing
    const closing = (async (): Promise<void> => {
      try {
        this.#append({ event: "closing", name, reason })
      } catch {
        // Process cleanup and in-memory terminal evidence must survive journal failure.
      }
      try {
        await record.child.close(reason, graceMs, forceMs)
      } finally {
        this.#retainExit(name, record)
      }
    })()
    record.closing = closing
    return closing
  }

  #completion(completion: SubagentCompletion): void {
    const retained = retainCompletion(completion)
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
        const entry = this.#sessionManager.appendOperationOutcome(
          subagentOutcome(completion, this.#profiles.get(completion.name), preview)
        )
        this.#ledger.commitPersistence(completion.name, completion.workCycle, entry.id)
        changed.add(completion.name)
        this.#emit({ type: "entry_appended", entry })
      } catch {
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
    this.#changed(name)
  }

  #retainExit(name: string, record: LiveRecord): void {
    if (this.#live.get(name) !== record) return
    this.#live.delete(name)
    const state = record.child.state
    if (record.lastWorkCycle > 0 && !this.#delivery(name, record.lastWorkCycle)) {
      const failure =
        state.type === "exited" && state.outcome.type !== "closed"
          ? {
              reason: state.outcome.type === "killed" ? ("child_killed" as const) : ("child_failed" as const),
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
      sessionEvents: record.child.sessionEvents(),
      transcript: record.child.transcript(),
      exitedAt: Date.now(),
      task: record.task
    })
    try {
      const outcome = state.type === "exited" ? JSON.stringify(state.outcome) : snapshot.lifecycle
      this.#append({ event: "exited", name, outcome: clipUtf8(outcome, durablePreviewBytes).text })
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
        ...(record.sessionEvents ? { sessionEvents: record.sessionEvents } : {}),
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
    admittedDelivery: CompletionDelivery["type"] | undefined,
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
    return this.#settleDelivery(name, workCycle, admittedSnapshot, admittedDelivery, deliveryMode, true, claimId)
  }

  #settleDelivery(
    name: string,
    workCycle: number,
    admittedSnapshot: ChildSnapshot,
    admittedDelivery: CompletionDelivery["type"] | undefined,
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
    if (delivery?.type === "delivered" && !requireTerminalEvidence && admittedDelivery !== "delivered") {
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
    this.#emit({ type: "entry_appended", entry })
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
    if (this.#live.size > maxLiveChildren || this.#exited.length > maxRetainedSubagents) {
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
    for (const name of retained) {
      if (!this.#names.has(name))
        throw new Error("Subagent supervisor invariant violated: retained subagent is unnamed")
    }
    for (const completion of this.#ledger.identities()) {
      if (!this.#names.has(completion.name)) {
        throw new Error("Subagent supervisor invariant violated: completion belongs to an unknown subagent")
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

function validateCommand(command: readonly string[]): readonly string[] {
  if (
    command.length === 0 ||
    command.length > 16 ||
    !isAbsolute(command[0]!) ||
    command.some(part => part.length === 0 || part.includes("\0") || Buffer.byteLength(part) > 4096)
  ) {
    throw new Error("Subagent commands require an absolute executable and at most 15 bounded prefix arguments")
  }
  return Object.freeze([...command])
}

function validateEnvironment(
  environment: Readonly<Record<string, string | undefined>>
): Readonly<Record<string, string | undefined>> {
  const entries = Object.entries(environment)
  if (entries.length > 4096) throw new Error("Subagent environment cannot exceed 4096 entries")
  for (const [name, value] of entries) {
    if (
      name.length === 0 ||
      name.includes("\0") ||
      Buffer.byteLength(name) > 4096 ||
      (value !== undefined && (value.includes("\0") || Buffer.byteLength(value) > 64 * 1024))
    ) {
      throw new Error("Subagent environment contains an invalid entry")
    }
  }
  return Object.freeze(Object.fromEntries(entries))
}

function retainCompletion(completion: SubagentCompletion): SubagentCompletion {
  if (completion.status !== "failed") return Object.freeze({ ...completion })
  return Object.freeze({
    ...completion,
    ...(completion.error ? { error: clipUtf8(completion.error, durablePreviewBytes).text } : {})
  })
}

function subagentOutcome(
  completion: SubagentCompletion,
  profile: string | undefined,
  preview: ReturnType<typeof clipUtf8>
): OperationOutcomeEntryInput {
  const common = {
    capability: "subagent" as const,
    operation: "work_cycle" as const,
    operationId: subagentWorkCycleOperationId(completion.name, completion.workCycle),
    name: completion.name,
    workCycle: completion.workCycle,
    ...(profile ? { profile } : {}),
    preview: preview.text,
    originalBytes: completion.originalBytes,
    omittedBytes: completion.omittedBytes + preview.omittedBytes,
    truncated: completion.truncated || preview.omittedBytes > 0,
    durationMs: completion.durationMs
  }
  if (completion.status === "failed") {
    if (completion.reason === "legacy_failure") throw new Error("Cannot append a projected legacy outcome")
    return {
      ...common,
      result: "failed",
      errorCode: completion.reason,
      ...(completion.error ? { errorMessage: completion.error } : {})
    }
  }
  return { ...common, result: completion.status === "completed" ? "succeeded" : "cancelled" }
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

function waitCancellationError(): Error {
  const error = new Error("Subagent wait was cancelled")
  error.name = "AbortError"
  return error
}

function isWorkingLifecycle(lifecycle: ChildSnapshot["lifecycle"]): boolean {
  return (
    lifecycle === "starting" ||
    lifecycle === "spawn_admitting" ||
    lifecycle === "running" ||
    lifecycle === "interrupting"
  )
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
