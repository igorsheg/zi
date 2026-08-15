import { expect, test } from "bun:test"
import { mkdir, mkdtemp, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type { AgentTool } from "@earendil-works/pi-agent-core"
import { InvariantRegistry } from "@with-zi/invariants"

import { isRecord } from "../src/guards.js"
import { ZiPaths } from "../src/paths.js"
import { SessionManager } from "../src/session-manager.js"
import { SubagentSupervisor } from "../src/subagents/supervisor.js"
import {
  isSubagentToolDetails,
  maxProjectedSubagentToolEvidenceBytes,
  maxSubagentToolDetailsBytes,
  projectSubagentToolAgents
} from "../src/subagents/tool-details.js"
import { createSubagentTools, maxSubagentToolResultBytes } from "../src/subagents/tools.js"
import { projectToolPresentation } from "../src/tools/presentation/project.js"
import { createTestChildSessionFactory } from "./subagent-harness.js"
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
  const harness = await createHarness("catalog", "found", 100)
  try {
    expect(createSubagentTools([], harness.supervisor, harness.spawn)).toEqual([])

    const tools = createSubagentTools([pathfinderProfile], harness.supervisor, harness.spawn)
    expect(tools.map(tool => tool.name)).toEqual([
      "list_subagent_profiles",
      "spawn_subagent",
      "send_subagent_message",
      "assign_subagent_task",
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
    expect(Reflect.get(profileParameter, "description")).toContain("reusable configuration, not a runtime name")
    expect(Reflect.get(profileParameter, "description")).toContain("pathfinder: Find implementation evidence")
    const runtimeNameParameter = requireRecord(Reflect.get(parameters, "name"), "runtime name parameter")
    expect(requireString(runtimeNameParameter.description, "runtime name description")).toContain(
      "separate from the profile name"
    )
    expect(spawn.description).toContain("Completion is delivered to parent context")
    expect(spawn.description).toContain("at most 4 live subagents")
    expect(requireTool(tools, "send_subagent_message").description).toContain("never starts an idle turn")
    expect(requireTool(tools, "assign_subagent_task").description).toContain("Starts a new work cycle when idle")
    expect(requireTool(tools, "assign_subagent_task").description).toContain("separate cycle")
    const waitTool = requireTool(tools, "wait_subagents")
    expect(waitTool.description).toContain("older pending completion")
    expect(waitTool.description).toContain("does not depend on this tool")
    const waitSchema = requireRecord(waitTool.parameters, "wait schema")
    expect(Array.isArray(waitSchema.required) ? waitSchema.required : []).not.toContain("names")
    const waitProperties = requireRecord(waitSchema.properties, "wait properties")
    const waitNames = requireRecord(waitProperties.names, "wait names parameter")
    expect(requireString(waitNames.description, "wait names description")).toContain("once when the call begins")
    expect(requireTool(tools, "close_subagent").description).toContain("runtime name remains reserved")
    expect(requireTool(tools, "interrupt_subagent").description).toContain("exact work cycle")
    expect(requireTool(tools, "list_subagents").description).toContain("elapsed time")
    expect(requireTool(tools, "list_subagents").description).toContain("assign work with assign_subagent_task")
    expect(requireTool(tools, "list_subagents").description).toContain("release its slot with close_subagent")

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
      subagents: [{ name: "finder-1", completion: { work_cycle: 1, status: "completed", text: "found" } }],
      pending_names: [],
      timed_out: false
    })
    expect(isSubagentToolDetails(waited.details)).toBe(true)

    const sent = await requireTool(tools, "send_subagent_message").execute(
      "send",
      { name: "finder-1", text: "Include ownership notes" },
      undefined
    )
    expect(isSubagentToolDetails(sent.details)).toBe(true)
    expect(resultText(sent)).toBe("Sent context to finder-1.")
    expect(harness.supervisor.snapshots()[0]).toMatchObject({ lifecycle: "idle", workCycle: 1 })

    const continued = await requireTool(tools, "assign_subagent_task").execute(
      "continue",
      { name: "finder-1", text: "Report the final answer" },
      undefined
    )
    expect(isSubagentToolDetails(continued.details)).toBe(true)
    expect(resultText(continued)).toBe("Started a new task cycle for finder-1.")
    expect(harness.supervisor.snapshots()[0]).toMatchObject({ lifecycle: "running", workCycle: 2 })
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
    expect(JSON.parse(resultText(interrupted))).toMatchObject({
      result: "already_idle",
      all_completed: true,
      subagents: [{ name: "finder-1", completion: { work_cycle: 2, status: "completed" } }]
    })

    const listed = await requireTool(tools, "list_subagents").execute("list", {}, undefined)
    expect(isSubagentToolDetails(listed.details)).toBe(true)
    expect(JSON.parse(resultText(listed))).toEqual({
      subagents: [
        {
          name: "finder-1",
          status: "idle",
          work_cycle: 2,
          task: "Report the final answer",
          elapsed_ms: expect.any(Number)
        }
      ]
    })

    const closed = await requireTool(tools, "close_subagent").execute("close", { name: "finder-1" }, undefined)
    expect(isSubagentToolDetails(closed.details)).toBe(true)
    expect(JSON.parse(resultText(closed))).toMatchObject({
      previous_status: "idle",
      all_completed: true,
      subagents: [{ name: "finder-1", completion: { work_cycle: 2, status: "completed" } }]
    })
  } finally {
    await harness.dispose()
  }
}, 15_000)

