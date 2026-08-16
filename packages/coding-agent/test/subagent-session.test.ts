import { expect, test } from "bun:test"
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { fileURLToPath } from "node:url"

import { FileCredentialStore } from "../src/credential-store.js"
import { ModelRegistry } from "../src/model-registry.js"
import { ZiPaths } from "../src/paths.js"
import type { ProcessScope, ProcessTreeTracker } from "../src/processes/process-tree.js"
import { createProcessTreeTracker } from "../src/processes/process-tree.js"
import { ResourceLoader } from "../src/resource-loader.js"
import { type AgentSessionServices } from "../src/sdk.js"
import { SettingsManager } from "../src/settings-manager.js"
import type { PeerRelay } from "../src/subagents/peer.js"
import { createSubagentSessionFactory } from "../src/subagents/session.js"
import { createModels, createTestAgentRuntime, fauxAssistantMessage, fauxProvider } from "../src/testing.js"

const extensionWorkerCommand = Object.freeze([
  process.execPath,
  fileURLToPath(new URL("../src/extensions/worker-entry.ts", import.meta.url))
])
const unavailablePeerRelay: PeerRelay = () => Promise.reject(new Error("Peer relay unavailable in session unit test"))

const codeModeWorkerCommand = Object.freeze([
  process.execPath,
  fileURLToPath(new URL("../src/code-mode/worker-entry.ts", import.meta.url))
])

test("depth-zero production runtimes enable in-process subagents without a subprocess command", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-subagent-runtime-"))
  const cwd = join(root, "project")
  const agentDir = join(root, "agent")
  await mkdir(cwd, { recursive: true })
  await mkdir(join(agentDir, "subagents"), { recursive: true })
  await writeFile(
    join(agentDir, "subagents", "reviewer.md"),
    `---\ndescription: Review a change\n---\nReturn concrete findings.\n`
  )
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  let tools: readonly string[] = []
  faux.setResponses([
    context => {
      tools = (context.tools ?? []).map(tool => tool.name)
      return fauxAssistantMessage("inspected")
    }
  ])
  const runtime = await createTestAgentRuntime({
    cwd,
    agentDir,
    models,
    model: "faux/faux-1",
    session: { type: "new", persist: false }
  })
  try {
    await runtime.session.prompt("inspect tools")
    expect(tools).toEqual(
      expect.arrayContaining([
        "spawn_agent",
        "send_message",
        "followup_task",
        "wait_agent",
        "list_agents",
        "interrupt_agent"
      ])
    )
    expect(tools).not.toContain("spawn_subagent")
    expect(tools).not.toContain("wait_subagents")
    expect(tools).not.toContain("list_peer_subagents")
    expect(tools).not.toContain("send_peer_message")
  } finally {
    runtime.session.dispose()
    await runtime.session.waitForIdle()
    await rm(root, { recursive: true, force: true })
  }
})

test("production factory cancellation disposes a worker blocked in extension startup", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-subagent-session-cancel-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "agent"))
  await mkdir(paths.cwd, { recursive: true })
  await mkdir(join(paths.globalDir, "extensions"), { recursive: true })
  await writeFile(
    join(paths.globalDir, "extensions", "pending.ts"),
    `await new Promise(() => {})
export default function (): void {}
`
  )

  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  const settingsManager = SettingsManager.create(paths, "trusted")
  const services: AgentSessionServices = Object.freeze({
    paths,
    settingsManager,
    credentialStore: new FileCredentialStore(paths),
    modelRegistry: new ModelRegistry(models),
    resourceLoader: new ResourceLoader({ paths, project: "trusted", settingsManager })
  })
  const ownedTracker = createProcessTreeTracker()
  let trackedScopes = 0
  let disposedScopes = 0
  const tracker: ProcessTreeTracker = {
    track(pid, onFailure): ProcessScope {
      trackedScopes++
      const scope = ownedTracker.track(pid, onFailure)
      return {
        platform: scope.platform,
        workerPid: scope.workerPid,
        admitted: scope.admitted,
        snapshot: () => scope.snapshot(),
        refresh: () => scope.refresh(),
        terminate: () => scope.terminate(),
        async dispose(): Promise<void> {
          disposedScopes++
          await scope.dispose()
        }
      }
    },
    dispose: () => ownedTracker.dispose()
  }
  const factory = createSubagentSessionFactory({
    services,
    project: "trusted",
    processTreeTracker: tracker,
    extensionWorkerCommand,
    codeModeWorkerCommand,
    extensionMode: "embedded"
  })
  const controller = new AbortController()
  const creation = factory({
    name: "cancelled-worker",
    model: "faux/faux-1",
    thinkingLevel: "off",
    toolSurface: "direct-and-code",
    peerRelay: unavailablePeerRelay,
    signal: controller.signal
  })

  try {
    expect(trackedScopes).toBe(1)
    controller.abort()
    const boundedCreation = Promise.race([
      creation,
      Bun.sleep(3_000).then(() => {
        throw new Error("cancelled production factory did not settle promptly")
      })
    ])
    expect(boundedCreation).rejects.toThrow("spawn was cancelled")
    expect(disposedScopes).toBe(1)
  } finally {
    await creation.catch(() => {})
    await tracker.dispose()
    await rm(root, { recursive: true, force: true })
  }
})

