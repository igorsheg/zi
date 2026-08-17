import { expect, test } from "bun:test"
import { mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { fileURLToPath } from "node:url"

import { isCodeModeDetails } from "../src/code-mode/trace.js"
import { isPositiveInteger, isRecord } from "../src/guards.js"
import type { AgentMessage } from "../src/messages.js"
import { ZiPaths } from "../src/paths.js"
import {
  createModels,
  createTestAgentRuntime,
  fauxAssistantMessage,
  fauxProvider,
  fauxToolCall
} from "../src/testing.js"

const fixture = fileURLToPath(new URL("./fixtures/mcp-host-server.ts", import.meta.url))
type ToolResultMessage = Extract<AgentMessage, { readonly role: "toolResult" }>
const mcpToolNames = ["mcp_search", "mcp_describe", "mcp_call", "mcp_status"] as const

test("trusted project MCP stays deferred behind Code Mode and releases its process tree", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-mcp-code-mode-"))
  const pidFile = join(root, "mcp-pids.json")
  const project = await prepareProject(root, "runtime", true, pidFile)
  const models = createModels()
  const faux = fauxProvider({ provider: "mcp-e2e", models: [{ id: "model" }], tokensPerSecond: 10_000 })
  models.setProvider(faux.provider)
  const providerCatalogs: string[][] = []
  const codeDescriptions: string[] = []
  faux.setResponses([
    context => {
      captureExposure(context.tools, providerCatalogs, codeDescriptions)
      return fauxAssistantMessage(
        fauxToolCall(
          "code",
          {
            description: "Find and describe the process identity tool",
            code: `
const [selected] = await zi.mcp_search({ query: "process_info", limit: 5 });
if (!selected) throw new Error("Missing process identity tool");
scratch.selectedMcpTool = selected;
const contract = await zi.mcp_describe({ server: selected.server, tool: selected.tool });
return { selected, contract };
`
          },
          { id: "mcp-discovery" }
        ),
        { stopReason: "toolUse" }
      )
    },
    context => {
      captureExposure(context.tools, providerCatalogs, codeDescriptions)
      return fauxAssistantMessage(
        fauxToolCall(
          "code",
          {
            description: "Call the selected MCP tool",
            code: `
const selected = scratch.selectedMcpTool as { server: string; tool: string };
return await zi.mcp_call({ server: selected.server, tool: selected.tool, arguments: {} });
`
          },
          { id: "mcp-call" }
        ),
        { stopReason: "toolUse" }
      )
    },
    context => {
      captureExposure(context.tools, providerCatalogs, codeDescriptions)
      return fauxAssistantMessage("Done.")
    }
  ])

  const runtime = await createTestAgentRuntime({
    cwd: project.cwd,
    agentDir: project.agentDir,
    models,
    model: "mcp-e2e/model",
    projectTrust: { type: "trusted", cwd: project.cwd, source: "runtime" },
    session: { type: "new", persist: false },
    toolSurface: "direct-and-code"
  })
  let disposed = false
  try {
    await runtime.session.prompt("Use the project MCP server.")

    for (const catalog of providerCatalogs) {
      for (const name of mcpToolNames) expect(catalog).not.toContain(name)
    }
    expect(codeDescriptions).not.toHaveLength(0)
    for (const description of codeDescriptions) {
      for (const name of mcpToolNames) expect(description).toContain(`${name}: (input:`)
    }

    const codeResults = runtime.session.messages.filter(
      (message): message is ToolResultMessage => message.role === "toolResult" && message.toolName === "code"
    )
    const nestedCalls = codeResults.flatMap(message =>
      isCodeModeDetails(message.details) ? message.details.calls.map(call => call.name) : []
    )
    expect(nestedCalls).toEqual(["mcp_search", "mcp_describe", "mcp_call"])

    const discoveryResult = codeResults.find(message => message.toolCallId === "mcp-discovery")
    if (!discoveryResult || discoveryResult.content[0]?.type !== "text") {
      throw new Error("Missing MCP discovery result")
    }
    const discovery: unknown = JSON.parse(discoveryResult.content[0].text)
    if (!isRecord(discovery) || !isRecord(discovery.selected) || !isRecord(discovery.contract)) {
      throw new Error("Invalid MCP discovery result")
    }
    expect(discovery.selected).toMatchObject({ server: "fixture", tool: "process_info" })
    expect(discovery.contract).toMatchObject({ server: "fixture", name: "process_info" })

    const callResult = codeResults.find(message => message.toolCallId === "mcp-call")
    if (!callResult || callResult.content[0]?.type !== "text") throw new Error("Missing MCP Code Mode result")
    const value: unknown = JSON.parse(callResult.content[0].text)
    if (!isRecord(value) || !isRecord(value.structuredContent)) throw new Error("Invalid MCP Code Mode result")
    expect(value.content).toEqual([expect.objectContaining({ type: "text" })])
    expect(value.structuredContent.server).toBeNumber()
    expect(value.structuredContent.descendant).toBeNumber()

    const pids = await readPids(pidFile)
    expect(isAlive(pids.server)).toBe(true)
    expect(isAlive(pids.descendant)).toBe(true)

    runtime.session.dispose()
    await runtime.session.waitForIdle()
    disposed = true
    await waitForExit(pids.server)
    await waitForExit(pids.descendant)
  } finally {
    if (!disposed) {
      runtime.session.dispose()
      await runtime.session.waitForIdle().catch(() => undefined)
    }
  }
})

