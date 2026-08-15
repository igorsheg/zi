import { mkdir, mkdtemp, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type { Context } from "@earendil-works/pi-ai"
import { InvariantRegistry } from "@with-zi/invariants"

import { FileCredentialStore } from "../src/credential-store.js"
import { ModelRegistry } from "../src/model-registry.js"
import { ZiPaths } from "../src/paths.js"
import { ResourceLoader, createSessionResources } from "../src/resource-loader.js"
import { createAgentSession, type AgentSessionServices } from "../src/sdk.js"
import { SessionManager } from "../src/session-manager.js"
import { SettingsManager } from "../src/settings-manager.js"
import type { CreateSubagentChildSession, SubagentChildSessionRequest } from "../src/subagents/child.js"
import { SubagentSupervisor } from "../src/subagents/supervisor.js"
import { createModels, fauxAssistantMessage, fauxProvider } from "../src/testing.js"

export interface InProcessSubagentHarnessOptions {
  readonly reply?: string | ((request: SubagentChildSessionRequest, prompt: string, call: number) => string)
  readonly delayMs?: number | ((request: SubagentChildSessionRequest, prompt: string, call: number) => number)
  readonly workTimeoutMs?: number
  readonly closeSettlementMs?: number
  readonly childDisposeNeverSettles?: boolean
  readonly failResultPersistence?: boolean
  readonly onCreate?: (request: SubagentChildSessionRequest) => void
  readonly onRunStart?: (request: SubagentChildSessionRequest, prompt: string) => void
  readonly onRunEnd?: (request: SubagentChildSessionRequest, prompt: string) => void
}

export async function createInProcessSubagentHarness(name: string, options: InProcessSubagentHarnessOptions = {}) {
  const root = await mkdtemp(join(tmpdir(), `zi-subagent-${name}-`))
  const paths = new ZiPaths(join(root, "project"), join(root, "agent"))
  await mkdir(paths.cwd, { recursive: true })
  const sessionManager = SessionManager.create(paths, { persist: false })
  const createChildSession = createTestChildSessionFactory(paths, options)
  const supervisor = new SubagentSupervisor({
    createChildSession,
    selection: () => ({ model: "faux/faux-1", thinkingLevel: "off" }),
    sessionManager,
    invariantRegistry: new InvariantRegistry(),
    ...(options.workTimeoutMs ? { workTimeoutMs: options.workTimeoutMs } : {}),
    ...(options.closeSettlementMs ? { closeSettlementMs: options.closeSettlementMs } : {})
  })
  supervisor.bindSubagentWorkResultSink((result, persisted) => {
    if (options.failResultPersistence) throw new Error("result persistence unavailable")
    const entry = sessionManager.appendSubagentWorkResult(result)
    persisted(entry)
    return entry
  })
  return {
    root,
    paths,
    sessionManager,
    supervisor,
    createChildSession,
    async dispose(): Promise<void> {
      await supervisor.shutdown().catch(() => {})
      await rm(root, { recursive: true, force: true })
    }
  }
}

export function createTestChildSessionFactory(
  paths: ZiPaths,
  options: InProcessSubagentHarnessOptions = {}
): CreateSubagentChildSession {
  return async request => {
    options.onCreate?.(request)
    const models = createModels()
    const faux = fauxProvider()
    models.setProvider(faux.provider)
    const responses = Array.from({ length: 64 }, (_, index) => async (context: Context) => {
      const prompt = context.messages.findLast(message => message.role === "user")
      const content = prompt?.role === "user" ? prompt.content : ""
      const text =
        typeof content === "string"
          ? content
          : content
              .filter(block => block.type === "text")
              .map(block => block.text)
              .join("")
      options.onRunStart?.(request, text)
      try {
        const delayMs =
          typeof options.delayMs === "function" ? options.delayMs(request, text, index + 1) : options.delayMs
        if (delayMs) await Bun.sleep(delayMs)
        const reply =
          typeof options.reply === "function"
            ? options.reply(request, text, index + 1)
            : (options.reply ?? "child-done")
        return fauxAssistantMessage(reply)
      } finally {
        options.onRunEnd?.(request, text)
      }
    })
    faux.setResponses(responses)
    const services: AgentSessionServices = Object.freeze({
      paths,
      settingsManager: new SettingsManager(),
      credentialStore: new FileCredentialStore(paths),
      modelRegistry: new ModelRegistry(models),
      resourceLoader: new ResourceLoader({ paths, project: "trusted" })
    })
    const created = await createAgentSession({
      services,
      sessionManager: SessionManager.create(paths, { persist: false }),
      model: faux.getModel(),
      thinkingLevel: request.thinkingLevel,
      tools: [],
      resources: createSessionResources(),
      peerRelay: request.peerRelay
    })
    await created.session.startExtensionLifecycle("startup")
    return Object.freeze({
      session: created.session,
      async dispose(): Promise<void> {
        created.session.dispose()
        if (options.childDisposeNeverSettles) await new Promise<void>(() => {})
        await created.session.waitForIdle()
      }
    })
  }
}

export async function waitFor(predicate: () => boolean, timeoutMs = 5_000): Promise<void> {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    if (predicate()) return
    // oxlint-disable-next-line no-await-in-loop -- polling observes an asynchronous state transition.
    await Bun.sleep(10)
  }
  throw new Error("condition not met before deadline")
}
