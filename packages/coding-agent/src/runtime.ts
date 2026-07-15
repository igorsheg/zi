import type { Models } from "@earendil-works/pi-ai"
import { builtinModels } from "@earendil-works/pi-ai/providers/all"

import { FileCredentialStore } from "./credential-store.js"
import { ModelRegistry } from "./model-registry.js"
import { resolveInitialModel } from "./model-resolver.js"
import { getAgentDir, OpenZiPaths } from "./paths.js"
import { DefaultResourceLoader } from "./resource-loader.js"
import { createAgentSession, type AgentSessionServices } from "./services.js"
import { SessionManager } from "./session-manager.js"
import { SettingsManager, type AgentSettings } from "./settings-manager.js"
import { createCodingTools } from "./tools/index.js"

export interface AgentRuntimeServices extends AgentSessionServices {
  credentialStore: FileCredentialStore
}

export interface CreateAgentRuntimeOptions {
  cwd: string
  model?: string
  models?: Models
  agentDir?: string
  sessionDir?: string
  sessionFile?: string
  persist?: boolean
  settings?: Partial<AgentSettings>
}

export async function createAgentRuntime(options: CreateAgentRuntimeOptions) {
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
  const modelRegistry = new ModelRegistry(options.models ?? builtinModels({ credentials: credentialStore }))
  const resourceLoader = new DefaultResourceLoader({ paths })
  const services: AgentRuntimeServices = { paths, settingsManager, credentialStore, modelRegistry, resourceLoader }
  const model = await resolveInitialModel(modelRegistry, settingsManager.get().model)
  const sessionManager =
    resumed ?? SessionManager.create(paths, options.persist === undefined ? {} : { persist: options.persist })
  const session = await createAgentSession({ services, sessionManager, model, tools: createCodingTools(paths.cwd) })
  return { session, services }
}
