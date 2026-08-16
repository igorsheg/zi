import { isPositiveInteger, isRecord } from "../guards.js"
import type { SessionEntryBase } from "../session-manager.js"
import { childAgentPath, parseAgentPath, rootAgentPath, type AgentPath } from "./path.js"
import { isAgentTurnResult, type AgentTurnResult } from "./result.js"

export type ForkTurns = "all" | "none" | number

export const maxAgentRecords = 64
export const maxPendingAgentMail = 256
export const maxPendingAgentMailBytes = 4 * 1024 * 1024
export const maxAgentMailTextBytes = 64 * 1024

export type AgentTeamEntryData =
  | {
      readonly type: "agent_spawn_reserved"
      readonly operationId: string
      readonly path: AgentPath
      readonly parentPath: AgentPath
      readonly sessionId: string
      readonly parentSessionId: string
      readonly parentEntryId: string | null
      readonly generation: number
      readonly taskName: string
      readonly forkTurns: ForkTurns
      readonly role?: string
    }
  | { readonly type: "agent_spawn_committed"; readonly operationId: string }
  | { readonly type: "agent_spawn_aborted"; readonly operationId: string; readonly reason: string }
  | {
      readonly type: "agent_turn_reserved"
      readonly operationId: string
      readonly path: AgentPath
      readonly turn: number
      readonly mailId: string
    }
  | { readonly type: "agent_turn_started"; readonly operationId: string; readonly inputEntryId: string }
  | {
      readonly type: "agent_turn_settled"
      readonly operationId: string
      readonly path: AgentPath
      readonly turn: number
      readonly result: AgentTurnResult
    }
  | {
      readonly type: "agent_mail_queued"
      readonly mailId: string
      readonly sender: AgentPath
      readonly target: AgentPath
      readonly kind: "message" | "task"
      readonly text: string
    }
  | { readonly type: "agent_mail_delivered"; readonly mailId: string; readonly targetEntryId: string }
  | {
      readonly type: "agent_completion_delivered"
      readonly path: AgentPath
      readonly turn: number
      readonly targetEntryId: string
    }

export type AgentTeamEntry = SessionEntryBase & AgentTeamEntryData

export type SettledAgentStatus = "not_started" | "completed" | "interrupted" | "failed"

export interface DurableAgentRecord {
  readonly path: AgentPath
  readonly parentPath: AgentPath
  readonly sessionId: string
  readonly parentSessionId: string
  readonly parentEntryId: string | null
  readonly generation: number
  readonly taskName: string
  readonly role?: string
  readonly nextTurn: number
  readonly status: SettledAgentStatus
}

export type PendingAgentTurn = {
  readonly operationId: string
  readonly path: AgentPath
  readonly turn: number
  readonly mailId: string
} & ({ readonly stage: "reserved" } | { readonly stage: "started"; readonly inputEntryId: string })

export interface PendingAgentCompletion {
  readonly path: AgentPath
  readonly parentPath: AgentPath
  readonly turn: number
  readonly result: AgentTurnResult
}

export interface AgentTeamJournalState {
  readonly records: ReadonlyMap<AgentPath, DurableAgentRecord>
  readonly spawnReservations: ReadonlyMap<string, Extract<AgentTeamEntryData, { type: "agent_spawn_reserved" }>>
  readonly pendingTurns: ReadonlyMap<string, PendingAgentTurn>
  readonly pendingMail: ReadonlyMap<string, Extract<AgentTeamEntryData, { type: "agent_mail_queued" }>>
  readonly deliveredMail: ReadonlyMap<string, string>
  readonly pendingCompletions: ReadonlyMap<string, PendingAgentCompletion>
  readonly deliveredCompletions: ReadonlyMap<string, string>
}

export class AgentTeamJournalError extends Error {
  constructor(message: string) {
    super(message)
    this.name = "AgentTeamJournalError"
  }
}