test("targetless wait captures the eligible set once at call start", async () => {
  const harness = await createHarness("targetless-capture", "capture-ok", 400)
  try {
    const tools = createSubagentTools([pathfinderProfile], harness.supervisor, harness.spawn)
    const wait = requireTool(tools, "wait_subagents")
    const empty = await wait.execute("empty-wait", { timeout_ms: 5_000 }, undefined)
    expect(JSON.parse(resultText(empty))).toEqual({
      subagents: [],
      pending_names: [],
      timed_out: false,
      omitted_bytes: 0
    })

    await harness.spawn("pathfinder", "captured-worker", "captured")
    const waiting = wait.execute("captured-wait", { timeout_ms: 5_000 }, undefined)
    await harness.spawn("pathfinder", "later-worker", "not captured")

    expect(JSON.parse(resultText(await waiting)).subagents).toEqual([
      expect.objectContaining({ name: "captured-worker", completion: expect.objectContaining({ status: "completed" }) })
    ])
  } finally {
    await harness.dispose()
  }
}, 15_000)

test("wait returns the first mailbox completion and leaves captured peers running", async () => {
  const harness = await createHarness("receive-first", "mailbox-ok", 300)
  try {
    const tools = createSubagentTools([pathfinderProfile], harness.supervisor, harness.spawn)
    await harness.spawn("pathfinder", "first-worker", "first")
    await Bun.sleep(100)
    await harness.spawn("pathfinder", "second-worker", "second")

    const waited = await requireTool(tools, "wait_subagents").execute(
      "receive-first",
      { names: ["first-worker", "second-worker"], timeout_ms: 5_000 },
      undefined
    )
    expect(JSON.parse(resultText(waited))).toMatchObject({
      subagents: [{ name: "first-worker", completion: { status: "completed" } }],
      pending_names: ["second-worker"],
      timed_out: false
    })
    expect(waited.details).toMatchObject({ operation: "wait", pendingNames: ["second-worker"], timedOut: false })
    expect(harness.supervisor.status()).toEqual({ workingNames: ["second-worker"], readyNames: [] })

    const timedOut = await requireTool(tools, "wait_subagents").execute(
      "receive-timeout",
      { names: ["second-worker"], timeout_ms: 0 },
      undefined
    )
    expect(JSON.parse(resultText(timedOut))).toEqual({
      subagents: [],
      pending_names: ["second-worker"],
      timed_out: true,
      omitted_bytes: 0
    })
  } finally {
    await harness.dispose()
  }
}, 15_000)

test("wait projects the oldest pending completion before active work", async () => {
  const harness = await createHarness("partial-timeout", "cycle-ok", 300)
  try {
    const tools = createSubagentTools([pathfinderProfile], harness.supervisor, harness.spawn)
    await harness.spawn("pathfinder", "running-worker", "first cycle")
    await harness.spawn("pathfinder", "completed-worker", "only cycle")
    await waitFor(() => harness.supervisor.status().readyNames.length === 2, 5_000)
    await harness.supervisor.continue("running-worker", "second cycle")

    const waited = await requireTool(tools, "wait_subagents").execute(
      "partial-wait",
      { names: ["running-worker", "completed-worker"], timeout_ms: 0 },
      undefined
    )
    expect(JSON.parse(resultText(waited))).toEqual({
      subagents: [
        expect.objectContaining({
          name: "running-worker",
          completion: expect.objectContaining({ status: "completed" })
        }),
        expect.objectContaining({
          name: "completed-worker",
          completion: expect.objectContaining({ status: "completed" })
        })
      ],
      pending_names: ["running-worker"],
      timed_out: false,
      omitted_bytes: 0
    })
    const details = requireRecord(waited.details, "wait details")
    const agents = requireArray(details.agents, "wait agents")
    expect(requireRecord(agents[0], "running agent")).toMatchObject({ capturedWorkCycle: 1 })
    expect(requireRecord(agents[0], "running agent").completion).toEqual(
      expect.objectContaining({ status: "completed", workCycle: 1 })
    )
    expect(requireRecord(agents[1], "completed agent")).toMatchObject({ capturedWorkCycle: 1 })
    expect(requireRecord(agents[1], "completed agent").completion).toEqual(
      expect.objectContaining({ status: "completed", workCycle: 1 })
    )
    expect(harness.supervisor.status()).toEqual({ workingNames: ["running-worker"], readyNames: [] })
  } finally {
    await harness.dispose()
  }
}, 15_000)

test("profile and wait projections remain bounded", async () => {
  const taskAgents = projectSubagentToolAgents(
    Array.from({ length: 36 }, (_, index) => ({
      name: `task-${index}`,
      lifecycle: "exited" as const,
      task: "\\".repeat(256)
    }))
  )
  expect(Buffer.byteLength(JSON.stringify(taskAgents))).toBeLessThanOrEqual(maxProjectedSubagentToolEvidenceBytes)

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
    await waitFor(() => harness.supervisor.status().readyNames.length === 2, 5_000)
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

async function createHarness(name: string, reply: string, delayMs = 30) {
  const root = await mkdtemp(join(tmpdir(), `zi-subagent-tools-${name}-`))
  const paths = new ZiPaths(join(root, "project"), join(root, "agent"))
  await mkdir(paths.cwd)
  const sessionManager = SessionManager.inMemory(paths.cwd)
  const supervisor = new SubagentSupervisor({
    createChildSession: createTestChildSessionFactory(paths, { reply, delayMs }),
    selection: () => ({ model: "faux/faux-1", thinkingLevel: "off" }),
    sessionManager,
    invariantRegistry: new InvariantRegistry()
  })
  supervisor.bindSubagentWorkResultSink((result, persisted) => {
    const entry = sessionManager.appendSubagentWorkResult(result)
    persisted(entry)
    return entry
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

function requireArray(value: unknown, label: string): unknown[] {
  if (!Array.isArray(value)) throw new Error(`Expected ${label}`)
  return value
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
