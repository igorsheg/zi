import { isAbsolute } from "node:path"

import type { ThinkingLevel } from "@earendil-works/pi-agent-core"

import type { SessionEntry, SessionManager, SubagentEntry, SubagentEntryInput } from "../session-manager.js"
import { ChildZiProcess, clipUtf8, type ChildSnapshot, type SubagentCompletion } from "./child-process.js"
import { generalSubagentType, type RegisteredSubagentType, type SubagentTypeDefinition } from "./definitions.js"

export const maxLiveChildren = 4
export const maxRetainedSubagents = 32
export const maxMailboxCompletions = 32
export const maxWaitIds = 16
export const maxWaitTimeoutMs = 25_000
export const defaultWaitTimeoutMs = 10_000
export const maxSubagentPromptBytes = 8 * 1024 * 1024
export const maxSubagentAgentIdBytes = 256
export const durablePreviewBytes = 8 * 1024
export const subagentShutdownMs = 9_000

export type SupervisorState = { readonly type: "open" } | { readonly type: "stopping" } | { readonly type: "closed" }

export type CompletionDelivery =
  | { readonly type: "pending"; readonly completion: SubagentCompletion }
  | { readonly type: "durable"; readonly completion: SubagentCompletion; readonly entryId: string }
  | { readonly type: "delivered"; readonly completion: SubagentCompletion; readonly entryId: string }

export interface SubagentSnapshot {
  readonly agentId: string
  readonly lifecycle: ChildSnapshot["lifecycle"]
  readonly definition: SubagentTypeDefinition
  readonly workCycle?: number
  readonly sessionId?: string
  readonly completion?: SubagentCompletion
  readonly completionDelivery?: CompletionDelivery["type"]
}

export interface SubagentStatus {
  readonly workingAgentIds: readonly string[]
  readonly readyAgentIds: readonly string[]
}

interface LiveRecord {
  readonly child: ChildZiProcess
  readonly definition: SubagentTypeDefinition
  readonly serial: PromiseQueue
  readonly createdAt: number
  lastWorkCycle: number
}

interface ExitedRecord {
  readonly agentId: string
  readonly definition: SubagentTypeDefinition
  readonly snapshot: ChildSnapshot
  readonly exitedAt: number
}

export interface SubagentSupervisorOptions {
  readonly command: readonly string[]
  readonly cwd: string
  readonly env: Readonly<Record<string, string | undefined>>
  readonly selection: () => { readonly model: string; readonly thinkingLevel: ThinkingLevel; readonly apiKey?: string }
  readonly sessionManager: SessionManager
  readonly extensionTypes?: readonly RegisteredSubagentType[]
}

export type SubagentSupervisorEvent =
  | { readonly type: "changed"; readonly agentId: string }
  | { readonly type: "entry_appended"; readonly entry: SessionEntry }

export class SubagentSupervisor {
  readonly #command: readonly string[]
  readonly #cwd: string
  readonly #env: Readonly<Record<string, string | undefined>>
  readonly #selection: () => { readonly model: string; readonly thinkingLevel: ThinkingLevel; readonly apiKey?: string }
  readonly #sessionManager: SessionManager
  readonly #listeners = new Set<(event: SubagentSupervisorEvent) => void>()
  readonly #live = new Map<string, LiveRecord>()
  readonly #exited: ExitedRecord[] = []
  readonly #mailbox = new Map<string, CompletionDelivery>()
  readonly #completionReservations = new Set<string>()
  readonly #waiters = new Set<() => void>()
  #extensionTypes: readonly RegisteredSubagentType[]
  #state: SupervisorState = { type: "open" }
  #shutdown: Promise<void> | undefined

  constructor(options: SubagentSupervisorOptions) {
    this.#command = validateCommand(options.command)
    if (!isAbsolute(options.cwd)) throw new Error("Subagent cwd must be absolute")
    this.#cwd = options.cwd
    this.#env = validateEnvironment(options.env)
    this.#selection = options.selection
    this.#sessionManager = options.sessionManager
    this.#extensionTypes = Object.freeze([...(options.extensionTypes ?? [])])
    this.#recover()
  }

