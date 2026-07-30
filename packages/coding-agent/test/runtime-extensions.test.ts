import { expect, test } from "bun:test"
import { existsSync } from "node:fs"
import { access, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises"
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
    execute: ({ value }) => ({ prefix, value })
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
    fauxAssistantMessage(
      fauxToolCall(
        "code",
        { code: `async () => (await zi.repository_echo({ value: "nested" })).value` },
        { id: "extension-code-1" }
      ),
      { stopReason: "toolUse" }
    ),
    fauxAssistantMessage(fauxText("Extension completed."))
  ])
  const runtime = await createAgentRuntime({
    cwd,
    agentDir,
    model: "faux/faux-1",
    modelFactory: () => models,
    session: { type: "new", persist: true }
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
    expect(runtime.session.extensionHostSnapshot).toMatchObject({ status: "ready", lifecycle: "started" })
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

test("a failed extension generation is removed from current and future provider catalogs", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-runtime-extension-tool-failure-"))
  const cwd = join(root, "project")
  const agentDir = join(root, "agent")
  const extensionDir = join(agentDir, "extensions")
  await mkdir(cwd, { recursive: true })
  await mkdir(extensionDir, { recursive: true })
  await writeFile(
    join(extensionDir, "crash.ts"),
    `import { Schema } from "@with-zi/extension-api"
export default zi => zi.registerTool({
  name: "crash_tool",
  description: "Crash the extension worker",
  parameters: Schema.object({}),
  execute: () => process.exit(17)
})
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
    expect(catalogs[1]).not.toContain("crash_tool")
    expect(catalogs[2]).not.toContain("crash_tool")
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
  for (const name of ["read", "code", "then"]) zi.registerTool({
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