test("Code Mode traces redact configured values reflected by an MCP server", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-mcp-redaction-"))
  const secret = "code-mode-reflected-secret"
  const project = await prepareProject(root, "reflect-secret", false, undefined, 1_000, {
    MCP_REFLECTED_SECRET: secret
  })
  const models = createModels()
  const faux = fauxProvider({ provider: "mcp-redaction", models: [{ id: "model" }] })
  models.setProvider(faux.provider)
  faux.setResponses([
    fauxAssistantMessage(
      fauxToolCall(
        "code",
        {
          description: "Inspect reflected MCP output",
          code: `
const descriptor = await zi.mcp_describe({ server: "fixture", tool: "rich" });
const value = await zi.mcp_call({ server: "fixture", tool: "rich", arguments: {} });
let failure = "";
try {
  await zi.mcp_call({ server: "fixture", tool: "fail", arguments: {} });
} catch (cause) {
  failure = cause instanceof Error ? cause.message : String(cause);
}
return { descriptor, value, failure };
`
        },
        { id: "redaction" }
      ),
      { stopReason: "toolUse" }
    ),
    fauxAssistantMessage("Done.")
  ])
  const runtime = await createTestAgentRuntime({
    cwd: project.cwd,
    agentDir: project.agentDir,
    models,
    model: "mcp-redaction/model",
    projectTrust: { type: "trusted", cwd: project.cwd, source: "runtime" },
    session: { type: "new", persist: false },
    toolSurface: "direct-and-code"
  })
  try {
    await runtime.session.prompt("Inspect reflected output.")
    const trace = JSON.stringify(runtime.session.messages)
    expect(trace).toContain("[redacted]")
    expect(trace).not.toContain(secret)
  } finally {
    runtime.session.dispose()
    await runtime.session.waitForIdle()
  }
})

