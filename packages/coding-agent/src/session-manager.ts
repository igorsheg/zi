import { createHash } from "node:crypto"
import {
  appendFileSync,
  closeSync,
  linkSync,
  mkdirSync,
  openSync,
  readFileSync,
  readSync,
  rmSync,
  statSync,
  truncateSync,
  writeFileSync
} from "node:fs"
import { open, opendir, rm, stat, unlink } from "node:fs/promises"
import { dirname, join } from "node:path"

import type { ThinkingLevel } from "@earendil-works/pi-agent-core"
import type { ImageContent, TextContent } from "@earendil-works/pi-ai"

import { formatCompactionSummary, type AgentMessage, type CompactionSummaryMessage } from "./messages.js"
import { type ZiPaths, resolveZiPath } from "./paths.js"
import { maxRetryCount } from "./retry.js"
import {
  appendSessionColdEntries,
  sessionColdBytes,
  sessionColdLogicalBytes,
  type SessionColdBlock,
  visitSessionColdLines
} from "./session-cold-history.js"

export type SessionFormatVersion = 1 | 2

export interface SessionHeader {
  type: "session"
  version: SessionFormatVersion
  id: string
  timestamp: string
  cwd: string
}

interface SessionEntryBase {
  id: string
  parentId: string | null
  timestamp: string
}

export type CompactionReason = "manual" | "threshold" | "overflow"

export interface CompactionDetails {
  readonly readFiles: readonly string[]
  readonly modifiedFiles: readonly string[]
  readonly omittedReadFiles: number
  readonly omittedModifiedFiles: number
}

export interface RetryEntryData {
  readonly type: "retry"
  readonly failedEntryId: string
  readonly attempt: number
}

export interface CompactionEntryData {
  readonly type: "compaction"
  readonly reason: CompactionReason
  readonly summary: string
  readonly firstKeptEntryId: string
  readonly tokensBefore: number
  readonly estimatedTokensAfter: number
  readonly details: CompactionDetails
  readonly excludedFailureEntryId?: string
}

export type SessionJson =
  | null
  | boolean
  | number
  | string
  | readonly SessionJson[]
  | { readonly [key: string]: SessionJson }

export interface CustomEntryData {
  readonly type: "custom"
  readonly customType: string
  readonly data?: SessionJson
}

export type CustomMessageContent = string | readonly (TextContent | ImageContent)[]

export interface CustomMessageEntryData {
  readonly type: "custom_message"
  readonly customType: string
  readonly content: CustomMessageContent
  readonly display: boolean
  readonly details?: SessionJson
}

export interface CustomMessageInput {
  readonly customType: string
  readonly content: CustomMessageContent
  readonly display: boolean
  readonly details?: SessionJson
}

export type SubagentCompletionStatus = "completed" | "failed" | "cancelled"

export type SubagentEntryData =
  | { readonly type: "subagent"; readonly event: "starting"; readonly agentId: string; readonly definitionName: string }
  | { readonly type: "subagent"; readonly event: "ready"; readonly agentId: string; readonly sessionId?: string }
  | {
      readonly type: "subagent"
      readonly event: "work_cycle_started"
      readonly agentId: string
      readonly workCycle: number
    }
  | {
      readonly type: "subagent"
      readonly event: "work_cycle_finished"
      readonly agentId: string
      readonly workCycle: number
      readonly status: SubagentCompletionStatus
      readonly preview: string
      readonly originalBytes: number
      readonly omittedBytes: number
      readonly truncated: boolean
      readonly durationMs: number
      readonly reason?: string
      readonly error?: string
    }
  | { readonly type: "subagent"; readonly event: "closing"; readonly agentId: string; readonly reason: string }
  | { readonly type: "subagent"; readonly event: "exited"; readonly agentId: string; readonly outcome: string }
  | { readonly type: "subagent"; readonly event: "lost"; readonly agentId: string; readonly reason: "session_restored" }

export type SubagentEntryInput = SubagentEntryData extends infer Entry
  ? Entry extends { readonly type: "subagent" }
    ? Omit<Entry, "type">
    : never
  : never

export type SessionEntryData =
  | { type: "message"; message: AgentMessage }
  | { type: "model_change"; provider: string; modelId: string }
  | { type: "thinking_level_change"; thinkingLevel: ThinkingLevel }
  | RetryEntryData
  | CompactionEntryData
  | CustomEntryData
  | CustomMessageEntryData
  | SubagentEntryData

export type SessionEntry = SessionEntryBase & SessionEntryData
export type MessageEntry = SessionEntryBase & Extract<SessionEntryData, { type: "message" }>
export type RetryEntry = SessionEntryBase & RetryEntryData
export type CompactionEntry = SessionEntryBase & CompactionEntryData
export type CustomEntry = SessionEntryBase & CustomEntryData
export type CustomMessageEntry = SessionEntryBase & CustomMessageEntryData
export type SubagentEntry = SessionEntryBase & SubagentEntryData

export interface NewSessionOptions {
  sessionId?: string
  persist?: boolean
}

export const maxSessionFileBytes = 64 * 1024 * 1024
export const maxSessionStorageBytes = 64 * 1024 * 1024
export const maxSessionListCandidates = 4096
export const maxSessionListResults = 200
export const maxSessionListPreviewBytes = 256 * 1024
export const maxSessionFirstMessageLength = 512
export const maxSessionPromptHistoryEntries = 100
export const maxSessionPromptHistoryEntryBytes = 1024 * 1024
export const maxSessionPromptHistoryBytes = 8 * 1024 * 1024
export const maxCompactionSummaryBytes = 128 * 1024
export const maxCompactionFilePaths = 256
export const maxCompactionPathBytes = 4096
export const maxCustomTypeBytes = 128
export const maxCustomJsonDepth = 32
export const maxCustomJsonNodes = 4096
export const maxCustomJsonBytes = 256 * 1024
export const maxCustomMessageBytes = 1024 * 1024
export const maxCustomStateEntries = 2048
export const maxCustomStateBytes = 2 * 1024 * 1024
export const maxSubagentJournalTextBytes = 8 * 1024

const customTypePattern = /^[a-z][a-z0-9._:/-]*$/

const currentSessionFormat: SessionFormatVersion = 2
const sessionReadBufferBytes = 64 * 1024
const sessionListConcurrency = 8
const imageDigestPattern = /^[0-9a-f]{64}$/

export interface SessionInfo {
  readonly path: string
  readonly id: string
  readonly cwd: string
  readonly createdAt: string
  readonly modifiedAt: string
  readonly firstMessage: string
}

export interface SessionListResult {
  readonly sessions: readonly SessionInfo[]
  readonly invalid: number
  readonly omitted: number
}

export interface SessionListOptions {
  readonly limit?: number
}

export interface SessionModel {
  readonly provider: string
  readonly modelId: string
}

export interface SessionPromptHistoryEntry {
  readonly entryId: string
  readonly text: string
}

export interface SessionContext {
  readonly messages: readonly AgentMessage[]
  readonly model?: SessionModel
  readonly thinkingLevel?: ThinkingLevel
}

export interface SessionJournalMemoryDiagnostics {
  readonly entries: number
  readonly residentEntries: number
  readonly coldEntries: number
  readonly journalBytes: number
  readonly residentEntryBytes: number
  readonly imageBlobBytes: number
  readonly customStateEntries: number
  readonly customStateBytes: number
  readonly coldMemoryBytes: number
  readonly coldMemoryLogicalBytes: number
  readonly coldMemoryBlocks: number
}

type SessionPersistence =
  | { readonly type: "memory" }
  | { readonly type: "pending"; readonly file: string }
  | {
      readonly type: "durable"
      readonly file: string
      readonly appendRepair?: { readonly type: "truncate"; readonly offset: number } | { readonly type: "newline" }
    }

interface StoredImageReference {
  readonly type: "image"
  readonly mimeType: string
  readonly blob: { readonly sha256: string; readonly bytes: number }
}

interface StoredAgentMessage extends Record<string, unknown> {
  readonly role: AgentMessage["role"]
  readonly timestamp: number
}

type StoredMessageEntry = SessionEntryBase & { readonly type: "message"; readonly message: StoredAgentMessage }
type StoredCustomMessageContent = string | readonly (TextContent | ImageContent | StoredImageReference)[]
type StoredCustomMessageEntry = SessionEntryBase &
  Omit<CustomMessageEntryData, "content"> & { readonly content: StoredCustomMessageContent }
type StoredSessionEntry =
  | Exclude<SessionEntry, MessageEntry | CustomMessageEntry>
  | StoredMessageEntry
  | StoredCustomMessageEntry

interface PreparedBlob {
  readonly sha256: string
  readonly bytes: number
  readonly data: Buffer
}

interface PreparedRecord {
  readonly line: string
  readonly bytes: number
  readonly blobs: ReadonlyMap<string, PreparedBlob>
}

interface PreparedCompaction {
  readonly boundary: number
  readonly coldBlocks: readonly SessionColdBlock[] | undefined
}

interface JournalRecord {
  readonly line: string
  readonly bytes: number
  readonly start: number
  readonly end: number
  readonly terminated: boolean
}

