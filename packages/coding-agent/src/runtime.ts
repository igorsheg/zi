import type { ThinkingLevel } from "@earendil-works/pi-agent-core"
import type { CredentialStore, Models } from "@earendil-works/pi-ai"
import { builtinModels } from "@earendil-works/pi-ai/providers/all"

import type { AgentSession } from "./agent-session.js"
import { FileCredentialStore } from "./credential-store.js"
import { ModelRegistry } from "./model-registry.js"
import { resolveRequestedModel } from "./model-resolver.js"
import { getAgentDir, ZiPaths } from "./paths.js"
import { ResourceLoader } from "./resource-loader.js"
import { createAgentSession, type AgentSessionServices, type SessionBootstrapDiagnostic } from "./sdk.js"
import { SessionManager } from "./session-manager.js"
import { SessionShell } from "./session-shell.js"
import { SettingsManager, type AgentSettings } from "./settings-manager.js"
import { createCodingTools } from "./tools/index.js"

export type AgentRuntimeServices = AgentSessionServices

export interface AgentRuntime {
  readonly session: AgentSession
  readonly services: AgentRuntimeServices
  readonly bootstrapDiagnostic: SessionBootstrapDiagnostic | undefined
}

export interface CreateAgentRuntimeOptions {
  readonly cwd: string
  readonly model?: string
  readonly apiKey?: string
  readonly thinkingLevel?: ThinkingLevel
  readonly modelFactory?: (credentials: CredentialStore) => Models
  readonly agentDir?: string
  readonly sessionDir?: string
  readonly sessionFile?: string
  readonly continueRecent?: boolean
  readonly persist?: boolean
  readonly settings?: Readonly<Partial<AgentSettings>>
}

/** Assemble cwd-bound production services and a session. The caller owns `session.dispose()`. */
export async function createAgentRuntime(options: CreateAgentRuntimeOptions): Promise<AgentRuntime> {
  if (options.sessionFile && options.continueRecent)
    throw new Error("sessionFile and continueRecent cannot be combined")
  if (options.continueRecent && options.persist === false)
    throw new Error("continueRecent requires session persistence")
  const agentDir = options.agentDir ?? getAgentDir()
  const requestedPaths = new ZiPaths(options.cwd, agentDir, options.sessionDir)
  const resumed = options.sessionFile
    ? SessionManager.open(options.sessionFile)
    : options.continueRecent
      ? await SessionManager.continueRecent(requestedPaths)
      : undefined
  const cwd = resumed?.header.cwd ?? options.cwd
  const sessionDir = options.sessionDir ?? resumed?.sessionDir
  const paths = new ZiPaths(cwd, agentDir, sessionDir)
  const settingsManager = SettingsManager.create(paths, options.settings ?? {})
  const credentialStore = new FileCredentialStore(paths)
  const models = options.modelFactory?.(credentialStore) ?? builtinModels({ credentials: credentialStore })
  const modelRegistry = new ModelRegistry(models)
  const resourceLoader = new ResourceLoader({ paths })
  const services: AgentRuntimeServices = Object.freeze({
    paths,
    settingsManager,
    credentialStore,
    modelRegistry,
    resourceLoader
  })
  if (options.apiKey !== undefined && options.apiKey.length === 0) {
    throw new Error("--api-key requires a non-empty value")
  }
  const model = options.model
    ? resolveRequestedModel(modelRegistry, options.model)
    : options.apiKey
      ? resolveSettingsModel(modelRegistry, settingsManager)
      : undefined
  const sessionManager =
    resumed ?? SessionManager.create(paths, options.persist === undefined ? {} : { persist: options.persist })
  const shell = new SessionShell({ cwd: paths.cwd, sessionId: sessionManager.sessionId })
  const created = await createAgentSession({
    services,
    sessionManager,
    shell,
    ...(model ? { model } : {}),
    ...(options.thinkingLevel ? { thinkingLevel: options.thinkingLevel } : {}),
    ...(options.apiKey ? { apiKey: options.apiKey } : {}),
    tools: createCodingTools({ cwd: paths.cwd, shell })
  })
  return Object.freeze({ session: created.session, services, bootstrapDiagnostic: created.bootstrapDiagnostic })
}

function resolveSettingsModel(registry: ModelRegistry, settings: SettingsManager) {
  const provider = settings.getDefaultProvider()
  const modelId = settings.getDefaultModel()
  if (!provider || !modelId) throw new Error("--api-key requires a model so its provider can be determined")
  const model = registry.get(provider, modelId)
  if (!model) throw new Error(`Unknown model: ${provider}/${modelId}. Use provider/model-id.`)
  return model
}
