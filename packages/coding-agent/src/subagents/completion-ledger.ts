import type { ProjectedSubagentWorkCycleOutcome } from "../operation-outcomes.js"
import type { SubagentEntry } from "../session-manager.js"
import type { SubagentCompletion } from "./child-process.js"

export const maxCompletionLedgerEntries = 32

export type CompletionDelivery =
  | { readonly type: "pending"; readonly completion: SubagentCompletion }
  | { readonly type: "durable"; readonly completion: SubagentCompletion; readonly entryId: string }
  | {
      readonly type: "claimed"
      readonly completion: SubagentCompletion
      readonly entryId?: string
      readonly claimId: string
    }
  | { readonly type: "delivered"; readonly completion: SubagentCompletion; readonly entryId?: string }

export type CompletionAdmission = "accepted" | "duplicate" | "stale"

type CompletionState =
  | { readonly type: "reserved"; readonly name: string; readonly workCycle: number }
  | { readonly type: "pending"; readonly completion: SubagentCompletion }
  | { readonly type: "durable"; readonly completion: SubagentCompletion; readonly entryId: string }
  | { readonly type: "claimed_pending"; readonly completion: SubagentCompletion; readonly claimId: string }
  | {
      readonly type: "claimed_durable"
      readonly completion: SubagentCompletion
      readonly entryId: string
      readonly claimId: string
    }
  | { readonly type: "delivered_pending"; readonly completion: SubagentCompletion }
  | { readonly type: "delivered_durable"; readonly completion: SubagentCompletion; readonly entryId: string }

export interface PendingCompletionPersistence {
  readonly completion: SubagentCompletion
}

export class CompletionLedger {
  readonly #maximum: number
  readonly #states = new Map<string, CompletionState>()

  constructor(maximum = maxCompletionLedgerEntries) {
    if (!Number.isInteger(maximum) || maximum < 1 || maximum > maxCompletionLedgerEntries) {
      throw new Error(`Completion ledger capacity must be 1 through ${maxCompletionLedgerEntries}`)
    }
    this.#maximum = maximum
  }

