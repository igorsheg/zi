import { expect, test } from "bun:test"
import { existsSync } from "node:fs"
import { access, copyFile, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join, resolve } from "node:path"

import { Type } from "@earendil-works/pi-ai"

import { createAgentSessionRuntime } from "../src/agent-session-runtime.js"
import { createAgentRuntime } from "../src/runtime.js"
import { SessionManager } from "../src/session-manager.js"
import { createModels, fauxAssistantMessage, fauxProvider, fauxText, fauxToolCall } from "../src/testing.js"

const cli = resolve(import.meta.dirname, "../../cli/src/main.ts")
const mockChild = resolve(import.meta.dirname, "fixtures/mock-rpc-child.ts")
const workerCommand = Object.freeze([process.execPath, cli])

function programmaticProfileSource(name: string): string {
  return `import type { ExtensionAPI } from "@with-zi/extension-api"
export default function (zi: ExtensionAPI): void {
  zi.registerSubagentProfile({ name: "${name}", description: "${name} profile", instructions: "Work." })
}
`
}

test("AgentSession owns one discovered extension lifecycle through final disposal", async () => {
  const fixture = await extensionFixture("direct")
  const runtime = await createAgentRuntime({
    cwd: fixture.cwd,
    agentDir: fixture.agentDir,
    session: { type: "new", persist: false },
    extensionWorkerCommand: workerCommand
  })

  try {
    const snapshot = runtime.session.extensionHostSnapshot
    expect(snapshot).toMatchObject({
      status: "ready",
      lifecycle: "started",
      extensions: [{ status: "loaded" }],
      stdout: { text: "runtime extension stdout\n" },
      stderr: { text: "runtime extension stderr\n" }
    })
    if (!existsSync(fixture.lifecycle)) {
      throw new Error(`Lifecycle handler did not run: ${JSON.stringify(snapshot)}`)
    }
    expect(await readFile(fixture.lifecycle, "utf8")).toBe("start:startup\n")
  } finally {
    runtime.session.dispose()
    await runtime.session.waitForIdle()
  }

  expect(await readFile(fixture.lifecycle, "utf8")).toBe("start:startup\nstop:quit\n")
  await rm(fixture.root, { recursive: true, force: true })
}, 10_000)

test("runtime extension discovery consumes configured settings paths", async () => {
  const fixture = await extensionFixture("settings-path")
  const configured = join(fixture.agentDir, "configured", "lifecycle.ts")
  await mkdir(join(fixture.agentDir, "configured"), { recursive: true })
  await copyFile(join(fixture.agentDir, "extensions", "lifecycle.ts"), configured)
  await rm(join(fixture.agentDir, "extensions"), { recursive: true })
  await writeFile(join(fixture.agentDir, "settings.json"), JSON.stringify({ extensions: ["configured/lifecycle.ts"] }))

  const runtime = await createAgentRuntime({
    cwd: fixture.cwd,
    agentDir: fixture.agentDir,
    session: { type: "new", persist: false },
    extensionWorkerCommand: workerCommand
  })

  try {
    expect(runtime.session.extensionHostSnapshot).toMatchObject({
      status: "ready",
      extensions: [{ status: "loaded", source: { declaredPath: configured, origin: "settings" } }]
    })
    await waitForFile(fixture.lifecycle)

    const reloaded = join(fixture.agentDir, "configured", "reloaded.ts")
    await copyFile(configured, reloaded)
    await writeFile(join(fixture.agentDir, "settings.json"), JSON.stringify({ extensions: ["configured/reloaded.ts"] }))

    expect(await runtime.session.reload()).toMatchObject({ extensions: { outcome: "replaced" } })
    expect(runtime.session.extensionHostSnapshot).toMatchObject({
      status: "ready",
      extensions: [{ status: "loaded", source: { declaredPath: reloaded, origin: "settings" } }]
    })
  } finally {
    runtime.session.dispose()
    await runtime.session.waitForIdle()
    await rm(fixture.root, { recursive: true, force: true })
  }
}, 10_000)

test("AgentSession publishes one final settled notification after a turn", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-runtime-extension-agent-events-"))
  const cwd = join(root, "project")
  const agentDir = join(root, "agent")
  const extensionDir = join(agentDir, "extensions")
  const log = join(root, "events.log")
  await mkdir(cwd, { recursive: true })
  await mkdir(extensionDir, { recursive: true })
  await writeFile(
    join(extensionDir, "events.ts"),
    `import { appendFileSync } from "node:fs"
import type { ExtensionAPI } from "@with-zi/extension-api"
export default function (zi: ExtensionAPI): void {
  zi.on("agent_start", (event, context) => appendFileSync(${JSON.stringify(log)}, event.type + ":" + context.mode + "\\n"))
  zi.on("agent_settled", (event, context) => appendFileSync(${JSON.stringify(log)}, event.type + ":" + context.mode + "\\n"))
}
`
  )
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  faux.setResponses([fauxAssistantMessage(fauxText("Done."))])
  const runtime = await createAgentRuntime({
    cwd,
    agentDir,
    model: "faux/faux-1",
    modelFactory: () => models,
    session: { type: "new", persist: false },
    extensionWorkerCommand: workerCommand
  })

  try {
    await runtime.session.prompt("Complete the task.")
    await waitForCondition(() => existsSync(log) && Bun.file(log).size > 0, 1_000)
    await waitForCondition(() => {
      if (!existsSync(log)) return false
      return Bun.file(log)
        .text()
        .then(text => text.endsWith("agent_settled:embedded\n"))
    }, 1_000)
    expect(await readFile(log, "utf8")).toBe("agent_start:embedded\nagent_settled:embedded\n")
  } finally {
    runtime.session.dispose()
    await runtime.session.waitForIdle()
    await rm(root, { recursive: true, force: true })
  }
}, 10_000)

test("agent retry publishes one final extension settlement", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-runtime-extension-retry-event-"))
  const cwd = join(root, "project")
  const agentDir = join(root, "agent")
  const extensionDir = join(agentDir, "extensions")
  const log = join(root, "events.log")
  await mkdir(cwd, { recursive: true })
  await mkdir(extensionDir, { recursive: true })
  await writeFile(
    join(extensionDir, "events.ts"),
    `import { appendFileSync } from "node:fs"
export default function (zi): void {
  zi.on("agent_start", event => appendFileSync(${JSON.stringify(log)}, event.type + "\\n"))
  zi.on("agent_settled", event => appendFileSync(${JSON.stringify(log)}, event.type + "\\n"))
}
`
  )
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  faux.setResponses([
    fauxAssistantMessage("", { stopReason: "error", errorMessage: "overloaded_error" }),
    fauxAssistantMessage(fauxText("Recovered."))
  ])
  const runtime = await createAgentRuntime({
    cwd,
    agentDir,
    model: "faux/faux-1",
    modelFactory: () => models,
    session: { type: "new", persist: false },
    settings: { retryEnabled: true, retryMaxRetries: 1, retryBaseDelayMs: 0 },
    extensionWorkerCommand: workerCommand
  })

  try {
    await runtime.session.prompt("Retry once.")
    await waitForCondition(
      async () => existsSync(log) && (await Bun.file(log).text()).endsWith("agent_settled\n"),
      1_000
    )
    const events = (await readFile(log, "utf8")).trim().split("\n")
    expect(events.filter(event => event === "agent_start").length).toBeGreaterThanOrEqual(1)
    expect(events.filter(event => event === "agent_settled")).toHaveLength(1)
    expect(events.at(-1)).toBe("agent_settled")
  } finally {
    runtime.session.dispose()
    await runtime.session.waitForIdle()
    await rm(root, { recursive: true, force: true })
  }
}, 10_000)

test("a blocked agent event handler cannot delay AgentSession settlement", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-runtime-extension-blocked-event-"))
  const cwd = join(root, "project")
  const agentDir = join(root, "agent")
  const extensionDir = join(agentDir, "extensions")
  await mkdir(cwd, { recursive: true })
  await mkdir(extensionDir, { recursive: true })
  await writeFile(
    join(extensionDir, "blocked.ts"),
    `export default zi => zi.on("agent_start", () => { while (true) {} })\n`
  )
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  faux.setResponses([fauxAssistantMessage(fauxText("Settled independently."))])
  const runtime = await createAgentRuntime({
    cwd,
    agentDir,
    model: "faux/faux-1",
    modelFactory: () => models,
    session: { type: "new", persist: false },
    extensionWorkerCommand: workerCommand
  })

  try {
    await runtime.session.prompt("Complete without the observer.")
    expect(runtime.session.messages.at(-1)).toMatchObject({ role: "assistant" })
    await waitForCondition(() => runtime.session.extensionHostSnapshot?.status === "failed", 2_000)
    expect(runtime.session.extensionHostSnapshot).toMatchObject({
      failure: { phase: "event", message: "Extension agent event did not settle within 1000ms" }
    })
  } finally {
    runtime.session.dispose()
    await runtime.session.waitForIdle()
    await rm(root, { recursive: true, force: true })
  }
}, 10_000)

test("runtime freezes memory and journal extension identities", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-runtime-extension-context-"))
  const cwd = join(root, "project")
  const agentDir = join(root, "agent")
  const extensionDir = join(agentDir, "extensions")
  const log = join(root, "contexts.log")
  await mkdir(cwd, { recursive: true })
  await mkdir(extensionDir, { recursive: true })
  await writeFile(
    join(extensionDir, "context.ts"),
    `import { appendFileSync } from "node:fs"
export default zi => zi.on("session_start", (_event, context) => {
  appendFileSync(${JSON.stringify(log)}, JSON.stringify({
    ...context,
    frozen: Object.isFrozen(context) && Object.isFrozen(context.session)
  }) + "\\n")
})
`
  )

  const memory = await createAgentRuntime({
    cwd,
    agentDir,
    session: { type: "new", persist: false },
    extensionWorkerCommand: workerCommand
  })
  const memoryId = memory.session.sessionManager.sessionId
  memory.session.dispose()
  await memory.session.waitForIdle()

  const journal = await createAgentRuntime({
    cwd,
    agentDir,
    session: { type: "new", persist: true },
    extensionWorkerCommand: workerCommand
  })
  const journalId = journal.session.sessionManager.sessionId
  const journalFile = journal.session.sessionManager.file
  journal.session.dispose()
  await journal.session.waitForIdle()

  const contexts = (await readFile(log, "utf8"))
    .trim()
    .split("\n")
    .map(line => JSON.parse(line))
  expect(contexts).toEqual([
    { mode: "embedded", cwd, session: { type: "memory", id: memoryId }, frozen: true },
    { mode: "embedded", cwd, session: { type: "journal", id: journalId, file: journalFile }, frozen: true }
  ])
  await rm(root, { recursive: true, force: true })
}, 10_000)