export function replayAgentTeamJournal(entries: readonly AgentTeamEntry[]): AgentTeamJournalState {
  const records = new Map<AgentPath, DurableAgentRecord>()
  const spawnReservations = new Map<string, Extract<AgentTeamEntryData, { readonly type: "agent_spawn_reserved" }>>()
  const pendingTurns = new Map<string, PendingAgentTurn>()
  const operationIds = new Set<string>()
  const pendingMail = new Map<string, Extract<AgentTeamEntryData, { readonly type: "agent_mail_queued" }>>()
  let pendingMailBytes = 0
  const deliveredMail = new Map<string, string>()
  const knownMail = new Set<string>()
  const pendingCompletions = new Map<string, PendingAgentCompletion>()
  const deliveredCompletions = new Map<string, string>()

  for (const entry of entries) {
    const { id: _id, parentId: _parentId, timestamp: _timestamp, ...data } = entry
    if (!isAgentTeamEntryData(data)) throw new AgentTeamJournalError("Invalid agent-team journal entry")
    switch (entry.type) {
      case "agent_spawn_reserved": {
        if (operationIds.has(entry.operationId)) {
          throw new AgentTeamJournalError(`Duplicate agent operation: ${entry.operationId}`)
        }
        const parent = entry.parentPath === rootAgentPath ? undefined : records.get(entry.parentPath)
        if (entry.parentPath !== rootAgentPath && !parent) {
          throw new AgentTeamJournalError(`Unknown agent parent: ${entry.parentPath}`)
        }
        if (parent && entry.parentSessionId !== parent.sessionId) {
          throw new AgentTeamJournalError(`Agent parent session does not match: ${entry.path}`)
        }
        if (
          childAgentPath(entry.parentPath, entry.taskName) !== entry.path ||
          entry.generation !== entry.path.split("/").length - 2
        ) {
          throw new AgentTeamJournalError(`Agent lineage does not match its parent and task name: ${entry.path}`)
        }
        if (
          records.has(entry.path) ||
          [...spawnReservations.values()].some(reservation => reservation.path === entry.path)
        ) {
          throw new AgentTeamJournalError(`Agent path already exists: ${entry.path}`)
        }
        if (records.size + spawnReservations.size === maxAgentRecords) {
          throw new AgentTeamJournalError(`Agent tree cannot exceed ${maxAgentRecords} records`)
        }
        operationIds.add(entry.operationId)
        spawnReservations.set(entry.operationId, spawnReservation(entry))
        break
      }
      case "agent_spawn_committed": {
        const reservation = spawnReservations.get(entry.operationId)
        if (!reservation) throw new AgentTeamJournalError(`Unknown agent spawn operation: ${entry.operationId}`)
        spawnReservations.delete(entry.operationId)
        records.set(reservation.path, {
          path: reservation.path,
          parentPath: reservation.parentPath,
          sessionId: reservation.sessionId,
          parentSessionId: reservation.parentSessionId,
          parentEntryId: reservation.parentEntryId,
          generation: reservation.generation,
          taskName: reservation.taskName,
          ...(reservation.role === undefined ? {} : { role: reservation.role }),
          nextTurn: 1,
          status: "not_started"
        })
        break
      }
      case "agent_spawn_aborted": {
        if (!spawnReservations.delete(entry.operationId)) {
          throw new AgentTeamJournalError(`Unknown agent spawn operation: ${entry.operationId}`)
        }
        break
      }
      case "agent_turn_reserved": {
        const record = records.get(entry.path)
        if (!record) throw new AgentTeamJournalError(`Unknown agent path: ${entry.path}`)
        if (operationIds.has(entry.operationId)) {
          throw new AgentTeamJournalError(`Duplicate agent operation: ${entry.operationId}`)
        }
        if (entry.turn !== record.nextTurn) {
          throw new AgentTeamJournalError(`Agent turn is not monotonic: ${entry.path}/${entry.turn}`)
        }
        if ([...pendingTurns.values()].some(turn => turn.path === entry.path)) {
          throw new AgentTeamJournalError(`Agent already has a pending turn: ${entry.path}`)
        }
        if (knownMail.has(entry.mailId)) throw new AgentTeamJournalError(`Duplicate agent mail: ${entry.mailId}`)
        knownMail.add(entry.mailId)
        operationIds.add(entry.operationId)
        pendingTurns.set(entry.operationId, {
          operationId: entry.operationId,
          path: entry.path,
          turn: entry.turn,
          mailId: entry.mailId,
          stage: "reserved"
        })
        break
      }
      case "agent_turn_started": {
        const pending = pendingTurns.get(entry.operationId)
        if (!pending) throw new AgentTeamJournalError(`Unknown agent turn operation: ${entry.operationId}`)
        if (pending.stage !== "reserved") {
          throw new AgentTeamJournalError(`Agent turn already started: ${entry.operationId}`)
        }
        pendingTurns.set(entry.operationId, { ...pending, stage: "started", inputEntryId: entry.inputEntryId })
        break
      }
      case "agent_turn_settled": {
        const pending = pendingTurns.get(entry.operationId)
        if (!pending) throw new AgentTeamJournalError(`Unknown agent turn operation: ${entry.operationId}`)
        if (pending.path !== entry.path || pending.turn !== entry.turn) {
          throw new AgentTeamJournalError(`Agent turn settlement identity mismatch: ${entry.operationId}`)
        }
        const record = records.get(entry.path)!
        records.set(entry.path, { ...record, nextTurn: entry.turn + 1, status: entry.result.status })
        pendingTurns.delete(entry.operationId)
        pendingCompletions.set(completionIdentity(entry.path, entry.turn), {
          path: entry.path,
          parentPath: record.parentPath,
          turn: entry.turn,
          result: entry.result
        })
        break
      }
      case "agent_mail_queued": {
        if (!knownPath(records, entry.sender) || !knownPath(records, entry.target)) {
          throw new AgentTeamJournalError(`Unknown agent mail route: ${entry.sender} -> ${entry.target}`)
        }
        if (knownMail.has(entry.mailId)) throw new AgentTeamJournalError(`Duplicate agent mail: ${entry.mailId}`)
        const textBytes = Buffer.byteLength(entry.text)
        if (pendingMail.size === maxPendingAgentMail || pendingMailBytes + textBytes > maxPendingAgentMailBytes) {
          throw new AgentTeamJournalError("Agent mailbox capacity exceeded")
        }
        knownMail.add(entry.mailId)
        pendingMail.set(entry.mailId, mailReservation(entry))
        pendingMailBytes += textBytes
        break
      }
      case "agent_mail_delivered": {
        const mail = pendingMail.get(entry.mailId)
        if (!mail) throw new AgentTeamJournalError(`Unknown pending agent mail: ${entry.mailId}`)
        pendingMail.delete(entry.mailId)
        pendingMailBytes -= Buffer.byteLength(mail.text)
        deliveredMail.set(entry.mailId, entry.targetEntryId)
        break
      }
      case "agent_completion_delivered": {
        const identity = completionIdentity(entry.path, entry.turn)
        if (!pendingCompletions.delete(identity)) {
          throw new AgentTeamJournalError(`Unknown pending agent completion: ${entry.path}/${entry.turn}`)
        }
        deliveredCompletions.set(identity, entry.targetEntryId)
        break
      }
      default:
        assertNever(entry)
    }
  }

  return {
    records,
    spawnReservations,
    pendingTurns,
    pendingMail,
    deliveredMail,
    pendingCompletions,
    deliveredCompletions
  }
}