test("session reload resolves MCP settings and projects authoritative server changes", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-mcp-reload-"))
  const project = await prepareProject(root, "single", false)
  const models = createModels()
  const faux = fauxProvider({ provider: "mcp-reload", models: [{ id: "model" }] })
  models.setProvider(faux.provider)
  const runtime = await createTestAgentRuntime({
    cwd: project.cwd,
    agentDir: project.agentDir,
    models,
    model: "mcp-reload/model",
    projectTrust: { type: "trusted", cwd: project.cwd, source: "runtime" },
    session: { type: "new", persist: false },
    toolSurface: "direct-and-code"
  })
  const changed: string[] = []
  const unsubscribe = runtime.session.subscribe(event => {
    if (event.type === "mcp_server_changed") changed.push(event.server)
  })
  try {
    expect(runtime.session.mcpHostSnapshot).toEqual([
      expect.objectContaining({ name: "fixture", transport: "stdio", status: "ready" })
    ])
    await writeFile(project.settingsFile, "{")
    const malformed = await runtime.session.reload()
    expect(malformed.settingsErrors).toHaveLength(1)
    expect(malformed.mcp).toBeUndefined()
    expect(runtime.session.mcpHostSnapshot).toEqual([
      expect.objectContaining({ name: "fixture", transport: "stdio", status: "ready" })
    ])

    await writeFile(project.settingsFile, JSON.stringify({ mcpServers: { fixture: { enabled: false } } }))
    const result = await runtime.session.reload()

    expect(result.mcp).toEqual({ failures: [] })
    expect(runtime.session.mcpHostSnapshot).toEqual([{ name: "fixture", status: "disabled" }])
    expect(changed).toContain("fixture")
  } finally {
    unsubscribe()
    runtime.session.dispose()
    await runtime.session.waitForIdle()
  }
})

test("provider exposure is byte-identical for one and 256 discovered MCP tools", async () => {
  const single = await captureProviderExposure("single")
  const maximum = await captureProviderExposure("maximum")

  expect(single.tools).toEqual(maximum.tools)
  expect(single.definitions).toBe(maximum.definitions)
  expect(Buffer.byteLength(single.definitions)).toBe(Buffer.byteLength(maximum.definitions))
  expect(single.description).toBe(maximum.description)
  expect(Buffer.byteLength(single.description)).toBe(Buffer.byteLength(maximum.description))
  for (const name of mcpToolNames) expect(single.tools).not.toContain(name)
})

test("required startup failure cleans up while optional failure remains inspectable", async () => {
  const requiredRoot = await mkdtemp(join(tmpdir(), "zi-mcp-required-"))
  const pidFile = join(requiredRoot, "mcp-pids.json")
  const requiredProject = await prepareProject(requiredRoot, "required-hang", true, pidFile, 600)
  const requiredModels = createModels()
  const requiredFaux = fauxProvider({ provider: "mcp-required", models: [{ id: "model" }] })
  requiredModels.setProvider(requiredFaux.provider)

  await expectRejection(
    createTestAgentRuntime({
      cwd: requiredProject.cwd,
      agentDir: requiredProject.agentDir,
      models: requiredModels,
      model: "mcp-required/model",
      projectTrust: { type: "trusted", cwd: requiredProject.cwd, source: "runtime" },
      session: { type: "new", persist: false },
      toolSurface: "direct-and-code"
    }),
    "Required MCP server fixture failed"
  )
  const requiredPids = await readPids(pidFile)
  await waitForExit(requiredPids.server)
  await waitForExit(requiredPids.descendant)

  const optionalRoot = await mkdtemp(join(tmpdir(), "zi-mcp-optional-"))
  const optionalProject = await prepareProject(optionalRoot, "exit", false)
  const optionalModels = createModels()
  const optionalFaux = fauxProvider({ provider: "mcp-optional", models: [{ id: "model" }] })
  optionalModels.setProvider(optionalFaux.provider)
  optionalFaux.setResponses([
    fauxAssistantMessage(
      fauxToolCall(
        "code",
        { description: "Inspect MCP status", code: "return await zi.mcp_status({})" },
        { id: "status" }
      ),
      { stopReason: "toolUse" }
    ),
    fauxAssistantMessage("Done.")
  ])
  const optional = await createTestAgentRuntime({
    cwd: optionalProject.cwd,
    agentDir: optionalProject.agentDir,
    models: optionalModels,
    model: "mcp-optional/model",
    projectTrust: { type: "trusted", cwd: optionalProject.cwd, source: "runtime" },
    session: { type: "new", persist: false },
    toolSurface: "direct-and-code"
  })
  try {
    await optional.session.prompt("Check status.")
    const result = optional.session.messages.find(
      (message): message is ToolResultMessage => message.role === "toolResult" && message.toolCallId === "status"
    )
    if (!result || result.content[0]?.type !== "text") throw new Error("Missing MCP status result")
    expect(JSON.parse(result.content[0].text)).toEqual([
      expect.objectContaining({ name: "fixture", transport: "stdio", status: "failed" })
    ])
    if (!isCodeModeDetails(result.details)) throw new Error("Missing MCP status trace")
    expect(result.details.calls.map(call => call.name)).toEqual(["mcp_status"])
  } finally {
    optional.session.dispose()
    await optional.session.waitForIdle()
  }
})

