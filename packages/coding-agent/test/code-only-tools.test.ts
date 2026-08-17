import { afterEach, expect, test } from "bun:test"
import { mkdtemp } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { fileURLToPath } from "node:url"

import type { AgentTool, AgentToolResult } from "@earendil-works/pi-agent-core"
import { Type } from "@earendil-works/pi-ai"

import type { AgentSession } from "../src/agent-session.js"
import { CodeMode } from "../src/code-mode/code-mode.js"
import type { CodeModeCapableTool } from "../src/code-mode/tool-contract.js"
import { FileCredentialStore } from "../src/credential-store.js"
import type { ExtensionHost } from "../src/extensions/host.js"
import type { ExtensionToolRegistration } from "../src/extensions/protocol.js"
import { admitExtensionTools } from "../src/extensions/tools.js"
import { ModelRegistry } from "../src/model-registry.js"
import { ZiPaths } from "../src/paths.js"
import { createProcessTreeTracker } from "../src/processes/process-tree.js"
import { createSessionResources, ResourceLoader } from "../src/resource-loader.js"
import { createAgentSessionWithProcessTreeTracker } from "../src/sdk.js"
import { SessionManager } from "../src/session-manager.js"
import { SettingsManager } from "../src/settings-manager.js"
import { createModels, fauxAssistantMessage, fauxProvider, fauxToolCall } from "../src/testing.js"
import type { ToolSurface } from "../src/tool-surface.js"

const workerCommand = Object.freeze([
  process.execPath,
  fileURLToPath(new URL("../src/code-mode/worker-entry.ts", import.meta.url))
])
const sessions = new Set<AgentSession>()

const probeResult: AgentToolResult<{ readonly invoked: true }> = {
  content: [{ type: "text", text: "invoked" }],
  details: Object.freeze({ invoked: true })
}
const probeTool: CodeModeCapableTool = {
  name: "deferred_probe",
  label: "deferred_probe",
  description: "Invoke the deferred probe",
  parameters: Type.Object({}),
  execute: async () => probeResult,
  codeMode: { outputSchema: Type.String(), execute: async () => ({ result: probeResult, value: "invoked" }) }
}

const collisionTool: AgentTool = {
  name: probeTool.name,
  label: probeTool.label,
  description: "Conflicting direct tool",
  parameters: Type.Object({}),
  execute: async () => probeResult
}

afterEach(async () => {
  for (const session of sessions) session.dispose()
  await Promise.all([...sessions].map(session => session.waitForIdle()))
  sessions.clear()
})

test("code-only tools stay behind Code Mode on both provider surfaces", async () => {
  await Promise.all(
    (["direct-and-code", "code-only"] satisfies readonly ToolSurface[]).map(async surface => {
      const catalogs: string[][] = []
      const descriptions: string[] = []
      const { session } = await createSession(surface, catalogs, descriptions, true)

      await session.prompt("Invoke the deferred probe.")

      expect(catalogs[0]).toEqual(surface === "code-only" ? ["code"] : ["update_plan", "code"])
      expect(catalogs[0]).not.toContain(probeTool.name)
      expect(descriptions[0]).toContain("deferred_probe: (input:")
      expect(descriptions[0]).toContain("session_failures: (input:")
      expect(
        session.messages.find(message => message.role === "toolResult" && message.toolCallId === "code-1")
      ).toMatchObject({
        role: "toolResult",
        toolName: "code",
        isError: false,
        content: [{ type: "text", text: expect.stringContaining('"retained": 0') }],
        details: {
          type: "code_mode",
          outcome: "success",
          calls: [
            expect.objectContaining({ name: probeTool.name, state: "succeeded", arguments: {} }),
            expect.objectContaining({ name: "session_failures", state: "succeeded", arguments: { limit: 1 } })
          ]
        }
      })
    })
  )
})

