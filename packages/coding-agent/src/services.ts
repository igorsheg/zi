import { Agent, type AgentTool } from "@earendil-works/pi-agent-core"
import { clampThinkingLevel, type Api, type Model } from "@earendil-works/pi-ai"

import { AgentSession } from "./agent-session.js"
import { Authentication } from "./authentication.js"
import type { FileCredentialStore } from "./credential-store.js"
import type { ModelRegistry } from "./model-registry.js"
import type { OpenZiPaths } from "./paths.js"
import { createSessionResources, type ResourceLoader, type SessionResources } from "./resource-loader.js"
import type { SessionManager } from "./session-manager.js"
import type { SessionShell } from "./session-shell.js"
import type { SettingsManager } from "./settings-manager.js"
import { buildSystemPrompt } from "./system-prompt.js"
import { isBuiltInToolError } from "./tools/index.js"

export interface AgentSessionServices {
  readonly paths: OpenZiPaths
  readonly settingsManager: SettingsManager
  readonly credentialStore: FileCredentialStore
  readonly modelRegistry: ModelRegistry
  readonly resourceLoader: ResourceLoader
}

export interface CreateAgentSessionOptions {
  readonly services: AgentSessionServices
  readonly sessionManager: SessionManager
  readonly model?: Model<Api>
  readonly apiKey?: string
  readonly tools: readonly AgentTool[]
  readonly shell?: SessionShell
  readonly resources?: SessionResources
}

/** Build one session from caller-owned services. The caller owns the returned session's disposal. */
export async function createAgentSession(options: CreateAgentSessionOptions): Promise<AgentSession> {
  const { services, sessionManager, model } = options
  const resources = options.resources ? createSessionResources(options.resources) : await services.resourceLoader.load()
  const settings = services.settingsManager.get()
  const thinkingLevel = model ? clampThinkingLevel(model, settings.thinkingLevel) : "off"
  const existing = sessionManager.entries().length > 0
  services.settingsManager.applyRuntime({ thinkingLevel })

  const agent = new Agent({
    initialState: {
      systemPrompt: buildSystemPrompt(sessionManager.header.cwd, resources, options.tools),
      ...(model ? { model } : {}),
      thinkingLevel,
      tools: [...options.tools],
      messages: sessionManager.messages()
    },
    sessionId: sessionManager.sessionId,
    streamFn: (requestedModel, context, streamOptions) => {
      const apiKey = requestedModel.provider === model?.provider ? options.apiKey : undefined
      return services.modelRegistry.models.streamSimple(requestedModel, context, {
        ...streamOptions,
        ...(apiKey ? { apiKey } : {})
      })
    },
    steeringMode: settings.steeringMode,
    followUpMode: settings.followUpMode,
    toolExecution: "parallel",
    afterToolCall: async ({ toolCall, result, isError }) =>
      !isError && isBuiltInToolError(toolCall.name, result.details) ? { isError: true } : undefined
  })

  if (!existing) {
    if (model) sessionManager.appendModelChange(model.provider, model.id)
    sessionManager.appendThinkingLevelChange(thinkingLevel)
  }

  return new AgentSession({
    agent,
    sessionManager,
    settingsManager: services.settingsManager,
    authentication: new Authentication(services.modelRegistry.models, services.credentialStore),
    modelRegistry: services.modelRegistry,
    resources,
    ...(options.shell ? { shell: options.shell } : {}),
    ...(model ? { model } : {}),
    ...(options.apiKey && model ? { apiKeyProvider: model.provider } : {})
  })
}