export function isAgentTeamEntryData(value: unknown): value is AgentTeamEntryData {
  if (!isRecord(value) || typeof value.type !== "string") return false
  switch (value.type) {
    case "agent_spawn_reserved":
      return (
        hasOnlyKeys(value, [
          "type",
          "operationId",
          "path",
          "parentPath",
          "sessionId",
          "parentSessionId",
          "parentEntryId",
          "generation",
          "taskName",
          "forkTurns",
          "role"
        ]) &&
        isBoundedId(value.operationId) &&
        isCanonicalPath(value.path) &&
        isCanonicalPath(value.parentPath) &&
        isBoundedId(value.sessionId) &&
        isBoundedId(value.parentSessionId) &&
        (value.parentEntryId === null || isBoundedId(value.parentEntryId)) &&
        isPositiveInteger(value.generation) &&
        typeof value.taskName === "string" &&
        isForkTurns(value.forkTurns) &&
        (value.role === undefined || isRoleName(value.role))
      )
    case "agent_spawn_committed":
      return hasOnlyKeys(value, ["type", "operationId"]) && isBoundedId(value.operationId)
    case "agent_spawn_aborted":
      return (
        hasOnlyKeys(value, ["type", "operationId", "reason"]) &&
        isBoundedId(value.operationId) &&
        typeof value.reason === "string" &&
        Buffer.byteLength(value.reason) <= 8 * 1024
      )
    case "agent_turn_reserved":
      return (
        hasOnlyKeys(value, ["type", "operationId", "path", "turn", "mailId"]) &&
        isBoundedId(value.operationId) &&
        isCanonicalPath(value.path) &&
        isPositiveInteger(value.turn) &&
        isBoundedId(value.mailId)
      )
    case "agent_turn_started":
      return (
        hasOnlyKeys(value, ["type", "operationId", "inputEntryId"]) &&
        isBoundedId(value.operationId) &&
        isBoundedId(value.inputEntryId)
      )
    case "agent_turn_settled":
      return (
        hasOnlyKeys(value, ["type", "operationId", "path", "turn", "result"]) &&
        isBoundedId(value.operationId) &&
        isCanonicalPath(value.path) &&
        isPositiveInteger(value.turn) &&
        isAgentTurnResult(value.result)
      )
    case "agent_mail_queued":
      return (
        hasOnlyKeys(value, ["type", "mailId", "sender", "target", "kind", "text"]) &&
        isBoundedId(value.mailId) &&
        isCanonicalPath(value.sender) &&
        isCanonicalPath(value.target) &&
        (value.kind === "message" || value.kind === "task") &&
        typeof value.text === "string" &&
        Buffer.byteLength(value.text) <= maxAgentMailTextBytes
      )
    case "agent_mail_delivered":
      return (
        hasOnlyKeys(value, ["type", "mailId", "targetEntryId"]) &&
        isBoundedId(value.mailId) &&
        isBoundedId(value.targetEntryId)
      )
    case "agent_completion_delivered":
      return (
        hasOnlyKeys(value, ["type", "path", "turn", "targetEntryId"]) &&
        isCanonicalPath(value.path) &&
        isPositiveInteger(value.turn) &&
        isBoundedId(value.targetEntryId)
      )
    default:
      return false
  }
}