interface EntryReference {
  readonly id: string
  readonly index: number
  readonly type: SessionEntry["type"]
  readonly role?: AgentMessage["role"]
  readonly stopReason?: unknown
  readonly contextVisible: boolean
}

interface LoadedJournal {
  readonly header: SessionHeader
  readonly entries: SessionEntry[]
  readonly recordBytes: number[]
  readonly promptHistory: SessionPromptHistoryEntry[]
  readonly promptHistoryBytes: number
  readonly model: SessionModel | undefined
  readonly thinkingLevel: ThinkingLevel | undefined
  readonly leafId: string | null
  readonly entryCount: number
  readonly journalBytes: number
  readonly imageBlobs: Map<string, number>
  readonly imageBlobBytes: number
  readonly customEntries: CustomEntry[]
  readonly customStateBytes: number
  readonly appendRepair?: { readonly type: "truncate"; readonly offset: number } | { readonly type: "newline" }
}

export class SessionCapacityError extends Error {
  constructor() {
    super(`Session storage cannot exceed ${maxSessionStorageBytes} bytes`)
    this.name = "SessionCapacityError"
  }
}

export class CustomStateCapacityError extends Error {
  constructor() {
    super(`Custom session state cannot exceed ${maxCustomStateEntries} entries or ${maxCustomStateBytes} bytes`)
    this.name = "CustomStateCapacityError"
  }
}

export class SessionManager {
  readonly header: SessionHeader
  #persistence: SessionPersistence
  readonly #entries: SessionEntry[] = []
  readonly #residentRecordBytes: number[] = []
  #presentationMessages: AgentMessage[] = []
  readonly #promptHistory: SessionPromptHistoryEntry[] = []
  readonly #customEntries: CustomEntry[] = []
  #coldMemory: readonly SessionColdBlock[] = []
  readonly #imageBlobs = new Map<string, number>()
  #promptHistoryBytes = 0
  #customStateBytes = 0
  #leafId: string | null = null
  #entryCount = 0
  #journalBytes: number
  #imageBlobBytes = 0
  #model: SessionModel | undefined
  #thinkingLevel: ThinkingLevel | undefined

  private constructor(
    cwd: string,
    sessionDir: string,
    sessionId?: string,
    persist = true,
    restoredHeader?: SessionHeader
  ) {
    const id = sessionId ?? crypto.randomUUID()
    this.header =
      restoredHeader ??
      ({ type: "session", version: currentSessionFormat, id, timestamp: new Date().toISOString(), cwd } as const)
    this.#journalBytes = lineBytes(JSON.stringify(this.header))
    if (persist) mkdirSync(sessionDir, { recursive: true })
    this.#persistence = persist ? { type: "pending", file: join(sessionDir, `${id}.jsonl`) } : { type: "memory" }
  }

  static create(paths: ZiPaths, options: NewSessionOptions = {}): SessionManager {
    return new SessionManager(paths.cwd, paths.sessionDir, options.sessionId, options.persist)
  }

  static inMemory(cwd = process.cwd(), sessionId?: string): SessionManager {
    return new SessionManager(resolveZiPath(cwd), "", sessionId, false)
  }

