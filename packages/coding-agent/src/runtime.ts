import type { CredentialStore, Models } from "@earendil-works/pi-ai"
import { builtinModels } from "@earendil-works/pi-ai/providers/all"

import type { AgentSession } from "./agent-session.js"
import { FileCredentialStore } from "./credential-store.js"
import { ModelRegistry } from "./model-registry.js"
import { resolveInitialModel } from "./model-resolver.js"
import { getAgentDir, OpenZiPaths } from "./paths.js"
import { ResourceLoader } from "./resource-loader.js"
import { createAgentSession, type AgentSessionServices } from "./services.js"
import { SessionManager } from "./session-manager.js"
import { SettingsManager, type AgentSettings } from "./settings-manager.js"
import { createCodingTools } from "./tools/index.js"

export type AgentRuntimeServices = AgentSessionServices

export interface AgentRuntime {
  readonly session: AgentSession
  readonly services: AgentRuntimeServices
}

export interface CreateAgentRuntimeOptions {
  readonly cwd: string
  readonly model?: string
  readonly apiKey?: string
  readonly modelFactory?: (credentials: CredentialStore) => Models
  readonly agentDir?: string
  readonly sessionDir?: string
  readonly sessionFile?: string
  readonly persist?: boolean
  readonly settings?: Readonly<Partial<AgentSettings>>
}

/** Assemble cwd-bound production services and a session. The caller owns `session.dispose()`. */
export async function createAgentRuntime(options: CreateAgentRuntimeOptions): Promise<AgentRuntime> {
  const resumed = options.sessionFile ? SessionManager.open(options.sessionFile) : undefined
  const cwd = resumed?.header.cwd ?? options.cwd
  const sessionDir = options.sessionDir ?? resumed?.sessionDir
  const paths = new OpenZiPaths(cwd, options.agentDir ?? getAgentDir(), sessionDir)
  const savedModel = resumed?.entries().findLast(entry => entry.type === "model_change")
  const savedThinking = resumed?.entries().findLast(entry => entry.type === "thinking_level_change")
  const runtimeSettings: Partial<AgentSettings> = { ...options.settings }
  if (savedModel && runtimeSettings.model === undefined) {
    runtimeSettings.model = `${savedModel.provider}/${savedModel.modelId}`
  }
  if (savedThinking && runtimeSettings.thinkingLevel === undefined) {
    runtimeSettings.thinkingLevel = savedThinking.thinkingLevel
  }
  if (options.model !== undefined) runtimeSettings.model = options.model

  const settingsManager = SettingsManager.create(paths, runtimeSettings)
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
  const modelReference = settingsManager.get().model
  if (options.apiKey !== undefined && options.apiKey.length === 0) {
    throw new Error("--api-key requires a non-empty value")
  }
  if (options.apiKey !== undefined && modelReference === undefined) {
    throw new Error("--api-key requires a model so its provider can be determined")
  }
  const model = await resolveInitialModel(
    modelRegistry,
    modelReference,
    options.model !== undefined || options.settings?.model !== undefined || options.apiKey !== undefined,
    options.apiKey !== undefined
  )
  const sessionManager =
    resumed ?? SessionManager.create(paths, options.persist === undefined ? {} : { persist: options.persist })
  const session = await createAgentSession({
    services,
    sessionManager,
    ...(model ? { model } : {}),
    ...(options.apiKey ? { apiKey: options.apiKey } : {}),
    tools: createCodingTools(paths.cwd)
  })
  return Object.freeze({ session, services })
}
