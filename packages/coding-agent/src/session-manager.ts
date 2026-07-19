import { appendFileSync, mkdirSync, readFileSync, statSync, writeFileSync } from "node:fs"
import { open, opendir, stat } from "node:fs/promises"
import { dirname, join } from "node:path"

import type { ThinkingLevel } from "@earendil-works/pi-agent-core"

import { formatCompactionSummary, type AgentMessage, type CompactionSummaryMessage } from "./messages.js"
import { type OpenZiPaths, resolveOpenZiPath } from "./paths.js"

export interface SessionHeader {
  type: "session"
  version: 1
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

export type SessionEntryData =
  | { type: "message"; message: AgentMessage }
  | { type: "model_change"; provider: string; modelId: string }
  | { type: "thinking_level_change"; thinkingLevel: ThinkingLevel }
  | CompactionEntryData

export type SessionEntry = SessionEntryBase & SessionEntryData
export type MessageEntry = SessionEntryBase & Extract<SessionEntryData, { type: "message" }>
export type CompactionEntry = SessionEntryBase & CompactionEntryData

export interface NewSessionOptions {
  sessionId?: string
  persist?: boolean
}

export const maxSessionFileBytes = 64 * 1024 * 1024
export const maxSessionListCandidates = 4096
export const maxSessionListResults = 200
export const maxSessionListPreviewBytes = 256 * 1024
export const maxSessionFirstMessageLength = 512
export const maxCompactionSummaryBytes = 128 * 1024
export const maxCompactionFilePaths = 256
export const maxCompactionPathBytes = 4096

const sessionListConcurrency = 8

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

export class SessionManager {
  readonly header: SessionHeader
  #file: string | undefined
  readonly #entries: SessionEntry[] = []
  #leafId: string | null = null

