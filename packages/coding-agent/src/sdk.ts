import { Agent, type AgentTool, type ThinkingLevel } from "@earendil-works/pi-agent-core"
import { clampThinkingLevel, type Api, type Model } from "@earendil-works/pi-ai"
import type { ExtensionContext, ExtensionMode, ExtensionSession } from "@with-zi/extension-api"
import { InvariantRegistry, type InvariantRegistryOptions } from "@with-zi/invariants"

import { AgentSessionInvariant } from "./agent-session-invariant.js"
import { AgentSession, type SessionReloadDeps } from "./agent-session.js"
import { AgentTeam, type CreateAgentTeamSession } from "./agent-team/agent-team.js"
import { rootAgentPath, type AgentPath } from "./agent-team/path.js"
import { createAgentTeamRoot } from "./agent-team/session.js"
import { Authentication } from "./authentication.js"
import type { CodeMode } from "./code-mode/code-mode.js"
import { isCodeModeDetails } from "./code-mode/trace.js"
import { applyCodexRequestSettings } from "./codex-settings.js"
import type { FileCredentialStore } from "./credential-store.js"
import { DEFAULT_THINKING_LEVEL } from "./defaults.js"
import type { ExtensionHost } from "./extensions/host.js"
import { convertToLlm, type AgentMessage } from "./messages.js"
import type { ModelRegistry } from "./model-registry.js"
import { findInitialModel, restoreModelFromSession } from "./model-resolver.js"
import type { ZiPaths } from "./paths.js"
import { createProcessTreeTracker, type ProcessTreeTracker } from "./processes/process-tree.js"
import { ProjectFileSearch } from "./project-file-search.js"
import type { ProjectConfigurationAdmission } from "./project-trust.js"
import { createSessionResources, type ResourceLoader, type SessionResources } from "./resource-loader.js"
import type { SessionManager, SessionModel } from "./session-manager.js"
import type { SessionShell } from "./session-shell.js"
import type { SettingsManager } from "./settings-manager.js"
import { buildSystemPrompt } from "./system-prompt.js"
import { snapshotToolSurface, type ToolSurface } from "./tool-surface.js"
import { isBuiltInToolError } from "./tools/index.js"
import { createUpdatePlanTool } from "./tools/work-plan.js"
import { WorkPlan } from "./work-plan.js"

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
  readonly extensionMode?: ExtensionMode
  readonly resources?: SessionResources
  readonly codeMode?: CodeMode
  readonly project?: ProjectConfigurationAdmission
  readonly extensionPaths?: readonly string[]
  readonly agentTeam?: AgentTeamMembership
  readonly toolSurface?: ToolSurface
  readonly invariants?: InvariantRegistryOptions
}

export type AgentTeamMembership =
  | { readonly type: "root"; readonly createChildSession: CreateAgentTeamSession }
  | { readonly type: "member"; readonly team: AgentTeam; readonly path: AgentPath }

export type AgentSessionProcessTree =
  | { readonly type: "owned"; readonly tracker: ProcessTreeTracker }
  | { readonly type: "borrowed"; readonly tracker: ProcessTreeTracker }

/** Build one session from caller-owned services. The caller owns the returned session's disposal. */
export function createAgentSession(options: CreateAgentSessionOptions): Promise<CreateAgentSessionResult> {
  return createAgentSessionWithProcessTreeTracker(options, { type: "owned", tracker: createProcessTreeTracker() })
}