test("session shutdown handlers can commit final extension state before operations unbind", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-runtime-extension-shutdown-state-"))
  const cwd = join(root, "project")
  const agentDir = join(root, "agent")
  const extensionDir = join(agentDir, "extensions")
  await mkdir(cwd, { recursive: true })
  await mkdir(extensionDir, { recursive: true })
  await writeFile(
    join(extensionDir, "shutdown-state.ts"),
    `import type { ExtensionAPI } from "@with-zi/extension-api"
export default function (zi: ExtensionAPI): void {
  zi.on("session_shutdown", async () => {
    const previous = await zi.getSessionEntries("example.shutdown")
    await zi.appendEntry("example.shutdown", { previous: previous.length })
  })
}
`
  )
  const runtime = await createAgentRuntime({
    cwd,
    agentDir,
    session: { type: "new", persist: true },
    extensionWorkerCommand: workerCommand
  })
  const sessionFile = runtime.session.sessionManager.file!

  runtime.session.dispose()
  await runtime.session.waitForIdle()

  expect(runtime.session.extensionHostSnapshot).toBeUndefined()
  expect(SessionManager.open(sessionFile).customEntries("example.shutdown")).toMatchObject([{ data: { previous: 0 } }])
  await rm(root, { recursive: true, force: true })
}, 10_000)

test("runtime project trust excludes extension code before worker startup", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-runtime-extension-trust-"))
  const cwd = join(root, "project")
  const agentDir = join(root, "agent")
  const extensionDir = join(cwd, ".zi", "extensions")
  const loaded = join(root, "loaded.log")
  await mkdir(extensionDir, { recursive: true })
  await writeFile(
    join(extensionDir, "project.ts"),
    `import { writeFileSync } from "node:fs"
export default function (): void { writeFileSync(${JSON.stringify(loaded)}, "loaded") }
`
  )

  const runtime = await createAgentSessionRuntime({
    cwd,
    agentDir,
    session: { type: "new", persist: false },
    extensionWorkerCommand: workerCommand
  })
  const excluded = runtime.session
  expect(runtime.projectTrust.type).toBe("unresolved")
  expect(excluded.extensionHostSnapshot).toMatchObject({ status: "disabled", extensions: [] })
  expect(access(loaded)).rejects.toThrow()

  try {
    await runtime.decideProjectTrust({ type: "trusted", persistence: "session" })
    expect(await readFile(loaded, "utf8")).toBe("loaded")
    expect(runtime.session.extensionHostSnapshot).toMatchObject({ status: "ready", lifecycle: "started" })
    expect(() => excluded.prompt("disposed")).toThrow("AgentSession is disposed")
  } finally {
    runtime.dispose()
    await runtime.waitForIdle()
    await rm(root, { recursive: true, force: true })
  }
}, 10_000)

test("extension commands are idle session actions with durable state and model-invisible feedback", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-runtime-extension-command-"))
  const cwd = join(root, "project")
  const agentDir = join(root, "agent")
  const extensionDir = join(agentDir, "extensions")
  await mkdir(cwd, { recursive: true })
  await mkdir(extensionDir, { recursive: true })
  await writeFile(
    join(extensionDir, "counter.ts"),
    `import type { ExtensionAPI } from "@with-zi/extension-api"
export default function (zi: ExtensionAPI): void {
  let count = 0
  zi.on("session_start", async () => {
    const latest = (await zi.getSessionEntries("example.counter")).at(-1)?.data
    if (typeof latest === "object" && latest !== null && !Array.isArray(latest) && typeof latest.count === "number") {
      count = latest.count
    }
  })
  zi.registerCommand({
    name: "counter",
    description: "Manage the durable counter",
    argumentHint: "[show|increment|wait]",
    async execute(arguments_, { signal }) {
      if (arguments_ === "wait") {
        if (!signal.aborted) await new Promise(resolve => signal.addEventListener("abort", resolve, { once: true }))
        return "late"
      }
      if (arguments_ === "increment") {
        count++
        await zi.appendEntry("example.counter", { count })
      }
      return "Counter: " + count
    }
  })
  zi.registerCommand({ name: "reload", description: "Must not shadow the built-in", execute: () => "shadow" })
  zi.registerCommand({ name: "new", description: "Must also not shadow the built-in", execute: () => "shadow" })
}
`
  )
  const runtime = await createAgentRuntime({
    cwd,
    agentDir,
    session: { type: "new", persist: true },
    extensionWorkerCommand: workerCommand
  })

  try {
    expect(runtime.session.listExtensionCommands()).toEqual([
      {
        name: "counter",
        description: "Manage the durable counter",
        argumentHint: "[show|increment|wait]",
        extensionId: expect.any(String)
      }
    ])
    expect(
      runtime.session.extensionHostSnapshot?.diagnostics.filter(
        diagnostic => diagnostic.phase === "registration" && diagnostic.message.includes("built-in command")
      )
    ).toHaveLength(2)
    expect(await runtime.session.invokeExtensionCommand("counter", "increment")).toBe("Counter: 1")
    expect(runtime.session.messages).toEqual([])
    expect(runtime.session.getCustomEntries("example.counter")).toMatchObject([{ data: { count: 1 } }])

    const pending = runtime.session.invokeExtensionCommand("counter", "wait")
    const observed = pending.then(
      value => ({ type: "resolved" as const, value }),
      cause => ({ type: "rejected" as const, cause })
    )
    expect(runtime.session.extensionCommandStatus).toEqual({ type: "running", name: "counter", phase: "executing" })
    expect(() => runtime.session.invokeExtensionCommand("counter", "show")).toThrow("agent is running")
    await runtime.session.abort()
    expect(await observed).toEqual({ type: "rejected", cause: expect.objectContaining({ name: "AbortError" }) })
    expect(runtime.session.extensionCommandStatus).toEqual({ type: "idle" })

    expect((await runtime.session.reload()).extensions?.outcome).toBe("replaced")
    const reloadDiagnostics = runtime.session.extensionHostSnapshot?.diagnostics ?? []
    expect(
      reloadDiagnostics.filter(
        diagnostic => diagnostic.phase === "registration" && diagnostic.message.includes("built-in command")
      )
    ).toHaveLength(4)
    expect(reloadDiagnostics.some(diagnostic => diagnostic.phase === "protocol")).toBe(false)
    expect(await runtime.session.invokeExtensionCommand("counter", "show")).toBe("Counter: 1")
    expect(runtime.session.messages).toEqual([])
  } finally {
    runtime.session.dispose()
    await runtime.session.waitForIdle()
    await rm(root, { recursive: true, force: true })
  }
}, 10_000)

test("a registered extension tool joins a real agent turn and durable history", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-runtime-extension-tool-"))
  const cwd = join(root, "project")
  const agentDir = join(root, "agent")
  const extensionDir = join(agentDir, "extensions", "repository-tool")
  const dependencyDir = join(extensionDir, "node_modules", "repository-prefix")
  await mkdir(cwd, { recursive: true })
  await mkdir(dependencyDir, { recursive: true })
  await writeFile(
    join(dependencyDir, "package.json"),
    JSON.stringify({ name: "repository-prefix", type: "module", exports: "./index.js" })
  )
  await writeFile(join(dependencyDir, "index.js"), `export const prefix = "repository"\n`)
  await writeFile(
    join(extensionDir, "index.ts"),
    `import { Schema, type ExtensionAPI } from "@with-zi/extension-api"
import { prefix } from "repository-prefix"
export default function (zi: ExtensionAPI): void {
  zi.registerTool({
    name: "repository_echo",
    description: "Echo a repository value",
    parameters: Schema.object({ value: Schema.string() }),
    outputSchema: Schema.object({ prefix: Schema.string(), value: Schema.string() }),
    execute: ({ value }, { reportProgress }) => {
      reportProgress("Resolving " + value)
      return { prefix, value }
    }
  })
}
`
  )
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  faux.setResponses([
    fauxAssistantMessage(fauxToolCall("repository_echo", { value: "accepted" }, { id: "extension-tool-1" }), {
      stopReason: "toolUse"
    }),
    context => {
      expect(JSON.stringify(context)).not.toContain("Resolving accepted")
      return fauxAssistantMessage(
        fauxToolCall(
          "code",
          { code: `async () => (await zi.repository_echo({ value: "nested" })).value` },
          { id: "extension-code-1" }
        ),
        { stopReason: "toolUse" }
      )
    },
    context => {
      expect(JSON.stringify(context)).not.toContain("Resolving accepted")
      expect(JSON.stringify(context)).not.toContain("Resolving nested")
      return fauxAssistantMessage(fauxText("Extension completed."))
    }
  ])
  const runtime = await createAgentRuntime({
    cwd,
    agentDir,
    model: "faux/faux-1",
    modelFactory: () => models,
    session: { type: "new", persist: true }
  })

  const progress: Array<{ readonly toolCallId: string; readonly text: string; readonly details: unknown }> = []
  const unsubscribe = runtime.session.subscribe(event => {
    if (event.type !== "tool_execution_update") return
    const content = event.partialResult.content[0]
    if (content?.type === "text") {
      progress.push({ toolCallId: event.toolCallId, text: content.text, details: event.partialResult.details })
    }
  })

  try {
    await runtime.session.prompt("Use the repository echo tool.")
    const results = runtime.session.messages.filter(message => message.role === "toolResult")
    expect(results).toHaveLength(2)
    expect(results[0]).toMatchObject({
      toolCallId: "extension-tool-1",
      toolName: "repository_echo",
      content: [{ type: "text", text: '{"prefix":"repository","value":"accepted"}' }],
      details: { type: "extension", toolName: "repository_echo", outcome: "success" }
    })
    expect(results[1]).toMatchObject({
      toolCallId: "extension-code-1",
      toolName: "code",
      content: [{ type: "text", text: "nested" }],
      details: {
        type: "code_mode",
        outcome: "success",
        calls: [expect.objectContaining({ name: "repository_echo", state: "succeeded" })]
      }
    })
    expect(progress).toContainEqual({
      toolCallId: "extension-tool-1",
      text: "Resolving accepted",
      details: expect.objectContaining({ type: "extension", toolName: "repository_echo", outcome: "progress" })
    })
    expect(progress).toContainEqual({
      toolCallId: "extension-code-1",
      text: "Running repository_echo",
      details: expect.objectContaining({
        type: "code_mode",
        outcome: "progress",
        calls: [expect.objectContaining({ name: "repository_echo", preview: "Resolving nested" })]
      })
    })
    const journal = await readFile(runtime.session.sessionManager.file!, "utf8")
    expect(journal).not.toContain("Resolving accepted")
    expect(journal).not.toContain("Resolving nested")
    expect(runtime.session.extensionHostSnapshot).toMatchObject({ status: "ready", lifecycle: "started" })
  } finally {
    unsubscribe()
    runtime.session.dispose()
    await runtime.session.waitForIdle()
    await rm(root, { recursive: true, force: true })
  }
}, 10_000)