test("production child sessions are ephemeral, depth-one, extension-started, and borrow the process tracker", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-subagent-session-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "agent"))
  const lifecycle = join(root, "lifecycle.log")
  await mkdir(paths.cwd, { recursive: true })
  await mkdir(join(paths.globalDir, "extensions"), { recursive: true })
  await mkdir(join(paths.globalDir, "subagents"), { recursive: true })
  await writeFile(
    join(paths.globalDir, "extensions", "lifecycle.ts"),
    `import { appendFileSync } from "node:fs"
import type { ExtensionAPI } from "@with-zi/extension-api"
export default function (zi: ExtensionAPI): void {
  zi.on("session_start", event => appendFileSync(${JSON.stringify(lifecycle)}, "start:" + event.reason + "\\n"))
  zi.on("session_shutdown", event => appendFileSync(${JSON.stringify(lifecycle)}, "stop:" + event.reason + "\\n"))
}
`
  )
  await writeFile(
    join(paths.globalDir, "subagents", "reviewer.md"),
    `---\ndescription: Review a change\n---\nReturn concrete findings.\n`
  )

  const models = createModels()
  const faux = fauxProvider()
  const reasoningModel = { ...faux.getModel(), reasoning: true }
  models.setProvider({ ...faux.provider, getModels: () => [reasoningModel] })
  let tools: readonly string[] = []
  faux.setResponses([
    context => {
      tools = (context.tools ?? []).map(tool => tool.name)
      return fauxAssistantMessage("inspected")
    }
  ])
  const settingsManager = SettingsManager.create(paths, "trusted")
  const services: AgentSessionServices = Object.freeze({
    paths,
    settingsManager,
    credentialStore: new FileCredentialStore(paths),
    modelRegistry: new ModelRegistry(models),
    resourceLoader: new ResourceLoader({ paths, project: "trusted", settingsManager })
  })
  const ownedTracker = createProcessTreeTracker()
  let trackerDisposals = 0
  const tracker: ProcessTreeTracker = {
    track: (pid, onFailure) => ownedTracker.track(pid, onFailure),
    async dispose(): Promise<void> {
      trackerDisposals++
      await ownedTracker.dispose()
    }
  }
  const factory = createSubagentSessionFactory({
    services,
    project: "trusted",
    processTreeTracker: tracker,
    extensionWorkerCommand,
    codeModeWorkerCommand,
    extensionMode: "embedded"
  })

  let owner: Awaited<ReturnType<typeof factory>> | undefined
  try {
    owner = await factory({
      name: "reviewer-1",
      model: "faux/faux-1",
      thinkingLevel: "high",
      toolSurface: "direct-and-code",
      peerRelay: unavailablePeerRelay
    })
    expect(owner.session.sessionManager.file).toBeUndefined()
    expect(owner.session.model).toMatchObject({ provider: "faux", id: "faux-1" })
    expect(owner.session.thinkingLevel).toBe("high")
    expect(owner.session.extensionHostSnapshot).toMatchObject({ status: "ready", lifecycle: "started" })
    expect(await readFile(lifecycle, "utf8")).toBe("start:startup\n")

    await owner.session.prompt("inspect tools")
    expect(tools).not.toContain("spawn_subagent")
    expect(tools).not.toContain("list_subagent_profiles")
    expect(tools).toContain("list_peer_subagents")
    expect(tools).toContain("send_peer_message")

    await owner.dispose("quit")
    owner = undefined
    expect(await readFile(lifecycle, "utf8")).toBe("start:startup\nstop:quit\n")
    expect(trackerDisposals).toBe(0)
  } finally {
    await owner?.dispose("quit").catch(() => {})
    await tracker.dispose()
    await rm(root, { recursive: true, force: true })
  }
})