function spawnReservation(
  entry: Extract<AgentTeamEntry, { readonly type: "agent_spawn_reserved" }>
): Extract<AgentTeamEntryData, { readonly type: "agent_spawn_reserved" }> {
  return {
    type: entry.type,
    operationId: entry.operationId,
    path: entry.path,
    parentPath: entry.parentPath,
    sessionId: entry.sessionId,
    parentSessionId: entry.parentSessionId,
    parentEntryId: entry.parentEntryId,
    generation: entry.generation,
    taskName: entry.taskName,
    forkTurns: entry.forkTurns,
    ...(entry.role === undefined ? {} : { role: entry.role })
  }
}

function mailReservation(
  entry: Extract<AgentTeamEntry, { readonly type: "agent_mail_queued" }>
): Extract<AgentTeamEntryData, { readonly type: "agent_mail_queued" }> {
  return {
    type: entry.type,
    mailId: entry.mailId,
    sender: entry.sender,
    target: entry.target,
    kind: entry.kind,
    text: entry.text
  }
}

function completionIdentity(path: AgentPath, turn: number): string {
  return `${path}\0${turn}`
}

function knownPath(records: ReadonlyMap<AgentPath, DurableAgentRecord>, path: AgentPath): boolean {
  return path === rootAgentPath || records.has(path)
}

function isCanonicalPath(value: unknown): value is AgentPath {
  if (typeof value !== "string") return false
  try {
    return parseAgentPath(value) === value
  } catch {
    return false
  }
}

function isForkTurns(value: unknown): value is ForkTurns {
  return value === "all" || value === "none" || (isPositiveInteger(value) && Number.isSafeInteger(value))
}

function isRoleName(value: unknown): value is string {
  return typeof value === "string" && /^[a-z][a-z0-9_-]*$/u.test(value) && Buffer.byteLength(value) <= 64
}

function isBoundedId(value: unknown): value is string {
  return typeof value === "string" && value.length > 0 && Buffer.byteLength(value) <= 128
}

function hasOnlyKeys(value: Record<string, unknown>, keys: readonly string[]): boolean {
  const admitted = new Set(keys)
  return Object.keys(value).every(key => admitted.has(key))
}

function assertNever(value: never): never {
  throw new AgentTeamJournalError(`Unexpected agent-team entry: ${String(value)}`)
}
