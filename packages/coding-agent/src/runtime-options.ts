import type { ThinkingLevel } from "@earendil-works/pi-agent-core"
import type { CredentialStore, Models } from "@earendil-works/pi-ai"

import type { AgentSettings } from "./settings-manager.js"

export type AgentRuntimeSessionIntent =
  | { readonly type: "new"; readonly persist: boolean }
  | { readonly type: "continue" }
  | { readonly type: "resume"; readonly file: string }

export interface CreateAgentRuntimeOptions {
  readonly cwd: string
  readonly model?: string
  readonly apiKey?: string
  readonly thinkingLevel?: ThinkingLevel
  readonly systemPrompt?: string
  readonly appendSystemPrompt?: readonly string[]
  readonly modelFactory?: (credentials: CredentialStore) => Models
  readonly agentDir?: string
  readonly sessionDir?: string
  readonly session?: AgentRuntimeSessionIntent
  readonly settings?: Readonly<Partial<AgentSettings>>
}

export function snapshotAgentRuntimeOptions(options: CreateAgentRuntimeOptions): CreateAgentRuntimeOptions {
  return Object.freeze({
    ...options,
    ...(options.session === undefined ? {} : { session: snapshotSession(options.session) }),
    ...(options.appendSystemPrompt === undefined
      ? {}
      : { appendSystemPrompt: Object.freeze([...options.appendSystemPrompt]) }),
    ...(options.settings === undefined ? {} : { settings: Object.freeze({ ...options.settings }) })
  })
}

function snapshotSession(session: AgentRuntimeSessionIntent): AgentRuntimeSessionIntent {
  switch (session.type) {
    case "new":
      if (typeof session.persist !== "boolean") throw new Error("New runtime session requires a persistence choice")
      return Object.freeze({ type: "new", persist: session.persist })
    case "continue":
      return Object.freeze({ type: "continue" })
    case "resume":
      if (typeof session.file !== "string" || session.file.trim().length === 0) {
        throw new Error("Resumed runtime session requires a file")
      }
      return Object.freeze({ type: "resume", file: session.file })
    default:
      return assertNever(session)
  }
}

function assertNever(value: never): never {
  throw new Error(`Unknown runtime session: ${String(value)}`)
}
