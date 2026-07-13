import { appendFileSync, mkdirSync, readFileSync, writeFileSync } from "node:fs"
import { dirname, join } from "node:path"
import type { AgentMessage, ThinkingLevel } from "@earendil-works/pi-agent-core"

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

export interface SessionManagerOptions {
  cwd: string
  sessionDir: string
  sessionId?: string
  persist?: boolean
}

export class SessionManager {
  readonly header: SessionHeader
  #file: string | undefined
  readonly #entries: SessionEntry[] = []
  #leafId: string | null = null

  constructor(options: SessionManagerOptions) {
    const id = options.sessionId ?? crypto.randomUUID()
    this.header = {
      type: "session",
      version: 1,
      id,
      timestamp: new Date().toISOString(),
      cwd: options.cwd,
    }

    if (options.persist === false) return
    mkdirSync(options.sessionDir, { recursive: true })
    this.#file = join(options.sessionDir, `${id}.jsonl`)
    writeFileSync(this.#file, `${JSON.stringify(this.header)}\n`, { flag: "wx" })
  }

  static open(file: string): SessionManager {
    const lines = readFileSync(file, "utf8").split("\n").filter(Boolean)
    const header = JSON.parse(lines.shift() ?? "null") as SessionHeader
    if (header?.type !== "session" || header.version !== 1 || typeof header.id !== "string" || typeof header.cwd !== "string") {
      throw new Error(`Invalid session header: ${file}`)
    }

    const manager = new SessionManager({ cwd: header.cwd, sessionDir: dirname(file), sessionId: header.id, persist: false })
    manager.#file = file
    manager.#entries.push(...lines.map((line) => parseEntry(line, file)))
    manager.#leafId = manager.#entries.at(-1)?.id ?? null
    Object.assign(manager.header, header)
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
    return this.#entries.flatMap((entry) => (entry.type === "message" ? [entry.message] : []))
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

  #append(entry: SessionEntryData): string {
    const next = {
      ...entry,
      id: crypto.randomUUID(),
      parentId: this.#leafId,
      timestamp: new Date().toISOString(),
    } as SessionEntry
    this.#entries.push(next)
    this.#leafId = next.id
    if (this.#file) appendFileSync(this.#file, `${JSON.stringify(next)}\n`)
    return next.id
  }
}

function parseEntry(line: string, file: string): SessionEntry {
  const entry = JSON.parse(line) as SessionEntry
  const base =
    entry &&
    typeof entry.id === "string" &&
    (entry.parentId === null || typeof entry.parentId === "string") &&
    typeof entry.timestamp === "string"
  const data =
    (entry?.type === "message" && typeof entry.message?.role === "string") ||
    (entry?.type === "model_change" && typeof entry.provider === "string" && typeof entry.modelId === "string") ||
    (entry?.type === "thinking_level_change" && typeof entry.thinkingLevel === "string")
  if (!base || !data) throw new Error(`Invalid session entry: ${file}`)
  return entry
}
