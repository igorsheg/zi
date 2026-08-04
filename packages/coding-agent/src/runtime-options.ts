import type { ThinkingLevel } from "@earendil-works/pi-agent-core"
import type { CredentialStore, Models } from "@earendil-works/pi-ai"
import type { ExtensionMode } from "@with-zi/extension-api"

import { maxExplicitExtensionPaths } from "./extensions/discovery.js"
import type { ProjectTrustDecision } from "./project-trust.js"
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
  readonly projectTrust?: ProjectTrustDecision
  readonly settings?: Readonly<Partial<AgentSettings>>
  readonly extensionPaths?: readonly string[]
  readonly extensionMode?: ExtensionMode
  readonly extensionWorkerCommand?: readonly string[]
  readonly codeModeWorkerCommand?: readonly string[]
  readonly subagentCommand?: readonly string[]
  /** Private invocation marker used by Zi child sessions to prevent recursive delegation. */
  readonly internalSubagentDepth?: 0 | 1
  readonly internalSubagentEnvironment?: Readonly<Record<string, string | undefined>>
}

export function snapshotAgentRuntimeOptions(options: CreateAgentRuntimeOptions): CreateAgentRuntimeOptions {
  return Object.freeze({
    ...options,
    ...(options.session === undefined ? {} : { session: snapshotSession(options.session) }),
    ...(options.projectTrust === undefined ? {} : { projectTrust: Object.freeze({ ...options.projectTrust }) }),
    ...(options.appendSystemPrompt === undefined
      ? {}
      : { appendSystemPrompt: Object.freeze([...options.appendSystemPrompt]) }),
    ...(options.settings === undefined ? {} : { settings: Object.freeze({ ...options.settings }) }),
    ...(options.extensionPaths === undefined
      ? {}
      : { extensionPaths: snapshotStrings(options.extensionPaths, maxExplicitExtensionPaths, "Extension paths") }),
    ...(options.extensionMode === undefined ? {} : { extensionMode: snapshotExtensionMode(options.extensionMode) }),
    ...(options.extensionWorkerCommand === undefined
      ? {}
      : { extensionWorkerCommand: snapshotStrings(options.extensionWorkerCommand, 16, "Extension worker command") }),
    ...(options.codeModeWorkerCommand === undefined
      ? {}
      : { codeModeWorkerCommand: snapshotStrings(options.codeModeWorkerCommand, 16, "Code-mode worker command") }),
    ...(options.subagentCommand === undefined
      ? {}
      : { subagentCommand: snapshotStrings(options.subagentCommand, 16, "Subagent command") }),
    ...(options.internalSubagentDepth === undefined
      ? {}
      : { internalSubagentDepth: snapshotSubagentDepth(options.internalSubagentDepth) }),
    ...(options.internalSubagentEnvironment === undefined
      ? {}
      : { internalSubagentEnvironment: snapshotEnvironment(options.internalSubagentEnvironment) })
  })
}

function snapshotEnvironment(
  value: Readonly<Record<string, string | undefined>>
): Readonly<Record<string, string | undefined>> {
  const entries = Object.entries(value)
  if (entries.length > 4096) throw new Error("Subagent environment cannot exceed 4096 entries")
  for (const [name, entry] of entries) {
    if (name.length === 0 || name.includes("\0") || Buffer.byteLength(name) > 4096) {
      throw new Error("Subagent environment contains an invalid name")
    }
    if (
      entry !== undefined &&
      (typeof entry !== "string" || entry.includes("\0") || Buffer.byteLength(entry) > 64 * 1024)
    ) {
      throw new Error(`Subagent environment value is invalid: ${name}`)
    }
  }
  return Object.freeze(Object.fromEntries(entries))
}

function snapshotExtensionMode(value: unknown): ExtensionMode {
  switch (value) {
    case "interactive":
    case "text":
    case "json":
    case "rpc":
    case "embedded":
      return value
    default:
      throw new Error(`Unknown extension mode: ${String(value)}`)
  }
}

function snapshotSubagentDepth(value: unknown): 0 | 1 {
  if (value !== 0 && value !== 1) throw new Error("Internal subagent depth must be zero or one")
  return value
}

function snapshotStrings(values: readonly string[], maximum: number, name: string): readonly string[] {
  if (!Array.isArray(values) || values.length > maximum || values.some(value => typeof value !== "string")) {
    throw new Error(`${name} must contain at most ${maximum} strings`)
  }
  return Object.freeze([...values])
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
