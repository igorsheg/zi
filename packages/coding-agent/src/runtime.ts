import { fileURLToPath } from "node:url"

// Pi AI keeps OAuth flows behind dynamic imports for browser bundlers. Standalone
// Bun binaries register the static loaders so /login can open subscription flows.
import { createModels, type Models } from "@earendil-works/pi-ai"
import { registerBunOAuthFlows } from "@earendil-works/pi-ai/bun-oauth"
import { builtinProviders, getBuiltinModelDataGeneratedAt } from "@earendil-works/pi-ai/providers/all"

registerBunOAuthFlows()

import type { AgentSession } from "./agent-session.js"
import { createAgentTeamSessionFactory } from "./agent-team/session-factory.js"
import { CodeMode } from "./code-mode/code-mode.js"
import { FileCredentialStore } from "./credential-store.js"
import { discoverExtensionLoadPlan, extensionDiscoveryDiagnostic } from "./extensions/discovery.js"
import { ExtensionHost } from "./extensions/host.js"
import { spawnExtensionWorker } from "./extensions/process.js"
import { FileModelCatalogStore } from "./model-catalog-store.js"
import { ModelRegistry } from "./model-registry.js"
import { resolveRequestedModel } from "./model-resolver.js"
import { getAgentDir, ZiPaths } from "./paths.js"
import { createProcessTreeTracker } from "./processes/process-tree.js"
import { projectConfigurationAdmission, resolveProjectTrust, type ProjectTrustResolution } from "./project-trust.js"
import { withRemoteModelCatalog } from "./remote-model-catalog.js"
import { ResourceLoader } from "./resource-loader.js"
import {
  snapshotAgentRuntimeOptions,
  type AgentRuntimeSessionIntent,
  type CreateAgentRuntimeOptions
} from "./runtime-options.js"
import {
  createAgentSessionWithProcessTreeTracker,
  type AgentSessionServices,
  type SessionBootstrapDiagnostic
} from "./sdk.js"
import { SessionManager } from "./session-manager.js"
import { SessionShell } from "./session-shell.js"
import { SettingsManager } from "./settings-manager.js"
import { createCodingTools } from "./tools/index.js"

export type { AgentRuntimeSessionIntent, CreateAgentRuntimeOptions } from "./runtime-options.js"
export type { ToolSurface } from "./tool-surface.js"

export type AgentRuntimeServices = AgentSessionServices

export interface AgentRuntime {
  readonly session: AgentSession
  readonly services: AgentRuntimeServices
  readonly projectTrust: ProjectTrustResolution
  readonly bootstrapDiagnostic: SessionBootstrapDiagnostic | undefined
}

/** Assemble cwd-bound production services and a session. The caller owns `session.dispose()`. */
export async function createAgentRuntime(requested: CreateAgentRuntimeOptions): Promise<AgentRuntime> {
  const runtime = await createUnboundAgentRuntime(requested)
  try {
    await runtime.session.startExtensionLifecycle("startup")
    return runtime
  } catch (cause) {
    runtime.session.dispose()
    await runtime.session.waitForIdle()
    throw cause
  }
}