  private constructor(cwd: string, sessionDir: string, sessionId?: string, persist = true) {
    const id = sessionId ?? crypto.randomUUID()
    this.header = { type: "session", version: 1, id, timestamp: new Date().toISOString(), cwd }

    if (!persist) return
    mkdirSync(sessionDir, { recursive: true })
    this.#file = join(sessionDir, `${id}.jsonl`)
    writeFileSync(this.#file, `${JSON.stringify(this.header)}\n`, { flag: "wx" })
  }

  static create(paths: OpenZiPaths, options: NewSessionOptions = {}): SessionManager {
    return new SessionManager(paths.cwd, paths.sessionDir, options.sessionId, options.persist)
  }

  static inMemory(cwd = process.cwd(), sessionId?: string): SessionManager {
    return new SessionManager(resolveOpenZiPath(cwd), "", sessionId, false)
  }

  static open(file: string): SessionManager {
    const resolvedFile = resolveOpenZiPath(file)
    const size = statSync(resolvedFile).size
    if (size > maxSessionFileBytes) {
      throw new Error(`Session file cannot exceed ${maxSessionFileBytes} bytes: ${resolvedFile}`)
    }
    const content = readFileSync(resolvedFile, "utf8")
    const lines = content.split("\n")
    if (lines.at(-1) === "") lines.pop()
    const header = parseHeader(lines.shift() ?? "null", resolvedFile)
    const entries: SessionEntry[] = []
    for (let index = 0; index < lines.length; index++) {
      const line = lines[index]
      if (!line) continue
      try {
        entries.push(parseEntry(line, resolvedFile))
      } catch (cause) {
        if (index === lines.length - 1 && !content.endsWith("\n")) break
        throw cause
      }
    }
    const manager = new SessionManager(resolveOpenZiPath(header.cwd), dirname(resolvedFile), header.id, false)
    manager.#file = resolvedFile
    validateJournal(entries, resolvedFile)
    manager.#entries.push(...entries)
    manager.#leafId = manager.#entries.at(-1)?.id ?? null
    Object.assign(manager.header, header, { cwd: resolveOpenZiPath(header.cwd) })
    return manager
  }

  static async list(paths: OpenZiPaths, options: SessionListOptions = {}): Promise<SessionListResult> {
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

  static async continueRecent(paths: OpenZiPaths): Promise<SessionManager> {
    const listed = await SessionManager.list(paths, { limit: 1 })
    const recent = listed.sessions[0]
    return recent ? SessionManager.open(recent.path) : SessionManager.create(paths)
  }

  appendMessage(message: AgentMessage): MessageEntry {
    if (!isAgentMessage(message)) throw new Error("Invalid session message")
    return this.#append({ type: "message", message })
  }

  appendModelChange(provider: string, modelId: string): SessionEntry {
    return this.#append({ type: "model_change", provider, modelId })
  }

  appendThinkingLevelChange(thinkingLevel: ThinkingLevel): SessionEntry {
    return this.#append({ type: "thinking_level_change", thinkingLevel })
  }

  appendCompaction(data: Omit<CompactionEntryData, "type">): CompactionEntry {
    return this.#append({ type: "compaction", ...data })
  }

  messages(): AgentMessage[] {
    return this.#entries.flatMap(entry => (entry.type === "message" ? [entry.message] : []))
  }

  activeEntries(): readonly SessionEntry[] {
    const markerIndex = this.#entries.findLastIndex(entry => entry.type === "compaction")
    if (markerIndex < 0) return this.#entries.filter(isContextVisibleEntry)

    const marker = this.#entries[markerIndex]
    if (marker?.type !== "compaction") throw new Error("Compaction marker index is invalid")
    const firstKeptIndex = this.#entries.findIndex(entry => entry.id === marker.firstKeptEntryId)
    const excluded = marker.excludedFailureEntryId
    const exact = [...this.#entries.slice(firstKeptIndex, markerIndex), ...this.#entries.slice(markerIndex + 1)].filter(
      entry => isContextVisibleEntry(entry) && entry.id !== excluded
    )
    return [marker, ...exact]
  }

  activeMessages(): AgentMessage[] {
    return this.activeEntries().flatMap(entry => {
      if (entry.type === "message") return [entry.message]
      if (entry.type !== "compaction") return []
      return [compactionMessage(entry)]
    })
  }

  latestCompaction(): CompactionEntry | undefined {
    return this.#entries.findLast((entry): entry is CompactionEntry => entry.type === "compaction")
  }

  activeUsageAnchorIndex(): number {
    const markerIndex = this.#entries.findLastIndex(entry => entry.type === "compaction")
    if (markerIndex < 0) return 0
    const active = this.activeEntries()
    const afterMarker = new Set(this.#entries.slice(markerIndex + 1).map(entry => entry.id))
    const firstAfterMarker = active.findIndex(entry => afterMarker.has(entry.id))
    return firstAfterMarker < 0 ? active.length : firstAfterMarker
  }

  entries(): readonly SessionEntry[] {
    return this.#entries
  }

  get sessionId(): string {
    return this.header.id
  }

  get file(): string | undefined {
    return this.#file
  }

  get sessionDir(): string {
    return this.#file ? dirname(this.#file) : ""
  }

  #append<Entry extends SessionEntryData>(entry: Entry): SessionEntryBase & Entry {
    const next = {
      ...entry,
      id: crypto.randomUUID(),
      parentId: this.#leafId,
      timestamp: new Date().toISOString()
    } as SessionEntryBase & Entry
    validateNextEntry(next, this.#entries, this.#file ?? "<memory>")
    if (this.#file) appendFileSync(this.#file, `${JSON.stringify(next)}\n`)
    this.#entries.push(next)
    this.#leafId = next.id
    return next
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
      let entry: SessionEntry
      try {
        entry = parseEntry(line, candidate.path)
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
      cwd: resolveOpenZiPath(header.cwd),
      createdAt: new Date(created).toISOString(),
      modifiedAt: new Date(candidate.modifiedMs).toISOString(),
      firstMessage
    })
  } catch {
    return undefined
  }
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

function parseHeader(line: string, file: string): SessionHeader {
  const value = parseJson(line, "header", file)
  if (
    !isRecord(value) ||
    value.type !== "session" ||
    value.version !== 1 ||
    typeof value.id !== "string" ||
    typeof value.timestamp !== "string" ||
    typeof value.cwd !== "string"
  ) {
    throw new Error(`Invalid session header: ${file}`)
  }
  return { type: value.type, version: value.version, id: value.id, timestamp: value.timestamp, cwd: value.cwd }
}

function parseEntry(line: string, file: string): SessionEntry {
  const value = parseJson(line, "entry", file)
  if (
    !isRecord(value) ||
    typeof value.id !== "string" ||
    (value.parentId !== null && typeof value.parentId !== "string") ||
    typeof value.timestamp !== "string"
  ) {
    throw new Error(`Invalid session entry: ${file}`)
  }

  const base = { id: value.id, parentId: value.parentId, timestamp: value.timestamp }
  if (value.type === "message" && isAgentMessage(value.message)) {
    return { ...base, type: value.type, message: value.message }
  }
  if (value.type === "model_change" && typeof value.provider === "string" && typeof value.modelId === "string") {
    return { ...base, type: value.type, provider: value.provider, modelId: value.modelId }
  }
  if (value.type === "thinking_level_change" && isThinkingLevel(value.thinkingLevel)) {
    return { ...base, type: value.type, thinkingLevel: value.thinkingLevel }
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

function isAgentMessage(value: unknown): value is AgentMessage {
  if (!isRecord(value) || typeof value.timestamp !== "number") return false
  switch (value.role) {
    case "user":
      return typeof value.content === "string" || isContentArray(value.content)
    case "assistant":
      return (
        isContentArray(value.content) &&
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
        isContentArray(value.content) &&
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
        (typeof value.content === "string" || isContentArray(value.content)) &&
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

function isContentArray(value: unknown): boolean {
  return Array.isArray(value) && value.every(isContent)
}

function isContent(value: unknown): boolean {
  if (!isRecord(value)) return false
  if (value.type === "text") return typeof value.text === "string"
  if (value.type === "thinking") return typeof value.thinking === "string"
  if (value.type === "image") return typeof value.data === "string" && typeof value.mimeType === "string"
  return (
    value.type === "toolCall" &&
    typeof value.id === "string" &&
    typeof value.name === "string" &&
    isRecord(value.arguments)
  )
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
  if (next.type !== "compaction") return
  if (!isCompactionEntryData(next)) throw new Error(`Invalid session entry: ${file}`)

  const markerIndex = preceding.length
  const firstKeptIndex = preceding.findIndex(entry => entry.id === next.firstKeptEntryId)
  if (firstKeptIndex < 0 || firstKeptIndex >= markerIndex || !isContextVisibleEntry(preceding[firstKeptIndex]!)) {
    throw new Error(`Invalid compaction boundary: ${file}`)
  }
  if (preceding[firstKeptIndex]!.type === "message" && preceding[firstKeptIndex]!.message.role === "toolResult") {
    throw new Error(`Invalid compaction boundary: ${file}`)
  }

  if (next.excludedFailureEntryId !== undefined) {
    const failure = preceding.find(entry => entry.id === next.excludedFailureEntryId)
    if (failure?.type !== "message" || failure.message.role !== "assistant" || failure.message.stopReason !== "error") {
      throw new Error(`Invalid compaction failure reference: ${file}`)
    }
  }

  const firstProjected = preceding
    .slice(firstKeptIndex)
    .find(entry => isContextVisibleEntry(entry) && entry.id !== next.excludedFailureEntryId)
  if (firstProjected?.type === "message" && firstProjected.message.role === "toolResult") {
    throw new Error(`Invalid compaction boundary: ${file}`)
  }
}

function isContextVisibleEntry(entry: SessionEntry): boolean {
  return entry.type === "message" && !(entry.message.role === "bashExecution" && entry.message.excludeFromContext)
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

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}