test("extension tools replace an extension-scoped catalog at provider-step boundaries", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-runtime-extension-active-tools-"))
  const cwd = join(root, "project")
  const agentDir = join(root, "agent")
  const extensionDir = join(agentDir, "extensions")
  await mkdir(cwd, { recursive: true })
  await mkdir(extensionDir, { recursive: true })
  await writeFile(
    join(extensionDir, "active-tools.ts"),
    `import { Schema, type ExtensionAPI } from "@with-zi/extension-api"
export default function (zi: ExtensionAPI): void {
  zi.registerTool({
    name: "activate_catalog",
    description: "Activate the dormant tool",
    parameters: Schema.object({}),
    async execute() {
      const before = await zi.getActiveTools()
      let crossExtensionRefused = false
      try {
        await zi.setActiveTools(["other_extension_tool"])
      } catch {
        crossExtensionRefused = true
      }
      await zi.setActiveTools(["activate_catalog", "deactivate_catalog", "dormant_echo"])
      const after = await zi.getActiveTools()
      return JSON.stringify({ before, crossExtensionRefused, after })
    }
  })
  zi.registerTool({
    name: "deactivate_catalog",
    description: "Hide the dormant tool",
    parameters: Schema.object({}),
    async execute() {
      await zi.setActiveTools(["activate_catalog"])
      return "Catalog deactivated"
    }
  })
  zi.registerTool({
    name: "dormant_echo",
    description: "Echo one value after activation",
    active: false,
    parameters: Schema.object({ value: Schema.string() }),
    execute: ({ value }) => "dormant:" + value
  })
}
`
  )
  await writeFile(
    join(extensionDir, "other-tools.ts"),
    `import { Schema, type ExtensionAPI } from "@with-zi/extension-api"
export default function (zi: ExtensionAPI): void {
  zi.registerTool({
    name: "other_extension_tool",
    description: "A tool owned by another extension",
    parameters: Schema.object({}),
    execute: () => "other"
  })
}
`
  )
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  faux.setResponses([
    fauxAssistantMessage(
      [
        fauxToolCall("activate_catalog", {}, { id: "activate-catalog" }),
        fauxToolCall("dormant_echo", { value: "same-batch" }, { id: "dormant-same-batch" }),
        fauxToolCall(
          "code",
          { code: `async () => { await zi.activate_catalog({}); return typeof zi.dormant_echo }` },
          { id: "code-same-batch" }
        )
      ],
      { stopReason: "toolUse" }
    ),
    fauxAssistantMessage(fauxToolCall("dormant_echo", { value: "direct" }, { id: "dormant-direct" }), {
      stopReason: "toolUse"
    }),
    fauxAssistantMessage(fauxToolCall("other_extension_tool", {}, { id: "other-direct" }), { stopReason: "toolUse" }),
    fauxAssistantMessage(
      fauxToolCall("code", { code: `async () => await zi.dormant_echo({ value: "nested" })` }, { id: "dormant-code" }),
      { stopReason: "toolUse" }
    ),
    fauxAssistantMessage(
      [
        fauxToolCall("deactivate_catalog", {}, { id: "deactivate-catalog" }),
        fauxToolCall("dormant_echo", { value: "deactivation-batch" }, { id: "dormant-deactivation-batch" })
      ],
      { stopReason: "toolUse" }
    ),
    fauxAssistantMessage(
      fauxToolCall("dormant_echo", { value: "after-deactivation" }, { id: "dormant-after-deactivation" }),
      { stopReason: "toolUse" }
    ),
    fauxAssistantMessage("Catalog activated and deactivated.")
  ])
  const runtime = await createAgentRuntime({
    cwd,
    agentDir,
    model: "faux/faux-1",
    modelFactory: () => models,
    session: { type: "new", persist: false }
  })

  try {
    expect(runtime.session.extensionHostSnapshot).toMatchObject({
      tools: [
        { name: "activate_catalog", active: true },
        { name: "deactivate_catalog", active: true },
        { name: "dormant_echo", active: false },
        { name: "other_extension_tool", active: true }
      ]
    })
    await runtime.session.prompt("Activate and use the dormant tool.")
    const results = runtime.session.messages.filter(message => message.role === "toolResult")
    expect(results).toHaveLength(9)
    expect(results[0]).toMatchObject({
      toolCallId: "activate-catalog",
      content: [
        {
          type: "text",
          text: '{"before":["activate_catalog","deactivate_catalog"],"crossExtensionRefused":true,"after":["activate_catalog","deactivate_catalog","dormant_echo"]}'
        }
      ]
    })
    expect(results[1]).toMatchObject({
      toolCallId: "dormant-same-batch",
      toolName: "dormant_echo",
      content: [{ type: "text", text: "Tool dormant_echo not found" }],
      isError: true
    })
    expect(results[2]).toMatchObject({
      toolCallId: "code-same-batch",
      content: [{ type: "text", text: "undefined" }],
      details: { type: "code_mode", outcome: "success" }
    })
    expect(results[3]).toMatchObject({
      toolCallId: "dormant-direct",
      content: [{ type: "text", text: "dormant:direct" }]
    })
    expect(results[4]).toMatchObject({ toolCallId: "other-direct", content: [{ type: "text", text: "other" }] })
    expect(results[5]).toMatchObject({
      toolCallId: "dormant-code",
      content: [{ type: "text", text: "dormant:nested" }],
      details: { type: "code_mode", outcome: "success" }
    })
    expect(results[6]).toMatchObject({
      toolCallId: "deactivate-catalog",
      content: [{ type: "text", text: "Catalog deactivated" }]
    })
    expect(results[7]).toMatchObject({
      toolCallId: "dormant-deactivation-batch",
      content: [{ type: "text", text: "dormant:deactivation-batch" }]
    })
    expect(results[8]).toMatchObject({
      toolCallId: "dormant-after-deactivation",
      content: [{ type: "text", text: "Tool dormant_echo not found" }],
      isError: true
    })
    faux.setResponses([
      fauxAssistantMessage(fauxToolCall("dormant_echo", { value: "after-reload" }, { id: "dormant-after-reload" }), {
        stopReason: "toolUse"
      }),
      fauxAssistantMessage("Catalog reset.")
    ])
    expect(await runtime.session.reload()).toMatchObject({ extensions: { outcome: "replaced" } })
    await runtime.session.prompt("Try the dormant tool after reload.")
    expect(
      runtime.session.messages.find(
        message => message.role === "toolResult" && message.toolCallId === "dormant-after-reload"
      )
    ).toMatchObject({ content: [{ type: "text", text: "Tool dormant_echo not found" }], isError: true })
  } finally {
    runtime.session.dispose()
    await runtime.session.waitForIdle()
    await rm(root, { recursive: true, force: true })
  }
}, 10_000)

test("session_start can restore durable active tools after reload", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-runtime-extension-active-tools-restore-"))
  const cwd = join(root, "project")
  const agentDir = join(root, "agent")
  const extensionDir = join(agentDir, "extensions")
  const observed = join(root, "restored.log")
  await mkdir(cwd, { recursive: true })
  await mkdir(extensionDir, { recursive: true })
  await writeFile(
    join(extensionDir, "durable-active-tools.ts"),
    `import { appendFileSync } from "node:fs"
import { Schema, type ExtensionAPI } from "@with-zi/extension-api"
export default function (zi: ExtensionAPI): void {
  zi.on("session_start", async () => {
    const entries = await zi.getSessionEntries("example.active-tools")
    const latest = entries.at(-1)?.data
    if (typeof latest === "object" && latest !== null && !Array.isArray(latest) && latest.enabled === true) {
      await zi.setActiveTools(["enable_durable_tool", "durable_echo"])
      appendFileSync(${JSON.stringify(observed)}, "restored\\n")
    }
  })
  zi.registerTool({
    name: "enable_durable_tool",
    description: "Persist and activate the durable tool",
    parameters: Schema.object({}),
    async execute() {
      await zi.appendEntry("example.active-tools", { enabled: true })
      await zi.setActiveTools(["enable_durable_tool", "durable_echo"])
      return "enabled"
    }
  })
  zi.registerTool({
    name: "durable_echo",
    description: "Echo after durable restoration",
    active: false,
    parameters: Schema.object({ value: Schema.string() }),
    execute: ({ value }) => "durable:" + value
  })
}
`
  )
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  faux.setResponses([
    fauxAssistantMessage(fauxToolCall("enable_durable_tool", {}, { id: "enable-durable" }), { stopReason: "toolUse" }),
    fauxAssistantMessage("Enabled.")
  ])
  const runtime = await createAgentRuntime({
    cwd,
    agentDir,
    model: "faux/faux-1",
    modelFactory: () => models,
    session: { type: "new", persist: false }
  })

  try {
    await runtime.session.prompt("Enable the durable tool.")
    faux.setResponses([
      fauxAssistantMessage(fauxToolCall("durable_echo", { value: "restored" }, { id: "durable-restored" }), {
        stopReason: "toolUse"
      }),
      fauxAssistantMessage("Restored.")
    ])
    expect(await runtime.session.reload()).toMatchObject({ extensions: { outcome: "replaced" } })
    expect(await readFile(observed, "utf8")).toBe("restored\n")
    await runtime.session.prompt("Use the restored tool.")
    expect(
      runtime.session.messages.find(
        message => message.role === "toolResult" && message.toolCallId === "durable-restored"
      )
    ).toMatchObject({ content: [{ type: "text", text: "durable:restored" }] })
  } finally {
    runtime.session.dispose()
    await runtime.session.waitForIdle()
    await rm(root, { recursive: true, force: true })
  }
}, 10_000)