  get state(): SupervisorState {
    return this.#state
  }

  subscribe(listener: (event: SubagentSupervisorEvent) => void): () => void {
    this.#listeners.add(listener)
    return () => this.#listeners.delete(listener)
  }

  definitions(): readonly SubagentTypeDefinition[] {
    return Object.freeze([generalSubagentType, ...this.#extensionTypes])
  }

  replaceExtensionTypes(types: readonly RegisteredSubagentType[]): void {
    this.#assertOpen()
    this.#extensionTypes = Object.freeze([...types])
  }

  snapshots(): readonly SubagentSnapshot[] {
    return Object.freeze([
      ...[...this.#live.values()].map(record => this.#snapshot(record.child.snapshot(), record.definition)),
      ...this.#exited.map(record => this.#snapshot(record.snapshot, record.definition))
    ])
  }

  runningCount(): number {
    let count = 0
    for (const record of this.#live.values()) {
      if (record.child.state.type !== "idle" && record.child.state.type !== "exited") count++
    }
    return count
  }

  status(): SubagentStatus {
    const workingAgentIds = [...this.#live.values()]
      .filter(record => isWorkingLifecycle(record.child.state.type))
      .map(record => record.child.agentId)
    const readyAgentIds = [
      ...new Set(
        [...this.#mailbox.values()]
          .filter(delivery => delivery.type === "durable")
          .map(delivery => delivery.completion.agentId)
      )
    ]
    return Object.freeze({
      workingAgentIds: Object.freeze(workingAgentIds),
      readyAgentIds: Object.freeze(readyAgentIds)
    })
  }

  completionNotice(): string | undefined {
    const ids = [...this.#mailbox.entries()]
      .filter(([, delivery]) => delivery.type === "durable")
      .map(([key]) => key.slice(0, key.lastIndexOf(":")))
    const unique = [...new Set(ids)].slice(0, maxWaitIds)
    return unique.length === 0
      ? undefined
      : `Subagents completed: ${unique.join(", ")}. Call wait_subagents for their output.`
  }

  async spawn(prompt: string, typeName: string | undefined, signal?: AbortSignal): Promise<string> {
    this.#assertOpen()
    validateText(prompt, "Subagent prompt", maxSubagentPromptBytes)
    if (this.#live.size >= maxLiveChildren) {
      throw new Error(`Subagent capacity exceeded: at most ${maxLiveChildren} live children`)
    }
    const definition = this.#definition(typeName ?? generalSubagentType.name)
    const agentId = crypto.randomUUID()
    const reservationKey = this.#reserveCompletion(agentId, 1)
    this.#append({ event: "starting", agentId, definitionName: definition.name })

    const selection = this.#selection()
    validateText(selection.model, "Subagent model", 4_096)
    if (selection.apiKey) validateText(selection.apiKey, "Subagent API key", 64 * 1024)
    const command = [
      ...this.#command,
      "--mode",
      "rpc",
      "--no-session",
      "--cwd",
      this.#cwd,
      "--model",
      selection.model,
      ...(selection.apiKey ? ["--api-key", selection.apiKey] : []),
      "--thinking",
      selection.thinkingLevel
    ]
    let child: ChildZiProcess
    try {
      child = new ChildZiProcess({
        agentId,
        command,
        cwd: this.#cwd,
        env: this.#env,
        onStateChange: () => this.#childChanged(agentId),
        onCompletion: completion => this.#completion(completion)
      })
    } catch (cause) {
      this.#completionReservations.delete(reservationKey)
      const message = cause instanceof Error ? cause.message : String(cause)
      this.#append({ event: "exited", agentId, outcome: clipUtf8(message, durablePreviewBytes).text })
      throw cause
    }
    const record: LiveRecord = {
      child,
      definition,
      serial: new PromiseQueue(),
      createdAt: Date.now(),
      lastWorkCycle: 0
    }
    this.#live.set(agentId, record)
    this.#changed(agentId)

    const abort = (): void => {
      void this.close(agentId, "startup_cancelled").catch(() => {})
    }
    if (signal?.aborted) {
      abort()
      throw new Error(`Subagent ${agentId} spawn was cancelled`)
    }
    signal?.addEventListener("abort", abort, { once: true })
    try {
      await child.start()
      const sessionId = child.snapshot().sessionId
      this.#append({ event: "ready", agentId, ...(sessionId ? { sessionId } : {}) })
      this.#append({ event: "work_cycle_started", agentId, workCycle: 1 })
      const admittedPrompt = `${definition.instructions}\n\nDelegated task:\n${prompt}`
      await child.spawnAdmit(admittedPrompt)
      signal?.removeEventListener("abort", abort)
      return agentId
    } catch (cause) {
      signal?.removeEventListener("abort", abort)
      await this.close(agentId, "startup_failed").catch(() => {})
      if (!this.#mailbox.has(reservationKey)) this.#completionReservations.delete(reservationKey)
      throw cause
    }
  }

  async send(agentId: string, text: string): Promise<void> {
    this.#assertOpen()
    validateAgentId(agentId)
    validateText(text, "Subagent message", maxSubagentPromptBytes)
    const record = this.#requireLive(agentId)
    await record.serial.run(() => record.child.sendFollowUp(text))
    this.#pumpMailbox()
  }

  async continue(agentId: string, text: string): Promise<void> {
    this.#assertOpen()
    validateAgentId(agentId)
    validateText(text, "Subagent message", maxSubagentPromptBytes)
    const record = this.#requireLive(agentId)
    const snapshot = record.child.snapshot()
    const nextCycle = (snapshot.workCycle ?? 0) + 1
    const reservationKey = snapshot.lifecycle === "idle" ? this.#reserveCompletion(agentId, nextCycle) : undefined
    if (reservationKey) this.#append({ event: "work_cycle_started", agentId, workCycle: nextCycle })
    try {
      await record.serial.run(() => record.child.continueWith(text))
    } catch (cause) {
      if (reservationKey) this.#completionReservations.delete(reservationKey)
      throw cause
    }
    this.#pumpMailbox()
  }

  async interrupt(agentId: string): Promise<"interrupted" | "already_idle"> {
    this.#assertOpen()
    validateAgentId(agentId)
    const record = this.#requireLive(agentId)
    return record.serial.run(() => record.child.interrupt())
  }

  async close(agentId: string, reason = "close", graceMs?: number, forceMs?: number): Promise<void> {
    validateAgentId(agentId)
    const record = this.#live.get(agentId)
    if (!record) {
      if (this.#exited.some(value => value.agentId === agentId)) return
      throw new Error(`Unknown subagent: ${agentId}`)
    }
    this.#append({ event: "closing", agentId, reason })
    await record.child.close(reason, graceMs, forceMs)
    this.#retainExit(agentId, record)
  }

  async wait(
    agentIds: readonly string[],
    timeoutMs = defaultWaitTimeoutMs,
    signal?: AbortSignal
  ): Promise<SubagentSnapshot[]> {
    this.#assertOpen()
    if (agentIds.length === 0 || agentIds.length > maxWaitIds) {
      throw new Error(`wait_subagents requires 1 through ${maxWaitIds} agent ids`)
    }
    if (new Set(agentIds).size !== agentIds.length) throw new Error("wait_subagents rejects duplicate agent ids")
    for (const id of agentIds) {
      validateAgentId(id)
      this.#requireKnown(id)
    }
    const targetCycles = new Map(agentIds.map(id => [id, this.#currentWorkCycle(id)]))
    const boundedTimeout = Math.min(Math.max(0, timeoutMs), maxWaitTimeoutMs)
    const deadline = Date.now() + boundedTimeout
    this.#pumpMailbox()
    while (Date.now() < deadline && !agentIds.some(id => this.#hasDurableCompletion(id, targetCycles.get(id) ?? 0))) {
      if (signal?.aborted) break
      // oxlint-disable-next-line no-await-in-loop -- one bounded semantic wait owner
      await this.#waitPulse(Math.min(100, deadline - Date.now()), signal)
      this.#pumpMailbox()
    }
    const snapshots = agentIds.map(id => this.#snapshotFor(id))
    for (const id of agentIds) this.#markDelivered(id)
    return snapshots
  }

  shutdown(): Promise<void> {
    if (this.#shutdown) return this.#shutdown
    if (this.#state.type === "closed") return Promise.resolve()
    this.#state = { type: "stopping" }
    const closeAll = Promise.all(
      [...this.#live.keys()].map(id => this.#closeImmediately(id, "session_disposed", 3_500, 3_500).catch(() => {}))
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

  async #closeImmediately(agentId: string, reason: string, graceMs: number, forceMs: number): Promise<void> {
    const record = this.#live.get(agentId)
    if (!record) return
    this.#append({ event: "closing", agentId, reason })
    await record.child.close(reason, graceMs, forceMs)
    this.#retainExit(agentId, record)
  }

  #definition(name: string): SubagentTypeDefinition {
    const definition = this.definitions().find(value => value.name === name)
    if (!definition) throw new Error(`Unknown subagent type: ${name}`)
    return Object.freeze({
      name: definition.name,
      description: definition.description,
      instructions: definition.instructions
    })
  }

  #completion(completion: SubagentCompletion): void {
    const key = completionKey(completion.agentId, completion.workCycle)
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
          agentId: completion.agentId,
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
        changed.add(completion.agentId)
      } catch {
        break
      }
    }
    this.#evictMailbox()
    for (const agentId of changed) this.#changed(agentId)
    this.#notifyWaiters()
  }

  #recover(): void {
    const latest = new Map<string, SubagentEntry>()
    const definitions = new Map<string, string>()
    for (const entry of this.#sessionManager.subagentEntries()) {
      latest.delete(entry.agentId)
      latest.set(entry.agentId, entry)
      while (latest.size > maxRetainedSubagents) {
        const oldest = latest.keys().next().value
        if (oldest === undefined) break
        latest.delete(oldest)
        definitions.delete(oldest)
      }
      if (entry.event === "starting") definitions.set(entry.agentId, entry.definitionName)
      if (entry.event === "work_cycle_finished") {
        const completion: SubagentCompletion = {
          agentId: entry.agentId,
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
        this.#mailbox.set(completionKey(entry.agentId, entry.workCycle), {
          type: "durable",
          completion,
          entryId: entry.id
        })
        this.#evictMailbox()
      }
    }
    for (const [agentId, entry] of latest) {
      if (entry.event !== "exited" && entry.event !== "lost") {
        this.#append({ event: "lost", agentId, reason: "session_restored" })
      }
      const name = definitions.get(agentId) ?? generalSubagentType.name
      const definition = this.definitions().find(value => value.name === name) ?? generalSubagentType
      this.#retainExited({
        agentId,
        definition,
        snapshot: { agentId, lifecycle: "exited" },
        exitedAt: Date.parse(entry.timestamp)
      })
    }
    this.#evictMailbox()
  }

  #childChanged(agentId: string): void {
    const record = this.#live.get(agentId)
    const snapshot = record?.child.snapshot()
    if (record && snapshot?.workCycle !== undefined) record.lastWorkCycle = snapshot.workCycle
    if (record?.child.state.type === "exited") this.#retainExit(agentId, record)
    this.#changed(agentId)
  }

  #retainExit(agentId: string, record: LiveRecord): void {
    if (this.#live.get(agentId) !== record) return
    this.#live.delete(agentId)
    if (record.lastWorkCycle > 0 && !this.#delivery(agentId, record.lastWorkCycle)) {
      this.#completion({
        agentId,
        workCycle: record.lastWorkCycle,
        status: "failed",
        text: "",
        originalBytes: 0,
        omittedBytes: 0,
        truncated: false,
        durationMs: Math.max(0, Date.now() - record.createdAt),
        reason: "child_exited"
      })
    }
    const snapshot = record.child.snapshot()
    const state = record.child.state
    const outcome = state.type === "exited" ? JSON.stringify(state.outcome) : snapshot.lifecycle
    this.#append({ event: "exited", agentId, outcome: clipUtf8(outcome, durablePreviewBytes).text })
    this.#retainExited({ agentId, definition: record.definition, snapshot, exitedAt: Date.now() })
    this.#changed(agentId)
  }

  #retainExited(record: ExitedRecord): void {
    const existing = this.#exited.findIndex(value => value.agentId === record.agentId)
    if (existing >= 0) this.#exited.splice(existing, 1)
    this.#exited.push(record)
    while (this.#exited.length > maxRetainedSubagents) this.#exited.shift()
  }

  #snapshot(snapshot: ChildSnapshot, definition: SubagentTypeDefinition): SubagentSnapshot {
    const delivery = this.#latestDelivery(snapshot.agentId)
    return Object.freeze({
      agentId: snapshot.agentId,
      lifecycle: snapshot.lifecycle,
      definition,
      ...(snapshot.workCycle !== undefined ? { workCycle: snapshot.workCycle } : {}),
      ...(snapshot.sessionId ? { sessionId: snapshot.sessionId } : {}),
      ...(delivery?.type === "durable" || delivery?.type === "delivered" ? { completion: delivery.completion } : {}),
      ...(delivery ? { completionDelivery: delivery.type } : {})
    })
  }

  #snapshotFor(agentId: string): SubagentSnapshot {
    const live = this.#live.get(agentId)
    if (live) return this.#snapshot(live.child.snapshot(), live.definition)
    const exited = this.#exited.find(value => value.agentId === agentId)
    if (!exited) throw new Error(`Unknown subagent: ${agentId}`)
    return this.#snapshot(exited.snapshot, exited.definition)
  }

  #delivery(agentId: string, workCycle: number): CompletionDelivery | undefined {
    return this.#mailbox.get(completionKey(agentId, workCycle))
  }

  #latestDelivery(agentId: string): CompletionDelivery | undefined {
    let latest: CompletionDelivery | undefined
    for (const delivery of this.#mailbox.values()) {
      if (delivery.completion.agentId !== agentId) continue
      if (!latest || delivery.completion.workCycle > latest.completion.workCycle) latest = delivery
    }
    return latest
  }

  #hasDurableCompletion(agentId: string, workCycle: number): boolean {
    const delivery = this.#latestDelivery(agentId)
    return (
      delivery !== undefined &&
      delivery.completion.workCycle >= workCycle &&
      (delivery.type === "durable" || delivery.type === "delivered")
    )
  }

  #currentWorkCycle(agentId: string): number {
    const live = this.#live.get(agentId)
    if (live) return live.child.snapshot().workCycle ?? live.lastWorkCycle
    return this.#latestDelivery(agentId)?.completion.workCycle ?? 0
  }