test("a rejected direct-tool collision does not poison the active catalog", async () => {
  const catalogs: string[][] = []
  const descriptions: string[] = []
  const { session } = await createSession("direct-and-code", catalogs, descriptions)

  expect(() => session.setActiveTools([collisionTool])).toThrow(
    "Code-only tool deferred_probe conflicts with an existing session tool"
  )
  expect(session.reload()).resolves.toMatchObject({ settingsErrors: [] })
  await session.prompt("Invoke the unchanged deferred probe.")

  expect(catalogs[0]).toEqual(["update_plan", "code"])
  expect(descriptions[0]).toContain("deferred_probe: (input:")
  expect(
    session.messages.find(message => message.role === "toolResult" && message.toolCallId === "code-1")
  ).toMatchObject({ content: [{ type: "text", text: "invoked" }] })
})

test("inactive extension registrations cannot claim code-only names", () => {
  const registration: ExtensionToolRegistration = {
    source: {
      id: "conflicting-extension",
      declaredPath: "/extensions/conflict.ts",
      entryPath: "/extensions/conflict.ts",
      scope: "global",
      origin: "directory"
    },
    name: probeTool.name,
    label: probeTool.label,
    description: "Conflicts while inactive",
    active: false,
    parameters: { type: "object", properties: {} },
    outputSchema: {}
  }
  const rejections: string[] = []
  let catalog: readonly ExtensionToolRegistration[] = [registration]
  const host = {
    toolCatalog: () => catalog,
    rejectTool(tool: ExtensionToolRegistration, message: string) {
      catalog = catalog.filter(candidate => candidate !== tool)
      rejections.push(message)
    },
    invokeTool: async () => null
  } satisfies Pick<ExtensionHost, "toolCatalog" | "rejectTool" | "invokeTool">

  const admitted = admitExtensionTools([], host, new Set(), new Set([probeTool.name]))

  expect(admitted).toEqual([])
  expect(catalog).toEqual([])
  expect(rejections).toEqual(["Extension tool deferred_probe conflicts with an existing session tool and was ignored"])
})

async function createSession(
  surface: ToolSurface,
  catalogs: string[][],
  descriptions: string[],
  invokeSessionFailures = false
) {
  const cwd = await mkdtemp(join(tmpdir(), "zi-code-only-tools-"))
  const paths = new ZiPaths(cwd, join(cwd, "agent"))
  const models = createModels()
  const faux = fauxProvider({ tokensPerSecond: 10_000 })
  models.setProvider(faux.provider)
  faux.setResponses([
    context => {
      catalogs.push((context.tools ?? []).map(tool => tool.name))
      descriptions.push(context.tools?.find(tool => tool.name === "code")?.description ?? "")
      return fauxAssistantMessage(
        fauxToolCall(
          "code",
          {
            description: "Invoke the deferred probe",
            code: invokeSessionFailures
              ? "await zi.deferred_probe({}); return await zi.session_failures({ limit: 1 })"
              : "return await zi.deferred_probe({})"
          },
          { id: "code-1" }
        ),
        { stopReason: "toolUse" }
      )
    },
    fauxAssistantMessage("Done.")
  ])
  const settingsManager = new SettingsManager()
  const services = Object.freeze({
    paths,
    settingsManager,
    credentialStore: new FileCredentialStore(paths),
    modelRegistry: new ModelRegistry(models),
    resourceLoader: new ResourceLoader({ paths, project: "trusted", settingsManager })
  })
  const processTree = createProcessTreeTracker()
  const sessionManager = SessionManager.inMemory(cwd)
  const codeMode = new CodeMode(cwd, workerCommand, sessionManager, processTree)

  try {
    const { session } = await createAgentSessionWithProcessTreeTracker(
      {
        services,
        sessionManager,
        model: faux.getModel(),
        tools: [],
        resources: createSessionResources(),
        codeMode,
        toolSurface: surface
      },
      { type: "owned", tracker: processTree },
      { codeOnlyTools: [probeTool] }
    )
    sessions.add(session)
    return { session }
  } catch (cause) {
    await codeMode.dispose()
    await processTree.dispose()
    throw cause
  }
}