test("extension lifecycle and tools can read, append, and message through nested session operations", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-runtime-extension-session-"))
  const cwd = join(root, "project")
  const agentDir = join(root, "agent")
  const extensionDir = join(agentDir, "extensions")
  const observed = join(root, "observed.log")
  await mkdir(cwd, { recursive: true })
  await mkdir(extensionDir, { recursive: true })
  await writeFile(
    join(extensionDir, "durable-counter.ts"),
    `import { appendFileSync } from "node:fs"
import { Schema, type ExtensionAPI } from "@with-zi/extension-api"
export default function (zi: ExtensionAPI): void {
  let count = 0
  zi.on("session_start", async () => {
    const entries = await zi.getSessionEntries("example.counter")
    const latest = entries.at(-1)?.data
    count = typeof latest === "object" && latest !== null && !Array.isArray(latest) && typeof latest.count === "number"
      ? latest.count
      : 0
    appendFileSync(${JSON.stringify(observed)}, "start:" + count + "\\n")
  })
  zi.registerTool({
    name: "increment_counter",
    description: "Increment durable session state",
    parameters: Schema.object({}),
    async execute() {
      count++
      await zi.appendEntry("example.counter", { count })
      let refused = false
      try { await zi.appendEntry("Invalid Type", null) } catch { refused = true }
      await zi.sendMessage(
        { customType: "example.counter", content: "counter:" + count, display: true },
        "follow_up"
      )
      return String(count) + ":" + refused
    }
  })
}
`
  )
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  faux.setResponses([
    fauxAssistantMessage(fauxToolCall("increment_counter", {}, { id: "counter-1" }), { stopReason: "toolUse" }),
    fauxAssistantMessage("Tool completed."),
    fauxAssistantMessage("Custom follow-up handled.")
  ])
  const first = await createAgentRuntime({
    cwd,
    agentDir,
    model: "faux/faux-1",
    modelFactory: () => models,
    session: { type: "new", persist: true },
    extensionWorkerCommand: workerCommand
  })
  let sessionFile: string
  try {
    await first.session.prompt("Increment the counter.")
    sessionFile = first.session.sessionManager.file!
    expect(first.session.getCustomEntries("example.counter")).toMatchObject([
      { customType: "example.counter", data: { count: 1 } }
    ])
    expect(first.session.messages).toContainEqual(
      expect.objectContaining({ role: "custom", customType: "example.counter", content: "counter:1" })
    )
    expect(first.session.messages).toContainEqual(
      expect.objectContaining({ role: "toolResult", content: [{ type: "text", text: "1:true" }] })
    )
    expect(first.session.extensionHostSnapshot).toMatchObject({ status: "ready", lifecycle: "started" })
  } finally {
    first.session.dispose()
    await first.session.waitForIdle()
  }

  const resumedModels = createModels()
  resumedModels.setProvider(fauxProvider().provider)
  const second = await createAgentRuntime({
    cwd,
    agentDir,
    modelFactory: () => resumedModels,
    session: { type: "resume", file: sessionFile },
    extensionWorkerCommand: workerCommand
  })
  try {
    expect(await readFile(observed, "utf8")).toBe("start:0\nstart:1\n")
    expect(second.session.getCustomEntries("example.counter")).toMatchObject([{ data: { count: 1 } }])
  } finally {
    second.session.dispose()
    await second.session.waitForIdle()
    await rm(root, { recursive: true, force: true })
  }
}, 10_000)

test("custom extension orchestration shares session-owned profile mechanics", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-runtime-extension-subagent-"))
  const cwd = join(root, "project")
  const agentDir = join(root, "agent")
  const childArgv = join(root, "child-argv.json")
  await mkdir(cwd, { recursive: true })
  await mkdir(join(agentDir, "extensions"), { recursive: true })
  await mkdir(join(agentDir, "subagents"), { recursive: true })
  await writeFile(
    join(agentDir, "subagents", "resource-reviewer.md"),
    "---\ndescription: Review from a resource\n---\nReview the requested change."
  )
  await writeFile(
    join(agentDir, "subagents", "unavailable.md"),
    "---\ndescription: Missing model\nmodel: missing/model\n---\nThis profile cannot start."
  )
  await writeFile(
    join(agentDir, "extensions", "delegate.ts"),
    `import { Schema, type ExtensionAPI } from "@with-zi/extension-api"
export default function (zi: ExtensionAPI): void {
  zi.registerSubagentProfile({
    name: "resource-reviewer",
    description: "Extension default that must lose to the resource",
    instructions: "Extension fallback."
  })
  zi.registerSubagentProfile({
    name: "extension-finder",
    description: "Find evidence",
    instructions: "Find only the requested evidence.",
    model: "faux/faux-1",
    thinking: "high"
  })
  zi.registerTool({
    name: "delegate_once",
    description: "Delegate one task",
    parameters: Schema.object({}),
    async execute(_input, context) {
      if (!zi.subagents) throw new Error("subagents unavailable")
      const profiles = await zi.subagents.listProfiles()
      let unavailableSource = false
      try {
        await zi.subagents.spawn("unavailable", "missing-1", "inspect", context.signal)
      } catch (cause) {
        unavailableSource = cause instanceof Error && cause.message.includes("unavailable.md")
      }
      const name = await zi.subagents.spawn("extension-finder", "finder-1", "inspect", context.signal)
      const active = await zi.subagents.list()
      await zi.subagents.send(name, "context")
      const followed = await zi.subagents.continue(name, "follow up")
      const waited = await zi.subagents.wait([name], 5_000, context.signal)
      const started = await zi.subagents.continue(name, "second cycle")
      const interrupted = await zi.subagents.interrupt(name)
      const closed = await zi.subagents.close(name)
      return JSON.stringify({
        profiles: profiles.map(profile => profile.name),
        resourceDescription: profiles.find(profile => profile.name === "resource-reviewer")?.description,
        unavailableSource,
        active: active.map(snapshot => ({
          name: snapshot.name,
          task: snapshot.task,
          workCycle: snapshot.workCycle,
          elapsed: typeof snapshot.elapsedMs
        })),
        followed,
        capturedCycle: waited[0]?.capturedWorkCycle,
        resultCycle: waited[0]?.completion?.workCycle,
        result: waited[0]?.completion?.text,
        started,
        interrupted: interrupted.result,
        interruptedCycle: interrupted.snapshot.capturedWorkCycle,
        cancelled: interrupted.snapshot.completion?.status,
        closed: closed.name
      })
    }
  })
}
`
  )
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  faux.setResponses([
    fauxAssistantMessage(fauxToolCall("delegate_once", {}, { id: "delegate-1" }), { stopReason: "toolUse" }),
    fauxAssistantMessage("Delegation complete.")
  ])
  const runtime = await createAgentRuntime({
    cwd,
    agentDir,
    model: "faux/faux-1",
    modelFactory: () => models,
    session: { type: "new", persist: false },
    extensionWorkerCommand: workerCommand,
    subagentCommand: [process.execPath, mockChild],
    internalSubagentEnvironment: {
      MOCK_RPC_REPLY: "extension-result",
      MOCK_RPC_DELAY_MS: "100",
      MOCK_RPC_ARGV: childArgv
    }
  })
  try {
    expect(runtime.session.extensionHostSnapshot).toMatchObject({
      status: "ready",
      extensions: [{ status: "loaded" }],
      tools: [{ name: "delegate_once" }]
    })
    expect(runtime.session.resourceDiagnostics).toContainEqual(
      expect.objectContaining({
        type: "collision",
        resource: "subagent-profile",
        name: "resource-reviewer",
        winnerPath: expect.stringContaining("resource-reviewer.md"),
        loserPath: expect.stringContaining("delegate.ts")
      })
    )
    await runtime.session.prompt("Delegate this task.")
    const result = runtime.session.messages.find(
      message => message.role === "toolResult" && message.toolName === "delegate_once"
    )
    expect(result).toMatchObject({
      content: [
        {
          type: "text",
          text: JSON.stringify({
            profiles: ["resource-reviewer", "unavailable", "extension-finder"],
            resourceDescription: "Review from a resource",
            unavailableSource: true,
            active: [{ name: "finder-1", task: "inspect", workCycle: 1, elapsed: "number" }],
            followed: "follow_up",
            capturedCycle: 1,
            resultCycle: 1,
            result: "extension-result",
            started: "started_turn",
            interrupted: "interrupted",
            interruptedCycle: 2,
            cancelled: "cancelled",
            closed: "finder-1"
          })
        }
      ]
    })
    expect(JSON.parse(await readFile(childArgv, "utf8"))).toEqual(
      expect.arrayContaining(["--model", "faux/faux-1", "--thinking", "high"])
    )
  } finally {
    runtime.session.dispose()
    await runtime.session.waitForIdle()
    await rm(root, { recursive: true, force: true })
  }
}, 15_000)

test("extension reload replaces profile registrations without terminating admitted children", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-runtime-extension-subagent-reload-"))
  const cwd = join(root, "project")
  const agentDir = join(root, "agent")
  await mkdir(cwd, { recursive: true })
  await mkdir(join(agentDir, "extensions"), { recursive: true })
  await writeFile(
    join(agentDir, "extensions", "background.ts"),
    `import { Schema, type ExtensionAPI } from "@with-zi/extension-api"
export default function (zi: ExtensionAPI): void {
  zi.registerSubagentProfile({ name: "slow", description: "Slow worker", instructions: "Finish the task." })
  zi.registerTool({
    name: "begin_background",
    description: "Start background work",
    parameters: Schema.object({}),
    async execute(_input, context) {
      if (!zi.subagents) throw new Error("subagents unavailable")
      return zi.subagents.spawn("slow", "slow-1", "work", context.signal)
    }
  })
  zi.registerTool({
    name: "collect_background",
    description: "Collect background work",
    parameters: Schema.object({}),
    async execute(_input, context) {
      if (!zi.subagents) throw new Error("subagents unavailable")
      const profiles = await zi.subagents.listProfiles()
      const waited = await zi.subagents.wait(["slow-1"], 5_000, context.signal)
      await zi.subagents.close("slow-1")
      return profiles.map(profile => profile.name).join(",") + ":" + waited[0]?.completion?.text
    }
  })
}
`
  )
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  faux.setResponses([
    fauxAssistantMessage(fauxToolCall("begin_background", {}, { id: "begin-1" }), { stopReason: "toolUse" }),
    fauxAssistantMessage("Started."),
    fauxAssistantMessage(fauxToolCall("collect_background", {}, { id: "collect-1" }), { stopReason: "toolUse" }),
    fauxAssistantMessage("Collected.")
  ])
  const runtime = await createAgentRuntime({
    cwd,
    agentDir,
    model: "faux/faux-1",
    modelFactory: () => models,
    session: { type: "new", persist: false },
    extensionWorkerCommand: workerCommand,
    subagentCommand: [process.execPath, mockChild],
    internalSubagentEnvironment: { MOCK_RPC_REPLY: "survived-reload", MOCK_RPC_DELAY_MS: "400" }
  })
  try {
    await runtime.session.prompt("Start background work.")
    expect(await runtime.session.reload()).toMatchObject({ extensions: { outcome: "replaced" } })
    await runtime.session.prompt("Collect background work.")
    expect(runtime.session.messages).toContainEqual(
      expect.objectContaining({
        role: "toolResult",
        toolName: "collect_background",
        content: [{ type: "text", text: "slow:survived-reload" }]
      })
    )
  } finally {
    runtime.session.dispose()
    await runtime.session.waitForIdle()
    await rm(root, { recursive: true, force: true })
  }
}, 15_000)

