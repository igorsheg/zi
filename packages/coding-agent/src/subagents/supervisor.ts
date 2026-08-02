import { isAbsolute } from "node:path"

import type { ThinkingLevel } from "@earendil-works/pi-agent-core"

import type { ProcessTreeTracker } from "../processes/process-tree.js"
import type { SessionEntry, SessionManager, SubagentEntry, SubagentEntryInput } from "../session-manager.js"
import { ChildZiProcess, clipUtf8, type ChildSnapshot, type SubagentCompletion } from "./child-process.js"
import { internalSubagentApiKeyEnvironment } from "./invocation.js"
import { defaultWaitTimeoutMs, isSubagentWaitTimeout, maxWaitTimeoutMs } from "./wait-policy.js"

export { defaultWaitTimeoutMs, maxWaitTimeoutMs } from "./wait-policy.js"

export const maxLiveChildren = 4
export const maxRetainedSubagents = 32
export const maxSubagentReadyResults = 32
export const maxMailboxCompletions = maxSubagentReadyResults
export const maxWaitNames = 16
export const maxSubagentPromptBytes = 8 * 1024 * 1024
export const maxSubagentNameBytes = 64
export const durablePreviewBytes = 8 * 1024
export const subagentShutdownMs = 9_000

export type SupervisorState = { readonly type: "open" } | { readonly type: "stopping" } | { readonly type: "closed" }

export type CompletionDelivery =
  | { readonly type: "pending"; readonly completion: SubagentCompletion }
  | { readonly type: "durable"; readonly completion: SubagentCompletion; readonly entryId: string }
  | { readonly type: "delivered"; readonly completion: SubagentCompletion; readonly entryId: string }

export interface SubagentSnapshot {
  readonly name: string
  readonly lifecycle: ChildSnapshot["lifecycle"]
  readonly workCycle?: number
  readonly capturedWorkCycle?: number
  readonly sessionId?: string
  readonly completion?: SubagentCompletion
  readonly completionDelivery?: CompletionDelivery["type"]
}

export interface SubagentStatus {
  readonly workingNames: readonly string[]
  readonly readyNames: readonly string[]
}

export interface SubagentCapacity {
  readonly live: number
  readonly maximum: number
}

interface LiveRecord {
  readonly child: ChildZiProcess
  readonly serial: PromiseQueue
  readonly createdAt: number
  lastWorkCycle: number
}

interface ExitedRecord {
  readonly snapshot: ChildSnapshot
  readonly exitedAt: number
}

export interface SubagentSpawnSelection {
  readonly model?: string
  readonly thinkingLevel?: ThinkingLevel
}

export interface SubagentSupervisorOptions {
  readonly command: readonly string[]
  readonly cwd: string
  readonly env: Readonly<Record<string, string | undefined>>
  readonly selection: () => { readonly model: string; readonly thinkingLevel: ThinkingLevel; readonly apiKey?: string }
  readonly sessionManager: SessionManager
  readonly processTreeTracker: ProcessTreeTracker
  readonly waitTimeoutMs?: number
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
  readonly #listeners = new Set<(event: SubagentSupervisorEvent) => void>()
  readonly #names = new Set<string>()
  readonly #live = new Map<string, LiveRecord>()
  readonly #exited: ExitedRecord[] = []
  readonly #mailbox = new Map<string, CompletionDelivery>()
  readonly #completionReservations = new Set<string>()
  readonly #waiters = new Set<() => void>()
  readonly waitTimeoutMs: number
  #state: SupervisorState = { type: "open" }
  #shutdown: Promise<void> | undefined

