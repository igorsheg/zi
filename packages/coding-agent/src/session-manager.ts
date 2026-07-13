import { appendFileSync, mkdirSync, writeFileSync } from "node:fs"
import { join } from "node:path"
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