test("the canonical programmatic profile example activates standard tools", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-runtime-subagent-example-"))
  const cwd = join(root, "project")
  const agentDir = join(root, "agent")
  await mkdir(cwd, { recursive: true })
  await mkdir(join(agentDir, "extensions"), { recursive: true })
  await copyFile(
    resolve(import.meta.dirname, "../../../examples/extensions/subagents/index.ts"),
    join(agentDir, "extensions", "subagents.ts")
  )
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  let postWaitContext = ""
  faux.setResponses([
    fauxAssistantMessage(
      fauxToolCall(
        "spawn_subagent",
        { profile: "finder", name: "example-finder", prompt: "Find one fact." },
        { id: "example-spawn-1" }
      ),
      { stopReason: "toolUse" }
    ),
    fauxAssistantMessage(
      fauxToolCall("wait_subagents", { names: ["example-finder"], timeout_ms: 5_000 }, { id: "example-wait-1" }),
      { stopReason: "toolUse" }
    ),
    context => {
      postWaitContext = JSON.stringify(context.messages)
      return fauxAssistantMessage("Example complete.")
    }
  ])
  const runtime = await createAgentRuntime({
    cwd,
    agentDir,
    model: "faux/faux-1",
    modelFactory: () => models,
    session: { type: "new", persist: false },
    extensionWorkerCommand: workerCommand,
    subagentCommand: [process.execPath, mockChild],
    internalSubagentEnvironment: { MOCK_RPC_REPLY: "example-result" }
  })
  try {
    await runtime.session.prompt("Use the example.")
    expect(runtime.session.messages).toContainEqual(
      expect.objectContaining({
        role: "toolResult",
        toolName: "wait_subagents",
        content: [expect.objectContaining({ type: "text", text: expect.stringContaining("example-result") })]
      })
    )
    expect(postWaitContext).not.toContain("<subagent_completion>")
    expect(
      runtime.session.sessionManager
        .subagentEntries()
        .filter(entry => entry.event === "work_cycle_delivered" && entry.name === "example-finder")
    ).toHaveLength(1)
  } finally {
    runtime.session.dispose()
    await runtime.session.waitForIdle()
    await rm(root, { recursive: true, force: true })
  }
}, 15_000)

test("a Markdown profile activates the standard subagent tools without an extension", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-runtime-subagent-resource-tools-"))
  const cwd = join(root, "project")
  const agentDir = join(root, "agent")
  const childArgv = join(root, "child-argv.json")
  await mkdir(cwd, { recursive: true })
  await mkdir(join(agentDir, "subagents"), { recursive: true })
  await writeFile(
    join(agentDir, "subagents", "pathfinder.md"),
    `---\ndescription: Find authoritative implementation paths\n---\nReturn concrete file paths.\n`
  )
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  let admittedTools: readonly string[] = []
  faux.setResponses([
    context => {
      admittedTools = (context.tools ?? []).map(tool => tool.name)
      return fauxAssistantMessage(
        fauxToolCall(
          "spawn_subagent",
          { profile: "pathfinder", name: "finder-1", prompt: "Find ResourceDirectory." },
          { id: "spawn-standard-1" }
        ),
        { stopReason: "toolUse" }
      )
    },
    fauxAssistantMessage(
      fauxToolCall("wait_subagents", { names: ["finder-1"], timeout_ms: 5_000 }, { id: "wait-standard-1" }),
      { stopReason: "toolUse" }
    ),
    fauxAssistantMessage("Delegation complete.")
  ])
  const runtime = await createAgentRuntime({
    cwd,
    agentDir,
    model: "faux/faux-1",
    modelFactory: () => models,
    session: { type: "new", persist: false },
    extensionWorkerCommand: workerCommand,
    subagentCommand: [process.execPath, mockChild],
    internalSubagentEnvironment: { MOCK_RPC_REPLY: "resource-profile-result", MOCK_RPC_ARGV: childArgv }
  })
  try {
    await runtime.session.prompt("Delegate this search.")
    expect(admittedTools).toContain("list_subagent_profiles")
    expect(admittedTools).toContain("spawn_subagent")
    const waited = runtime.session.messages.find(
      message => message.role === "toolResult" && message.toolName === "wait_subagents"
    )
    expect(waited).toMatchObject({
      content: [{ type: "text", text: expect.stringContaining("resource-profile-result") }]
    })
    expect(JSON.parse(await readFile(childArgv, "utf8"))).toEqual(
      expect.arrayContaining(["--model", "faux/faux-1", "--thinking", "off"])
    )
  } finally {
    runtime.session.dispose()
    await runtime.session.waitForIdle()
    await rm(root, { recursive: true, force: true })
  }
}, 15_000)

test("subagent completion stays passive and joins the next parent model request", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-runtime-subagent-passive-completion-"))
  const cwd = join(root, "project")
  const agentDir = join(root, "agent")
  await mkdir(cwd, { recursive: true })
  await mkdir(join(agentDir, "subagents"), { recursive: true })
  await writeFile(
    join(agentDir, "subagents", "pathfinder.md"),
    `---\ndescription: Find implementation evidence\n---\nReturn concrete evidence.\n`
  )
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  let completionContext = ""
  faux.setResponses([
    fauxAssistantMessage(
      fauxToolCall(
        "spawn_subagent",
        { profile: "pathfinder", name: "passive-worker", prompt: "Find one fact." },
        { id: "spawn-passive-1" }
      ),
      { stopReason: "toolUse" }
    ),
    fauxAssistantMessage("The child is working in the background."),
    context => {
      completionContext = JSON.stringify(context.messages)
      return fauxAssistantMessage("Used the delivered child result.")
    }
  ])
  const runtime = await createAgentRuntime({
    cwd,
    agentDir,
    model: "faux/faux-1",
    modelFactory: () => models,
    session: { type: "new", persist: false },
    extensionWorkerCommand: workerCommand,
    subagentCommand: [process.execPath, mockChild],
    internalSubagentEnvironment: { MOCK_RPC_REPLY: "passive-result", MOCK_RPC_DELAY_MS: "150" }
  })
  try {
    await runtime.session.prompt("Start the background investigation.")
    expect(faux.state.callCount).toBe(2)

    await waitForCondition(
      () => runtime.session.sessionManager.subagentEntries().some(entry => entry.event === "work_cycle_finished"),
      5_000
    )
    expect(faux.state.callCount).toBe(2)
    expect(runtime.session.messages.some(message => message.role === "custom")).toBe(false)

    await runtime.session.prompt("Use any completed investigation.")
    expect(faux.state.callCount).toBe(3)
    expect(completionContext).toContain("<subagent_completion>")
    expect(completionContext).toContain("passive-result")
    expect(
      runtime.session.messages.some(message => message.role === "toolResult" && message.toolName === "wait_subagents")
    ).toBe(false)
    expect(runtime.session.sessionManager.retainedEntries()).toContainEqual(
      expect.objectContaining({ type: "custom_message", customType: "zi.subagent_completion", display: false })
    )
  } finally {
    runtime.session.dispose()
    await runtime.session.waitForIdle()
    await rm(root, { recursive: true, force: true })
  }
}, 15_000)

test("subagent completion joins the next model step of an active parent turn", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-runtime-subagent-active-completion-"))
  const cwd = join(root, "project")
  const agentDir = join(root, "agent")
  await mkdir(cwd, { recursive: true })
  await mkdir(join(agentDir, "subagents"), { recursive: true })
  await writeFile(
    join(agentDir, "subagents", "pathfinder.md"),
    `---\ndescription: Find implementation evidence\n---\nReturn concrete evidence.\n`
  )
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  let completionContext = ""
  faux.setResponses([
    fauxAssistantMessage(
      fauxToolCall(
        "spawn_subagent",
        { profile: "pathfinder", name: "active-worker", prompt: "Find one fact." },
        { id: "spawn-active-1" }
      ),
      { stopReason: "toolUse" }
    ),
    fauxAssistantMessage(fauxToolCall("hold", {}, { id: "hold-active-1" }), { stopReason: "toolUse" }),
    context => {
      completionContext = JSON.stringify(context.messages)
      return fauxAssistantMessage("Used the active child result.")
    }
  ])
  const runtime = await createAgentRuntime({
    cwd,
    agentDir,
    model: "faux/faux-1",
    modelFactory: () => models,
    session: { type: "new", persist: false },
    extensionWorkerCommand: workerCommand,
    subagentCommand: [process.execPath, mockChild],
    internalSubagentEnvironment: { MOCK_RPC_REPLY: "active-result", MOCK_RPC_DELAY_MS: "100" }
  })
  runtime.session.setActiveTools([
    {
      name: "hold",
      label: "hold",
      description: "Hold the parent turn while child work settles",
      parameters: Type.Object({}),
      async execute() {
        await Bun.sleep(300)
        return { content: [{ type: "text" as const, text: "released" }], details: undefined }
      }
    }
  ])
  try {
    await runtime.session.prompt("Investigate while continuing parent work.")
    expect(faux.state.callCount).toBe(3)
    expect(completionContext).toContain("<subagent_completion>")
    expect(completionContext).toContain("active-result")
    expect(
      runtime.session.messages.some(message => message.role === "toolResult" && message.toolName === "wait_subagents")
    ).toBe(false)
  } finally {
    runtime.session.dispose()
    await runtime.session.waitForIdle()
    await rm(root, { recursive: true, force: true })
  }
}, 15_000)