async function captureProviderExposure(mode: "single" | "maximum") {
  const root = await mkdtemp(join(tmpdir(), `zi-mcp-exposure-${mode}-`))
  const project = await prepareProject(root, mode, true)
  const models = createModels()
  const faux = fauxProvider({ provider: `mcp-${mode}`, models: [{ id: "model" }] })
  models.setProvider(faux.provider)
  let tools: string[] = []
  let definitions = ""
  let description = ""
  faux.setResponses([
    context => {
      tools = (context.tools ?? []).map(tool => tool.name)
      definitions = JSON.stringify(context.tools ?? [])
      description = context.tools?.find(tool => tool.name === "code")?.description ?? ""
      return fauxAssistantMessage("Done.")
    }
  ])
  const runtime = await createTestAgentRuntime({
    cwd: project.cwd,
    agentDir: project.agentDir,
    models,
    model: `${faux.provider.id}/model`,
    projectTrust: { type: "trusted", cwd: project.cwd, source: "runtime" },
    session: { type: "new", persist: false },
    toolSurface: "direct-and-code"
  })
  try {
    await runtime.session.prompt("Inspect tools.")
    return { tools, definitions, description }
  } finally {
    runtime.session.dispose()
    await runtime.session.waitForIdle()
  }
}

async function prepareProject(
  root: string,
  mode: string,
  required: boolean,
  pidFile?: string,
  startupTimeoutMs = 1_000,
  environment: Readonly<Record<string, string>> = Object.freeze({})
) {
  const cwd = join(root, "project")
  const agentDir = join(root, "agent")
  const paths = new ZiPaths(cwd, agentDir)
  await mkdir(paths.projectDir, { recursive: true })
  await writeFile(
    paths.projectSettingsFile,
    JSON.stringify({
      mcpServers: {
        fixture: {
          transport: "stdio",
          command: [process.execPath, fixture, mode],
          required,
          startupTimeoutMs,
          toolTimeoutMs: 1_000,
          ...(pidFile || Object.keys(environment).length > 0
            ? { environment: { ...(pidFile ? { MCP_PID_FILE: pidFile } : {}), ...environment } }
            : {})
        }
      }
    })
  )
  return { cwd, agentDir, settingsFile: paths.projectSettingsFile }
}

function captureExposure(
  tools: readonly { readonly name: string; readonly description?: string }[] | undefined,
  catalogs: string[][],
  descriptions: string[]
): void {
  catalogs.push((tools ?? []).map(tool => tool.name))
  descriptions.push(tools?.find(tool => tool.name === "code")?.description ?? "")
}

async function readPids(path: string): Promise<{ readonly server: number; readonly descendant: number }> {
  const value: unknown = JSON.parse(await readFile(path, "utf8"))
  if (!isRecord(value) || !isPositiveInteger(value.server) || !isPositiveInteger(value.descendant)) {
    throw new Error("Invalid MCP process marker")
  }
  return { server: value.server, descendant: value.descendant }
}

async function waitForExit(pid: number): Promise<void> {
  const deadline = Date.now() + 2_000
  while (isAlive(pid)) {
    if (Date.now() >= deadline) throw new Error(`MCP process ${pid} remained alive after disposal`)
    // oxlint-disable-next-line no-await-in-loop -- bounded poll of process settlement
    await Bun.sleep(10)
  }
}

async function expectRejection(operation: Promise<unknown>, message: string): Promise<void> {
  try {
    await operation
    throw new Error("Expected operation to reject")
  } catch (cause) {
    if (!(cause instanceof Error)) throw cause
    expect(cause.message).toContain(message)
  }
}

function isAlive(pid: number): boolean {
  try {
    process.kill(pid, 0)
    return true
  } catch {
    return false
  }
}
