import { expect, test } from "bun:test"
import { mkdir, mkdtemp, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join, resolve } from "node:path"

import type { AgentTool } from "@earendil-works/pi-agent-core"

import { createProcessTreeTracker } from "../src/processes/process-tree.js"
import { SessionManager } from "../src/session-manager.js"
import { SubagentSupervisor } from "../src/subagents/supervisor.js"
import { isSubagentToolDetails, maxSubagentToolDetailsBytes } from "../src/subagents/tool-details.js"
import { createSubagentTools, maxSubagentToolResultBytes } from "../src/subagents/tools.js"
import { projectToolPresentation } from "../src/tools/presentation/project.js"

const mockChild = resolve(import.meta.dir, "fixtures/mock-rpc-child.ts")
const pathfinderProfile = Object.freeze({
  name: "pathfinder",
  description: "Find implementation evidence",
  instructions: "Return concrete paths."
})

test("spawn profile schema exposes bounded purpose summaries without requiring catalog listing", async () => {
  const harness = await createHarness("profile-schema", "unused")
  try {
    const profiles = Array.from({ length: 64 }, (_, index) => ({
      name: `p${index.toString(36).padStart(2, "0")}${"x".repeat(60)}`,
      description: `Purpose ${index} ${"detail ".repeat(800)}`,
      instructions: `Handle profile ${index}.`
    }))
    const spawn = requireTool(createSubagentTools(profiles, harness.supervisor, harness.spawn), "spawn_subagent")
    const properties = requireRecord(Reflect.get(spawn.parameters, "properties"), "spawn properties")
    const profile = requireRecord(properties.profile, "profile parameter")
    const description = requireString(profile.description, "profile description")

    expect(profile.enum).toEqual(profiles.map(candidate => candidate.name))
    expect(Buffer.byteLength(description)).toBeLessThanOrEqual(8 * 1024)
    expect(description).toContain(`${profiles[0]?.name}: Purpose 0`)
    expect(description).toContain(`${profiles[63]?.name}: Purpose 63`)
  } finally {
    await harness.dispose()
  }
})

test("standard subagent tools exist only for an admitted profile catalog", async () => {
  const harness = await createHarness("catalog", "found")
  try {
    expect(createSubagentTools([], harness.supervisor, harness.spawn)).toEqual([])

    const tools = createSubagentTools([pathfinderProfile], harness.supervisor, harness.spawn)
    expect(tools.map(tool => tool.name)).toEqual([
      "list_subagent_profiles",
      "spawn_subagent",
      "send_subagent",
      "continue_subagent",
      "wait_subagents",
      "interrupt_subagent",
      "close_subagent",
      "list_subagents"
    ])
    const spawn = requireTool(tools, "spawn_subagent")
    const parameters: unknown = Reflect.get(spawn.parameters, "properties")
    if (typeof parameters !== "object" || parameters === null || Array.isArray(parameters)) {
      throw new Error("Expected spawn properties")
    }
    const profileParameter: unknown = Reflect.get(parameters, "profile")
    if (typeof profileParameter !== "object" || profileParameter === null || Array.isArray(profileParameter)) {
      throw new Error("Expected profile parameter")
    }
    expect(Reflect.get(profileParameter, "enum")).toEqual(["pathfinder"])
    expect(Reflect.get(profileParameter, "description")).toContain("pathfinder: Find implementation evidence")

    const spawned = await spawn.execute(
      "spawn",
      { profile: "pathfinder", name: "finder-1", prompt: "Locate the owner" },
      undefined
    )
    expect(JSON.parse(resultText(spawned))).toEqual({ name: "finder-1", profile: "pathfinder" })
    expect(spawned.details).toMatchObject({
      type: "subagent",
      outcome: "success",
      operation: "spawn",
      profile: "pathfinder",
      agent: { name: "finder-1" }
    })
    expect(isSubagentToolDetails(spawned.details)).toBe(true)
    expect(harness.admissions).toEqual([{ profile: "pathfinder", name: "finder-1", prompt: "Locate the owner" }])

    const wait = requireTool(tools, "wait_subagents")
    const waited = await wait.execute("wait", { names: ["finder-1"], timeout_ms: 5_000 }, undefined)
    expect(JSON.parse(resultText(waited))).toMatchObject({
      subagents: [{ name: "finder-1", completion: { status: "completed", text: "found" } }],
      all_completed: true
    })
    expect(isSubagentToolDetails(waited.details)).toBe(true)

    const sent = await requireTool(tools, "send_subagent").execute(
      "send",
      { name: "finder-1", text: "Include ownership notes" },
      undefined
    )
    expect(isSubagentToolDetails(sent.details)).toBe(true)
    expect(resultText(sent)).toBe("Queued message for finder-1.")

    const continued = await requireTool(tools, "continue_subagent").execute(
      "continue",
      { name: "finder-1", text: "Report the final answer" },
      undefined
    )
    expect(isSubagentToolDetails(continued.details)).toBe(true)
    expect(resultText(continued)).toBe("Started follow-up for finder-1.")
    await waitFor(() => harness.supervisor.status().readyNames.includes("finder-1"), 5_000)
    const waitedAgain = await wait.execute("wait-again", { timeout_ms: 5_000 }, undefined)
    expect(JSON.parse(resultText(waitedAgain)).subagents).toEqual([
      expect.objectContaining({ name: "finder-1", completion: expect.objectContaining({ status: "completed" }) })
    ])

    const interrupted = await requireTool(tools, "interrupt_subagent").execute(
      "interrupt",
      { name: "finder-1" },
      undefined
    )
    expect(isSubagentToolDetails(interrupted.details)).toBe(true)

    const listed = await requireTool(tools, "list_subagents").execute("list", {}, undefined)
    expect(isSubagentToolDetails(listed.details)).toBe(true)

    const closed = await requireTool(tools, "close_subagent").execute("close", { name: "finder-1" }, undefined)
    expect(isSubagentToolDetails(closed.details)).toBe(true)
  } finally {
    await harness.dispose()
  }
}, 15_000)

