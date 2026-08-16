import { expect, test } from "bun:test"
import { existsSync } from "node:fs"
import { access, copyFile, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join, resolve } from "node:path"

import { createAgentSessionRuntime } from "../src/agent-session-runtime.js"
import { createAgentRuntime } from "../src/runtime.js"
import { SessionManager } from "../src/session-manager.js"
import { createModels, fauxAssistantMessage, fauxProvider, fauxText, fauxToolCall } from "../src/testing.js"

const cli = resolve(import.meta.dirname, "../../cli/src/main.ts")
const workerCommand = Object.freeze([process.execPath, cli])

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
          {
            description: "Call the repository echo extension",
            code: `return (await zi.repository_echo({ value: "nested" })).value`
          },
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
          {
            description: "Activate the extension catalog",
            code: `await zi.activate_catalog({}); return typeof zi.dormant_echo`
          },
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
      fauxToolCall(
        "code",
        { description: "Call the activated extension", code: `return zi.dormant_echo({ value: "nested" })` },
        { id: "dormant-code" }
      ),
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

test("extensions orchestrate the root AgentTeam through the six-operation API", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-runtime-extension-agents-"))
  const cwd = join(root, "project")
  const agentDir = join(root, "agent")
  const modes = join(root, "modes.log")
  await mkdir(cwd, { recursive: true })
  await mkdir(join(agentDir, "extensions"), { recursive: true })
  await writeFile(
    join(agentDir, "extensions", "agents.ts"),
    `import { appendFileSync } from "node:fs"
import { Schema } from "@with-zi/extension-api"
export default function (zi) {
  zi.on("agent_start", (_event, context) => appendFileSync(${JSON.stringify(modes)}, context.mode + "\\n"))
  zi.registerTool({
    name: "delegate_agent",
    label: "delegate_agent",
    description: "Delegate through AgentTeam",
    parameters: Schema.object({}),
    outputSchema: Schema.string(),
    async execute() {
      if (!zi.agents) throw new Error("AgentTeam API unavailable")
      let invalidModelError = ""
      try {
        await zi.agents.spawn("invalid_task", "This must not reserve an agent.", { model: "missing/model" })
      } catch (cause) {
        invalidModelError = String(cause)
      }
      const path = await zi.agents.spawn("extension_task", "Act as a focused worker. Find one fact.", {
        agentType: "worker",
        model: "faux/faux-1",
        thinking: "high"
      })
      const firstWait = await zi.agents.wait(1_000)
      const secondWait = await zi.agents.wait(1_000)
      const listed = await zi.agents.list()
      return JSON.stringify({
        path,
        invalidModelError,
        waits: [firstWait, secondWait].map(result => ({
          message: result.message,
          timedOut: result.timedOut,
          paths: result.agents.map(agent => agent.path)
        })),
        listed: listed.map(agent => ({ path: agent.path, status: agent.status, residency: agent.residency }))
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
    fauxAssistantMessage(fauxToolCall("delegate_agent", {}, { id: "delegate-agent" }), { stopReason: "toolUse" }),
    fauxAssistantMessage("extension child answer"),
    fauxAssistantMessage("extension delegation admitted"),
    fauxAssistantMessage("extension completion received")
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
    await runtime.session.prompt("Delegate from the extension.")
    expect(runtime.session.messages).toContainEqual(
      expect.objectContaining({
        role: "toolResult",
        toolName: "delegate_agent",
        content: [
          expect.objectContaining({
            text: expect.stringContaining(
              '"waits":[{"message":"Wait completed.\\n\\nRequested timeout of 1000ms was clamped to the minimum of 10000ms.","timedOut":false,"paths":["/root/extension_task"]}'
            )
          })
        ]
      })
    )
    expect(runtime.session.messages).toContainEqual(
      expect.objectContaining({
        role: "toolResult",
        toolName: "delegate_agent",
        content: [
          expect.objectContaining({
            text: expect.stringContaining('"invalidModelError":"Error: Unknown model: missing/model.')
          })
        ]
      })
    )
    expect(runtime.session.messages).toContainEqual(
      expect.objectContaining({
        role: "toolResult",
        toolName: "delegate_agent",
        content: [expect.objectContaining({ text: expect.stringContaining('"status":"completed"') })]
      })
    )
    expect(runtime.session.agentSnapshots()).toEqual([
      expect.objectContaining({ path: "/root/extension_task", agentType: "worker", status: "completed" })
    ])
    expect(runtime.session.sessionManager.agentTeamEntries()).toContainEqual(
      expect.objectContaining({
        type: "agent_spawn_reserved",
        agentType: "worker",
        execution: { model: { provider: "faux", modelId: "faux-1" }, thinkingLevel: "off" }
      })
    )
    expect(await readFile(modes, "utf8")).toBe("embedded\nembedded\n")
  } finally {
    runtime.session.dispose()
    await runtime.session.waitForIdle()
    await rm(root, { recursive: true, force: true })
  }
}, 15_000)

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
    extensionWorkerCommand: workerCommand
  })

  try {
    await runtime.session.prompt("Crash the extension tool.")
    await runtime.session.prompt("Continue without it.")
    expect(catalogs[0]).toContain("crash_tool")
    expect(catalogs[0]).toContain("spawn_agent")
    expect(catalogs[1]).not.toContain("crash_tool")
    expect(catalogs[1]).toContain("spawn_agent")
    expect(catalogs[2]).not.toContain("crash_tool")
    expect(catalogs[2]).toContain("spawn_agent")
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
  for (const name of ["read", "code", "then", "spawn_agent"]) zi.registerTool({
    name,
    description: "Conflicts with built-in " + name,
    parameters: Schema.object({}),
    execute: () => "must not run"
  })
}
`
  )
  const runtime = await createAgentRuntime({ cwd, agentDir, session: { type: "new", persist: false } })

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
          message: expect.stringContaining("spawn_agent conflicts with an existing session tool")
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
