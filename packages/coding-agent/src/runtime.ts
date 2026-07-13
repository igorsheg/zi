import type { Models } from "@earendil-works/pi-ai"
import { builtinModels } from "@earendil-works/pi-ai/providers/all"
import { createCodingTools } from "./tools/index.js"
import { getAgentDir, getSessionDir } from "./paths.js"
import { ModelRegistry } from "./model-registry.js"
import { resolveInitialModel } from "./model-resolver.js"
import { DefaultResourceLoader } from "./resource-loader.js"
import { SessionManager } from "./session-manager.js"
import { SettingsManager, type AgentSettings } from "./settings-manager.js"
import { createAgentSession, type AgentSessionServices } from "./services.js"

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
  const agentDir = options.agentDir ?? getAgentDir()
  const resumed = options.sessionFile ? SessionManager.open(options.sessionFile) : undefined
  const cwd = resumed?.header.cwd ?? options.cwd
  const savedModel = resumed?.entries().findLast((entry) => entry.type === "model_change")
  const savedThinking = resumed?.entries().findLast((entry) => entry.type === "thinking_level_change")
  const modelReference =
    options.model ?? options.settings?.model ?? (savedModel ? `${savedModel.provider}/${savedModel.modelId}` : undefined)
  const settingsManager = new SettingsManager({
    ...options.settings,
    ...(savedThinking && options.settings?.thinkingLevel === undefined
      ? { thinkingLevel: savedThinking.thinkingLevel }
      : {}),
    ...(modelReference === undefined ? {} : { model: modelReference }),
  })
  const modelRegistry = new ModelRegistry(options.models ?? builtinModels())
  const resourceLoader = new DefaultResourceLoader({ cwd, agentDir })
  const services: AgentSessionServices = { cwd, settingsManager, modelRegistry, resourceLoader }
  const model = await resolveInitialModel(modelRegistry, settingsManager.get().model)
  const sessionManager =
    resumed ??
    new SessionManager({
      cwd,
      sessionDir: options.sessionDir ?? getSessionDir(cwd, agentDir),
      ...(options.persist === undefined ? {} : { persist: options.persist }),
    })
  const session = await createAgentSession({ services, sessionManager, model, tools: createCodingTools(cwd) })
  return { session, services }
}