test("profile and wait projections remain bounded", async () => {
  const reply = "界".repeat(Math.floor((40 * 1024) / 3))
  const harness = await createHarness("bounds", reply)
  try {
    const profiles = Array.from({ length: 64 }, (_, index) => ({
      name: `profile-${index}`,
      description: "d".repeat(4 * 1024),
      instructions: "Inspect."
    }))
    const tools = createSubagentTools(profiles, harness.supervisor, harness.spawn)
    const listed = await requireTool(tools, "list_subagent_profiles").execute("profiles", {}, undefined)
    expect(Buffer.byteLength(resultText(listed))).toBeLessThanOrEqual(maxSubagentToolResultBytes)
    expect(JSON.parse(resultText(listed)).omitted_bytes).toBeGreaterThan(0)
    expect(Buffer.byteLength(JSON.stringify(listed.details))).toBeLessThanOrEqual(maxSubagentToolDetailsBytes)
    expect(isSubagentToolDetails(listed.details)).toBe(true)

    await harness.spawn("profile-1", "first", "inspect")
    await harness.spawn("profile-2", "second", "inspect")
    const waited = await requireTool(tools, "wait_subagents").execute(
      "wait",
      { names: ["first", "second"], timeout_ms: 5_000 },
      undefined
    )
    const text = resultText(waited)
    expect(Buffer.byteLength(text)).toBeLessThanOrEqual(maxSubagentToolResultBytes)
    expect(JSON.parse(text).omitted_bytes).toBeGreaterThan(0)
    expect(Buffer.byteLength(JSON.stringify(waited.details))).toBeLessThanOrEqual(maxSubagentToolDetailsBytes)
    expect(isSubagentToolDetails(waited.details)).toBe(true)
    const presentation = projectToolPresentation({
      status: "done",
      name: "wait_subagents",
      args: { names: ["first", "second"] },
      result: waited
    })
    expect(presentation.body?.text).toContain("First output:")
    expect(presentation.body?.text).toContain("Second output:")
  } finally {
    await harness.dispose()
  }
}, 15_000)

async function createHarness(name: string, reply: string) {
  const root = await mkdtemp(join(tmpdir(), `zi-subagent-tools-${name}-`))
  const cwd = join(root, "project")
  await mkdir(cwd)
  const supervisor = new SubagentSupervisor({
    command: [process.execPath, mockChild],
    cwd,
    env: { ...process.env, MOCK_RPC_REPLY: reply },
    selection: () => ({ model: "faux/faux-1", thinkingLevel: "off" }),
    sessionManager: SessionManager.inMemory(cwd),
    processTreeTracker: createProcessTreeTracker()
  })
  const admissions: Array<{ profile: string; name: string; prompt: string }> = []
  return {
    supervisor,
    admissions,
    spawn: (profileName: string, runtimeName: string, prompt: string, signal?: AbortSignal) => {
      admissions.push({ profile: profileName, name: runtimeName, prompt })
      return supervisor.spawn(runtimeName, prompt, signal)
    },
    async dispose() {
      await supervisor.shutdown()
      await rm(root, { recursive: true, force: true })
    }
  }
}

function requireRecord(value: unknown, label: string): Record<string, unknown> {
  if (!isRecord(value)) throw new Error(`Expected ${label}`)
  return value
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}

function requireString(value: unknown, label: string): string {
  if (typeof value !== "string") throw new Error(`Expected ${label}`)
  return value
}

function requireTool(tools: readonly AgentTool[], name: string): AgentTool {
  const tool = tools.find(candidate => candidate.name === name)
  if (!tool) throw new Error(`Expected ${name}`)
  return tool
}

async function waitFor(predicate: () => boolean, timeoutMs: number): Promise<void> {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    if (predicate()) return
    // oxlint-disable-next-line no-await-in-loop -- bounded test poll
    await Bun.sleep(10)
  }
  throw new Error("condition not met before deadline")
}

function resultText(result: {
  readonly content: readonly { readonly type: string; readonly text?: string }[]
}): string {
  const content = result.content[0]
  if (content?.type !== "text" || content.text === undefined) throw new Error("Expected text result")
  return content.text
}