  #markDelivered(agentId: string): void {
    let changed = false
    for (const [key, delivery] of this.#mailbox) {
      if (delivery.completion.agentId === agentId && delivery.type === "durable") {
        this.#mailbox.set(key, { ...delivery, type: "delivered" })
        changed = true
      }
    }
    if (changed) this.#changed(agentId)
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

  #reserveCompletion(agentId: string, workCycle: number): string {
    this.#ensureCompletionCapacity()
    const key = completionKey(agentId, workCycle)
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

  #requireLive(agentId: string): LiveRecord {
    const record = this.#live.get(agentId)
    if (!record) throw new Error(`Unknown live subagent: ${agentId}`)
    return record
  }

  #requireKnown(agentId: string): void {
    if (!this.#live.has(agentId) && !this.#exited.some(value => value.agentId === agentId)) {
      throw new Error(`Unknown subagent: ${agentId}`)
    }
  }

  #assertOpen(): void {
    if (this.#state.type !== "open") throw new Error(`Subagent supervisor is ${this.#state.type}`)
  }

  #changed(agentId: string): void {
    this.#emit({ type: "changed", agentId })
    this.#notifyWaiters()
  }

  #emit(event: SubagentSupervisorEvent): void {
    for (const listener of this.#listeners) listener(event)
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

function validateAgentId(agentId: string): void {
  validateText(agentId, "Subagent agent id", maxSubagentAgentIdBytes)
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

function completionKey(agentId: string, workCycle: number): string {
  return `${agentId}:${workCycle}`
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
