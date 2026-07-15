import { Agent, type AgentTool } from "@earendil-works/pi-agent-core"
import { clampThinkingLevel, type Api, type Model } from "@earendil-works/pi-ai"

import { AgentSession } from "./agent-session.js"
import type { ModelRegistry } from "./model-registry.js"
import type { OpenZiPaths } from "./paths.js"
import type { ResourceLoader } from "./resource-loader.js"
import type { SessionManager } from "./session-manager.js"
import type { SettingsManager } from "./settings-manager.js"
import { buildSystemPrompt } from "./system-prompt.js"

export interface AgentSessionServices {
  paths: OpenZiPaths
  settingsManager: SettingsManager
  modelRegistry: ModelRegistry
  resourceLoader: ResourceLoader
}

export interface CreateAgentSessionOptions {
  services: AgentSessionServices
  sessionManager: SessionManager
  model: Model<Api>
  tools: readonly AgentTool[]
}

export async function createAgentSession(options: CreateAgentSessionOptions): Promise<AgentSession> {
  const { services, sessionManager, model } = options
  await services.resourceLoader.reload()
  const settings = services.settingsManager.get()
  const thinkingLevel = clampThinkingLevel(model, settings.thinkingLevel)
  const existing = sessionManager.entries().length > 0
  services.settingsManager.applyRuntime({ thinkingLevel })

  const agent = new Agent({
    initialState: {
      systemPrompt: buildSystemPrompt(services.paths.cwd, services.resourceLoader.get()),
      model,
      thinkingLevel,
      tools: [...options.tools],
      messages: sessionManager.messages()
    },
    sessionId: sessionManager.sessionId,
    streamFn: (requestedModel, context, streamOptions) =>
      services.modelRegistry.models.streamSimple(requestedModel, context, streamOptions),
    steeringMode: settings.steeringMode,
    followUpMode: settings.followUpMode,
    toolExecution: "parallel"
  })

  if (!existing) {
    sessionManager.appendModelChange(model.provider, model.id)
    sessionManager.appendThinkingLevelChange(thinkingLevel)
  }

  return new AgentSession({
    agent,
    sessionManager,
    settingsManager: services.settingsManager,
    modelRegistry: services.modelRegistry
  })
}
