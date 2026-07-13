import { Agent, type AgentTool } from "@earendil-works/pi-agent-core"
import type { Api, Model } from "@earendil-works/pi-ai"
import { AgentSession } from "./agent-session.js"
import type { ModelRegistry } from "./model-registry.js"
import type { ResourceLoader } from "./resource-loader.js"
import type { SessionManager } from "./session-manager.js"
import type { SettingsManager } from "./settings-manager.js"
import { buildSystemPrompt } from "./system-prompt.js"

export interface AgentSessionServices {
  cwd: string
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
  const existing = sessionManager.entries().length > 0

  const agent = new Agent({
    initialState: {
      systemPrompt: buildSystemPrompt(services.cwd, services.resourceLoader.get()),
      model,
      thinkingLevel: settings.thinkingLevel,
      tools: [...options.tools],
      messages: sessionManager.messages(),
    },
    sessionId: sessionManager.sessionId,
    streamFn: (requestedModel, context, streamOptions) =>
      services.modelRegistry.models.streamSimple(requestedModel, context, streamOptions),
    steeringMode: settings.steeringMode,
    followUpMode: settings.followUpMode,
    toolExecution: "parallel",
  })

  if (!existing) {
    sessionManager.appendModelChange(model.provider, model.id)
    sessionManager.appendThinkingLevelChange(settings.thinkingLevel)
  }

  return new AgentSession({ agent, sessionManager, settingsManager: services.settingsManager })
}
