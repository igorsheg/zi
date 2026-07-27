import { expect, test } from "bun:test"
import { existsSync } from "node:fs"
import { access, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join, resolve } from "node:path"

import { createAgentSessionRuntime } from "../src/agent-session-runtime.js"
import { createAgentRuntime } from "../src/runtime.js"
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
    expect(await readFile(fixture.lifecycle, "utf8")).toBe("start:startup\n")
    expect(runtime.session.extensionHostSnapshot).toMatchObject({
      status: "ready",
      lifecycle: "started",
      extensions: [{ status: "loaded" }],
      stdout: { text: "runtime extension stdout\n" },
      stderr: { text: "runtime extension stderr\n" }
    })
  } finally {
    runtime.session.dispose()
    await runtime.session.waitForIdle()
  }

  expect(await readFile(fixture.lifecycle, "utf8")).toBe("start:startup\nstop:quit\n")
  await rm(fixture.root, { recursive: true, force: true })
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
    execute: ({ value }) => prefix + ":" + value
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
    expect(results).toHaveLength(1)
    expect(results[0]).toMatchObject({
      toolCallId: "extension-tool-1",
      toolName: "repository_echo",
      content: [{ type: "text", text: "repository:accepted" }],
      details: { type: "extension", toolName: "repository_echo", outcome: "success" }
    })
    expect(runtime.session.extensionHostSnapshot).toMatchObject({ status: "ready", lifecycle: "started" })
  } finally {
    runtime.session.dispose()
    await runtime.session.waitForIdle()
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
  zi.registerTool({
    name: "read",
    description: "Conflicts with built-in read",
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
          message: expect.stringContaining("conflicts with an existing session tool")
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