test("restoration and compaction never redeliver durable child completion evidence", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-runtime-subagent-restored-completion-"))
  const cwd = join(root, "project")
  const agentDir = join(root, "agent")
  await mkdir(cwd, { recursive: true })
  await mkdir(join(agentDir, "subagents"), { recursive: true })
  await writeFile(
    join(agentDir, "subagents", "pathfinder.md"),
    `---\ndescription: Find implementation evidence\n---\nReturn concrete evidence.\n`
  )
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  faux.setResponses([
    fauxAssistantMessage(
      fauxToolCall(
        "spawn_subagent",
        { profile: "pathfinder", name: "restored-worker", prompt: "Find one restored fact." },
        { id: "spawn-restored-1" }
      ),
      { stopReason: "toolUse" }
    ),
    fauxAssistantMessage("The child is working in the background.")
  ])
  const first = await createAgentRuntime({
    cwd,
    agentDir,
    model: "faux/faux-1",
    modelFactory: () => models,
    session: { type: "new", persist: true },
    extensionWorkerCommand: workerCommand,
    subagentCommand: [process.execPath, mockChild],
    internalSubagentEnvironment: { MOCK_RPC_REPLY: "restored-result", MOCK_RPC_DELAY_MS: "80" }
  })
  let second: Awaited<ReturnType<typeof createAgentRuntime>> | undefined
  let third: Awaited<ReturnType<typeof createAgentRuntime>> | undefined
  try {
    await first.session.prompt("Start a restorable background investigation.")
    await waitForCondition(
      () =>
        first.session.sessionManager
          .subagentEntries()
          .some(entry => entry.event === "work_cycle_finished" && entry.name === "restored-worker"),
      5_000
    )
    const sessionFile = first.session.sessionManager.file!
    first.session.dispose()
    await first.session.waitForIdle()

    let restoredOccurrences = 0
    faux.setResponses([
      context => {
        const serialized = JSON.stringify(context.messages)
        restoredOccurrences = serialized.split("<subagent_completion>").length - 1
        return fauxAssistantMessage("Used restored child evidence.")
      }
    ])
    second = await createAgentRuntime({
      cwd,
      agentDir,
      model: "faux/faux-1",
      modelFactory: () => models,
      session: { type: "resume", file: sessionFile },
      extensionWorkerCommand: workerCommand,
      subagentCommand: [process.execPath, mockChild]
    })
    await second.session.prompt("Use the restored result.")
    expect(restoredOccurrences).toBe(1)
    expect(
      second.session.sessionManager
        .entries()
        .filter(entry => entry.type === "custom_message" && entry.customType === "zi.subagent_completion")
    ).toHaveLength(1)
    expect(
      second.session.sessionManager
        .subagentEntries()
        .filter(entry => entry.event === "work_cycle_delivered" && entry.name === "restored-worker")
    ).toHaveLength(1)
    second.session.dispose()
    await second.session.waitForIdle()
    second = undefined

    const compacted = SessionManager.open(sessionFile)
    const kept = compacted
      .entries()
      .find(
        entry =>
          entry.type === "message" &&
          entry.message.role === "user" &&
          JSON.stringify(entry.message.content).includes("Use the restored result")
      )
    if (!kept) throw new Error("Expected the post-completion user message")
    compacted.appendCompaction({
      reason: "manual",
      summary: "The restored child result was delivered once.",
      firstKeptEntryId: kept.id,
      tokensBefore: 100,
      estimatedTokensAfter: 20,
      details: { readFiles: [], modifiedFiles: [], omittedReadFiles: 0, omittedModifiedFiles: 0 }
    })

    let compactedContext = ""
    faux.setResponses([
      context => {
        compactedContext = JSON.stringify(context.messages)
        return fauxAssistantMessage("Continued after compaction.")
      }
    ])
    third = await createAgentRuntime({
      cwd,
      agentDir,
      model: "faux/faux-1",
      modelFactory: () => models,
      session: { type: "resume", file: sessionFile },
      extensionWorkerCommand: workerCommand,
      subagentCommand: [process.execPath, mockChild]
    })
    await third.session.prompt("Continue after compaction.")
    expect(compactedContext).toContain("restored child result was delivered once")
    expect(compactedContext).not.toContain("<subagent_completion>")
    expect(
      third.session.sessionManager
        .entries()
        .filter(entry => entry.type === "custom_message" && entry.customType === "zi.subagent_completion")
    ).toHaveLength(1)
  } finally {
    first.session.dispose()
    await first.session.waitForIdle()
    second?.session.dispose()
    if (second) await second.session.waitForIdle()
    third?.session.dispose()
    if (third) await third.session.waitForIdle()
    await rm(root, { recursive: true, force: true })
  }
}, 20_000)

test("a programmatic profile activates the same standard subagent tools", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-runtime-subagent-programmatic-tools-"))
  const cwd = join(root, "project")
  const agentDir = join(root, "agent")
  await mkdir(cwd, { recursive: true })
  await mkdir(join(agentDir, "extensions"), { recursive: true })
  await writeFile(
    join(agentDir, "extensions", "reviewer.ts"),
    `import type { ExtensionAPI } from "@with-zi/extension-api"
export default function (zi: ExtensionAPI): void {
  zi.registerSubagentProfile({
    name: "reviewer",
    description: "Review one bounded implementation",
    instructions: "Return concrete evidence."
  })
}
`
  )
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  let admittedTools: readonly string[] = []
  faux.setResponses([
    context => {
      admittedTools = (context.tools ?? []).map(tool => tool.name)
      return fauxAssistantMessage(
        fauxToolCall(
          "spawn_subagent",
          { profile: "reviewer", name: "reviewer-1", prompt: "Review the owner." },
          { id: "spawn-programmatic-1" }
        ),
        { stopReason: "toolUse" }
      )
    },
    fauxAssistantMessage(
      fauxToolCall("wait_subagents", { names: ["reviewer-1"], timeout_ms: 5_000 }, { id: "wait-programmatic-1" }),
      { stopReason: "toolUse" }
    ),
    fauxAssistantMessage("Review complete.")
  ])
  const runtime = await createAgentRuntime({
    cwd,
    agentDir,
    model: "faux/faux-1",
    modelFactory: () => models,
    session: { type: "new", persist: false },
    extensionWorkerCommand: workerCommand,
    subagentCommand: [process.execPath, mockChild],
    internalSubagentEnvironment: { MOCK_RPC_REPLY: "programmatic-profile-result" }
  })
  try {
    expect(runtime.session.extensionHostSnapshot).toMatchObject({ tools: [] })
    await runtime.session.prompt("Delegate this review.")
    expect(admittedTools).toContain("list_subagent_profiles")
    expect(admittedTools).toContain("spawn_subagent")
    expect(runtime.session.messages).toContainEqual(
      expect.objectContaining({
        role: "toolResult",
        toolName: "wait_subagents",
        content: [expect.objectContaining({ text: expect.stringContaining("programmatic-profile-result") })]
      })
    )
  } finally {
    runtime.session.dispose()
    await runtime.session.waitForIdle()
    await rm(root, { recursive: true, force: true })
  }
}, 15_000)

test("subagent mechanics expose no model-facing tools without admitted profiles", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-runtime-subagent-empty-catalog-"))
  const cwd = join(root, "project")
  await mkdir(cwd, { recursive: true })
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  let admittedTools: readonly string[] = []
  faux.setResponses([
    context => {
      admittedTools = (context.tools ?? []).map(tool => tool.name)
      return fauxAssistantMessage("No delegation tools.")
    }
  ])
  const runtime = await createAgentRuntime({
    cwd,
    agentDir: join(root, "agent"),
    model: "faux/faux-1",
    modelFactory: () => models,
    session: { type: "new", persist: false },
    extensionWorkerCommand: workerCommand,
    subagentCommand: [process.execPath, mockChild]
  })
  try {
    await runtime.session.prompt("Inspect available tools.")
    expect(admittedTools).not.toContain("list_subagent_profiles")
    expect(admittedTools).not.toContain("spawn_subagent")
  } finally {
    runtime.session.dispose()
    await runtime.session.waitForIdle()
    await rm(root, { recursive: true, force: true })
  }
})

test("a depth-one child does not activate recursive subagent tools", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-runtime-subagent-depth-one-"))
  const cwd = join(root, "project")
  const agentDir = join(root, "agent")
  await mkdir(cwd, { recursive: true })
  await mkdir(join(agentDir, "subagents"), { recursive: true })
  await writeFile(
    join(agentDir, "subagents", "nested.md"),
    "---\ndescription: Must not activate recursively\n---\nWork.\n"
  )
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  let admittedTools: readonly string[] = []
  faux.setResponses([
    context => {
      admittedTools = (context.tools ?? []).map(tool => tool.name)
      return fauxAssistantMessage("No recursive delegation.")
    }
  ])
  const runtime = await createAgentRuntime({
    cwd,
    agentDir,
    model: "faux/faux-1",
    modelFactory: () => models,
    session: { type: "new", persist: false },
    subagentCommand: [process.execPath, mockChild],
    internalSubagentDepth: 1
  })
  try {
    await runtime.session.prompt("Inspect tools.")
    expect(admittedTools).not.toContain("list_subagent_profiles")
    expect(admittedTools).not.toContain("spawn_subagent")
  } finally {
    runtime.session.dispose()
    await runtime.session.waitForIdle()
    await rm(root, { recursive: true, force: true })
  }
})