  constructor(options: SubagentSupervisorOptions) {
    this.#command = validateCommand(options.command)
    if (!isAbsolute(options.cwd)) throw new Error("Subagent cwd must be absolute")
    this.#cwd = options.cwd
    this.#env = validateEnvironment(options.env)
    this.#selection = options.selection
    this.#sessionManager = options.sessionManager
    this.#processTreeTracker = options.processTreeTracker
    this.waitTimeoutMs = options.waitTimeoutMs ?? defaultWaitTimeoutMs
    if (!isSubagentWaitTimeout(this.waitTimeoutMs)) throw new Error("Invalid subagent wait timeout")
    this.#recover()
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
      ...[...this.#live.values()].map(record => this.#snapshot(record.child.snapshot())),
      ...this.#exited.map(record => this.#snapshot(record.snapshot))
    ])
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
    const readyNames = [
      ...new Set(
        [...this.#mailbox.values()]
          .filter(delivery => delivery.type === "durable")
          .map(delivery => delivery.completion.name)
      )
    ]
    return Object.freeze({ workingNames: Object.freeze(workingNames), readyNames: Object.freeze(readyNames) })
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
    const selection = {
      model: requestedSelection.model ?? inheritedSelection.model,
      thinkingLevel: requestedSelection.thinkingLevel ?? inheritedSelection.thinkingLevel,
      ...(requestedSelection.model === undefined || requestedSelection.model === inheritedSelection.model
        ? { apiKey: inheritedSelection.apiKey }
        : {})
    }
    validateText(selection.model, "Subagent model", 4_096)
    if (selection.apiKey) validateText(selection.apiKey, "Subagent API key", 64 * 1024)
    const reservationKey = this.#reserveCompletion(name, 1)
    try {
      this.#append({ event: "starting", name })
    } catch (cause) {
      this.#completionReservations.delete(reservationKey)
      throw cause
    }
    this.#names.add(name)

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
      selection.thinkingLevel
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
        onStateChange: () => this.#childChanged(name),
        onCompletion: completion => this.#completion(completion)
      })
    } catch (cause) {
      this.#completionReservations.delete(reservationKey)
      const message = cause instanceof Error ? cause.message : String(cause)
      const snapshot = Object.freeze({ name, lifecycle: "exited" as const })
      this.#retainExited({ snapshot, exitedAt: Date.now() })
      try {
        this.#append({ event: "exited", name, outcome: clipUtf8(message, durablePreviewBytes).text })
      } finally {
        this.#changed(name)
      }
      throw cause
    }
    const record: LiveRecord = { child, serial: new PromiseQueue(), createdAt: Date.now(), lastWorkCycle: 0 }
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
      if (!this.#mailbox.has(reservationKey)) this.#completionReservations.delete(reservationKey)
      throw cause
    }
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
      const reservationKey = startedTurn ? this.#reserveCompletion(name, nextCycle) : undefined
      try {
        if (reservationKey) this.#appendWorkCycleStarted(record, name, nextCycle)
        await record.child.continueWith(text)
      } catch (cause) {
        if (reservationKey) this.#completionReservations.delete(reservationKey)
        throw cause
      }
      return startedTurn ? "started_turn" : "follow_up"
    })
    this.#pumpMailbox()
    return delivery
  }

  async interrupt(name: string): Promise<"interrupted" | "already_idle"> {
    this.#assertOpen()
    validateSubagentName(name)
    const record = this.#requireLive(name)
    return record.serial.run(() => record.child.interrupt())
  }

  async close(name: string, reason = "close", graceMs?: number, forceMs?: number): Promise<SubagentSnapshot> {
    validateSubagentName(name)
    const record = this.#live.get(name)
    if (!record) return this.#snapshotFor(name)
    this.#append({ event: "closing", name, reason })
    await record.child.close(reason, graceMs, forceMs)
    this.#retainExit(name, record)
    return this.#snapshotFor(name)
  }

  async wait(
    names: readonly string[],
    timeoutMs = this.waitTimeoutMs,
    signal?: AbortSignal
  ): Promise<SubagentSnapshot[]> {
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
    const targets = names.map(name => ({
      name,
      workCycle: this.#currentWorkCycle(name),
      admittedSnapshot: this.#childSnapshotFor(name)
    }))
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
    const snapshots: SubagentSnapshot[] = []
    const deliveredTargets: Array<{ readonly name: string; readonly workCycle: number }> = []
    for (const target of targets) {
      const snapshot = this.#waitSnapshotFor(target.name, target.workCycle, target.admittedSnapshot)
      snapshots.push(snapshot)
      if (snapshot.completion) deliveredTargets.push({ name: target.name, workCycle: target.workCycle })
    }
    for (const target of deliveredTargets) this.#markDeliveredThrough(target.name, target.workCycle)
    return snapshots
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
      this.#notifyWaiters()
      this.#listeners.clear()
      return undefined
    })
    return this.#shutdown
  }

  async #closeImmediately(name: string, reason: string, graceMs: number, forceMs: number): Promise<void> {
    const record = this.#live.get(name)
    if (!record) return
    this.#append({ event: "closing", name, reason })
    await record.child.close(reason, graceMs, forceMs)
    this.#retainExit(name, record)
  }

  #completion(completion: SubagentCompletion): void {
    const key = completionKey(completion.name, completion.workCycle)
    this.#completionReservations.delete(key)
    const current = this.#mailbox.get(key)
    if (current && current.completion.workCycle > completion.workCycle) return
    this.#mailbox.set(key, { type: "pending", completion })
    this.#pumpMailbox()
  }

  #pumpMailbox(): void {
    const changed = new Set<string>()
    for (const [key, delivery] of this.#mailbox) {
      if (delivery.type !== "pending") continue
      const completion = delivery.completion
      const preview = clipUtf8(completion.text, durablePreviewBytes)
      try {
        const entry = this.#append({
          event: "work_cycle_finished",
          name: completion.name,
          workCycle: completion.workCycle,
          status: completion.status,
          preview: preview.text,
          originalBytes: completion.originalBytes,
          omittedBytes: completion.omittedBytes + preview.omittedBytes,
          truncated: completion.truncated || preview.omittedBytes > 0,
          durationMs: completion.durationMs,
          ...(completion.reason ? { reason: completion.reason } : {}),
          ...(completion.error ? { error: completion.error } : {})
        })
        this.#mailbox.set(key, { type: "durable", completion, entryId: entry.id })
        changed.add(completion.name)
      } catch {
        break
      }
    }
    this.#evictMailbox()
    for (const name of changed) this.#changed(name)
    this.#notifyWaiters()
  }

  #recover(): void {
    const latest = new Map<string, SubagentEntry>()
    for (const entry of this.#sessionManager.subagentEntries()) {
      latest.delete(entry.name)
      latest.set(entry.name, entry)
      while (latest.size > maxRetainedSubagents) {
        const oldest = latest.keys().next().value
        if (oldest === undefined) break
        latest.delete(oldest)
      }
      if (entry.event === "starting") {
        if (this.#names.has(entry.name)) throw new Error(`Duplicate subagent name in session journal: ${entry.name}`)
        this.#names.add(entry.name)
      }
      if (entry.event === "work_cycle_finished") {
        const completion: SubagentCompletion = {
          name: entry.name,
          workCycle: entry.workCycle,
          status: entry.status,
          text: entry.preview,
          originalBytes: entry.originalBytes,
          omittedBytes: entry.omittedBytes,
          truncated: entry.truncated,
          durationMs: entry.durationMs,
          ...(entry.reason ? { reason: entry.reason } : {}),
          ...(entry.error ? { error: entry.error } : {})
        }
        this.#mailbox.set(completionKey(entry.name, entry.workCycle), {
          type: "durable",
          completion,
          entryId: entry.id
        })
        this.#evictMailbox()
      }
    }
    for (const [name, entry] of latest) {
      if (entry.event !== "exited" && entry.event !== "lost") {
        this.#append({ event: "lost", name, reason: "session_restored" })
      }
      this.#retainExited({ snapshot: { name, lifecycle: "exited" }, exitedAt: Date.parse(entry.timestamp) })
    }
    this.#evictMailbox()
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
              reason: state.outcome.type === "killed" ? "child_killed" : "child_failed",
              error: clipUtf8(state.outcome.message, durablePreviewBytes).text
            }
          : { reason: "child_exited" }
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
    const outcome = state.type === "exited" ? JSON.stringify(state.outcome) : snapshot.lifecycle
    this.#append({ event: "exited", name, outcome: clipUtf8(outcome, durablePreviewBytes).text })
    this.#retainExited({ snapshot, exitedAt: Date.now() })
    this.#changed(name)
  }

  #retainExited(record: ExitedRecord): void {
    const existing = this.#exited.findIndex(value => value.snapshot.name === record.snapshot.name)
    if (existing >= 0) this.#exited.splice(existing, 1)
    this.#exited.push(record)
    while (this.#exited.length > maxRetainedSubagents) this.#exited.shift()
  }

  #snapshot(snapshot: ChildSnapshot): SubagentSnapshot {
    const delivery = this.#latestDelivery(snapshot.name)
    return Object.freeze({
      name: snapshot.name,
      lifecycle: snapshot.lifecycle,
      ...(snapshot.workCycle !== undefined ? { workCycle: snapshot.workCycle } : {}),
      ...(snapshot.sessionId ? { sessionId: snapshot.sessionId } : {}),
      ...(delivery?.type === "durable" || delivery?.type === "delivered" ? { completion: delivery.completion } : {}),
      ...(delivery ? { completionDelivery: delivery.type } : {})
    })
  }

  #snapshotFor(name: string): SubagentSnapshot {
    return this.#snapshot(this.#childSnapshotFor(name))
  }

  #waitSnapshotFor(name: string, workCycle: number, admittedSnapshot: ChildSnapshot): SubagentSnapshot {
    const live = this.#live.get(name)
    const retained = this.#exited.find(value => value.snapshot.name === name)
    const snapshot =
      live?.child.snapshot() ??
      retained?.snapshot ??
      Object.freeze({ ...admittedSnapshot, lifecycle: "exited" as const })
    const delivery = this.#delivery(name, workCycle)
    return Object.freeze({
      name,
      lifecycle: snapshot.lifecycle,
      ...(snapshot.workCycle !== undefined ? { workCycle: snapshot.workCycle } : {}),
      capturedWorkCycle: workCycle,
      ...(snapshot.sessionId ? { sessionId: snapshot.sessionId } : {}),
      ...(delivery?.type === "durable" || delivery?.type === "delivered" ? { completion: delivery.completion } : {}),
      ...(delivery ? { completionDelivery: delivery.type } : {})
    })
  }

  #childSnapshotFor(name: string): ChildSnapshot {
    const live = this.#live.get(name)
    if (live) return live.child.snapshot()
    const exited = this.#exited.find(value => value.snapshot.name === name)
    if (!exited) throw new Error(`Unknown subagent: ${name}`)
    return exited.snapshot
  }

  #delivery(name: string, workCycle: number): CompletionDelivery | undefined {
    return this.#mailbox.get(completionKey(name, workCycle))
  }

  #latestDelivery(name: string): CompletionDelivery | undefined {
    let latest: CompletionDelivery | undefined
    for (const delivery of this.#mailbox.values()) {
      if (delivery.completion.name !== name) continue
      if (!latest || delivery.completion.workCycle > latest.completion.workCycle) latest = delivery
    }
    return latest
  }

  #waitTargetSettled(name: string, workCycle: number): boolean {
    const delivery = this.#delivery(name, workCycle)
    if (delivery?.type === "durable" || delivery?.type === "delivered") return true
    return workCycle === 0 && !this.#live.has(name)
  }

  #currentWorkCycle(name: string): number {
    const live = this.#live.get(name)
    if (live) return live.child.snapshot().workCycle ?? live.lastWorkCycle
    return this.#latestDelivery(name)?.completion.workCycle ?? 0
  }

  #markDeliveredThrough(name: string, workCycle: number): void {
    let changed = false
    for (const [key, delivery] of this.#mailbox) {
      if (
        delivery.completion.name === name &&
        delivery.completion.workCycle <= workCycle &&
        delivery.type === "durable"
      ) {
        this.#mailbox.set(key, { ...delivery, type: "delivered" })
        changed = true
      }
    }
    if (changed) this.#changed(name)
  }

  #ensureCompletionCapacity(): void {
    while (this.#mailbox.size + this.#completionReservations.size >= maxMailboxCompletions) {
      const delivered = [...this.#mailbox.entries()].find(([, value]) => value.type === "delivered")
      if (!delivered) break
      this.#mailbox.delete(delivered[0])
    }
    if (this.#mailbox.size + this.#completionReservations.size >= maxMailboxCompletions) {
      throw new Error("Subagent completion capacity exceeded: undelivered completions fill the mailbox")
    }
  }

  #reserveCompletion(name: string, workCycle: number): string {
    this.#ensureCompletionCapacity()
    const key = completionKey(name, workCycle)
    this.#completionReservations.add(key)
    return key
  }

  #evictMailbox(): void {
    while (this.#mailbox.size > maxMailboxCompletions) {
      const entries = [...this.#mailbox.entries()]
      const evicted =
        entries.find(([, value]) => value.type === "delivered") ?? entries.find(([, value]) => value.type === "durable")
      if (!evicted) break
      this.#mailbox.delete(evicted[0])
    }
  }

  #append(data: SubagentEntryInput): SubagentEntry {
    const entry = this.#sessionManager.appendSubagent(data)
    this.#emit({ type: "entry_appended", entry })
    return entry
  }

  #appendWorkCycleStarted(record: LiveRecord, name: string, workCycle: number): void {
    const entry = this.#sessionManager.appendSubagent({ event: "work_cycle_started", name, workCycle })
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

  #changed(name: string): void {
    this.#emit({ type: "changed", name })
    this.#notifyWaiters()
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

function throwIfWaitCancelled(signal?: AbortSignal): void {
  if (!signal?.aborted) return
  const error = new Error("Subagent wait was cancelled")
  error.name = "AbortError"
  throw error
}

function completionKey(name: string, workCycle: number): string {
  return `${name}:${workCycle}`
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