export async function createAgentSessionWithProcessTreeTracker(
  options: CreateAgentSessionOptions,
  processTree: AgentSessionProcessTree
): Promise<CreateAgentSessionResult> {
  const { services, sessionManager } = options
  if (options.toolSurface && !options.codeMode) throw new Error("Tool surface selection requires Code Mode")
  const invariantRegistry = new InvariantRegistry(options.invariants)
  const toolSurface = options.codeMode ? snapshotToolSurface(options.toolSurface ?? "direct-and-code") : undefined
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
  let session: AgentSession | undefined
  let ownedTeam: AgentTeam | undefined
  if (options.tools.some(tool => tool.name === "update_plan")) {
    throw new Error("The tool name update_plan is reserved for the native work plan")
  }
  const reservedAgentTools = new Set([
    "spawn_agent",
    "send_message",
    "followup_task",
    "wait_agent",
    "list_agents",
    "interrupt_agent"
  ])
  if (options.tools.some(tool => reservedAgentTools.has(tool.name))) {
    throw new Error("Agent collaboration tool names are reserved for AgentTeam")
  }
  const membership = options.agentTeam
  const team =
    membership?.type === "root"
      ? await AgentTeam.create({
          paths: services.paths,
          rootSessionManager: sessionManager,
          createSession: membership.createChildSession,
          turnTimeoutMs: settings.agentTurnTimeoutMs,
          shutdownTimeoutMs: 9_000
        })
      : membership?.team
  if (membership?.type === "root") ownedTeam = team
  const agentPath = membership?.type === "member" ? membership.path : rootAgentPath
  const workPlan = new WorkPlan(sessionManager)
  const sessionTools = Object.freeze([...options.tools, createUpdatePlanTool(workPlan)])
  const agent = new Agent({
    initialState: {
      systemPrompt: buildSystemPrompt(sessionManager.header.cwd, resources, sessionTools, toolSurface),
      ...(model ? { model } : {}),
      thinkingLevel,
      tools: [...sessionTools],
      messages: [...bootstrap.messages]
    },
    convertToLlm,
    sessionId: sessionManager.sessionId,
    streamFn: (requestedModel, requestContext, streamOptions) => {
      const apiKey = requestedModel.provider === model?.provider ? options.apiKey : undefined
      const codexFastMode = services.settingsManager.get().codexFastMode
      const onPayload =
        requestedModel.provider === "openai-codex"
          ? (payload: unknown, payloadModel: Model<Api>) =>
              applyCodexRequestSettings(payload, payloadModel, codexFastMode, streamOptions?.onPayload)
          : streamOptions?.onPayload
      return services.modelRegistry.models.streamSimple(requestedModel, requestContext, {
        ...streamOptions,
        ...(onPayload ? { onPayload } : {}),
        ...(apiKey ? { apiKey } : {})
      })
    },
    steeringMode: settings.steeringMode,
    followUpMode: settings.followUpMode,
    toolExecution: "parallel",
    afterToolCall: async ({ toolCall, result, isError }) =>
      !isError &&
      (isBuiltInToolError(toolCall.name, result.details) ||
        (toolCall.name === "code" && isCodeModeDetails(result.details) && result.details.outcome === "error"))
        ? { isError: true }
        : undefined
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

  const reload: SessionReloadDeps = Object.freeze({
    resourceLoader: services.resourceLoader,
    paths: services.paths,
    project: options.project ?? "absent",
    extensionPaths: Object.freeze([...(options.extensionPaths ?? [])])
  })
  const agentSessionInvariant = new AgentSessionInvariant(invariantRegistry)
  try {
    session = new AgentSession({
      agent,
      sessionManager,
      settingsManager: services.settingsManager,
      authentication: new Authentication(services.modelRegistry.models, services.credentialStore),
      modelRegistry: services.modelRegistry,
      resources,
      projectFileSearch: new ProjectFileSearch(services.paths),
      tools: sessionTools,
      toolSurface,
      reload,
      invariantRegistry,
      agentSessionInvariant,
      ...(team ? { agentTeam: { team, path: agentPath, owned: ownedTeam === team } } : {}),
      ...(options.codeMode ? { codeMode: options.codeMode } : {}),
      ...(options.extensionHost ? { extensionHost: options.extensionHost } : {}),
      extensionContext: createExtensionContext(options.extensionMode ?? "embedded", services, sessionManager),
      ...(processTree.type === "owned" ? { ownedProcessTreeTracker: processTree.tracker } : {}),
      workPlan,
      ...(options.shell ? { shell: options.shell } : {}),
      ...(model ? { model } : {}),
      ...(options.apiKey && model ? { apiKeyProvider: model.provider } : {})
    })
    if (ownedTeam) await ownedTeam.bindRoot(createAgentTeamRoot(session))
  } catch (cause) {
    if (session) {
      session.dispose()
      await session.waitForIdle()
    } else if (ownedTeam) {
      await ownedTeam.shutdown().catch(() => {})
      agentSessionInvariant.dispose()
      invariantRegistry.dispose()
    } else {
      agentSessionInvariant.dispose()
      invariantRegistry.dispose()
    }
    throw cause
  }
  return Object.freeze({ session, ...(bootstrapDiagnostic ? { bootstrapDiagnostic } : {}) })
}

function createExtensionContext(
  mode: ExtensionMode,
  services: AgentSessionServices,
  sessionManager: SessionManager
): ExtensionContext {
  const session: ExtensionSession = sessionManager.file
    ? Object.freeze({ type: "journal", id: sessionManager.sessionId, file: sessionManager.file })
    : Object.freeze({ type: "memory", id: sessionManager.sessionId })
  return Object.freeze({ mode, cwd: services.paths.cwd, session })
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