test("reload adds and removes standard tools with Markdown profiles", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-runtime-subagent-resource-reload-"))
  const cwd = join(root, "project")
  const agentDir = join(root, "agent")
  const profileDir = join(agentDir, "subagents")
  await mkdir(cwd, { recursive: true })
  const catalogs: string[][] = []
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  faux.setResponses([
    context => {
      catalogs.push((context.tools ?? []).map(tool => tool.name))
      return fauxAssistantMessage("No profile.")
    },
    context => {
      catalogs.push((context.tools ?? []).map(tool => tool.name))
      return fauxAssistantMessage("Profile added.")
    },
    context => {
      catalogs.push((context.tools ?? []).map(tool => tool.name))
      return fauxAssistantMessage("Profile removed.")
    }
  ])
  const runtime = await createAgentRuntime({
    cwd,
    agentDir,
    model: "faux/faux-1",
    modelFactory: () => models,
    session: { type: "new", persist: false },
    extensionWorkerCommand: workerCommand,
    subagentCommand: [process.execPath, mockChild]
  })
  try {
    await runtime.session.prompt("Inspect tools before the profile exists.")
    await mkdir(profileDir, { recursive: true })
    const profilePath = join(profileDir, "finder.md")
    await writeFile(profilePath, "---\ndescription: Find evidence\n---\nReturn paths.\n")
    await runtime.session.reload()
    await runtime.session.prompt("Inspect tools after adding the profile.")
    await rm(profilePath)
    await runtime.session.reload()
    await runtime.session.prompt("Inspect tools after removing the profile.")

    expect(catalogs[0]).not.toContain("spawn_subagent")
    expect(catalogs[1]).toContain("spawn_subagent")
    expect(catalogs[2]).not.toContain("spawn_subagent")
  } finally {
    runtime.session.dispose()
    await runtime.session.waitForIdle()
    await rm(root, { recursive: true, force: true })
  }
})

test("reload replaces programmatic profiles in the canonical catalog", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-runtime-subagent-profile-generation-"))
  const cwd = join(root, "project")
  const agentDir = join(root, "agent")
  const extensionDir = join(agentDir, "extensions")
  const extensionPath = join(extensionDir, "profile.ts")
  await mkdir(cwd, { recursive: true })
  await mkdir(extensionDir, { recursive: true })
  await writeFile(extensionPath, programmaticProfileSource("alpha"))
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  faux.setResponses([
    fauxAssistantMessage(fauxToolCall("list_subagent_profiles", {}, { id: "profiles-alpha" }), {
      stopReason: "toolUse"
    }),
    fauxAssistantMessage("Alpha listed."),
    fauxAssistantMessage(fauxToolCall("list_subagent_profiles", {}, { id: "profiles-beta" }), {
      stopReason: "toolUse"
    }),
    fauxAssistantMessage("Beta listed.")
  ])
  const runtime = await createAgentRuntime({
    cwd,
    agentDir,
    model: "faux/faux-1",
    modelFactory: () => models,
    session: { type: "new", persist: false },
    extensionWorkerCommand: workerCommand,
    subagentCommand: [process.execPath, mockChild]
  })
  try {
    await runtime.session.prompt("List profiles.")
    await writeFile(extensionPath, programmaticProfileSource("beta"))
    await runtime.session.reload()
    await runtime.session.prompt("List profiles again.")

    const results = runtime.session.messages.filter(
      message => message.role === "toolResult" && message.toolName === "list_subagent_profiles"
    )
    expect(results).toHaveLength(2)
    expect(results[0]).toMatchObject({ content: [{ text: expect.stringContaining('"name":"alpha"') }] })
    expect(results[1]).toMatchObject({ content: [{ text: expect.stringContaining('"name":"beta"') }] })
    expect(results[1]).not.toMatchObject({ content: [{ text: expect.stringContaining('"name":"alpha"') }] })
  } finally {
    runtime.session.dispose()
    await runtime.session.waitForIdle()
    await rm(root, { recursive: true, force: true })
  }
})

test("a failed extension generation is removed from current and future provider catalogs", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-runtime-extension-tool-failure-"))
  const cwd = join(root, "project")
  const agentDir = join(root, "agent")
  const extensionDir = join(agentDir, "extensions")
  await mkdir(cwd, { recursive: true })
  await mkdir(extensionDir, { recursive: true })
  await writeFile(
    join(extensionDir, "crash.ts"),
    `import { Schema, type ExtensionAPI } from "@with-zi/extension-api"
export default function (zi: ExtensionAPI): void {
  zi.registerSubagentProfile({
    name: "crash-profile",
    description: "Profile owned by a failing generation",
    instructions: "Work."
  })
  zi.registerTool({
    name: "crash_tool",
    description: "Crash the extension worker",
    parameters: Schema.object({}),
    execute: () => process.exit(17)
  })
}
`
  )
  const faux = fauxProvider()
  const catalogs: string[][] = []
  faux.setResponses([
    context => {
      catalogs.push((context.tools ?? []).map(tool => tool.name))
      return fauxAssistantMessage(fauxToolCall("crash_tool", {}, { id: "crash-call" }), { stopReason: "toolUse" })
    },
    context => {
      catalogs.push((context.tools ?? []).map(tool => tool.name))
      return fauxAssistantMessage("Recovered without extension tools.")
    },
    context => {
      catalogs.push((context.tools ?? []).map(tool => tool.name))
      return fauxAssistantMessage("Still recovered.")
    }
  ])
  const models = createModels()
  models.setProvider(faux.provider)
  const runtime = await createAgentRuntime({
    cwd,
    agentDir,
    model: "faux/faux-1",
    modelFactory: () => models,
    session: { type: "new", persist: false },
    extensionWorkerCommand: workerCommand,
    subagentCommand: [process.execPath, mockChild]
  })

  try {
    await runtime.session.prompt("Crash the extension tool.")
    await runtime.session.prompt("Continue without it.")
    expect(catalogs[0]).toContain("crash_tool")
    expect(catalogs[0]).toContain("spawn_subagent")
    expect(catalogs[1]).not.toContain("crash_tool")
    expect(catalogs[1]).not.toContain("spawn_subagent")
    expect(catalogs[2]).not.toContain("crash_tool")
    expect(catalogs[2]).not.toContain("spawn_subagent")
    expect(runtime.session.extensionHostSnapshot).toMatchObject({ status: "failed", tools: [] })
  } finally {
    runtime.session.dispose()
    await runtime.session.waitForIdle()
    await rm(root, { recursive: true, force: true })
  }
}, 10_000)

test("AgentSession rejects extension tools that conflict with built-ins", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-runtime-extension-tool-conflict-"))
  const cwd = join(root, "project")
  const agentDir = join(root, "agent")
  const extensionDir = join(agentDir, "extensions")
  await mkdir(cwd, { recursive: true })
  await mkdir(extensionDir, { recursive: true })
  await writeFile(
    join(extensionDir, "conflict.ts"),
    `import { Schema, type ExtensionAPI } from "@with-zi/extension-api"
export default function (zi: ExtensionAPI): void {
  zi.registerSubagentProfile({
    name: "conflict-profile",
    description: "Activates standard tools",
    instructions: "Work."
  })
  for (const name of ["read", "code", "then", "spawn_subagent"]) zi.registerTool({
    name,
    description: "Conflicts with built-in " + name,
    parameters: Schema.object({}),
    execute: () => "must not run"
  })
}
`
  )
  const runtime = await createAgentRuntime({
    cwd,
    agentDir,
    session: { type: "new", persist: false },
    subagentCommand: [process.execPath, mockChild]
  })

  try {
    expect(runtime.session.extensionHostSnapshot).toMatchObject({
      status: "ready",
      tools: [],
      diagnostics: [
        expect.objectContaining({
          path: expect.any(String),
          phase: "registration",
          message: expect.stringContaining("read conflicts with an existing session tool")
        }),
        expect.objectContaining({
          path: expect.any(String),
          phase: "registration",
          message: expect.stringContaining("code conflicts with an existing session tool")
        }),
        expect.objectContaining({
          path: expect.any(String),
          phase: "registration",
          message: expect.stringContaining("then conflicts with an existing session tool")
        }),
        expect.objectContaining({
          path: expect.any(String),
          phase: "registration",
          message: expect.stringContaining("spawn_subagent conflicts with an existing session tool")
        })
      ]
    })
  } finally {
    runtime.session.dispose()
    await runtime.session.waitForIdle()
    await rm(root, { recursive: true, force: true })
  }
}, 10_000)

test("interrupting an extension tool keeps its generation reusable", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-runtime-extension-tool-cancel-"))
  const cwd = join(root, "project")
  const agentDir = join(root, "agent")
  const extensionDir = join(agentDir, "extensions")
  const started = join(root, "started")
  await mkdir(cwd, { recursive: true })
  await mkdir(extensionDir, { recursive: true })
  await writeFile(
    join(extensionDir, "cancellable.ts"),
    `import { writeFileSync } from "node:fs"
import { Schema, type ExtensionAPI } from "@with-zi/extension-api"
export default function (zi: ExtensionAPI): void {
  zi.registerTool({
    name: "cancellable_echo",
    description: "Wait or echo",
    parameters: Schema.object({ value: Schema.string() }),
    async execute({ value }, { signal }) {
      if (value !== "wait") return value
      writeFileSync(${JSON.stringify(started)}, "started")
      await new Promise(resolve => signal.addEventListener("abort", resolve, { once: true }))
      return "late"
    }
  })
}
`
  )
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  faux.setResponses([
    fauxAssistantMessage(fauxToolCall("cancellable_echo", { value: "wait" }, { id: "cancel-tool-1" }), {
      stopReason: "toolUse"
    })
  ])
  const runtime = await createAgentRuntime({
    cwd,
    agentDir,
    model: "faux/faux-1",
    modelFactory: () => models,
    session: { type: "new", persist: false }
  })

  try {
    const run = runtime.session.prompt("Wait in the extension tool.")
    await waitForFile(started)
    await runtime.session.abort()
    await run
    expect(runtime.session.extensionHostSnapshot).toMatchObject({ status: "ready", lifecycle: "started" })

    faux.setResponses([
      fauxAssistantMessage(fauxToolCall("cancellable_echo", { value: "again" }, { id: "cancel-tool-2" }), {
        stopReason: "toolUse"
      }),
      fauxAssistantMessage("Recovered.")
    ])
    await runtime.session.prompt("Use the extension again.")
    expect(
      runtime.session.messages.find(message => message.role === "toolResult" && message.toolCallId === "cancel-tool-2")
    ).toMatchObject({ content: [{ type: "text", text: "again" }] })
  } finally {
    runtime.session.dispose()
    await runtime.session.waitForIdle()
    await rm(root, { recursive: true, force: true })
  }
}, 10_000)