  static restore(
    outcomes: Iterable<ProjectedSubagentWorkCycleOutcome>,
    entries: Iterable<SubagentEntry>,
    maximum = maxCompletionLedgerEntries
  ): CompletionLedger {
    const delivered = new Set(
      [...entries]
        .filter(entry => entry.event === "work_cycle_delivered")
        .map(entry => completionKey(entry.name, entry.workCycle))
    )
    const ledger = new CompletionLedger(maximum)
    const restored = new Set<string>()
    for (const outcome of outcomes) {
      const key = completionKey(outcome.name, outcome.workCycle)
      if (restored.has(key)) continue
      restored.add(key)
      ledger.#makeSpace(`Session contains more than ${maximum} undelivered subagent completions`)
      const common = {
        name: outcome.name,
        workCycle: outcome.workCycle,
        text: outcome.preview,
        originalBytes: outcome.originalBytes,
        omittedBytes: outcome.omittedBytes,
        truncated: outcome.truncated,
        durationMs: outcome.durationMs
      }
      const completion: SubagentCompletion = Object.freeze(
        outcome.result === "failed"
          ? {
              ...common,
              status: "failed",
              reason: outcome.errorCode,
              ...(outcome.errorMessage ? { error: outcome.errorMessage } : {})
            }
          : { ...common, status: outcome.result === "succeeded" ? "completed" : "cancelled" }
      )
      ledger.#states.set(
        key,
        delivered.has(key)
          ? { type: "delivered_durable", completion, entryId: outcome.sourceEntryId }
          : { type: "durable", completion, entryId: outcome.sourceEntryId }
      )
    }
    ledger.assertInvariants()
    return ledger
  }

  get size(): number {
    return this.#states.size
  }

  reserve(name: string, workCycle: number): void {
    assertCompletionIdentity(name, workCycle)
    const key = completionKey(name, workCycle)
    if (this.#states.has(key)) throw new Error(`Subagent completion already exists: ${key}`)
    this.#makeSpace("Subagent completion capacity exceeded: undelivered completions fill the mailbox")
    this.#states.set(key, { type: "reserved", name, workCycle })
    this.assertInvariants()
  }

  cancelReservation(name: string, workCycle: number): boolean {
    const key = completionKey(name, workCycle)
    if (this.#states.get(key)?.type !== "reserved") return false
    this.#states.delete(key)
    this.assertInvariants()
    return true
  }

  admit(completion: SubagentCompletion): CompletionAdmission {
    assertCompletionIdentity(completion.name, completion.workCycle)
    const key = completionKey(completion.name, completion.workCycle)
    const state = this.#states.get(key)
    if (!state) return "stale"
    if (state.type !== "reserved") return "duplicate"
    this.#states.delete(key)
    this.#states.set(key, { type: "pending", completion })
    this.assertInvariants()
    return "accepted"
  }

  pendingPersistence(): readonly PendingCompletionPersistence[] {
    const pending: PendingCompletionPersistence[] = []
    for (const state of this.#states.values()) {
      if (state.type === "pending" || state.type === "claimed_pending" || state.type === "delivered_pending") {
        pending.push(Object.freeze({ completion: state.completion }))
      }
    }
    return Object.freeze(pending)
  }

  commitPersistence(name: string, workCycle: number, entryId: string): void {
    if (entryId.length === 0) throw new Error("Subagent completion persistence requires an entry identity")
    const key = completionKey(name, workCycle)
    const state = this.#states.get(key)
    if (state?.type === "pending") {
      this.#states.set(key, { type: "durable", completion: state.completion, entryId })
    } else if (state?.type === "claimed_pending") {
      this.#states.set(key, { type: "claimed_durable", completion: state.completion, entryId, claimId: state.claimId })
    } else if (state?.type === "delivered_pending") {
      this.#states.set(key, { type: "delivered_durable", completion: state.completion, entryId })
    } else {
      throw new Error(`Subagent completion is not awaiting persistence: ${key}`)
    }
    this.assertInvariants()
  }

  delivery(name: string, workCycle: number): CompletionDelivery | undefined {
    const state = this.#states.get(completionKey(name, workCycle))
    return state ? publicDelivery(state) : undefined
  }

  deliveries(): readonly CompletionDelivery[] {
    const deliveries: CompletionDelivery[] = []
    for (const state of this.#states.values()) {
      const delivery = publicDelivery(state)
      if (delivery) deliveries.push(delivery)
    }
    return Object.freeze(deliveries)
  }

  identities(): readonly { readonly name: string; readonly workCycle: number }[] {
    return Object.freeze(
      [...this.#states.values()].map(state =>
        state.type === "reserved"
          ? Object.freeze({ name: state.name, workCycle: state.workCycle })
          : Object.freeze({ name: state.completion.name, workCycle: state.completion.workCycle })
      )
    )
  }

  oldestReady(name: string): Extract<CompletionDelivery, { type: "pending" | "durable" }> | undefined {
    let oldest: Extract<CompletionDelivery, { type: "pending" | "durable" }> | undefined
    for (const state of this.#states.values()) {
      if ((state.type !== "pending" && state.type !== "durable") || state.completion.name !== name) continue
      if (oldest && state.completion.workCycle >= oldest.completion.workCycle) continue
      oldest =
        state.type === "pending"
          ? { type: "pending", completion: state.completion }
          : { type: "durable", completion: state.completion, entryId: state.entryId }
    }
    return oldest
  }

  oldestDurable(name: string): Extract<CompletionDelivery, { type: "durable" }> | undefined {
    let oldest: Extract<CompletionDelivery, { type: "durable" }> | undefined
    for (const state of this.#states.values()) {
      if (state.type !== "durable" || state.completion.name !== name) continue
      if (!oldest || state.completion.workCycle < oldest.completion.workCycle) {
        oldest = { type: "durable", completion: state.completion, entryId: state.entryId }
      }
    }
    return oldest
  }

  latest(name: string): CompletionDelivery | undefined {
    let latest: CompletionDelivery | undefined
    for (const state of this.#states.values()) {
      const delivery = publicDelivery(state)
      if (!delivery || delivery.completion.name !== name) continue
      if (!latest || delivery.completion.workCycle > latest.completion.workCycle) latest = delivery
    }
    return latest
  }

  readyNames(): readonly string[] {
    const names = new Set<string>()
    for (const state of this.#states.values()) {
      if (state.type === "durable") names.add(state.completion.name)
    }
    return Object.freeze([...names])
  }

  acknowledge(name: string, workCycle: number): boolean {
    const key = completionKey(name, workCycle)
    const state = this.#states.get(key)
    if (state?.type === "pending" || state?.type === "claimed_pending") {
      this.#states.set(key, { type: "delivered_pending", completion: state.completion })
    } else if (state?.type === "durable" || state?.type === "claimed_durable") {
      this.#states.set(key, { type: "delivered_durable", completion: state.completion, entryId: state.entryId })
    } else {
      return false
    }
    this.assertInvariants()
    return true
  }

  markDelivered(name: string, workCycle: number): boolean {
    const key = completionKey(name, workCycle)
    const state = this.#states.get(key)
    if (state?.type !== "durable") return false
    this.#states.set(key, { type: "delivered_durable", completion: state.completion, entryId: state.entryId })
    this.assertInvariants()
    return true
  }

  claim(name: string, workCycle: number, claimId: string): boolean {
    if (claimId.length === 0) throw new Error("Subagent completion claim requires an owner")
    const key = completionKey(name, workCycle)
    const state = this.#states.get(key)
    if (state?.type === "pending") {
      this.#states.set(key, { type: "claimed_pending", completion: state.completion, claimId })
    } else if (state?.type === "durable") {
      this.#states.set(key, { type: "claimed_durable", completion: state.completion, entryId: state.entryId, claimId })
    } else {
      return false
    }
    this.assertInvariants()
    return true
  }

  releaseClaims(claimIdPrefix?: string): readonly string[] {
    const changed = new Set<string>()
    for (const [key, state] of this.#states) {
      if (
        (state.type !== "claimed_pending" && state.type !== "claimed_durable") ||
        (claimIdPrefix && !state.claimId.startsWith(claimIdPrefix))
      ) {
        continue
      }
      this.#states.set(
        key,
        state.type === "claimed_durable"
          ? { type: "durable", completion: state.completion, entryId: state.entryId }
          : { type: "pending", completion: state.completion }
      )
      changed.add(state.completion.name)
    }
    this.assertInvariants()
    return Object.freeze([...changed])
  }

  assertInvariants(): void {
    if (this.#states.size > this.#maximum) throw new Error("Completion ledger invariant violated: capacity exceeded")
    for (const [key, state] of this.#states) {
      const name = state.type === "reserved" ? state.name : state.completion.name
      const workCycle = state.type === "reserved" ? state.workCycle : state.completion.workCycle
      if (key !== completionKey(name, workCycle)) {
        throw new Error("Completion ledger invariant violated: key does not match completion identity")
      }
      if (name.length === 0 || !Number.isSafeInteger(workCycle) || workCycle < 1) {
        throw new Error("Completion ledger invariant violated: invalid completion identity")
      }
      if (
        (state.type === "durable" || state.type === "claimed_durable" || state.type === "delivered_durable") &&
        state.entryId.length === 0
      ) {
        throw new Error("Completion ledger invariant violated: durable completion has no entry identity")
      }
      if ((state.type === "claimed_pending" || state.type === "claimed_durable") && state.claimId.length === 0) {
        throw new Error("Completion ledger invariant violated: claimed completion has no owner")
      }
    }
  }

  #makeSpace(message: string): void {
    while (this.#states.size >= this.#maximum) {
      const delivered = [...this.#states].find(
        ([, state]) => state.type === "delivered_pending" || state.type === "delivered_durable"
      )
      if (!delivered) throw new Error(message)
      this.#states.delete(delivered[0])
    }
  }
}

function publicDelivery(state: CompletionState): CompletionDelivery | undefined {
  switch (state.type) {
    case "reserved":
      return undefined
    case "pending":
      return { type: "pending", completion: state.completion }
    case "durable":
      return { type: "durable", completion: state.completion, entryId: state.entryId }
    case "claimed_pending":
      return { type: "claimed", completion: state.completion, claimId: state.claimId }
    case "claimed_durable":
      return { type: "claimed", completion: state.completion, entryId: state.entryId, claimId: state.claimId }
    case "delivered_pending":
      return { type: "delivered", completion: state.completion }
    case "delivered_durable":
      return { type: "delivered", completion: state.completion, entryId: state.entryId }
    default: {
      const exhaustive: never = state
      return exhaustive
    }
  }
}

function completionKey(name: string, workCycle: number): string {
  return `${name}:${workCycle}`
}

function assertCompletionIdentity(name: string, workCycle: number): void {
  if (name.length === 0 || !Number.isSafeInteger(workCycle) || workCycle < 1) {
    throw new Error("Subagent completion requires a valid identity")
  }
}