  static open(file: string): SessionManager {
    const resolvedFile = resolveZiPath(file)
    const loaded = loadJournal(resolvedFile, "active")
    const manager = new SessionManager(
      resolveZiPath(loaded.header.cwd),
      dirname(resolvedFile),
      loaded.header.id,
      false,
      { ...loaded.header, cwd: resolveZiPath(loaded.header.cwd) }
    )
    manager.#persistence = {
      type: "durable",
      file: resolvedFile,
      ...(loaded.appendRepair ? { appendRepair: loaded.appendRepair } : {})
    }
    manager.#entries.push(...loaded.entries)
    manager.#residentRecordBytes.push(...loaded.recordBytes)
    manager.#promptHistory.push(...loaded.promptHistory)
    manager.#promptHistoryBytes = loaded.promptHistoryBytes
    manager.#leafId = loaded.leafId
    manager.#entryCount = loaded.entryCount
    manager.#journalBytes = loaded.journalBytes
    manager.#imageBlobBytes = loaded.imageBlobBytes
    manager.#customEntries.push(...loaded.customEntries)
    manager.#customStateBytes = loaded.customStateBytes
    for (const [digest, bytes] of loaded.imageBlobs) manager.#imageBlobs.set(digest, bytes)
    manager.#model = loaded.model
    manager.#thinkingLevel = loaded.thinkingLevel
    manager.#rebuildPresentationMessages()
    return manager
  }

  static async list(paths: ZiPaths, options: SessionListOptions = {}): Promise<SessionListResult> {
    const limit = options.limit ?? maxSessionListResults
    if (!Number.isInteger(limit) || limit < 1 || limit > maxSessionListResults) {
      throw new Error(`Session list limit must be between 1 and ${maxSessionListResults}`)
    }

    const files: string[] = []
    try {
      const directory = await opendir(paths.sessionDir)
      for await (const entry of directory) {
        if (!entry.isFile() || !entry.name.endsWith(".jsonl")) continue
        files.push(join(paths.sessionDir, entry.name))
        if (files.length > maxSessionListCandidates) {
          throw new Error(`Session directory cannot contain more than ${maxSessionListCandidates} session files`)
        }
      }
    } catch (cause) {
      if (isMissingFile(cause)) return emptySessionList()
      throw cause
    }

    const candidates: Array<{ path: string; size: number; modifiedMs: number }> = []
    for (let index = 0; index < files.length; index += sessionListConcurrency) {
      // Batches bound concurrent metadata descriptors without serializing the whole catalog.
      // oxlint-disable-next-line no-await-in-loop
      const batch = await Promise.all(
        files.slice(index, index + sessionListConcurrency).map(async path => {
          try {
            const metadata = await stat(path)
            return metadata.isFile() ? { path, size: metadata.size, modifiedMs: metadata.mtimeMs } : undefined
          } catch {
            return undefined
          }
        })
      )
      for (const candidate of batch) if (candidate) candidates.push(candidate)
    }
    candidates.sort((left, right) => right.modifiedMs - left.modifiedMs || left.path.localeCompare(right.path))

    const selected = candidates.slice(0, maxSessionListResults)
    const loaded: SessionInfo[] = []
    let invalid = 0
    let filtered = 0
    for (let index = 0; index < selected.length; index += sessionListConcurrency) {
      // Preview reads use the same fixed descriptor bound.
      // oxlint-disable-next-line no-await-in-loop
      const batch = await Promise.all(
        selected.slice(index, index + sessionListConcurrency).map(async candidate => {
          try {
            return await loadSessionInfo(candidate)
          } catch {
            return undefined
          }
        })
      )
      for (const info of batch) {
        if (!info) invalid++
        else if (info.cwd === paths.cwd) loaded.push(info)
        else filtered++
      }
    }
    const sessions = loaded.slice(0, limit)
    return Object.freeze({
      sessions: Object.freeze(sessions),
      invalid,
      omitted:
        filtered + Math.max(0, candidates.length - selected.length) + Math.max(0, loaded.length - sessions.length)
    })
  }

  static async continueRecent(paths: ZiPaths): Promise<SessionManager> {
    const listed = await SessionManager.list(paths, { limit: 1 })
    const recent = listed.sessions[0]
    return recent ? SessionManager.open(recent.path) : SessionManager.create(paths)
  }

  appendMessage(message: AgentMessage): MessageEntry {
    if (!isAgentMessage(message)) throw new Error("Invalid session message")
    if (message.role === "custom") throw new Error("Custom messages must use appendCustomMessage()")
    return this.#append({ type: "message", message })
  }

  appendCustomEntry(customType: string, data?: SessionJson): CustomEntry {
    validateCustomType(customType)
    if (data === undefined) return this.#append({ type: "custom", customType })
    return this.#append({ type: "custom", customType, data: snapshotSessionJson(data) })
  }

  appendCustomMessage(message: CustomMessageInput): CustomMessageEntry {
    const snapshot = snapshotCustomMessage(message)
    return this.#append(
      snapshot.details === undefined
        ? {
            type: "custom_message",
            customType: snapshot.customType,
            content: snapshot.content,
            display: snapshot.display
          }
        : {
            type: "custom_message",
            customType: snapshot.customType,
            content: snapshot.content,
            display: snapshot.display,
            details: snapshot.details
          }
    )
  }

  appendModelChange(provider: string, modelId: string): SessionEntry {
    return this.#append({ type: "model_change", provider, modelId })
  }

  appendThinkingLevelChange(thinkingLevel: ThinkingLevel): SessionEntry {
    return this.#append({ type: "thinking_level_change", thinkingLevel })
  }

  appendRetry(failedEntryId: string, attempt: number): RetryEntry {
    return this.#append({ type: "retry", failedEntryId, attempt })
  }

  appendCompaction(data: Omit<CompactionEntryData, "type">): CompactionEntry {
    return this.#append({ type: "compaction", ...data })
  }

  appendSubagent(data: SubagentEntryInput): SubagentEntry {
    const entry = { type: "subagent" as const, ...data } as SubagentEntryData
    validateSubagentEntryData(entry)
    return this.#append(entry)
  }

  subagentEntries(): readonly SubagentEntry[] {
    return this.entries().filter((entry): entry is SubagentEntry => entry.type === "subagent")
  }

  /** Materializes the complete journal. Runtime policy should consume retainedEntries(). */
  entries(): readonly SessionEntry[] {
    if (this.#entryCount === this.#entries.length) return this.#entries
    if (this.#persistence.type === "durable") return loadJournal(this.#persistence.file, "all").entries

    const entries: SessionEntry[] = []
    visitSessionColdLines(this.#coldMemory, line => {
      entries.push(hydrateStoredEntry(parseStoredEntry(line, "<memory>", this.header.version), undefined))
    })
    entries.push(...this.#entries)
    validateJournal(entries, "<memory>")
    return entries
  }

  retainedEntries(): readonly SessionEntry[] {
    return this.#entries
  }

  messages(): AgentMessage[] {
    return this.entries().flatMap(entry => (entry.type === "message" ? [entry.message] : []))
  }

  buildSessionContext(): SessionContext {
    return {
      messages: this.activeMessages(),
      ...(this.#model ? { model: this.#model } : {}),
      ...(this.#thinkingLevel ? { thinkingLevel: this.#thinkingLevel } : {})
    }
  }

  activeEntries(): readonly SessionEntry[] {
    return projectSessionEntries(this.#entries, "context")
  }

  activeMessages(): AgentMessage[] {
    return projectMessages(this.activeEntries(), "context")
  }

  presentationMessages(): readonly AgentMessage[] {
    return this.#presentationMessages
  }

  customEntries(customType: string): readonly CustomEntry[] {
    validateCustomType(customType)
    return this.#customEntries.filter(entry => entry.customType === customType)
  }

  latestCompaction(): CompactionEntry | undefined {
    return this.#entries.findLast((entry): entry is CompactionEntry => entry.type === "compaction")
  }

  latestPromptHistoryEntry(): SessionPromptHistoryEntry | undefined {
    return clonePromptHistory(this.#promptHistory.at(-1))
  }

  olderPromptHistoryEntry(entryId: string): SessionPromptHistoryEntry | undefined {
    const index = this.#promptHistory.findIndex(entry => entry.entryId === entryId)
    return index > 0 ? clonePromptHistory(this.#promptHistory[index - 1]) : undefined
  }

  activeUsageAnchorIndex(): number {
    const markerIndex = this.#entries.findLastIndex(entry => entry.type === "compaction")
    if (markerIndex < 0) return 0
    const active = this.activeEntries()
    const afterMarker = new Set(this.#entries.slice(markerIndex + 1).map(entry => entry.id))
    const firstAfterMarker = active.findIndex(entry => afterMarker.has(entry.id))
    return firstAfterMarker < 0 ? active.length : firstAfterMarker
  }

  get memoryDiagnostics(): SessionJournalMemoryDiagnostics {
    return {
      entries: this.#entryCount,
      residentEntries: this.#entries.length,
      coldEntries: this.#entryCount - this.#entries.length,
      journalBytes: this.#journalBytes,
      residentEntryBytes: this.#residentRecordBytes.reduce((total, bytes) => total + bytes, 0),
      imageBlobBytes: this.#imageBlobBytes,
      customStateEntries: this.#customEntries.length,
      customStateBytes: this.#customStateBytes,
      coldMemoryBytes: sessionColdBytes(this.#coldMemory),
      coldMemoryLogicalBytes: sessionColdLogicalBytes(this.#coldMemory),
      coldMemoryBlocks: this.#coldMemory.length
    }
  }

  get sessionId(): string {
    return this.header.id
  }

  get file(): string | undefined {
    return this.#persistence.type === "memory" ? undefined : this.#persistence.file
  }

  get sessionDir(): string {
    return this.#persistence.type === "memory" ? "" : dirname(this.#persistence.file)
  }

  async discardPersistence(): Promise<void> {
    const file = this.file
    if (!file) return
    const outcomes = await Promise.allSettled([unlink(file), rm(blobDirectory(file), { recursive: true, force: true })])
    const failure = outcomes.find((outcome): outcome is PromiseRejectedResult => outcome.status === "rejected")
    if (failure && !isMissingFile(failure.reason)) throw failure.reason
  }

  #append<Entry extends SessionEntryData>(entry: Entry): SessionEntryBase & Entry {
    const next = {
      ...entry,
      id: crypto.randomUUID(),
      parentId: this.#leafId,
      timestamp: new Date().toISOString()
    } as SessionEntryBase & Entry
    validateNextEntry(next, this.#entries, this.file ?? "<memory>")
    if (next.type === "custom") freezeCustomEntry(next)
    else if (next.type === "custom_message") freezeCustomMessageEntry(next)

    const customStateBytes = next.type === "custom" ? serializedCustomStateBytes(next) : 0
    if (
      next.type === "custom" &&
      (this.#customEntries.length === maxCustomStateEntries ||
        this.#customStateBytes + customStateBytes > maxCustomStateBytes)
    ) {
      throw new CustomStateCapacityError()
    }

    const prepared = prepareRecord(next, this.header.version, this.#persistence.type !== "memory")
    const newBlobBytes = additionalBlobBytes(prepared.blobs, this.#imageBlobs)
    if (
      this.#journalBytes + prepared.bytes > maxSessionFileBytes ||
      this.#journalBytes + prepared.bytes + this.#imageBlobBytes + newBlobBytes > maxSessionStorageBytes
    ) {
      throw new SessionCapacityError()
    }

    const preparedCompaction = next.type === "compaction" ? this.#prepareCompaction(next) : undefined
    this.#persist(next, prepared)
    this.#entries.push(next)
    this.#residentRecordBytes.push(prepared.bytes)
    this.#entryCount++
    this.#journalBytes += prepared.bytes
    for (const blob of prepared.blobs.values()) {
      if (this.#imageBlobs.has(blob.sha256)) continue
      this.#imageBlobs.set(blob.sha256, blob.bytes)
      this.#imageBlobBytes += blob.bytes
    }
    if (next.type === "custom") {
      this.#customEntries.push(next)
      this.#customStateBytes += customStateBytes
    }
    this.#updatePresentationMessages(next)
    this.#considerPromptHistoryEntry(next)
    this.#considerSessionContextEntry(next)
    this.#leafId = next.id
    if (preparedCompaction) this.#pruneCompactedPrefix(preparedCompaction)
    return next
  }

  #updatePresentationMessages(entry: SessionEntry): void {
    if (entry.type === "compaction") {
      this.#rebuildPresentationMessages()
      return
    }
    const message = sessionEntryToPresentationMessage(entry)
    if (message) this.#presentationMessages.push(message)
  }

  #rebuildPresentationMessages(): void {
    this.#presentationMessages = projectMessages(projectSessionEntries(this.#entries, "presentation"), "presentation")
  }

  #considerPromptHistoryEntry(entry: SessionEntry): void {
    if (entry.type !== "message" || entry.message.role !== "user") return
    const text = promptHistoryText(entry.message.content)
    if (text === undefined || this.#promptHistory.at(-1)?.text === text) return
    this.#promptHistory.push({ entryId: entry.id, text })
    this.#promptHistoryBytes += Buffer.byteLength(text)
    while (
      this.#promptHistory.length > maxSessionPromptHistoryEntries ||
      this.#promptHistoryBytes > maxSessionPromptHistoryBytes
    ) {
      const removed = this.#promptHistory.shift()
      if (removed) this.#promptHistoryBytes -= Buffer.byteLength(removed.text)
    }
  }

  #considerSessionContextEntry(entry: SessionEntry): void {
    if (entry.type === "model_change") this.#model = { provider: entry.provider, modelId: entry.modelId }
    else if (entry.type === "thinking_level_change") this.#thinkingLevel = entry.thinkingLevel
    else if (entry.type === "message" && entry.message.role === "assistant") {
      this.#model = { provider: entry.message.provider, modelId: entry.message.model }
    }
  }

  #prepareCompaction(marker: CompactionEntry): PreparedCompaction {
    const boundary = this.#entries.findIndex(entry => entry.id === marker.firstKeptEntryId)
    return {
      boundary,
      coldBlocks:
        boundary > 0 && this.#persistence.type === "memory"
          ? appendSessionColdEntries(this.#coldMemory, this.#entries.slice(0, boundary))
          : undefined
    }
  }

  #pruneCompactedPrefix(compaction: PreparedCompaction): void {
    if (compaction.boundary <= 0) return
    if (compaction.coldBlocks) this.#coldMemory = compaction.coldBlocks
    this.#entries.splice(0, compaction.boundary)
    this.#residentRecordBytes.splice(0, compaction.boundary)
  }

  #persist(next: SessionEntry, prepared: PreparedRecord): void {
    const persistence = this.#persistence
    if (persistence.type === "memory") return
    if (persistence.type === "durable") {
      const created = writeBlobs(blobDirectory(persistence.file), prepared.blobs, this.#imageBlobs, false)
      try {
        if (persistence.appendRepair?.type === "truncate")
          truncateSync(persistence.file, persistence.appendRepair.offset)
        else if (persistence.appendRepair?.type === "newline") appendFileSync(persistence.file, "\n")
        appendFileSync(persistence.file, prepared.line)
      } catch (cause) {
        for (const path of created) rmSync(path, { force: true })
        throw cause
      }
      if (persistence.appendRepair) this.#persistence = { type: "durable", file: persistence.file }
      return
    }

    if (
      next.type !== "custom" &&
      next.type !== "custom_message" &&
      next.type !== "subagent" &&
      (next.type !== "message" || next.message.role !== "assistant")
    ) {
      return
    }

    const entries = [...this.#entries, next]
    const records = entries.map(entry => prepareRecord(entry, this.header.version, true))
    const blobs = mergePreparedBlobs(records)
    const created = writeBlobs(blobDirectory(persistence.file), blobs, new Map(), true)
    try {
      const handle = openSync(persistence.file, "wx", 0o600)
      try {
        writeFileSync(handle, `${JSON.stringify(this.header)}\n`)
        for (const record of records) writeFileSync(handle, record.line)
      } finally {
        closeSync(handle)
      }
    } catch (cause) {
      rmSync(persistence.file, { force: true })
      for (const path of created) rmSync(path, { force: true })
      throw cause
    }
    this.#persistence = { type: "durable", file: persistence.file }
  }
}

async function loadSessionInfo(candidate: {
  path: string
  size: number
  modifiedMs: number
}): Promise<SessionInfo | undefined> {
  if (candidate.size === 0 || candidate.size > maxSessionFileBytes) return undefined
  const length = Math.min(candidate.size, maxSessionListPreviewBytes)
  const handle = await open(candidate.path, "r")
  let bytesRead = 0
  const buffer = Buffer.allocUnsafe(length)
  try {
    bytesRead = (await handle.read(buffer, 0, length, 0)).bytesRead
  } finally {
    await handle.close()
  }

  const content = buffer.subarray(0, bytesRead).toString("utf8")
  const lines = content.split("\n")
  if (candidate.size > bytesRead && !content.endsWith("\n")) lines.pop()
  if (lines.at(-1) === "") lines.pop()
  try {
    const header = parseHeader(lines.shift() ?? "null", candidate.path)
    let firstMessage = ""
    for (let index = 0; index < lines.length; index++) {
      const line = lines[index]
      if (!line) continue
      let entry: StoredSessionEntry
      try {
        entry = parseStoredEntry(line, candidate.path, header.version)
      } catch (cause) {
        if (candidate.size === bytesRead && index === lines.length - 1 && !content.endsWith("\n")) break
        throw cause
      }
      if (entry.type === "message" && entry.message.role === "user") {
        firstMessage = sessionMessageText(entry.message.content)
        break
      }
    }
    const created = Date.parse(header.timestamp)
    if (!Number.isFinite(created)) return undefined
    return Object.freeze({
      path: candidate.path,
      id: header.id,
      cwd: resolveZiPath(header.cwd),
      createdAt: new Date(created).toISOString(),
      modifiedAt: new Date(candidate.modifiedMs).toISOString(),
      firstMessage
    })
  } catch {
    return undefined
  }
}

function loadJournal(file: string, retention: "active" | "all"): LoadedJournal {
  const metadata = statSync(file)
  if (metadata.size > maxSessionFileBytes) {
    throw new Error(`Session file cannot exceed ${maxSessionFileBytes} bytes: ${file}`)
  }

  const handle = openSync(file, "r")
  let validBytes = metadata.size
  let repair: "none" | "truncate" | "newline" = "none"
  let header: SessionHeader | undefined
  const references = new Map<string, EntryReference>()
  const retryFailures = new Set<string>()
  const promptHistory: SessionPromptHistoryEntry[] = []
  let promptHistoryBytes = 0
  const imageBlobs = new Map<string, number>()
  let imageBlobBytes = 0
  const customEntries: CustomEntry[] = []
  let customStateBytes = 0
  let previous: EntryReference | undefined
  let entryCount = 0
  let latestBoundaryId: string | undefined
  let model: SessionModel | undefined
  let thinkingLevel: ThinkingLevel | undefined

  try {
    let firstRecord = true
    for (const record of readJournalRecords(handle, metadata.size)) {
      if (firstRecord) {
        firstRecord = false
        header = parseHeader(record.line || "null", file)
        continue
      }
      if (!record.line) continue

      let entry: StoredSessionEntry
      try {
        entry = parseStoredEntry(record.line, file, header!.version)
      } catch (cause) {
        if (!record.terminated && record.end === metadata.size) {
          validBytes = record.start
          repair = "truncate"
          break
        }
        throw cause
      }

      if (!record.terminated && record.end === metadata.size) repair = "newline"
      const reference = validateStoredJournalEntry(entry, entryCount, previous, references, retryFailures, file)
      references.set(entry.id, reference)
      previous = reference
      entryCount++

      if (entry.type === "compaction") latestBoundaryId = entry.firstKeptEntryId
      if (entry.type === "custom") {
        customEntries.push(freezeCustomEntry(entry))
        customStateBytes += serializedCustomStateBytes(entry)
        if (customEntries.length > maxCustomStateEntries || customStateBytes > maxCustomStateBytes) {
          throw new CustomStateCapacityError()
        }
      }
      if (entry.type === "model_change") model = { provider: entry.provider, modelId: entry.modelId }
      else if (entry.type === "thinking_level_change") thinkingLevel = entry.thinkingLevel
      else if (entry.type === "message") {
        if (entry.message.role === "assistant") {
          model = { provider: String(entry.message.provider), modelId: String(entry.message.model) }
        } else if (entry.message.role === "user") {
          const text = promptHistoryText(entry.message.content)
          if (text !== undefined && promptHistory.at(-1)?.text !== text) {
            promptHistory.push({ entryId: entry.id, text })
            promptHistoryBytes += Buffer.byteLength(text)
            while (
              promptHistory.length > maxSessionPromptHistoryEntries ||
              promptHistoryBytes > maxSessionPromptHistoryBytes
            ) {
              const removed = promptHistory.shift()
              if (removed) promptHistoryBytes -= Buffer.byteLength(removed.text)
            }
          }
        }
      }
      if (entry.type === "message" || entry.type === "custom_message") {
        const content = entry.type === "message" ? entry.message.content : entry.content
        for (const image of storedImageReferences(content)) {
          const previousBytes = imageBlobs.get(image.blob.sha256)
          if (previousBytes !== undefined && previousBytes !== image.blob.bytes) {
            throw new Error(`Invalid session image reference: ${file}`)
          }
          if (previousBytes === undefined) {
            imageBlobs.set(image.blob.sha256, image.blob.bytes)
            imageBlobBytes += image.blob.bytes
          }
        }
      }
    }
    if (!header) throw new Error(`Invalid session header: ${file}`)

    verifyBlobs(file, imageBlobs)
    if (validBytes + (repair === "newline" ? 1 : 0) + imageBlobBytes > maxSessionStorageBytes) {
      throw new Error(`Session storage cannot exceed ${maxSessionStorageBytes} bytes: ${file}`)
    }

    const entries: SessionEntry[] = []
    const recordBytes: number[] = []
    let retain = retention === "all" || latestBoundaryId === undefined
    let firstRetainedRecord = true
    for (const record of readJournalRecords(handle, validBytes)) {
      if (firstRetainedRecord) {
        firstRetainedRecord = false
        continue
      }
      if (!record.line) continue
      const stored = parseStoredEntry(record.line, file, header.version)
      if (!retain && stored.id === latestBoundaryId) retain = true
      if (!retain) continue
      entries.push(hydrateStoredEntry(stored, file))
      recordBytes.push(record.bytes)
    }
    if (!retain) throw new Error(`Invalid compaction boundary: ${file}`)

    if (repair === "newline" && validBytes === maxSessionFileBytes) {
      throw new Error(`Session file cannot exceed ${maxSessionFileBytes} bytes: ${file}`)
    }
    const journalBytes = repair === "newline" ? validBytes + 1 : validBytes

    return {
      header,
      entries,
      recordBytes,
      promptHistory,
      promptHistoryBytes,
      model,
      thinkingLevel,
      leafId: previous?.id ?? null,
      entryCount,
      journalBytes,
      imageBlobs,
      imageBlobBytes,
      customEntries,
      customStateBytes,
      ...(repair === "truncate"
        ? { appendRepair: { type: "truncate" as const, offset: validBytes } }
        : repair === "newline"
          ? { appendRepair: { type: "newline" as const } }
          : {})
    }
  } finally {
    closeSync(handle)
  }
}

function* readJournalRecords(handle: number, size: number): Generator<JournalRecord> {
  const readBuffer = Buffer.allocUnsafe(sessionReadBufferBytes)
  const parts: Buffer[] = []
  let partsBytes = 0
  let position = 0
  let lineStart = 0

  while (position < size) {
    const requested = Math.min(readBuffer.length, size - position)
    const bytesRead = readSync(handle, readBuffer, 0, requested, position)
    if (bytesRead === 0) break
    const chunkStart = position
    position += bytesRead
    let segmentStart = 0
    let newline = readBuffer.indexOf(10, segmentStart)

    while (newline >= 0 && newline < bytesRead) {
      const segment = readBuffer.subarray(segmentStart, newline)
      const lineBuffer =
        parts.length === 0 ? segment : Buffer.concat([...parts, segment], partsBytes + segment.byteLength)
      const end = chunkStart + newline + 1
      yield { line: decodeJournalLine(lineBuffer), bytes: end - lineStart, start: lineStart, end, terminated: true }
      parts.length = 0
      partsBytes = 0
      segmentStart = newline + 1
      lineStart = end
      newline = readBuffer.indexOf(10, segmentStart)
    }

    if (segmentStart < bytesRead) {
      const tail = Buffer.from(readBuffer.subarray(segmentStart, bytesRead))
      parts.push(tail)
      partsBytes += tail.byteLength
      if (partsBytes > maxSessionFileBytes) throw new Error("Session record exceeds the session file limit")
    }
  }

  if (partsBytes > 0) {
    const lineBuffer = parts.length === 1 ? parts[0]! : Buffer.concat(parts, partsBytes)
    yield {
      line: decodeJournalLine(lineBuffer),
      bytes: size - lineStart,
      start: lineStart,
      end: size,
      terminated: false
    }
  }
}

function decodeJournalLine(buffer: Buffer): string {
  try {
    return new TextDecoder("utf-8", { fatal: true }).decode(buffer)
  } catch {
    throw new Error("Session journal contains invalid UTF-8")
  }
}

function parseHeader(line: string, file: string): SessionHeader {
  const value = parseJson(line, "header", file)
  if (
    !isRecord(value) ||
    value.type !== "session" ||
    (value.version !== 1 && value.version !== 2) ||
    typeof value.id !== "string" ||
    !isValidTimestamp(value.timestamp) ||
    typeof value.cwd !== "string"
  ) {
    throw new Error(`Invalid session header: ${file}`)
  }
  return { type: value.type, version: value.version, id: value.id, timestamp: value.timestamp, cwd: value.cwd }
}

function parseStoredEntry(line: string, file: string, version: SessionFormatVersion): StoredSessionEntry {
  const value = parseJson(line, "entry", file)
  if (
    !isRecord(value) ||
    typeof value.id !== "string" ||
    (value.parentId !== null && typeof value.parentId !== "string") ||
    !isValidTimestamp(value.timestamp)
  ) {
    throw new Error(`Invalid session entry: ${file}`)
  }

  const base = { id: value.id, parentId: value.parentId, timestamp: value.timestamp }
  if (value.type === "message" && isStoredAgentMessage(value.message, version)) {
    return { ...base, type: value.type, message: value.message }
  }
  if (value.type === "model_change" && typeof value.provider === "string" && typeof value.modelId === "string") {
    return { ...base, type: value.type, provider: value.provider, modelId: value.modelId }
  }
  if (value.type === "thinking_level_change" && isThinkingLevel(value.thinkingLevel)) {
    return { ...base, type: value.type, thinkingLevel: value.thinkingLevel }
  }
  if (value.type === "retry" && typeof value.failedEntryId === "string" && isRetryAttempt(value.attempt)) {
    return { ...base, type: value.type, failedEntryId: value.failedEntryId, attempt: value.attempt }
  }
  if (value.type === "custom" && isStoredCustomEntry(value)) {
    return value.data === undefined
      ? { ...base, type: value.type, customType: value.customType }
      : { ...base, type: value.type, customType: value.customType, data: value.data }
  }
  if (value.type === "custom_message" && isStoredCustomMessageEntry(value, version)) {
    return {
      ...base,
      type: value.type,
      customType: value.customType,
      content: value.content,
      display: value.display,
      ...(value.details === undefined ? {} : { details: value.details })
    }
  }
  if (value.type === "subagent" && isSubagentEntryData(value)) {
    return { ...base, ...value }
  }
  if (value.type === "compaction" && isCompactionEntryData(value)) {
    return {
      ...base,
      type: value.type,
      reason: value.reason,
      summary: value.summary,
      firstKeptEntryId: value.firstKeptEntryId,
      tokensBefore: value.tokensBefore,
      estimatedTokensAfter: value.estimatedTokensAfter,
      details: value.details,
      ...(value.excludedFailureEntryId === undefined ? {} : { excludedFailureEntryId: value.excludedFailureEntryId })
    }
  }
  throw new Error(`Invalid session entry: ${file}`)
}

function hydrateStoredEntry(entry: StoredSessionEntry, file: string | undefined): SessionEntry {
  if (entry.type === "message") {
    const content = hydrateStoredContent(entry.message.content, file)
    const message = content === entry.message.content ? entry.message : { ...entry.message, content }
    if (!isAgentMessage(message)) throw new Error(`Invalid session message: ${file ?? "<memory>"}`)
    return { ...entry, message }
  }
  if (entry.type === "custom") return freezeCustomEntry(entry)
  if (entry.type === "custom_message") {
    const content = hydrateStoredContent(entry.content, file)
    if (!isRuntimeCustomMessageContent(content)) {
      throw new Error(`Invalid session message: ${file ?? "<memory>"}`)
    }
    return freezeCustomMessageEntry({ ...entry, content })
  }
  return entry
}

function hydrateStoredContent(content: unknown, file: string | undefined): unknown {
  if (!Array.isArray(content) || !content.some(isStoredImageReference)) return content
  if (!file) throw new Error("In-memory session cannot reference an image blob")

  return content.map(part => {
    if (!isStoredImageReference(part)) return part
    const path = join(blobDirectory(file), part.blob.sha256)
    const data = readFileSync(path)
    if (data.byteLength !== part.blob.bytes || sha256(data) !== part.blob.sha256) {
      throw new Error(`Invalid session image blob: ${path}`)
    }
    return { type: "image" as const, mimeType: part.mimeType, data: data.toString("base64") }
  })
}

function validateStoredJournalEntry(
  entry: StoredSessionEntry,
  index: number,
  previous: EntryReference | undefined,
  references: ReadonlyMap<string, EntryReference>,
  retryFailures: Set<string>,
  file: string
): EntryReference {
  if (references.has(entry.id) || entry.parentId !== (previous?.id ?? null)) {
    throw new Error(`Invalid session entry: ${file}`)
  }

  if (entry.type === "retry") {
    if (
      previous?.id !== entry.failedEntryId ||
      previous.type !== "message" ||
      previous.role !== "assistant" ||
      previous.stopReason !== "error"
    ) {
      throw new Error(`Invalid retry failure reference: ${file}`)
    }
    retryFailures.add(entry.failedEntryId)
  } else if (entry.type === "compaction") {
    const firstKept = references.get(entry.firstKeptEntryId)
    if (
      !firstKept ||
      firstKept.index >= index ||
      !firstKept.contextVisible ||
      firstKept.role === "toolResult" ||
      retryFailures.has(firstKept.id) ||
      entry.excludedFailureEntryId === firstKept.id
    ) {
      throw new Error(`Invalid compaction boundary: ${file}`)
    }
    if (entry.excludedFailureEntryId !== undefined) {
      const failure = references.get(entry.excludedFailureEntryId)
      if (!failure || failure.role !== "assistant" || failure.stopReason !== "error") {
        throw new Error(`Invalid compaction failure reference: ${file}`)
      }
    }
  }

  return storedEntryReference(entry, index)
}

function storedEntryReference(entry: StoredSessionEntry, index: number): EntryReference {
  if (entry.type === "custom_message") {
    return { id: entry.id, index, type: entry.type, role: "custom", contextVisible: true }
  }
  if (entry.type === "message") {
    const excludeFromContext = entry.message.role === "bashExecution" && entry.message.excludeFromContext === true
    return {
      id: entry.id,
      index,
      type: entry.type,
      role: entry.message.role,
      stopReason: entry.message.stopReason,
      contextVisible: !excludeFromContext
    }
  }
  return { id: entry.id, index, type: entry.type, contextVisible: false }
}

function prepareRecord(entry: SessionEntry, version: SessionFormatVersion, externalizeImages: boolean): PreparedRecord {
  const blobs = new Map<string, PreparedBlob>()
  let stored: unknown = entry
  if (version === 2 && externalizeImages) {
    if (entry.type === "message" && "content" in entry.message && Array.isArray(entry.message.content)) {
      const content = externalizeContentImages(entry.message.content, blobs)
      if (content !== entry.message.content) stored = { ...entry, message: { ...entry.message, content } }
    } else if (entry.type === "custom_message" && Array.isArray(entry.content)) {
      const content = externalizeContentImages(entry.content, blobs)
      if (content !== entry.content) stored = { ...entry, content }
    }
  }
  const line = `${JSON.stringify(stored)}\n`
  return { line, bytes: Buffer.byteLength(line), blobs }
}

function externalizeContentImages(content: readonly unknown[], blobs: Map<string, PreparedBlob>): readonly unknown[] {
  if (!content.some(part => isRecord(part) && part.type === "image")) return content
  return content.map(part => {
    if (
      !isRecord(part) ||
      part.type !== "image" ||
      typeof part.mimeType !== "string" ||
      typeof part.data !== "string"
    ) {
      return part
    }
    const data = decodeBase64(part.data)
    const digest = sha256(data)
    blobs.set(digest, { sha256: digest, bytes: data.byteLength, data })
    return { type: "image" as const, mimeType: part.mimeType, blob: { sha256: digest, bytes: data.byteLength } }
  })
}

function decodeBase64(value: string): Buffer {
  if (!/^[A-Za-z0-9+/]*={0,2}$/.test(value)) throw new Error("Invalid base64 session image")
  const data = Buffer.from(value, "base64")
  if (data.toString("base64").replace(/=+$/u, "") !== value.replace(/=+$/u, "")) {
    throw new Error("Invalid base64 session image")
  }
  return data
}

function mergePreparedBlobs(records: readonly PreparedRecord[]): Map<string, PreparedBlob> {
  const blobs = new Map<string, PreparedBlob>()
  for (const record of records) for (const [digest, blob] of record.blobs) blobs.set(digest, blob)
  return blobs
}

function additionalBlobBytes(blobs: ReadonlyMap<string, PreparedBlob>, known: ReadonlyMap<string, number>): number {
  let bytes = 0
  for (const blob of blobs.values()) if (!known.has(blob.sha256)) bytes += blob.bytes
  return bytes
}

function writeBlobs(
  directory: string,
  blobs: ReadonlyMap<string, PreparedBlob>,
  known: ReadonlyMap<string, number>,
  force: boolean
): string[] {
  const selected = [...blobs.values()].filter(blob => force || !known.has(blob.sha256))
  if (selected.length === 0) return []
  mkdirSync(directory, { recursive: true, mode: 0o700 })
  const created: string[] = []
  try {
    for (const blob of selected) {
      const path = join(directory, blob.sha256)
      if (writeBlob(path, blob)) created.push(path)
    }
    return created
  } catch (cause) {
    for (const path of created) rmSync(path, { force: true })
    throw cause
  }
}

function writeBlob(path: string, blob: PreparedBlob): boolean {
  let existing
  try {
    existing = statSync(path)
  } catch (cause) {
    if (!isMissingFile(cause)) throw cause
  }
  if (existing) {
    if (existing.size !== blob.bytes || hashFile(path) !== blob.sha256) {
      throw new Error(`Invalid existing session image blob: ${path}`)
    }
    return false
  }

  const pending = `${path}.${process.pid}.${crypto.randomUUID()}.tmp`
  writeFileSync(pending, blob.data, { flag: "wx", mode: 0o600 })
  try {
    linkSync(pending, path)
    return true
  } catch (cause) {
    if (!isAlreadyExists(cause)) throw cause
    const metadata = statSync(path)
    if (metadata.size !== blob.bytes || hashFile(path) !== blob.sha256) {
      throw new Error(`Invalid existing session image blob: ${path}`, { cause })
    }
    return false
  } finally {
    rmSync(pending, { force: true })
  }
}

function verifyBlobs(file: string, blobs: ReadonlyMap<string, number>): void {
  const directory = blobDirectory(file)
  for (const [digest, bytes] of blobs) {
    const path = join(directory, digest)
    let metadata
    try {
      metadata = statSync(path)
    } catch {
      throw new Error(`Missing session image blob: ${path}`)
    }
    if (!metadata.isFile() || metadata.size !== bytes || hashFile(path) !== digest) {
      throw new Error(`Invalid session image blob: ${path}`)
    }
  }
}

function hashFile(path: string): string {
  const handle = openSync(path, "r")
  const buffer = Buffer.allocUnsafe(sessionReadBufferBytes)
  const hash = createHash("sha256")
  try {
    for (;;) {
      const bytesRead = readSync(handle, buffer, 0, buffer.length, null)
      if (bytesRead === 0) return hash.digest("hex")
      hash.update(buffer.subarray(0, bytesRead))
    }
  } finally {
    closeSync(handle)
  }
}

function blobDirectory(file: string): string {
  return file.endsWith(".jsonl") ? `${file.slice(0, -".jsonl".length)}.blobs` : `${file}.blobs`
}

function sha256(data: Uint8Array): string {
  return createHash("sha256").update(data).digest("hex")
}

function clonePromptHistory(entry: SessionPromptHistoryEntry | undefined): SessionPromptHistoryEntry | undefined {
  return entry ? { entryId: entry.entryId, text: entry.text } : undefined
}

function promptHistoryText(content: unknown): string | undefined {
  if (typeof content === "string") {
    if (Buffer.byteLength(content) > maxSessionPromptHistoryEntryBytes) return undefined
    const text = content.trim()
    return text ? text : undefined
  }
  if (!Array.isArray(content)) return undefined

  const parts: string[] = []
  let bytes = 0
  for (const part of content) {
    if (!isRecord(part) || part.type !== "text" || typeof part.text !== "string") continue
    bytes += Buffer.byteLength(part.text)
    if (bytes > maxSessionPromptHistoryEntryBytes) return undefined
    parts.push(part.text)
  }
  const text = parts.join("").trim()
  return text ? text : undefined
}

function sessionMessageText(content: unknown): string {
  const text =
    typeof content === "string"
      ? content
      : Array.isArray(content)
        ? content
            .filter(
              (part): part is Record<string, unknown> & { text: string } =>
                isRecord(part) && part.type === "text" && typeof part.text === "string"
            )
            .map(part => part.text)
            .join(" ")
        : ""
  const normalized = text.replace(/\s+/g, " ").trim()
  return normalized.length <= maxSessionFirstMessageLength
    ? normalized
    : `${normalized.slice(0, maxSessionFirstMessageLength - 1)}…`
}

function emptySessionList(): SessionListResult {
  return Object.freeze({ sessions: Object.freeze([]), invalid: 0, omitted: 0 })
}

function isMissingFile(cause: unknown): boolean {
  return isRecord(cause) && cause.code === "ENOENT"
}

function isAlreadyExists(cause: unknown): boolean {
  return isRecord(cause) && cause.code === "EEXIST"
}

function isStoredAgentMessage(value: unknown, version: SessionFormatVersion): value is StoredAgentMessage {
  if (!isRecord(value) || typeof value.timestamp !== "number") return false
  switch (value.role) {
    case "user":
      return typeof value.content === "string" || isStoredContentArray(value.content, version)
    case "assistant":
      return (
        isStoredContentArray(value.content, version) &&
        typeof value.api === "string" &&
        typeof value.provider === "string" &&
        typeof value.model === "string" &&
        isUsage(value.usage) &&
        isStopReason(value.stopReason)
      )
    case "toolResult":
      return (
        typeof value.toolCallId === "string" &&
        typeof value.toolName === "string" &&
        isStoredContentArray(value.content, version) &&
        typeof value.isError === "boolean"
      )
    case "bashExecution":
      return (
        typeof value.command === "string" &&
        typeof value.output === "string" &&
        (value.exitCode === undefined || typeof value.exitCode === "number") &&
        typeof value.cancelled === "boolean" &&
        typeof value.truncated === "boolean"
      )
    case "custom":
      return (
        typeof value.customType === "string" &&
        (typeof value.content === "string" || isStoredContentArray(value.content, version)) &&
        typeof value.display === "boolean"
      )
    case "branchSummary":
      return typeof value.summary === "string" && typeof value.fromId === "string"
    case "compactionSummary":
      return (
        typeof value.summary === "string" &&
        typeof value.tokensBefore === "number" &&
        typeof value.estimatedTokensAfter === "number"
      )
    default:
      return false
  }
}

function isAgentMessage(value: unknown): value is AgentMessage {
  return isStoredAgentMessage(value, 1)
}

function freezeCustomEntry(entry: CustomEntry): CustomEntry {
  if (entry.data !== undefined) freezeSessionJson(entry.data)
  return Object.freeze(entry)
}

function freezeCustomMessageEntry(entry: CustomMessageEntry): CustomMessageEntry {
  if (Array.isArray(entry.content)) {
    for (const part of entry.content) Object.freeze(part)
    Object.freeze(entry.content)
  }
  if (entry.details !== undefined) freezeSessionJson(entry.details)
  return Object.freeze(entry)
}

function freezeSessionJson(value: SessionJson): void {
  if (value === null || typeof value !== "object") return
  const pending: object[] = [value]
  while (pending.length > 0) {
    const current = pending.pop()!
    for (const child of Object.values(current)) {
      if (child !== null && typeof child === "object") pending.push(child)
    }
    Object.freeze(current)
  }
}

function snapshotCustomMessage(value: unknown): CustomMessageInput {
  let snapshot: unknown
  try {
    snapshot = structuredClone(value)
  } catch {
    throw new Error("Invalid custom message")
  }
  validateCustomMessageInput(snapshot)
  return snapshot
}

function snapshotSessionJson(value: unknown): SessionJson {
  let snapshot: unknown
  try {
    snapshot = structuredClone(value)
  } catch {
    throw new Error("Invalid session entry")
  }
  if (!isSessionJson(snapshot)) throw new Error("Invalid session entry")
  return snapshot
}

export function validateCustomMessageInput(value: unknown): asserts value is CustomMessageInput {
  if (!isRecord(value)) throw new Error("Invalid custom message")
  const candidate = {
    type: "custom_message",
    id: "validation",
    parentId: null,
    timestamp: new Date(0).toISOString(),
    customType: value.customType,
    content: value.content,
    display: value.display,
    ...(value.details === undefined ? {} : { details: value.details })
  }
  if (
    !hasOnlyKeys(value, ["customType", "content", "display", "details"]) ||
    !isStoredCustomMessageEntry(candidate, 1)
  ) {
    throw new Error("Invalid custom message")
  }
}

function isStoredCustomEntry(value: unknown): value is Record<string, unknown> & CustomEntryData {
  return (
    isRecord(value) &&
    hasOnlyKeys(value, ["type", "id", "parentId", "timestamp", "customType", "data"]) &&
    isCustomType(value.customType) &&
    (value.data === undefined || isSessionJson(value.data))
  )
}

function isStoredCustomMessageEntry(
  value: unknown,
  version: SessionFormatVersion
): value is Record<string, unknown> & Omit<StoredCustomMessageEntry, keyof SessionEntryBase> {
  return (
    isRecord(value) &&
    hasOnlyKeys(value, ["type", "id", "parentId", "timestamp", "customType", "content", "display", "details"]) &&
    isCustomType(value.customType) &&
    isStoredCustomMessageContent(value.content, version) &&
    serializedBytesAtMost(value.content, maxCustomMessageBytes) &&
    typeof value.display === "boolean" &&
    (value.details === undefined || isSessionJson(value.details))
  )
}

function isRuntimeCustomMessageContent(value: unknown): value is CustomMessageContent {
  return isStoredCustomMessageContent(value, 1)
}

function isStoredCustomMessageContent(
  value: unknown,
  version: SessionFormatVersion
): value is StoredCustomMessageContent {
  return (
    typeof value === "string" ||
    (Array.isArray(value) &&
      value.every(part => {
        if (!isRecord(part)) return false
        if (part.type === "text") return hasOnlyKeys(part, ["type", "text"]) && typeof part.text === "string"
        if (part.type !== "image" || typeof part.mimeType !== "string") return false
        if (typeof part.data === "string") {
          return hasOnlyKeys(part, ["type", "mimeType", "data"]) && isValidBase64(part.data)
        }
        return (
          version === 2 &&
          hasOnlyKeys(part, ["type", "mimeType", "blob"]) &&
          isStoredImageReference(part) &&
          hasOnlyKeys(part.blob, ["sha256", "bytes"])
        )
      }))
  )
}

function isCustomType(value: unknown): value is string {
  return typeof value === "string" && Buffer.byteLength(value) <= maxCustomTypeBytes && customTypePattern.test(value)
}

export function validateCustomType(value: unknown): asserts value is string {
  if (!isCustomType(value)) {
    throw new Error(`Custom type must match ${customTypePattern} and fit in ${maxCustomTypeBytes} bytes`)
  }
}

export function isSessionJson(value: unknown): value is SessionJson {
  try {
    validateSessionJson(value)
    return serializedBytes(value) <= maxCustomJsonBytes
  } catch {
    return false
  }
}

function validateSessionJson(root: unknown): asserts root is SessionJson {
  type Visit =
    | { readonly type: "value"; readonly value: unknown; readonly depth: number }
    | { readonly type: "leave"; readonly value: object }
  const pending: Visit[] = [{ type: "value", value: root, depth: 1 }]
  const ancestors = new Set<object>()
  let nodes = 0
  while (pending.length > 0) {
    const visit = pending.pop()!
    if (visit.type === "leave") {
      ancestors.delete(visit.value)
      continue
    }
    const { value, depth } = visit
    nodes++
    if (nodes > maxCustomJsonNodes || depth > maxCustomJsonDepth) throw new Error("Custom JSON exceeds its bounds")
    if (value === null || typeof value === "string" || typeof value === "boolean") continue
    if (typeof value === "number" && Number.isFinite(value)) continue
    if (typeof value !== "object" || ancestors.has(value)) throw new Error("Custom data must be JSON")
    ancestors.add(value)
    pending.push({ type: "leave", value })
    if (Array.isArray(value)) {
      for (const item of value) pending.push({ type: "value", value: item, depth: depth + 1 })
      continue
    }
    if (
      !isRecord(value) ||
      (Object.getPrototypeOf(value) !== Object.prototype && Object.getPrototypeOf(value) !== null)
    ) {
      throw new Error("Custom data must be JSON")
    }
    for (const item of Object.values(value)) pending.push({ type: "value", value: item, depth: depth + 1 })
  }
}

function serializedBytes(value: unknown): number {
  const serialized = JSON.stringify(value)
  if (serialized === undefined) throw new Error("Custom data must be JSON")
  return Buffer.byteLength(serialized)
}

function serializedBytesAtMost(value: unknown, maximum: number): boolean {
  try {
    return serializedBytes(value) <= maximum
  } catch {
    return false
  }
}

function serializedCustomStateBytes(entry: Pick<CustomEntry, "customType" | "data">): number {
  return serializedBytes(
    entry.data === undefined ? { customType: entry.customType } : { customType: entry.customType, data: entry.data }
  )
}

function hasOnlyKeys(value: Record<string, unknown>, allowed: readonly string[]): boolean {
  const keys = Object.keys(value)
  return keys.length <= allowed.length && keys.every(key => allowed.includes(key))
}

function isValidBase64(value: string): boolean {
  try {
    decodeBase64(value)
    return true
  } catch {
    return false
  }
}

function isStoredContentArray(value: unknown, version: SessionFormatVersion): boolean {
  return Array.isArray(value) && value.every(part => isStoredContent(part, version))
}

function isStoredContent(value: unknown, version: SessionFormatVersion): boolean {
  if (!isRecord(value)) return false
  if (value.type === "text") return typeof value.text === "string"
  if (value.type === "thinking") return typeof value.thinking === "string"
  if (value.type === "image") {
    return (
      typeof value.mimeType === "string" &&
      (typeof value.data === "string" || (version === 2 && isStoredImageReference(value)))
    )
  }
  return (
    value.type === "toolCall" &&
    typeof value.id === "string" &&
    typeof value.name === "string" &&
    isRecord(value.arguments)
  )
}

function isStoredImageReference(value: unknown): value is StoredImageReference {
  return (
    isRecord(value) &&
    value.type === "image" &&
    typeof value.mimeType === "string" &&
    value.data === undefined &&
    isRecord(value.blob) &&
    typeof value.blob.sha256 === "string" &&
    imageDigestPattern.test(value.blob.sha256) &&
    isNonNegativeInteger(value.blob.bytes)
  )
}

function storedImageReferences(content: unknown): StoredImageReference[] {
  return Array.isArray(content) ? content.filter(isStoredImageReference) : []
}

function isUsage(value: unknown): boolean {
  if (!isRecord(value) || !isRecord(value.cost)) return false
  return [
    value.input,
    value.output,
    value.cacheRead,
    value.cacheWrite,
    value.totalTokens,
    value.cost.input,
    value.cost.output,
    value.cost.cacheRead,
    value.cost.cacheWrite,
    value.cost.total
  ].every(item => typeof item === "number" && Number.isFinite(item) && item >= 0)
}

function isStopReason(value: unknown): boolean {
  return value === "stop" || value === "length" || value === "toolUse" || value === "error" || value === "aborted"
}

function isThinkingLevel(value: unknown): value is ThinkingLevel {
  return (
    value === "off" ||
    value === "minimal" ||
    value === "low" ||
    value === "medium" ||
    value === "high" ||
    value === "xhigh" ||
    value === "max"
  )
}

function isRetryAttempt(value: unknown): value is number {
  return typeof value === "number" && Number.isInteger(value) && value >= 1 && value <= maxRetryCount
}

function validateSubagentEntryData(value: unknown): asserts value is SubagentEntryData {
  if (!isSubagentEntryData(value)) throw new Error("Invalid native subagent journal entry")
}

function isSubagentEntryData(value: unknown): value is SubagentEntryData {
  if (!isRecord(value) || value.type !== "subagent" || !boundedString(value.agentId, 256)) return false
  switch (value.event) {
    case "starting":
      return boundedString(value.definitionName, 64)
    case "ready":
      return value.sessionId === undefined || boundedString(value.sessionId, 256)
    case "work_cycle_started":
      return positiveSafeInteger(value.workCycle)
    case "work_cycle_finished":
      return (
        positiveSafeInteger(value.workCycle) &&
        (value.status === "completed" || value.status === "failed" || value.status === "cancelled") &&
        boundedString(value.preview, maxSubagentJournalTextBytes, true) &&
        isNonNegativeInteger(value.originalBytes) &&
        isNonNegativeInteger(value.omittedBytes) &&
        typeof value.truncated === "boolean" &&
        isNonNegativeInteger(value.durationMs) &&
        (value.reason === undefined || boundedString(value.reason, maxSubagentJournalTextBytes, true)) &&
        (value.error === undefined || boundedString(value.error, maxSubagentJournalTextBytes, true))
      )
    case "closing":
      return boundedString(value.reason, 256)
    case "exited":
      return boundedString(value.outcome, maxSubagentJournalTextBytes)
    case "lost":
      return value.reason === "session_restored"
    default:
      return false
  }
}

function boundedString(value: unknown, maxBytes: number, allowEmpty = false): value is string {
  return typeof value === "string" && (allowEmpty || value.length > 0) && Buffer.byteLength(value) <= maxBytes
}

function positiveSafeInteger(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value > 0
}

function isCompactionEntryData(value: unknown): value is CompactionEntryData {
  if (!isRecord(value)) return false
  return (
    isCompactionReason(value.reason) &&
    typeof value.summary === "string" &&
    Buffer.byteLength(value.summary) <= maxCompactionSummaryBytes &&
    typeof value.firstKeptEntryId === "string" &&
    isNonNegativeInteger(value.tokensBefore) &&
    isNonNegativeInteger(value.estimatedTokensAfter) &&
    isCompactionDetails(value.details) &&
    (value.excludedFailureEntryId === undefined ||
      (value.reason === "overflow" && typeof value.excludedFailureEntryId === "string"))
  )
}

function isCompactionReason(value: unknown): value is CompactionReason {
  return value === "manual" || value === "threshold" || value === "overflow"
}

function isCompactionDetails(value: unknown): value is CompactionDetails {
  if (!isRecord(value)) return false
  return (
    isBoundedPathList(value.readFiles) &&
    isBoundedPathList(value.modifiedFiles) &&
    isNonNegativeInteger(value.omittedReadFiles) &&
    isNonNegativeInteger(value.omittedModifiedFiles)
  )
}

function isBoundedPathList(value: unknown): value is string[] {
  return (
    Array.isArray(value) &&
    value.length <= maxCompactionFilePaths &&
    value.every(path => typeof path === "string" && Buffer.byteLength(path) <= maxCompactionPathBytes)
  )
}

function isNonNegativeInteger(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value) && Number.isInteger(value) && value >= 0
}

function validateJournal(entries: readonly SessionEntry[], file: string): void {
  const ids = new Set<string>()
  for (let index = 0; index < entries.length; index++) {
    const entry = entries[index]!
    if (ids.has(entry.id) || entry.parentId !== (entries[index - 1]?.id ?? null)) {
      throw new Error(`Invalid session entry: ${file}`)
    }
    validateNextEntry(entry, entries.slice(0, index), file)
    ids.add(entry.id)
  }
}

function validateNextEntry(next: SessionEntry, preceding: readonly SessionEntry[], file: string): void {
  if (next.type === "custom") {
    if (!isStoredCustomEntry(next)) throw new Error(`Invalid session entry: ${file}`)
    return
  }
  if (next.type === "custom_message") {
    if (!isStoredCustomMessageEntry(next, 1)) throw new Error(`Invalid session entry: ${file}`)
    return
  }
  if (next.type === "subagent") {
    if (!isSubagentEntryData(next)) throw new Error(`Invalid session entry: ${file}`)
    return
  }
  if (next.type === "retry") {
    const failure = preceding.at(-1)
    if (
      failure?.id !== next.failedEntryId ||
      failure.type !== "message" ||
      failure.message.role !== "assistant" ||
      failure.message.stopReason !== "error" ||
      !isRetryAttempt(next.attempt)
    ) {
      throw new Error(`Invalid retry failure reference: ${file}`)
    }
    return
  }
  if (next.type !== "compaction") return
  if (!isCompactionEntryData(next)) throw new Error(`Invalid session entry: ${file}`)

  const markerIndex = preceding.length
  const firstKeptIndex = preceding.findIndex(entry => entry.id === next.firstKeptEntryId)
  const firstKept = preceding[firstKeptIndex]
  if (firstKeptIndex < 0 || firstKeptIndex >= markerIndex || !firstKept || !isCompactionBoundaryEntry(firstKept)) {
    throw new Error(`Invalid compaction boundary: ${file}`)
  }
  if (sessionEntryToContextMessage(firstKept)?.role === "toolResult") {
    throw new Error(`Invalid compaction boundary: ${file}`)
  }

  if (next.excludedFailureEntryId !== undefined) {
    const failure = preceding.find(entry => entry.id === next.excludedFailureEntryId)
    if (failure?.type !== "message" || failure.message.role !== "assistant" || failure.message.stopReason !== "error") {
      throw new Error(`Invalid compaction failure reference: ${file}`)
    }
  }

  const firstProjected = projectSessionEntries([...preceding, next], "context").find(isCompactionBoundaryEntry)
  const firstMessage = firstProjected && sessionEntryToContextMessage(firstProjected)
  if (firstProjected?.id !== firstKept.id || firstMessage?.role === "toolResult") {
    throw new Error(`Invalid compaction boundary: ${file}`)
  }
}

function projectSessionEntries(entries: readonly SessionEntry[], mode: "context" | "presentation"): SessionEntry[] {
  const markerIndex = entries.findLastIndex(entry => entry.type === "compaction")
  const retryFailures = new Set<string>()
  for (let index = 0; index < entries.length; index++) {
    const entry = entries[index]!
    if (entry.type === "retry" && (mode === "context" || (markerIndex >= 0 && index < markerIndex))) {
      retryFailures.add(entry.failedEntryId)
    }
  }
  const visible = (entry: SessionEntry) =>
    (mode === "context"
      ? sessionEntryToContextMessage(entry) !== undefined
      : sessionEntryToPresentationMessage(entry) !== undefined) && !retryFailures.has(entry.id)
  if (markerIndex < 0) return entries.filter(visible)

  const marker = entries[markerIndex]
  if (marker?.type !== "compaction") throw new Error("Compaction marker index is invalid")
  const firstKeptIndex = entries.findIndex(entry => entry.id === marker.firstKeptEntryId)
  const keep = (entry: SessionEntry) =>
    entry.type !== "compaction" && visible(entry) && entry.id !== marker.excludedFailureEntryId
  const beforeMarker = entries.slice(firstKeptIndex, markerIndex).filter(keep)
  const afterMarker = entries.slice(markerIndex + 1).filter(keep)
  // Context leads with the checkpoint so the model sees summary then exact tail.
  // Presentation keeps journal order so the marker lands at the transcript tail after compact.
  return mode === "presentation" ? [...beforeMarker, marker, ...afterMarker] : [marker, ...beforeMarker, ...afterMarker]
}

function projectMessages(entries: readonly SessionEntry[], mode: "context" | "presentation"): AgentMessage[] {
  return entries.flatMap(entry => {
    const message = mode === "context" ? sessionEntryToContextMessage(entry) : sessionEntryToPresentationMessage(entry)
    return message ? [message] : []
  })
}

export function sessionEntryToContextMessage(entry: SessionEntry): AgentMessage | undefined {
  switch (entry.type) {
    case "message":
      return entry.message.role === "bashExecution" && entry.message.excludeFromContext ? undefined : entry.message
    case "custom_message":
      return customMessage(entry)
    case "compaction":
      return compactionMessage(entry)
    case "custom":
    case "model_change":
    case "thinking_level_change":
    case "retry":
    case "subagent":
      return undefined
    default:
      return assertNever(entry)
  }
}

function sessionEntryToPresentationMessage(entry: SessionEntry): AgentMessage | undefined {
  switch (entry.type) {
    case "message":
      return entry.message.role === "custom" && !entry.message.display ? undefined : entry.message
    case "custom_message":
      return entry.display ? customMessage(entry) : undefined
    case "compaction":
      return compactionMessage(entry)
    case "custom":
    case "model_change":
    case "thinking_level_change":
    case "retry":
    case "subagent":
      return undefined
    default:
      return assertNever(entry)
  }
}

function isCompactionBoundaryEntry(entry: SessionEntry): boolean {
  return entry.type !== "compaction" && sessionEntryToContextMessage(entry) !== undefined
}

function customMessage(entry: CustomMessageEntry): Extract<AgentMessage, { role: "custom" }> {
  const content = typeof entry.content === "string" ? entry.content : [...entry.content]
  if (Array.isArray(content)) Object.freeze(content)
  return Object.freeze({
    role: "custom",
    customType: entry.customType,
    content,
    display: entry.display,
    ...(entry.details === undefined ? {} : { details: entry.details }),
    timestamp: Date.parse(entry.timestamp)
  })
}

function compactionMessage(entry: CompactionEntry): CompactionSummaryMessage {
  return {
    role: "compactionSummary",
    summary: formatCompactionSummary(entry.summary, entry.details),
    tokensBefore: entry.tokensBefore,
    estimatedTokensAfter: entry.estimatedTokensAfter,
    timestamp: new Date(entry.timestamp).getTime()
  }
}

function parseJson(line: string, kind: "header" | "entry", file: string): unknown {
  try {
    return JSON.parse(line)
  } catch {
    throw new Error(`Invalid session ${kind}: ${file}`)
  }
}

function lineBytes(lineWithoutNewline: string): number {
  return Buffer.byteLength(lineWithoutNewline) + 1
}

function isValidTimestamp(value: unknown): value is string {
  return typeof value === "string" && Number.isFinite(Date.parse(value))
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}

function assertNever(value: never): never {
  throw new Error(`Unexpected session entry: ${String(value)}`)
}
