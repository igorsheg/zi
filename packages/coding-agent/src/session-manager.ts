import { appendFileSync, mkdirSync, readFileSync, writeFileSync } from "node:fs"
import { dirname, join } from "node:path"

import type { AgentMessage, ThinkingLevel } from "@earendil-works/pi-agent-core"

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

type SessionEntryData =
  | { type: "message"; message: AgentMessage }
  | { type: "model_change"; provider: string; modelId: string }
  | { type: "thinking_level_change"; thinkingLevel: ThinkingLevel }

export type SessionEntry = SessionEntryBase & SessionEntryData

export interface NewSessionOptions {
  sessionId?: string
  persist?: boolean
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
    const lines = readFileSync(resolvedFile, "utf8").split("\n").filter(Boolean)
    const header = parseHeader(lines.shift() ?? "null", resolvedFile)
    const manager = new SessionManager(resolveOpenZiPath(header.cwd), dirname(resolvedFile), header.id, false)
    manager.#file = resolvedFile
    manager.#entries.push(...lines.map(line => parseEntry(line, resolvedFile)))
    manager.#leafId = manager.#entries.at(-1)?.id ?? null
    Object.assign(manager.header, header, { cwd: resolveOpenZiPath(header.cwd) })
    return manager
  }

  appendMessage(message: AgentMessage): string {
    return this.#append({ type: "message", message })
  }

  appendModelChange(provider: string, modelId: string): string {
    return this.#append({ type: "model_change", provider, modelId })
  }

  appendThinkingLevelChange(thinkingLevel: ThinkingLevel): string {
    return this.#append({ type: "thinking_level_change", thinkingLevel })
  }

  messages(): AgentMessage[] {
    return this.#entries.flatMap(entry => (entry.type === "message" ? [entry.message] : []))
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

  #append(entry: SessionEntryData): string {
    const next = {
      ...entry,
      id: crypto.randomUUID(),
      parentId: this.#leafId,
      timestamp: new Date().toISOString()
    } as SessionEntry
    this.#entries.push(next)
    this.#leafId = next.id
    if (this.#file) appendFileSync(this.#file, `${JSON.stringify(next)}\n`)
    return next.id
  }
}

function parseHeader(line: string, file: string): SessionHeader {
  const value: unknown = JSON.parse(line)
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
  const value: unknown = JSON.parse(line)
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
      return typeof value.summary === "string" && typeof value.tokensBefore === "number"
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
  ].every(item => typeof item === "number")
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

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}
