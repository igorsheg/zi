import type { ExtensionMode } from "@with-zi/extension-api"

import type { AgentSession } from "../agent-session.js"
import { CodeMode } from "../code-mode/code-mode.js"
import { discoverExtensionLoadPlan, extensionDiscoveryDiagnostic } from "../extensions/discovery.js"
import { ExtensionHost } from "../extensions/host.js"
import { spawnExtensionWorker } from "../extensions/process.js"
import { resolveRequestedModel } from "../model-resolver.js"
import type { ProcessTreeTracker } from "../processes/process-tree.js"
import type { ProjectConfigurationAdmission } from "../project-trust.js"
import { createAgentSessionWithProcessTreeTracker, type AgentSessionServices } from "../sdk.js"
import { SessionShell } from "../session-shell.js"
import type { ToolSurface } from "../tool-surface.js"
import { createCodingTools } from "../tools/index.js"
import type { CreateAgentTeamSession } from "./agent-team.js"
import { createAgentTeamSessionOwner } from "./session.js"

export interface AgentTeamSessionFactoryOptions {
  readonly services: AgentSessionServices
  readonly project: ProjectConfigurationAdmission
  readonly processTreeTracker: ProcessTreeTracker
  readonly extensionWorkerCommand: readonly string[]
  readonly codeModeWorkerCommand: readonly string[]
  readonly extensionMode: ExtensionMode
  readonly toolSurface: ToolSurface
}

export function createAgentTeamSessionFactory(options: AgentTeamSessionFactoryOptions): CreateAgentTeamSession {
  return async request => {
    const { services, project, processTreeTracker } = options
    const extensions = discoverExtensionLoadPlan(services.paths, project, [], services.settingsManager)
    const extensionHost = new ExtensionHost(
      plan => spawnExtensionWorker(plan, options.extensionWorkerCommand, processTreeTracker),
      undefined,
      { subagents: false }
    )
    const shell = new SessionShell({
      cwd: services.paths.cwd,
      sessionId: request.sessionManager.sessionId,
      processTreeTracker
    })
    const codeMode = new CodeMode(
      services.paths.cwd,
      options.codeModeWorkerCommand,
      request.sessionManager,
      processTreeTracker
    )
    let session: AgentSession | undefined
    try {
      extensionHost.admitDiagnostics(
        extensions.diagnostics.map(extensionDiscoveryDiagnostic),
        extensions.omittedDiagnostics
      )
      await extensionHost.start(extensions.plan)
      const resources = await services.resourceLoader.load()
      const role =
        request.roleSelection ??
        (request.role === undefined
          ? undefined
          : (resources.subagentProfiles.find(item => item.name === request.role) ??
            extensionHost.subagentCatalog().find(item => item.name === request.role)))
      if (request.role !== undefined && !role) throw new Error(`Unknown agent role: ${request.role}`)
      const model = role?.model ? resolveRequestedModel(services.modelRegistry, role.model) : undefined
      const result = await createAgentSessionWithProcessTreeTracker(
        {
          services,
          sessionManager: request.sessionManager,
          ...(model ? { model } : {}),
          ...(role?.thinking ? { thinkingLevel: role.thinking } : {}),
          tools: createCodingTools({ cwd: services.paths.cwd, shell }),
          shell,
          extensionHost,
          extensionMode: options.extensionMode,
          resources,
          codeMode,
          project,
          agentTeam: { type: "member", team: request.team, path: request.path },
          toolSurface: options.toolSurface
        },
        { type: "borrowed", tracker: processTreeTracker }
      )
      session = result.session
      await session.startExtensionLifecycle("startup")
      return createAgentTeamSessionOwner(session)
    } catch (cause) {
      if (session) {
        session.dispose()
        await session.waitForIdle()
      } else {
        await disposeCreationResources(codeMode, extensionHost, shell)
      }
      throw cause
    }
  }
}

async function disposeCreationResources(
  codeMode: CodeMode,
  extensionHost: ExtensionHost,
  shell: SessionShell
): Promise<void> {
  const results = await Promise.allSettled([codeMode.dispose(), extensionHost.dispose(), shell.dispose()])
  const failures = results.flatMap(result => (result.status === "rejected" ? [result.reason] : []))
  if (failures.length === 1) throw failures[0]
  if (failures.length > 1) throw new AggregateError(failures, "Agent session resource cleanup failed")
}
