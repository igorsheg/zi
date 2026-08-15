import type { ExtensionMode, ExtensionShutdownReason } from "@with-zi/extension-api"

import type { AgentSession } from "../agent-session.js"
import { CodeMode } from "../code-mode/code-mode.js"
import { discoverExtensionLoadPlan, extensionDiscoveryDiagnostic } from "../extensions/discovery.js"
import { ExtensionHost } from "../extensions/host.js"
import { spawnExtensionWorker } from "../extensions/process.js"
import { resolveRequestedModel } from "../model-resolver.js"
import type { ProcessTreeTracker } from "../processes/process-tree.js"
import type { ProjectConfigurationAdmission } from "../project-trust.js"
import { createAgentSessionWithProcessTreeTracker, type AgentSessionServices } from "../sdk.js"
import { SessionManager } from "../session-manager.js"
import { SessionShell } from "../session-shell.js"
import { createCodingTools } from "../tools/index.js"
import type { CreateSubagentChildSession, SubagentChildSession } from "./child.js"

export interface SubagentSessionFactoryOptions {
  readonly services: AgentSessionServices
  readonly project: ProjectConfigurationAdmission
  readonly processTreeTracker: ProcessTreeTracker
  readonly extensionWorkerCommand: readonly string[]
  readonly codeModeWorkerCommand: readonly string[]
  readonly extensionMode: ExtensionMode
}

export function createSubagentSessionFactory(options: SubagentSessionFactoryOptions): CreateSubagentChildSession {
  return async request => {
    if (request.signal?.aborted) throw spawnCancellation(request.name)
    const { services, project, processTreeTracker } = options
    const sessionManager = SessionManager.create(services.paths, { persist: false })
    const extensions = discoverExtensionLoadPlan(services.paths, project, [], services.settingsManager)
    const extensionHost = new ExtensionHost(
      plan => spawnExtensionWorker(plan, options.extensionWorkerCommand, processTreeTracker),
      undefined,
      { subagents: false }
    )
    const shell = new SessionShell({ cwd: services.paths.cwd, sessionId: sessionManager.sessionId, processTreeTracker })
    const codeMode = new CodeMode(services.paths.cwd, options.codeModeWorkerCommand, sessionManager, processTreeTracker)
    let child: SubagentChildSession | undefined
    let cancellationCleanup: Promise<void> | undefined
    const cancelStartup = (): void => {
      cancellationCleanup ??= extensionHost.dispose("quit")
    }
    request.signal?.addEventListener("abort", cancelStartup, { once: true })
    try {
      extensionHost.admitDiagnostics(
        extensions.diagnostics.map(extensionDiscoveryDiagnostic),
        extensions.omittedDiagnostics
      )
      await extensionHost.start(extensions.plan)
      if (request.signal?.aborted) throw spawnCancellation(request.name)
      const model = resolveRequestedModel(services.modelRegistry, request.model)
      const resources = await services.resourceLoader.load()
      if (request.signal?.aborted) throw spawnCancellation(request.name)
      const created = await createAgentSessionWithProcessTreeTracker(
        {
          services,
          sessionManager,
          model,
          thinkingLevel: request.thinkingLevel,
          ...(request.apiKey ? { apiKey: request.apiKey } : {}),
          tools: createCodingTools({ cwd: services.paths.cwd, shell }),
          shell,
          extensionHost,
          extensionMode: options.extensionMode,
          resources,
          codeMode,
          project,
          peerRelay: request.peerRelay,
          toolSurface: request.toolSurface
        },
        { type: "borrowed", tracker: processTreeTracker }
      )
      child = sessionOwner(created.session)
      if (request.signal?.aborted) throw spawnCancellation(request.name)
      await created.session.startExtensionLifecycle("startup")
      if (request.signal?.aborted) throw spawnCancellation(request.name)
      return child
    } catch (cause) {
      try {
        if (child) await child.dispose("quit")
        else await disposeCreationResources(codeMode, extensionHost, shell)
      } catch (cleanupCause) {
        throw new Error(
          `${errorMessage(cause, "Subagent session creation failed")}; cleanup failed: ${errorMessage(cleanupCause, "unknown cleanup error")}`,
          { cause: cleanupCause }
        )
      }
      throw cause
    } finally {
      request.signal?.removeEventListener("abort", cancelStartup)
      await cancellationCleanup
    }
  }
}

function sessionOwner(session: AgentSession): SubagentChildSession {
  return Object.freeze({
    session,
    async dispose(reason: ExtensionShutdownReason): Promise<void> {
      session.dispose(reason)
      await session.waitForIdle()
    }
  })
}

async function disposeCreationResources(
  codeMode: CodeMode,
  extensionHost: ExtensionHost,
  shell: SessionShell
): Promise<void> {
  const results = await Promise.allSettled([codeMode.dispose(), extensionHost.dispose(), shell.dispose()])
  const failures = results.flatMap(result => (result.status === "rejected" ? [result.reason] : []))
  if (failures.length === 1) throw failures[0]
  if (failures.length > 1) throw new AggregateError(failures, "Subagent session resource cleanup failed")
}

function errorMessage(cause: unknown, fallback: string): string {
  return cause instanceof Error && cause.message ? cause.message : fallback
}

function spawnCancellation(name: string): Error {
  return new Error(`Subagent ${name} spawn was cancelled`)
}
