import { Agent, type AgentTool, type ThinkingLevel } from "@earendil-works/pi-agent-core"
import { clampThinkingLevel, type Api, type Model } from "@earendil-works/pi-ai"

import { AgentSession } from "./agent-session.js"
import { Authentication } from "./authentication.js"
import { CodeModePrototype } from "./code-mode-prototype.js"
import type { FileCredentialStore } from "./credential-store.js"
import { DEFAULT_THINKING_LEVEL } from "./defaults.js"
import type { ExtensionHost } from "./extensions/host.js"
import { admitExtensionTools } from "./extensions/tools.js"
import { convertToLlm, type AgentMessage } from "./messages.js"
import type { ModelRegistry } from "./model-registry.js"
import { findInitialModel, restoreModelFromSession } from "./model-resolver.js"
import type { ZiPaths } from "./paths.js"
import { ProjectFileSearch } from "./project-file-search.js"
import { createSessionResources, type ResourceLoader, type SessionResources } from "./resource-loader.js"
import type { SessionManager, SessionModel } from "./session-manager.js"
import type { SessionShell } from "./session-shell.js"
import type { SettingsManager } from "./settings-manager.js"
import { buildSystemPrompt } from "./system-prompt.js"
import { isBuiltInToolError } from "./tools/index.js"

export interface AgentSessionServices {
  readonly paths: ZiPaths
  readonly settingsManager: SettingsManager
  readonly credentialStore: FileCredentialStore
  readonly modelRegistry: ModelRegistry
  readonly resourceLoader: ResourceLoader
}

type SessionBootstrap =
  | {
      readonly type: "new"
      readonly messages: readonly AgentMessage[]
      readonly model?: SessionModel
      readonly thinkingLevel?: ThinkingLevel
    }
  | {
      readonly type: "resumed"
      readonly messages: readonly AgentMessage[]
      readonly model?: SessionModel
      readonly thinkingLevel?: ThinkingLevel
    }

export type SessionBootstrapDiagnostic =
  | {
      readonly type: "model_fallback"
      readonly savedModel: SessionModel
      readonly fallbackModel: SessionModel
      readonly message: string
    }
  | { readonly type: "resumed_model_unavailable"; readonly savedModel: SessionModel; readonly message: string }
  | { readonly type: "no_model"; readonly message: string }

export interface CreateAgentSessionResult {
  readonly session: AgentSession
  readonly bootstrapDiagnostic?: SessionBootstrapDiagnostic
}

export interface CreateAgentSessionOptions {
  readonly services: AgentSessionServices
  readonly sessionManager: SessionManager
  readonly model?: Model<Api>
  readonly thinkingLevel?: ThinkingLevel
  readonly apiKey?: string
  readonly tools: readonly AgentTool[]
  readonly shell?: SessionShell
  readonly extensionHost?: ExtensionHost
  readonly resources?: SessionResources
  readonly codeModePrototype?: boolean
}

/** Build one session from caller-owned services. The caller owns the returned session's disposal. */
export async function createAgentSession(options: CreateAgentSessionOptions): Promise<CreateAgentSessionResult> {
  const { services, sessionManager } = options
  const resources = options.resources ? createSessionResources(options.resources) : await services.resourceLoader.load()
  const settings = services.settingsManager.get()
  const context = sessionManager.buildSessionContext()
  const bootstrap: SessionBootstrap =
    context.messages.length === 0 ? { type: "new", ...context } : { type: "resumed", ...context }

  let model = options.model
  let unavailableSessionModel: SessionModel | undefined
  if (!model && bootstrap.type === "resumed" && bootstrap.model) {
    model = await restoreModelFromSession(services.modelRegistry, bootstrap.model)
    if (!model) unavailableSessionModel = bootstrap.model
  }
  model ??= await findInitialModel(
    services.modelRegistry,
    services.settingsManager.getDefaultProvider(),
    services.settingsManager.getDefaultModel(),
    options.apiKey !== undefined
  )

  const preferredThinking =
    options.thinkingLevel ??
    (bootstrap.type === "resumed" ? bootstrap.thinkingLevel : undefined) ??
    services.settingsManager.getDefaultThinkingLevel() ??
    DEFAULT_THINKING_LEVEL
  const thinkingLevel = model ? clampThinkingLevel(model, preferredThinking) : "off"
  const bootstrapDiagnostic = createBootstrapDiagnostic(unavailableSessionModel, model)
  const tools = admitExtensionTools(options.tools, options.extensionHost)
  const codeModePrototype = options.codeModePrototype ? new CodeModePrototype() : undefined
  const modelTools = codeModePrototype ? [codeModePrototype.createTool(tools)] : tools

  const agent = new Agent({
    initialState: {
      systemPrompt: buildSystemPrompt(sessionManager.header.cwd, resources, tools, codeModePrototype !== undefined),
      ...(model ? { model } : {}),
      thinkingLevel,
      tools: [...modelTools],
      messages: [...bootstrap.messages]
    },
    convertToLlm,
    sessionId: sessionManager.sessionId,
    streamFn: (requestedModel, requestContext, streamOptions) => {
      const apiKey = requestedModel.provider === model?.provider ? options.apiKey : undefined
      return services.modelRegistry.models.streamSimple(requestedModel, requestContext, {
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

  switch (bootstrap.type) {
    case "new":
      if (model) sessionManager.appendModelChange(model.provider, model.id)
      sessionManager.appendThinkingLevelChange(thinkingLevel)
      break
    case "resumed":
      if (bootstrap.thinkingLevel === undefined) sessionManager.appendThinkingLevelChange(thinkingLevel)
      break
    default:
      return assertNever(bootstrap)
  }

  const session = new AgentSession({
    agent,
    sessionManager,
    settingsManager: services.settingsManager,
    authentication: new Authentication(services.modelRegistry.models, services.credentialStore),
    modelRegistry: services.modelRegistry,
    resources,
    projectFileSearch: new ProjectFileSearch(services.paths),
    tools: options.tools,
    ...(codeModePrototype ? { codeModePrototype } : {}),
    ...(options.extensionHost ? { extensionHost: options.extensionHost } : {}),
    ...(options.shell ? { shell: options.shell } : {}),
    ...(model ? { model } : {}),
    ...(options.apiKey && model ? { apiKeyProvider: model.provider } : {})
  })
  return Object.freeze({ session, ...(bootstrapDiagnostic ? { bootstrapDiagnostic } : {}) })
}

function createBootstrapDiagnostic(
  sessionModel: SessionModel | undefined,
  model: Model<Api> | undefined
): SessionBootstrapDiagnostic | undefined {
  if (sessionModel && model) {
    const savedModel = Object.freeze({ ...sessionModel })
    const fallbackModel = Object.freeze({ provider: model.provider, modelId: model.id })
    return Object.freeze({
      type: "model_fallback",
      savedModel,
      fallbackModel,
      message: `Could not restore model ${savedModel.provider}/${savedModel.modelId}. Using ${model.provider}/${model.id}.`
    })
  }
  if (sessionModel) {
    const savedModel = Object.freeze({ ...sessionModel })
    return Object.freeze({
      type: "resumed_model_unavailable",
      savedModel,
      message: `Could not restore model ${savedModel.provider}/${savedModel.modelId}. No configured models are available.`
    })
  }
  if (!model) {
    return Object.freeze({ type: "no_model", message: "No configured models are available. Use /login, then /model." })
  }
  return undefined
}

function assertNever(value: never): never {
  throw new Error(`Unknown session bootstrap state: ${String(value)}`)
}