test("session reload keeps identity and runs reload lifecycle through the current host", async () => {
  const fixture = await extensionFixture("reload")
  const skillDir = join(fixture.agentDir, "skills", "reload-skill")
  await mkdir(skillDir, { recursive: true })
  await writeFile(
    join(skillDir, "SKILL.md"),
    `---
name: reload-skill
description: before reload
---
# Before
`
  )
  const runtime = await createAgentRuntime({
    cwd: fixture.cwd,
    agentDir: fixture.agentDir,
    session: { type: "new", persist: true },
    extensionWorkerCommand: workerCommand
  })

  try {
    const sessionId = runtime.session.sessionManager.sessionId
    const sessionFile = runtime.session.sessionManager.file
    expect(runtime.session.skills.map(skill => skill.description)).toContain("before reload")

    await writeFile(
      join(skillDir, "SKILL.md"),
      `---
name: reload-skill
description: after reload
---
# After
`
    )
    const result = await runtime.session.reload()
    expect(result.extensions?.outcome).toBe("replaced")
    expect(runtime.session.sessionManager.sessionId).toBe(sessionId)
    expect(runtime.session.sessionManager.file).toBe(sessionFile)
    expect(runtime.session.skills.map(skill => skill.description)).toContain("after reload")
    expect(await readFile(fixture.lifecycle, "utf8")).toBe("start:startup\nstop:reload\nstart:reload\n")
  } finally {
    runtime.session.dispose()
    await runtime.session.waitForIdle()
    await rm(fixture.root, { recursive: true, force: true })
  }
}, 10_000)

test("session reload restores durable extension state and recovers a failed host", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-runtime-extension-reload-state-"))
  const cwd = join(root, "project")
  const agentDir = join(root, "agent")
  const extensionDir = join(agentDir, "extensions")
  const observed = join(root, "observed.log")
  await mkdir(cwd, { recursive: true })
  await mkdir(extensionDir, { recursive: true })
  await writeFile(
    join(extensionDir, "durable-counter.ts"),
    `import { appendFileSync } from "node:fs"
import { Schema, type ExtensionAPI } from "@with-zi/extension-api"
export default function (zi: ExtensionAPI): void {
  let count = 0
  zi.on("session_start", async event => {
    const entries = await zi.getSessionEntries("example.counter")
    const latest = entries.at(-1)?.data
    count = typeof latest === "object" && latest !== null && !Array.isArray(latest) && typeof latest.count === "number"
      ? latest.count
      : 0
    appendFileSync(${JSON.stringify(observed)}, "start:" + event.reason + ":" + count + "\\n")
    if (event.reason === "reload") {
      await zi.appendEntry("example.counter", { count, restored: true })
      await zi.sendMessage(
        { customType: "example.counter", content: "restored:" + count, display: true },
        "append"
      )
    }
  })
  zi.on("session_shutdown", async event => {
    await zi.appendEntry("example.counter", { count, shutdown: event.reason })
  })
  zi.registerTool({
    name: "increment_counter",
    description: "Increment durable session state",
    parameters: Schema.object({}),
    async execute() {
      count++
      await zi.appendEntry("example.counter", { count })
      return String(count)
    }
  })
  zi.registerTool({
    name: "crash_worker",
    description: "Crash the extension worker",
    parameters: Schema.object({}),
    async execute() {
      process.exit(97)
    }
  })
}
`
  )
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  faux.setResponses([
    fauxAssistantMessage(fauxToolCall("increment_counter", {}, { id: "counter-1" }), { stopReason: "toolUse" }),
    fauxAssistantMessage("Incremented."),
    fauxAssistantMessage(fauxToolCall("crash_worker", {}, { id: "crash-1" }), { stopReason: "toolUse" }),
    fauxAssistantMessage("Crashed.")
  ])
  const runtime = await createAgentRuntime({
    cwd,
    agentDir,
    model: "faux/faux-1",
    modelFactory: () => models,
    session: { type: "new", persist: true },
    extensionWorkerCommand: workerCommand
  })

  try {
    const sessionId = runtime.session.sessionManager.sessionId
    await runtime.session.prompt("Increment the counter.")
    expect(runtime.session.getCustomEntries("example.counter")).toMatchObject([{ data: { count: 1 } }])

    const reloaded = await runtime.session.reload()
    expect(reloaded.extensions?.outcome).toBe("replaced")
    expect(runtime.session.sessionManager.sessionId).toBe(sessionId)
    expect(await readFile(observed, "utf8")).toContain("start:reload:1")
    expect(runtime.session.getCustomEntries("example.counter")).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ data: { count: 1 } }),
        expect.objectContaining({ data: { count: 1, shutdown: "reload" } }),
        expect.objectContaining({ data: { count: 1, restored: true } })
      ])
    )
    expect(runtime.session.messages).toContainEqual(
      expect.objectContaining({ role: "custom", customType: "example.counter", content: "restored:1" })
    )

    await runtime.session.prompt("Crash the worker.")
    expect(runtime.session.extensionHostSnapshot?.status).toBe("failed")

    const recovered = await runtime.session.reload()
    expect(recovered.extensions?.outcome).toBe("replaced")
    expect(runtime.session.extensionHostSnapshot).toMatchObject({ status: "ready", lifecycle: "started" })
    expect(await readFile(observed, "utf8")).toMatch(/start:reload:1[\s\S]*start:reload:/)
  } finally {
    runtime.session.dispose()
    await runtime.session.waitForIdle()
    await rm(root, { recursive: true, force: true })
  }
}, 15_000)

test("dispose during session reload settles without leaving the host running", async () => {
  const fixture = await extensionFixture("reload-dispose")
  const runtime = await createAgentRuntime({
    cwd: fixture.cwd,
    agentDir: fixture.agentDir,
    session: { type: "new", persist: false },
    extensionWorkerCommand: workerCommand
  })

  try {
    const reload = runtime.session.reload()
    runtime.session.dispose()
    const result = await reload
    await runtime.session.waitForIdle()
    expect(["replaced", "superseded", "disabled"]).toContain(result.extensions?.outcome ?? "disabled")
    expect(runtime.session.extensionHostSnapshot).toBeUndefined()
  } finally {
    await runtime.session.waitForIdle()
    await rm(fixture.root, { recursive: true, force: true })
  }
}, 10_000)

test("session reload refuses concurrent work and applies settings queue modes", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-runtime-extension-reload-admit-"))
  const cwd = join(root, "project")
  const agentDir = join(root, "agent")
  await mkdir(cwd, { recursive: true })
  await mkdir(join(agentDir, "extensions"), { recursive: true })
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  faux.setResponses([fauxAssistantMessage("hello")])
  const runtime = await createAgentRuntime({
    cwd,
    agentDir,
    model: "faux/faux-1",
    modelFactory: () => models,
    session: { type: "new", persist: false },
    extensionWorkerCommand: workerCommand
  })

  try {
    const pending = runtime.session.prompt("stay busy")
    expect(runtime.session.reload()).rejects.toThrow("Cannot reload while the agent is running")
    await pending

    await writeFile(join(agentDir, "settings.json"), JSON.stringify({ steeringMode: "all", followUpMode: "all" }))
    const events: string[] = []
    const unsubscribe = runtime.session.subscribe(event => {
      if (event.type === "steering_mode_changed" || event.type === "follow_up_mode_changed") events.push(event.type)
    })
    const result = await runtime.session.reload()
    unsubscribe()
    expect(result.extensions?.outcome).toBe("disabled")
    expect(runtime.session.steeringMode).toBe("all")
    expect(runtime.session.followUpMode).toBe("all")
    expect(events).toEqual(["steering_mode_changed", "follow_up_mode_changed"])
  } finally {
    runtime.session.dispose()
    await runtime.session.waitForIdle()
    await rm(root, { recursive: true, force: true })
  }
}, 10_000)

test("whole-runtime replacement starts the candidate only after retiring the current lifecycle", async () => {
  const fixture = await extensionFixture("replacement")
  const runtime = await createAgentSessionRuntime({
    cwd: fixture.cwd,
    agentDir: fixture.agentDir,
    session: { type: "new", persist: false },
    extensionWorkerCommand: workerCommand
  })

  try {
    expect(runtime.session.extensionHostSnapshot).toMatchObject({ status: "ready", lifecycle: "started" })
    await runtime.newSession()
    expect(await readFile(fixture.lifecycle, "utf8")).toBe("start:startup\nstop:new\nstart:new\n")
  } finally {
    runtime.dispose()
    await runtime.waitForIdle()
  }

  expect(await readFile(fixture.lifecycle, "utf8")).toBe("start:startup\nstop:new\nstart:new\nstop:quit\n")
  await rm(fixture.root, { recursive: true, force: true })
}, 10_000)

async function waitForCondition(predicate: () => boolean | Promise<boolean>, timeoutMs: number): Promise<void> {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    // oxlint-disable-next-line no-await-in-loop -- bounded test poll of authoritative state
    if (await predicate()) return
    // oxlint-disable-next-line no-await-in-loop -- bounded test poll of authoritative state
    await Bun.sleep(10)
  }
  throw new Error("Condition was not met before timeout")
}

async function waitForFile(path: string): Promise<void> {
  for (let attempt = 0; attempt < 1_000; attempt++) {
    if (existsSync(path)) return
    // oxlint-disable-next-line no-await-in-loop
    await Bun.sleep(1)
  }
  throw new Error(`File was not created: ${path}`)
}

async function extensionFixture(
  name: string
): Promise<{ readonly root: string; readonly cwd: string; readonly agentDir: string; readonly lifecycle: string }> {
  const root = await mkdtemp(join(tmpdir(), `zi-runtime-extension-${name}-`))
  const cwd = join(root, "project")
  const agentDir = join(root, "agent")
  const extensions = join(agentDir, "extensions")
  const lifecycle = join(root, "lifecycle.log")
  await mkdir(cwd, { recursive: true })
  await mkdir(extensions, { recursive: true })
  await writeFile(
    join(extensions, "lifecycle.ts"),
    `import { appendFileSync } from "node:fs"
import type { ExtensionAPI } from "@with-zi/extension-api"
export default function (zi: ExtensionAPI): void {
  console.log("runtime extension stdout")
  console.error("runtime extension stderr")
  zi.on("session_start", event => appendFileSync(${JSON.stringify(lifecycle)}, "start:" + event.reason + "\\n"))
  zi.on("session_shutdown", event => appendFileSync(${JSON.stringify(lifecycle)}, "stop:" + event.reason + "\\n"))
}
`
  )
  return { root, cwd, agentDir, lifecycle }
}
