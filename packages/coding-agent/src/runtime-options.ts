import type { ThinkingLevel } from "@earendil-works/pi-agent-core"
import type { CredentialStore, Models } from "@earendil-works/pi-ai"
import type { ExtensionMode } from "@with-zi/extension-api"

import { maxExplicitExtensionPaths } from "./extensions/discovery.js"
import type { ProjectTrustDecision } from "./project-trust.js"
import { maxConfiguredResourcePaths, type AgentSettings } from "./settings-manager.js"
import { snapshotToolSurface, type ToolSurface } from "./tool-surface.js"

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
  readonly toolSurface?: ToolSurface
}

export function snapshotAgentRuntimeOptions(options: CreateAgentRuntimeOptions): CreateAgentRuntimeOptions {
  return Object.freeze({
    ...options,
    ...(options.session === undefined ? {} : { session: snapshotSession(options.session) }),
    ...(options.projectTrust === undefined ? {} : { projectTrust: Object.freeze({ ...options.projectTrust }) }),
    ...(options.appendSystemPrompt === undefined
      ? {}
      : { appendSystemPrompt: Object.freeze([...options.appendSystemPrompt]) }),
    ...(options.settings === undefined ? {} : { settings: snapshotSettings(options.settings) }),
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
    ...(options.toolSurface === undefined ? {} : { toolSurface: snapshotToolSurface(options.toolSurface) })
  })
}

function snapshotSettings(settings: Readonly<Partial<AgentSettings>>): Readonly<Partial<AgentSettings>> {
  return Object.freeze({
    ...settings,
    ...(settings.extensions === undefined
      ? {}
      : { extensions: snapshotStrings(settings.extensions, maxConfiguredResourcePaths, "Extension settings paths") }),
    ...(settings.skills === undefined
      ? {}
      : { skills: snapshotStrings(settings.skills, maxConfiguredResourcePaths, "Skill settings paths") }),
    ...(settings.prompts === undefined
      ? {}
      : { prompts: snapshotStrings(settings.prompts, maxConfiguredResourcePaths, "Prompt settings paths") })
  })
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
