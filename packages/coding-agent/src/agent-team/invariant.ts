import type { InvariantContext, InvariantRegistry } from "@with-zi/invariants"

import type { CustomMessageEntry } from "../session-manager.js"
import { isAgentMailEntry, type AgentMailInput, type AgentMailPublication } from "./mail.js"
import type { AgentPath } from "./path.js"

const owner = "@with-zi/coding-agent/agent-team"

export interface AgentTeamTerminalSnapshot {
  readonly reservations: number
  readonly spawnOperations: number
  readonly settlements: number
  readonly transientRecords: number
  readonly transcriptOpen: boolean
}

export class AgentTeamInvariant {
  readonly #dispose: () => void
  #turnStarted: (input: AgentMailInput, entry: CustomMessageEntry, inputEntryId: string) => void = () => {}
  #mailDelivered: (
    input: AgentMailInput,
    expectedPublication: AgentMailPublication | undefined,
    entry: CustomMessageEntry,
    publication: AgentMailPublication,
    targetEntryId: string
  ) => void = () => {}
  #deadlineScheduled: (identity: string) => void = () => {}
  #deadlineReleased: (identity: string) => void = () => {}
  #shutdownSucceeded: (snapshot: AgentTeamTerminalSnapshot) => void = () => {}

  constructor(registry: InvariantRegistry) {
    this.#dispose = registry.register(owner, context => {
      const trace = new AgentTeamTrace(context)
      this.#turnStarted = (input, entry, inputEntryId) => trace.turnStarted(input, entry, inputEntryId)
      this.#mailDelivered = (input, expectedPublication, entry, publication, targetEntryId) =>
        trace.mailDelivered(input, expectedPublication, entry, publication, targetEntryId)
      this.#deadlineScheduled = identity => trace.deadlineScheduled(identity)
      this.#deadlineReleased = identity => trace.deadlineReleased(identity)
      this.#shutdownSucceeded = snapshot => trace.shutdownSucceeded(snapshot)
      return () => {
        this.#turnStarted = () => {}
        this.#mailDelivered = () => {}
        this.#deadlineScheduled = () => {}
        this.#deadlineReleased = () => {}
        this.#shutdownSucceeded = () => {}
      }
    })
  }

  turnStarted(input: AgentMailInput, entry: CustomMessageEntry, inputEntryId: string): void {
    this.#turnStarted(input, entry, inputEntryId)
  }

  mailDelivered(
    input: AgentMailInput,
    expectedPublication: AgentMailPublication | undefined,
    entry: CustomMessageEntry,
    publication: AgentMailPublication,
    targetEntryId: string
  ): void {
    this.#mailDelivered(input, expectedPublication, entry, publication, targetEntryId)
  }

  deadlineScheduled(path: AgentPath, turn: number): void {
    this.#deadlineScheduled(deadlineIdentity(path, turn))
  }

  deadlineReleased(path: AgentPath, turn: number): void {
    this.#deadlineReleased(deadlineIdentity(path, turn))
  }

  shutdownSucceeded(snapshot: AgentTeamTerminalSnapshot): void {
    this.#shutdownSucceeded(snapshot)
  }

  dispose(): void {
    this.#dispose()
  }
}

class AgentTeamTrace {
  readonly #context: InvariantContext
  readonly #deadlines = new Set<string>()

  constructor(context: InvariantContext) {
    this.#context = context
  }

  turnStarted(input: AgentMailInput, entry: CustomMessageEntry, inputEntryId: string): void {
    this.#context.assert(isAgentMailEntry(entry, input), `turn input ${input.deliveryId} does not match target entry`)
    this.#context.assert(
      inputEntryId === entry.id,
      `turn input ${input.deliveryId} acknowledgement does not name its target entry`
    )
  }

  mailDelivered(
    input: AgentMailInput,
    expectedPublication: AgentMailPublication | undefined,
    entry: CustomMessageEntry,
    publication: AgentMailPublication,
    targetEntryId: string
  ): void {
    this.#context.assert(isAgentMailEntry(entry, input), `mail ${input.deliveryId} does not match target entry`)
    if (expectedPublication !== undefined) {
      this.#context.assert(
        publication === expectedPublication,
        `mail ${input.deliveryId} published as ${publication}, expected ${expectedPublication}`
      )
    }
    this.#context.assert(
      targetEntryId === entry.id,
      `mail ${input.deliveryId} acknowledgement does not name its target entry`
    )
  }

  deadlineScheduled(identity: string): void {
    this.#context.assert(!this.#deadlines.has(identity), `turn deadline ${identity} was scheduled twice`)
    this.#deadlines.add(identity)
  }

  deadlineReleased(identity: string): void {
    this.#deadlines.delete(identity)
  }

  shutdownSucceeded(snapshot: AgentTeamTerminalSnapshot): void {
    this.#context.assert(snapshot.reservations === 0, "successful shutdown retained spawn reservations")
    this.#context.assert(snapshot.spawnOperations === 0, "successful shutdown retained spawn operations")
    this.#context.assert(snapshot.settlements === 0, "successful shutdown retained turn settlements")
    this.#context.assert(snapshot.transientRecords === 0, "successful shutdown retained transient agent records")
    this.#context.assert(!snapshot.transcriptOpen, "successful shutdown retained a transcript lease")
    this.#context.assert(this.#deadlines.size === 0, "successful shutdown retained turn deadlines", {
      deadlines: [...this.#deadlines]
    })
  }
}

function deadlineIdentity(path: AgentPath, turn: number): string {
  return `${path}/${turn}`
}