export async function createUnboundAgentRuntime(requested: CreateAgentRuntimeOptions): Promise<AgentRuntime> {
  const options = snapshotAgentRuntimeOptions(requested)
  const session = options.session ?? defaultRuntimeSession
  const agentDir = options.agentDir ?? getAgentDir()
  const requestedPaths = new ZiPaths(options.cwd, agentDir, options.sessionDir)
  const selected = await selectSession(session, requestedPaths)
  const cwd = selected.type === "resumed" ? selected.manager.header.cwd : options.cwd
  const sessionDir = options.sessionDir ?? (selected.type === "resumed" ? selected.manager.sessionDir : undefined)
  const paths = new ZiPaths(cwd, agentDir, sessionDir)
  const projectTrust = await resolveProjectTrust(paths, options.projectTrust)
  const project = projectConfigurationAdmission(projectTrust)
  const settingsManager = SettingsManager.create(paths, project, options.settings ?? {})
  const extensions = discoverExtensionLoadPlan(paths, project, options.extensionPaths ?? [], settingsManager)
  const processTreeTracker = createProcessTreeTracker()
  const extensionWorkerCommand = options.extensionWorkerCommand ?? defaultExtensionWorkerCommand
  const extensionHost = new ExtensionHost(
    plan => spawnExtensionWorker(plan, extensionWorkerCommand, processTreeTracker),
    undefined,
    { agents: true }
  )
  let shell: SessionShell | undefined
  try {
    extensionHost.admitDiagnostics(
      extensions.diagnostics.map(extensionDiscoveryDiagnostic),
      extensions.omittedDiagnostics
    )
    await extensionHost.start(extensions.plan)
    const credentialStore = new FileCredentialStore(paths)
    let models: Models
    let modelCatalogStore: FileModelCatalogStore | undefined
    if (options.modelFactory) {
      models = options.modelFactory(credentialStore)
    } else {
      modelCatalogStore = new FileModelCatalogStore(paths)
      models = createProductionModels(credentialStore, modelCatalogStore)
    }
    const modelRegistry = new ModelRegistry(models)
    if (modelCatalogStore) await modelRegistry.refresh({ allowNetwork: false })
    const resourceLoader = new ResourceLoader({
      paths,
      project,
      settingsManager,
      ...(options.systemPrompt === undefined ? {} : { systemPrompt: options.systemPrompt }),
      ...(options.appendSystemPrompt === undefined ? {} : { appendSystemPrompt: options.appendSystemPrompt })
    })
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
      selected.type === "resumed" ? selected.manager : SessionManager.create(paths, { persist: selected.persist })
    shell = new SessionShell({ cwd: paths.cwd, sessionId: sessionManager.sessionId, processTreeTracker })
    const codeMode = new CodeMode(
      paths.cwd,
      options.codeModeWorkerCommand ?? defaultCodeModeWorkerCommand,
      sessionManager,
      processTreeTracker
    )
    const extensionMode = options.extensionMode ?? "embedded"
    const createAgentTeamSession = createAgentTeamSessionFactory({
      services,
      project,
      processTreeTracker,
      extensionWorkerCommand,
      codeModeWorkerCommand: options.codeModeWorkerCommand ?? defaultCodeModeWorkerCommand,
      extensionMode,
      toolSurface: options.toolSurface ?? "direct-and-code"
    })
    const created = await createAgentSessionWithProcessTreeTracker(
      {
        services,
        sessionManager,
        shell,
        extensionHost,
        extensionMode,
        codeMode,
        project,
        extensionPaths: options.extensionPaths ?? [],
        agentTeam: { type: "root", createChildSession: createAgentTeamSession },
        toolSurface: options.toolSurface ?? "direct-and-code",
        ...(model ? { model } : {}),
        ...(options.thinkingLevel ? { thinkingLevel: options.thinkingLevel } : {}),
        ...(options.apiKey ? { apiKey: options.apiKey } : {}),
        tools: createCodingTools({ cwd: paths.cwd, shell })
      },
      { type: "owned", tracker: processTreeTracker }
    )
    return Object.freeze({
      session: created.session,
      services,
      projectTrust,
      bootstrapDiagnostic: created.bootstrapDiagnostic
    })
  } catch (cause) {
    await Promise.all([extensionHost.dispose(), shell?.dispose() ?? Promise.resolve()])
    await processTreeTracker.dispose()
    throw cause
  }
}

function createProductionModels(credentials: FileCredentialStore, modelsStore: FileModelCatalogStore) {
  const models = createModels({ credentials, modelsStore })
  const localGeneratedAt = getBuiltinModelDataGeneratedAt()
  const userAgent = `zi/${process.env.ZI_BUILD_VERSION ?? "dev"}`
  for (const provider of builtinProviders()) {
    models.setProvider(
      provider.id === "radius"
        ? provider
        : withRemoteModelCatalog(provider, {
            userAgent,
            ...(localGeneratedAt === undefined ? {} : { localGeneratedAt })
          })
    )
  }
  return models
}

const defaultRuntimeSession: AgentRuntimeSessionIntent = Object.freeze({ type: "new", persist: true })
const defaultCodeModeWorkerCommand = Object.freeze([
  process.execPath,
  fileURLToPath(new URL("./code-mode/worker-entry.ts", import.meta.url))
])
const defaultExtensionWorkerCommand = Object.freeze([
  process.execPath,
  fileURLToPath(new URL("./extensions/worker-entry.ts", import.meta.url))
])

type SelectedSession =
  | { readonly type: "new"; readonly persist: boolean }
  | { readonly type: "resumed"; readonly manager: SessionManager }

async function selectSession(session: AgentRuntimeSessionIntent, paths: ZiPaths): Promise<SelectedSession> {
  switch (session.type) {
    case "new":
      return { type: "new", persist: session.persist }
    case "continue":
      return { type: "resumed", manager: await SessionManager.continueRecent(paths) }
    case "resume":
      return { type: "resumed", manager: SessionManager.open(session.file) }
    default:
      return assertNever(session)
  }
}

function resolveSettingsModel(registry: ModelRegistry, settings: SettingsManager) {
  const provider = settings.getDefaultProvider()
  const modelId = settings.getDefaultModel()
  if (!provider || !modelId) throw new Error("--api-key requires a model so its provider can be determined")
  const model = registry.get(provider, modelId)
  if (!model) throw new Error(`Unknown model: ${provider}/${modelId}. Use provider/model-id.`)
  return model
}

function assertNever(value: never): never {
  throw new Error(`Unknown runtime session: ${String(value)}`)
}
