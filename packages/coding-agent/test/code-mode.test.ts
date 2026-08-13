import { afterEach, expect, test } from "bun:test"
import { mkdtemp } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { fileURLToPath } from "node:url"

import type { AgentTool } from "@earendil-works/pi-agent-core"
import { Type } from "@earendil-works/pi-ai"

import { CodeMode, isCodeModeDetails } from "../src/code-mode/code-mode.js"
import { maxCodeModeLogBytes, maxCodeModeOutputBytes, maxCodeModeStateBytes } from "../src/code-mode/protocol.js"
import type { CodeModeCapableTool } from "../src/code-mode/tool-contract.js"
import { maxCodeModeTerminalDetailsBytes } from "../src/code-mode/trace.js"
import { ZiPaths } from "../src/paths.js"
import { createProcessTreeTracker, type ProcessScope, type ProcessTreeTracker } from "../src/processes/process-tree.js"
import { SessionManager } from "../src/session-manager.js"
import { createModels, createTestAgentRuntime, fauxAssistantMessage, fauxProvider } from "../src/testing.js"
import { createReadTool } from "../src/tools/read.js"
import { createUpdatePlanTool } from "../src/tools/work-plan.js"
import { WorkPlan } from "../src/work-plan.js"

const workerCommand = Object.freeze([
  process.execPath,
  fileURLToPath(new URL("../src/code-mode/worker-entry.ts", import.meta.url))
])
const computeWorkerCommand = Object.freeze([
  process.execPath,
  fileURLToPath(new URL("./fixtures/code-mode-compute-worker.ts", import.meta.url))
])
const codeModes = new Set<CodeMode>()

function createCodeMode(cwd: string): CodeMode {
  const codeMode = new CodeMode(cwd, workerCommand)
  codeModes.add(codeMode)
  return codeMode
}

afterEach(async () => {
  await Promise.all([...codeModes].map(codeMode => codeMode.dispose()))
  codeModes.clear()
})

function processExists(pid: number): boolean {
  try {
    process.kill(pid, 0)
    return true
  } catch {
    return false
  }
}

async function rejectionMessage(operation: Promise<unknown>): Promise<string> {
  try {
    await operation
    throw new Error("Expected operation to reject")
  } catch (cause) {
    return cause instanceof Error ? cause.message : String(cause)
  }
}

const echoParameters = Type.Object({ value: Type.String() })

const echoTool: AgentTool<typeof echoParameters, { readonly echoed: string }> = {
  name: "echo",
  label: "echo",
  description: "Echo a value",
  parameters: echoParameters,
  execute: async (_id, input) => ({ content: [{ type: "text", text: input.value }], details: { echoed: input.value } })
}

const statsExecute: AgentTool["execute"] = async () => ({
  content: [{ type: "text", text: "3 files, 12 lines" }],
  details: { files: 3, lines: 12 }
})

test("new Zi sessions expose direct coding tools and code by default", async () => {
  const faux = fauxProvider()
  let catalog: readonly string[] = []
  faux.setResponses([
    context => {
      catalog = (context.tools ?? []).map(tool => tool.name)
      return fauxAssistantMessage("done")
    }
  ])
  const models = createModels()
  models.setProvider(faux.provider)
  const runtime = await createTestAgentRuntime({
    cwd: await mkdtemp(join(tmpdir(), "zi-code-mode-catalog-")),
    models,
    model: "faux/faux-1",
    session: { type: "new", persist: false }
  })

  try {
    await runtime.session.prompt("inspect tools")
    expect(catalog).toEqual([
      "read",
      "bash",
      "edit",
      "write",
      "list_tasks",
      "task_output",
      "kill_task",
      "update_plan",
      "code"
    ])
  } finally {
    runtime.session.dispose()
    await runtime.session.waitForIdle()
  }
})

test("code-only sessions expose one model tool backed by the complete Zi catalog", async () => {
  const faux = fauxProvider()
  let catalog: readonly string[] = []
  let description = ""
  let systemPrompt = ""
  faux.setResponses([
    context => {
      catalog = (context.tools ?? []).map(tool => tool.name)
      description = context.tools?.[0]?.description ?? ""
      systemPrompt = context.systemPrompt ?? ""
      return fauxAssistantMessage("done")
    }
  ])
  const models = createModels()
  models.setProvider(faux.provider)
  const runtime = await createTestAgentRuntime({
    cwd: await mkdtemp(join(tmpdir(), "zi-code-only-catalog-")),
    models,
    model: "faux/faux-1",
    toolSurface: "code-only",
    session: { type: "new", persist: false }
  })

  try {
    await runtime.session.prompt("inspect tools")
    expect(catalog).toEqual(["code"])
    expect(description).toContain("read: (input:")
    expect(description).toContain("bash: (input:")
    expect(description).toContain("Tools declared parallel may overlap up to 4 at once")
    expect(systemPrompt).toContain("The only model-facing tool is code")
    expect(systemPrompt).toContain("Promise.allSettled")
    expect(systemPrompt).not.toContain("Use direct tools for one ordinary read")
  } finally {
    runtime.session.dispose()
    await runtime.session.waitForIdle()
  }
})

test("code executes serial nested calls in an isolated worker", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-code-mode-execute-"))
  const tool = createCodeMode(cwd).createTool([echoTool])
  const result = await tool.execute(
    "outer",
    {
      description: "Test code",
      code: `
  const output = [];
  for (const value of ["a", "b", "c"]) output.push(await zi.echo({ value }));
  return output.join(",");
`
    },
    undefined
  )

  expect(result.content).toEqual([{ type: "text", text: "a,b,c" }])
  expect(isCodeModeDetails(result.details)).toBe(true)
  if (!isCodeModeDetails(result.details)) throw new Error("Expected code-mode details")
  expect(result.details.outcome).toBe("success")
  expect(result.details.calls.map(call => [call.name, call.state])).toEqual([
    ["echo", "succeeded"],
    ["echo", "succeeded"],
    ["echo", "succeeded"]
  ])
})

test("code exposes declared native values instead of presentation envelopes", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-code-mode-native-value-"))
  const statsTool: CodeModeCapableTool = {
    name: "stats",
    label: "stats",
    description: "Count files and lines",
    parameters: Type.Object({}),
    execute: statsExecute,
    codeMode: {
      outputSchema: Type.Object({ files: Type.Number(), lines: Type.Number() }),
      async execute(toolCallId, input, signal, onUpdate) {
        return { result: await statsExecute(toolCallId, input, signal, onUpdate), value: { files: 3, lines: 12 } }
      }
    }
  }
  const tool = createCodeMode(cwd).createTool([statsTool])

  expect(tool.description).toContain("stats: (input: {  }) => Promise<{ files: number; lines: number }>")
  expect(tool.description).toContain("scratch holds arbitrary volatile JavaScript")
  expect(tool.description).toContain("Tool calls and ambient effects are not transactional")
  expect(tool.description).toContain("A cell may make at most 64 zi calls")
  expect(tool.description).not.toContain("ZiToolResult")
  expect(tool.description).not.toContain("JSON.parse(response.text)")

  const result = await tool.execute(
    "outer",
    { description: "Test code", code: ` const stats = await zi.stats({}); return stats.lines; ` },
    undefined
  )

  expect(result.content).toEqual([{ type: "text", text: "12" }])
})

test("code updates the authoritative work plan through its native JSON contract", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-code-mode-work-plan-"))
  const manager = SessionManager.inMemory(cwd)
  const workPlan = new WorkPlan(manager)
  const tool = createCodeMode(cwd).createTool([createUpdatePlanTool(workPlan)])
  const result = await tool.execute(
    "outer",
    {
      description: "Test code",
      code: `return zi.update_plan({
  explanation: "From Code Mode",
  steps: [{ text: "Verify", status: "in_progress" }]
})`
    },
    undefined
  )

  if (result.content[0]?.type !== "text") throw new Error("Expected Code Mode JSON result")
  expect(JSON.parse(result.content[0].text)).toEqual({
    revision: 1,
    explanation: "From Code Mode",
    steps: [{ text: "Verify", status: "in_progress" }]
  })
  expect(workPlan.snapshot).toEqual({
    revision: 1,
    explanation: "From Code Mode",
    steps: [{ text: "Verify", status: "in_progress" }]
  })
  expect(manager.latestWorkPlan()).toMatchObject({ type: "work_plan", revision: 1 })
})

test("code serializes guest-created calls for deterministic mutation order", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-code-mode-serial-"))
  let active = 0
  let maximumActive = 0
  const order: number[] = []
  const serialTool: AgentTool = {
    name: "serial",
    label: "serial",
    description: "Record serialized execution",
    parameters: Type.Object({ value: Type.Number() }),
    execute: async (_id, input) => {
      active++
      maximumActive = Math.max(maximumActive, active)
      await Bun.sleep(5)
      const value = typeof input === "object" && input !== null && "value" in input ? Number(input.value) : -1
      order.push(value)
      active--
      return { content: [{ type: "text", text: String(value) }], details: {} }
    }
  }
  const tool = createCodeMode(cwd).createTool([serialTool])
  const result = await tool.execute(
    "outer",
    { description: "Test code", code: `return Promise.all([1, 2, 3].map(value => zi.serial({ value })))` },
    undefined
  )

  expect(isCodeModeDetails(result.details) && result.details.outcome).toBe("success")
  expect(maximumActive).toBe(1)
  expect(order).toEqual([1, 2, 3])
})

test("code runs parallel tools in a bounded pool and preserves exclusive barriers", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-code-mode-parallel-"))
  let activeParallel = 0
  let maximumParallel = 0
  let exclusiveActive = false
  const events: string[] = []
  const parallelTool: AgentTool = {
    name: "parallel",
    label: "parallel",
    description: "Exercise parallel scheduling",
    parameters: Type.Object({ value: Type.Number() }),
    executionMode: "parallel",
    execute: async (_id, input) => {
      const value = typeof input === "object" && input !== null && "value" in input ? Number(input.value) : -1
      expect(exclusiveActive).toBe(false)
      activeParallel++
      maximumParallel = Math.max(maximumParallel, activeParallel)
      events.push(`parallel-${value}-start`)
      await Bun.sleep(20)
      events.push(`parallel-${value}-end`)
      activeParallel--
      return { content: [{ type: "text", text: String(value) }], details: {} }
    }
  }
  const exclusiveTool: AgentTool = {
    name: "exclusive",
    label: "exclusive",
    description: "Exercise an exclusive scheduling barrier",
    parameters: Type.Object({}),
    executionMode: "sequential",
    execute: async () => {
      expect(activeParallel).toBe(0)
      exclusiveActive = true
      events.push("exclusive-start")
      await Bun.sleep(10)
      events.push("exclusive-end")
      exclusiveActive = false
      return { content: [{ type: "text", text: "exclusive" }], details: {} }
    }
  }
  const tool = createCodeMode(cwd).createTool([parallelTool, exclusiveTool])
  const result = await tool.execute(
    "outer",
    {
      description: "Exercise nested scheduling",
      code: `
const first = [1, 2, 3, 4, 5, 6].map(value => zi.parallel({ value }))
const barrier = zi.exclusive({})
const last = zi.parallel({ value: 7 })
return Promise.all([...first, barrier, last])`
    },
    undefined
  )

  expect(isCodeModeDetails(result.details) && result.details.outcome).toBe("success")
  expect(maximumParallel).toBe(4)
  expect(events.indexOf("exclusive-start")).toBeGreaterThan(events.indexOf("parallel-6-end"))
  expect(events.indexOf("parallel-7-start")).toBeGreaterThan(events.indexOf("exclusive-end"))
})

test("code accepts erasable TypeScript bodies and rejects runtime-emitting and legacy wrappers", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-code-mode-typescript-"))
  const tool = createCodeMode(cwd).createTool([])
  const success = await tool.execute(
    "typed",
    {
      description: "Exercise erasable TypeScript",
      code: `type Pair = { left: number; right: number }\nconst pair: Pair = { left: 2, right: 3 }\nreturn pair.left + pair.right`
    },
    undefined
  )
  const forbidden = [
    ["enum", `enum Value { Ready }\nreturn Value.Ready`, "TypeScript enums"],
    ["namespace", `namespace Value { export const ready = true }\nreturn Value.ready`, "TypeScript namespaces"],
    [
      "parameter-property",
      `class Value { constructor(public ready: boolean) {} }\nreturn new Value(true).ready`,
      "parameter properties"
    ],
    ["import-alias", `import Value = require("value")\nreturn Value`, "import = require()"],
    ["export-assignment", `export = 1`, "export ="]
  ] as const
  const forbiddenResults = []
  for (const [name, code] of forbidden) {
    // CodeMode owns one active cell and deliberately rejects overlapping execution.
    // eslint-disable-next-line no-await-in-loop
    forbiddenResults.push(await tool.execute(name, { description: "Reject runtime TypeScript", code }, undefined))
  }
  const legacy = await tool.execute(
    "legacy",
    { description: "Reject the legacy wrapper", code: `(async () => { return 1 })` },
    undefined
  )

  expect(success.content).toEqual([{ type: "text", text: "5" }])
  for (let index = 0; index < forbidden.length; index++) {
    expect(forbiddenResults[index]?.content[0]).toEqual({
      type: "text",
      text: expect.stringContaining(forbidden[index]![2])
    })
  }
  expect(legacy.content[0]).toEqual({ type: "text", text: expect.stringContaining("async function body") })
})

test("nested failures expose a stable ZiToolError with the failed tool name", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-code-mode-tool-error-"))
  const tool = createCodeMode(cwd).createTool([echoTool])
  const result = await tool.execute(
    "outer",
    {
      description: "Inspect a nested failure",
      code: `
try {
  await zi.echo({})
} catch (error) {
  return { typed: error instanceof ZiToolError, name: error.name, toolName: error.toolName }
}`
    },
    undefined
  )

  if (result.content[0]?.type !== "text") throw new Error("Expected typed error result")
  expect(JSON.parse(result.content[0].text)).toEqual({ typed: true, name: "ZiToolError", toolName: "echo" })
})

test("code snapshots returned values without consulting guest-replaced JSON intrinsics", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-code-mode-json-intrinsics-"))
  const tool = createCodeMode(cwd).createTool([])
  const result = await tool.execute(
    "outer",
    {
      description: "Replace guest JSON intrinsics",
      code: `
JSON.stringify = () => '"spoofed"'
Object.getPrototypeOf = () => null
return { real: true }`
    },
    undefined
  )

  expect(result.content).toEqual([{ type: "text", text: '{\n  "real": true\n}' }])
})

test("code preserves nested schema failures as bounded trace evidence", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-code-mode-schema-"))
  const tool = createCodeMode(cwd).createTool([echoTool])
  const result = await tool.execute("outer", { description: "Test code", code: `return zi.echo({})` }, undefined)

  expect(isCodeModeDetails(result.details)).toBe(true)
  if (!isCodeModeDetails(result.details)) throw new Error("Expected code-mode details")
  expect(result.details.outcome).toBe("error")
  expect(result.details.calls).toHaveLength(1)
  expect(result.details.calls[0]?.state).toBe("failed")
  expect(result.content[0]).toEqual({ type: "text", text: expect.stringContaining("Nested Zi tool echo failed") })
})

test("code distinguishes cell failures from nested tool failures", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-code-mode-failure-source-"))
  const tool = createCodeMode(cwd).createTool([echoTool])
  const syntax = await tool.execute("syntax", { description: "Test code", code: `return {` }, undefined)

  expect(isCodeModeDetails(syntax.details) && syntax.details.outcome).toBe("error")
  expect(syntax.content[0]).toEqual({ type: "text", text: expect.stringContaining("Code cell failed") })

  const collision = await tool.execute(
    "collision",
    {
      description: "Test code",
      code: `
  try { await zi.echo({}); }
  catch (error) { throw new Error(error instanceof Error ? error.message : String(error)); }
`
    },
    undefined
  )
  expect(isCodeModeDetails(collision.details) && collision.details.outcome).toBe("error")
  expect(collision.content[0]).toEqual({ type: "text", text: expect.stringContaining("Code cell failed") })
})

test("code replaces a worker when cancelled nested work cannot settle", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-code-mode-nested-settlement-"))
  const blockedTool: AgentTool = {
    name: "blocked",
    label: "blocked",
    description: "Never settle",
    parameters: Type.Object({}),
    execute: () => new Promise<never>(() => {})
  }
  const tool = createCodeMode(cwd).createTool([blockedTool])
  const failed = await tool.execute(
    "blocked",
    { description: "Test code", code: ` zi.blocked({}); return "too early"; ` },
    undefined
  )

  expect(isCodeModeDetails(failed.details)).toBe(true)
  if (!isCodeModeDetails(failed.details) || failed.details.outcome !== "error") {
    throw new Error("Expected nested settlement error")
  }
  expect(failed.details.calls).toEqual([expect.objectContaining({ name: "blocked", state: "aborted" })])
  expect(failed.content[0]).toEqual({ type: "text", text: expect.stringContaining("Nested Zi tool settlement failed") })

  const recovered = await tool.execute("recovered", { description: "Test code", code: `return "ready"` }, undefined)
  expect(recovered.content).toEqual([{ type: "text", text: "ready" }])
}, 7_000)

test("code exposes a closed non-thenable guest tool catalog", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-code-mode-proxy-"))
  let calls = 0
  const countedEcho: typeof echoTool = {
    ...echoTool,
    execute: async (...arguments_) => {
      calls++
      return echoTool.execute(...arguments_)
    }
  }
  const tool = createCodeMode(cwd).createTool([countedEcho])
  const controller = new AbortController()
  const timeout = setTimeout(() => controller.abort(new Error("guest proxy remained thenable")), 2_000)
  try {
    const result = await tool.execute(
      "outer",
      {
        description: "Test code",
        code: `
  const resolved = await Promise.resolve(zi);
  return {
    same: resolved === zi,
    admitted: typeof zi.echo,
    then: typeof zi.then,
    unknown: typeof zi.notATool,
    keys: Object.keys(zi),
    frozen: Object.isFrozen(zi),
    string: String(zi)
  };
`
      },
      controller.signal
    )

    expect(result.content).toEqual([
      {
        type: "text",
        text: '{\n  "same": true,\n  "admitted": "function",\n  "then": "undefined",\n  "unknown": "undefined",\n  "keys": [\n    "echo"\n  ],\n  "frozen": true,\n  "string": "[Zi tools]"\n}'
      }
    ])
    expect(calls).toBe(0)
    expect(isCodeModeDetails(result.details) && result.details.calls).toHaveLength(0)
  } finally {
    clearTimeout(timeout)
  }
})

test("code cells have full ambient Node-compatible authority", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-code-mode-isolation-"))
  const tool = createCodeMode(cwd).createTool([echoTool])
  const result = await tool.execute(
    "outer",
    {
      description: "Test code",
      code: `return ({
  process: typeof process,
  bun: typeof Bun,
  require: typeof require,
  fetch: typeof fetch,
  bridge: typeof __ziHostCall,
  imported: typeof (await project.import("node:path")).join
})`
    },
    undefined
  )

  expect(result.content).toEqual([
    {
      type: "text",
      text: '{\n  "process": "object",\n  "bun": "object",\n  "require": "undefined",\n  "fetch": "function",\n  "bridge": "undefined",\n  "imported": "function"\n}'
    }
  ])
})

test("code formats bounded console diagnostics for JavaScript values", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-code-mode-console-"))
  const tool = createCodeMode(cwd).createTool([])
  const result = await tool.execute(
    "console",
    {
      description: "Test code",
      code: `
  const circular = { answer: 42 };
  circular.self = circular;
  const guarded = {
    get secret() { throw new Error("getter invoked"); },
    [Symbol.for("nodejs.util.inspect.custom")]() { throw new Error("custom inspect invoked"); }
  };
  const guardedError = new Error("guarded");
  Object.defineProperty(guardedError, "stack", {
    get() { throw new Error("stack getter invoked"); }
  });
  console.log(
    circular,
    7n,
    new Error("boom"),
    guarded,
    guardedError,
    new Map([["a", 1]]),
    new Set(["x", "y"]),
    new Date("2020-01-02T03:04:05.000Z"),
    /zi/gi,
    { payload: "x".repeat(100_000) }
  );
  return "done";
`
    },
    undefined
  )

  expect(result.content[0]?.type).toBe("text")
  if (result.content[0]?.type !== "text") throw new Error("Expected text diagnostics")
  expect(result.content[0].text).toContain("answer: 42")
  expect(result.content[0].text).toContain("[Circular")
  expect(result.content[0].text).toContain("7n")
  expect(result.content[0].text).toContain("Error: boom")
  expect(result.content[0].text).toContain("secret: [Getter]")
  expect(result.content[0].text).toContain("Error: guarded")
  expect(result.content[0].text).toContain("Map(1) { 'a' => 1 }")
  expect(result.content[0].text).toContain("Set(2) { 'x', 'y' }")
  expect(result.content[0].text).toContain("2020-01-02T03:04:05.000Z")
  expect(result.content[0].text).toContain("/zi/gi")
  expect(result.content[0].text).toContain("Result:\ndone")
  expect(Buffer.byteLength(result.content[0].text)).toBeLessThan(maxCodeModeLogBytes)
})

test("code preserves console diagnostics when cells and nested tools fail", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-code-mode-failure-console-"))
  const tool = createCodeMode(cwd).createTool([echoTool])

  const cellFailure = await tool.execute(
    "cell",
    {
      description: "Test code",
      code: `
  console.log({ phase: "cell" });
  for (let index = 0; index < 4; index++) console.log("x".repeat(${maxCodeModeLogBytes}));
  throw new Error("cell boom");
`
    },
    undefined
  )
  expect(cellFailure.content[0]).toEqual({
    type: "text",
    text: expect.stringContaining("Console output:\n{ phase: 'cell' }")
  })
  expect(cellFailure.content[0]).toEqual({
    type: "text",
    text: expect.stringContaining("\n\nError:\nCode cell failed: Error: cell boom")
  })

  const nestedFailure = await tool.execute(
    "nested",
    {
      description: "Test code",
      code: `
  console.warn({ phase: "nested" });
  await zi.echo({});
`
    },
    undefined
  )
  expect(nestedFailure.content[0]).toEqual({
    type: "text",
    text: expect.stringContaining("Console output:\n[warn] { phase: 'nested' }\n\nError:\nNested Zi tool echo failed:")
  })
})

test("code keeps arbitrary scratch while committing JSON state only on success", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-code-mode-memory-tiers-"))
  const tool = createCodeMode(cwd).createTool([echoTool])

  const initialized = await tool.execute(
    "initialize",
    {
      description: "Test code",
      code: `
  scratch.marker = new Map([["ready", 1]]);
  state.count = 1;
  return scratch.marker instanceof Map;
`
    },
    undefined
  )
  expect(initialized.content).toEqual([{ type: "text", text: "true" }])

  const failed = await tool.execute(
    "fail",
    {
      description: "Test code",
      code: `
  state.count = 2;
  scratch.failures = (scratch.failures ?? 0) + 1;
  throw new Error("rollback");
`
    },
    undefined
  )
  expect(isCodeModeDetails(failed.details) && failed.details.outcome).toBe("error")

  const observed = await tool.execute(
    "observe",
    {
      description: "Test code",
      code: `return ({
  count: state.count,
  marker: scratch.marker instanceof Map && scratch.marker.get("ready"),
  failures: scratch.failures
})`
    },
    undefined
  )
  expect(observed.content).toEqual([{ type: "text", text: '{\n  "count": 1,\n  "marker": 1,\n  "failures": 1\n}' }])
})

test("code restores committed state for a replacement runtime", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-code-mode-resume-"))
  const sessionManager = SessionManager.create(new ZiPaths(cwd, join(cwd, "agent")))
  const first = new CodeMode(cwd, workerCommand, sessionManager)
  codeModes.add(first)
  const firstTool = first.createTool([echoTool])
  await firstTool.execute(
    "commit",
    { description: "Test code", code: ` state.answer = 42; scratch.onlyHere = true; ` },
    undefined
  )
  await first.dispose()
  codeModes.delete(first)

  if (!sessionManager.file) throw new Error("Expected durable session file")
  const restoredSession = SessionManager.open(sessionManager.file)
  const replacement = new CodeMode(cwd, workerCommand, restoredSession)
  codeModes.add(replacement)
  const result = await replacement
    .createTool([echoTool])
    .execute(
      "restore",
      { description: "Test code", code: `return ({ answer: state.answer, scratch: scratch.onlyHere ?? null })` },
      undefined
    )

  expect(result.content).toEqual([{ type: "text", text: '{\n  "answer": 42,\n  "scratch": null\n}' }])
})

test("code rejects invalid state commits, rolls back state, and remains reusable", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-code-mode-invalid-state-"))
  const tool = createCodeMode(cwd).createTool([echoTool])
  await tool.execute("commit", { description: "Test code", code: ` state.value = "committed"; ` }, undefined)

  const cyclic = await tool.execute(
    "cyclic",
    { description: "Test code", code: ` state.value = "lost"; state.loop = state; scratch.failure = "preserved"; ` },
    undefined
  )
  expect(isCodeModeDetails(cyclic.details) && cyclic.details.outcome).toBe("error")

  const oversized = await tool.execute(
    "oversized",
    { description: "Test code", code: ` state.payload = "x".repeat(${maxCodeModeStateBytes}); ` },
    undefined
  )
  expect(isCodeModeDetails(oversized.details) && oversized.details.outcome).toBe("error")

  const recovered = await tool.execute(
    "recovered",
    {
      description: "Test code",
      code: `return ({ value: state.value, payload: state.payload ?? null, scratch: scratch.failure })`
    },
    undefined
  )
  expect(recovered.content).toEqual([
    { type: "text", text: '{\n  "value": "committed",\n  "payload": null,\n  "scratch": "preserved"\n}' }
  ])
})

test("persistent runtime admits a fresh immutable tool catalog for each cell", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-code-mode-catalog-snapshot-"))
  const codeMode = createCodeMode(cwd)
  const first = codeMode.createTool([echoTool])
  await first.execute(
    "first",
    { description: "Test code", code: ` state.shared = 1; scratch.shared = new Set(["ready"]); ` },
    undefined
  )

  const renamed: typeof echoTool = { ...echoTool, name: "renamed" }
  const second = codeMode.createTool([renamed])
  const result = await second.execute(
    "second",
    {
      description: "Test code",
      code: `return ({
  old: typeof zi.echo,
  current: typeof zi.renamed,
  state: state.shared,
  scratch: scratch.shared.has("ready")
})`
    },
    undefined
  )
  expect(result.content).toEqual([
    { type: "text", text: '{\n  "old": "undefined",\n  "current": "function",\n  "state": 1,\n  "scratch": true\n}' }
  ])
})

test("code mode releases its tracked worker process tree on disposal", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-code-mode-process-tree-"))
  let trackedPid = 0
  let terminations = 0
  const tracker: ProcessTreeTracker = {
    track(pid): ProcessScope {
      trackedPid = pid
      return {
        platform: "posix",
        workerPid: pid,
        admitted: Promise.resolve(),
        snapshot: () => ({ workerPid: pid, identities: [] }),
        refresh: async () => ({ type: "ok" }),
        terminate: async () => {
          terminations++
          return { type: "terminated", signaledGroups: 1 }
        },
        dispose: async () => {}
      }
    },
    dispose: async () => {}
  }
  const codeMode = new CodeMode(cwd, workerCommand, undefined, tracker)
  codeModes.add(codeMode)
  const result = await codeMode
    .createTool([echoTool])
    .execute("tracked", { description: "Test code", code: `return "ready"` }, undefined)
  expect(result.content).toEqual([{ type: "text", text: "ready" }])
  expect(trackedPid).toBeGreaterThan(0)

  await codeMode.dispose()
  codeModes.delete(codeMode)
  expect(terminations).toBe(1)
})

test("disposing code mode kills a long-lived subprocess created by a cell", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-code-mode-descendant-"))
  const tracker = createProcessTreeTracker()
  const codeMode = new CodeMode(cwd, workerCommand, undefined, tracker)
  codeModes.add(codeMode)
  let pid = 0
  try {
    const result = await codeMode.createTool([]).execute(
      "spawn",
      {
        description: "Test code",
        code: `
  const child = Bun.spawn([process.execPath, "-e", "setInterval(() => {}, 1000)"], {
    stdout: "ignore",
    stderr: "ignore"
  });
  child.unref();
  return child.pid;
`
      },
      undefined
    )
    pid = Number(result.content[0]?.type === "text" ? result.content[0].text : "")
    expect(Number.isInteger(pid) && pid > 0).toBe(true)
    expect(processExists(pid)).toBe(true)

    await codeMode.dispose()
    codeModes.delete(codeMode)
    expect(processExists(pid)).toBe(false)
  } finally {
    await codeMode.dispose().catch(() => undefined)
    codeModes.delete(codeMode)
    await tracker.dispose()
    if (pid > 0 && processExists(pid)) process.kill(pid, "SIGKILL")
  }
})

test("disposing code mode during blocked worker admission releases the process scope", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-code-mode-startup-dispose-"))
  let terminations = 0
  let rejectAdmission!: (cause: unknown) => void
  const admitted = new Promise<void>((_, reject) => {
    rejectAdmission = reject
  })
  void admitted.catch(() => {})
  const tracker: ProcessTreeTracker = {
    track(pid): ProcessScope {
      return {
        platform: "posix",
        workerPid: pid,
        admitted,
        snapshot: () => ({ workerPid: pid, identities: [] }),
        refresh: async () => ({ type: "ok" }),
        terminate: async () => {
          terminations++
          rejectAdmission(new Error("admission interrupted by disposal"))
          return { type: "terminated", signaledGroups: 1 }
        },
        dispose: async () => {}
      }
    },
    dispose: async () => {}
  }
  const codeMode = new CodeMode(cwd, workerCommand, undefined, tracker)
  codeModes.add(codeMode)
  const execution = codeMode
    .createTool([echoTool])
    .execute("starting", { description: "Test code", code: `return "ready"` }, undefined)
  const settledExecution = execution.catch(cause => cause)
  await Bun.sleep(0)

  await codeMode.dispose()
  codeModes.delete(codeMode)
  const result = await settledExecution
  if (result instanceof Error) throw result
  expect(isCodeModeDetails(result.details) && result.details.outcome).toBe("error")
  expect(terminations).toBe(1)
})

test("code enforces its nested call bound", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-code-mode-call-bound-"))
  const tool = createCodeMode(cwd).createTool([echoTool])
  const result = await tool.execute(
    "outer",
    {
      description: "Test code",
      code: ` for (let index = 0; index < 65; index++) await zi.echo({ value: String(index) }); `
    },
    undefined
  )

  expect(isCodeModeDetails(result.details)).toBe(true)
  if (!isCodeModeDetails(result.details)) throw new Error("Expected code-mode details")
  if (result.details.outcome !== "error") throw new Error("Expected code-mode error")
  expect(result.details.version).toBe(1)
  expect(result.details.calls).toHaveLength(64)
  expect(result.content[0]).toEqual({ type: "text", text: expect.stringContaining("64 tool calls") })
  expect(Buffer.byteLength(JSON.stringify(result.details))).toBeLessThanOrEqual(maxCodeModeTerminalDetailsBytes)
})

test("code applies one aggregate serialized budget to console logs and the terminal result", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-code-mode-output-bound-"))
  const tool = createCodeMode(cwd).createTool([])
  const result = await tool.execute(
    "outer",
    {
      description: "Exceed aggregate output accounting",
      code: `for (let index = 0; index < 32; index++) console.log("x".repeat(${maxCodeModeLogBytes})); return "done"`
    },
    undefined
  )

  expect(isCodeModeDetails(result.details) && result.details.outcome).toBe("error")
  expect(result.content[0]).toEqual({
    type: "text",
    text: expect.stringContaining(`Code-mode output exceeded ${maxCodeModeOutputBytes} bytes`)
  })
})

test("code terminal traces enforce their aggregate serialized bound", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-code-mode-trace-bound-"))
  const readTool: AgentTool = {
    name: "read",
    label: "read",
    description: "Read a path",
    parameters: Type.Object({ path: Type.String() }),
    execute: async () => ({ content: [{ type: "text", text: "read" }], details: {} })
  }
  const result = await createCodeMode(cwd)
    .createTool([readTool])
    .execute(
      "outer",
      {
        description: "Test code",
        code: `
  const path = "\\u0000".repeat(4096);
  for (let index = 0; index < 64; index++) await zi.read({ path });
`
      },
      undefined
    )

  expect(isCodeModeDetails(result.details)).toBe(true)
  if (!isCodeModeDetails(result.details) || result.details.version !== 1) {
    throw new Error("Expected bounded versioned code-mode details")
  }
  expect(result.details.calls).toHaveLength(64)
  expect(result.details.calls.some(call => JSON.stringify(call.arguments) === "{}")).toBe(true)
  expect(Buffer.byteLength(JSON.stringify(result.details))).toBeLessThanOrEqual(maxCodeModeTerminalDetailsBytes)
})

test("code guest can catch built-in expected errors and uncaught failures settle the outer tool", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-code-mode-expected-error-"))
  const tool = createCodeMode(cwd).createTool([createReadTool(cwd)])
  const caught = await tool.execute(
    "caught",
    {
      description: "Test code",
      code: `
  try { await zi.read({ path: "missing.txt" }); }
  catch (error) { return String(error).includes("missing.txt"); }
`
    },
    undefined
  )
  expect(caught.content).toEqual([{ type: "text", text: "true" }])
  expect(isCodeModeDetails(caught.details) && caught.details.calls[0]?.state).toBe("failed")

  const uncaught = await tool.execute(
    "uncaught",
    { description: "Test code", code: `return zi.read({ path: "missing.txt" })` },
    undefined
  )
  expect(isCodeModeDetails(uncaught.details)).toBe(true)
  if (!isCodeModeDetails(uncaught.details) || uncaught.details.outcome !== "error") {
    throw new Error("Expected uncaught nested failure")
  }
  expect(uncaught.details.calls[0]?.state).toBe("failed")
  expect(uncaught.content[0]).toEqual({ type: "text", text: expect.stringContaining("Nested Zi tool read failed") })
})

test("code durable failed calls retain only their fixed failure stage", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-code-mode-failure-trace-"))
  const secret = "raw-failure-secret"
  const parameters = Type.Object({ token: Type.String() })
  const prepareFailure: AgentTool = {
    name: "prepare_failure",
    label: "prepare failure",
    description: "Fail while preparing arguments",
    parameters,
    prepareArguments: () => {
      throw new Error(`prepare:${secret}`)
    },
    execute: async () => {
      throw new Error("unreachable")
    }
  }
  const validateFailure: AgentTool = {
    name: "validate_failure",
    label: "validate failure",
    description: "Fail while validating arguments",
    parameters,
    execute: async () => {
      throw new Error("unreachable")
    }
  }
  const invokeFailure: AgentTool = {
    name: "invoke_failure",
    label: "invoke failure",
    description: "Fail while invoking the tool",
    parameters,
    execute: async () => {
      throw new Error(`invoke:${secret}`)
    }
  }
  const tool = createCodeMode(cwd).createTool([prepareFailure, validateFailure, invokeFailure])
  const result = await tool.execute(
    "outer",
    {
      description: "Test code",
      code: `
  for (const call of [
    () => zi.prepare_failure({ token: "${secret}" }),
    () => zi.validate_failure({}),
    () => zi.invoke_failure({ token: "${secret}" })
  ]) {
    try { await call(); } catch {}
  }
  return "caught";
`
    },
    undefined
  )

  expect(isCodeModeDetails(result.details)).toBe(true)
  if (!isCodeModeDetails(result.details)) throw new Error("Expected code-mode details")
  expect(result.details.outcome).toBe("success")
  expect(result.details.calls).toEqual([
    expect.objectContaining({ state: "failed", name: "prepare_failure", arguments: {}, stage: "prepare" }),
    expect.objectContaining({ state: "failed", name: "validate_failure", arguments: {}, stage: "validate" }),
    expect.objectContaining({ state: "failed", name: "invoke_failure", arguments: {}, stage: "invoke" })
  ])
  expect(result.details.calls.every(call => !("error" in call))).toBe(true)
  expect(JSON.stringify(result.details)).not.toContain(secret)

  const uncaught = await tool.execute(
    "uncaught",
    { description: "Test code", code: `return zi.invoke_failure({ token: "${secret}" })` },
    undefined
  )
  expect(isCodeModeDetails(uncaught.details)).toBe(true)
  if (!isCodeModeDetails(uncaught.details) || uncaught.details.outcome !== "error") {
    throw new Error("Expected uncaught code-mode failure")
  }
  expect(uncaught.details.error).toBe("Nested Zi tool invoke_failure failed")
  expect(JSON.stringify(uncaught.details)).not.toContain(secret)
  expect(uncaught.content[0]).toEqual({ type: "text", text: expect.stringContaining(secret) })
})

test("code durable traces omit arbitrary arguments and successful intermediate results", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-code-mode-private-trace-"))
  const secret = "extension-secret-value"
  const hugePreview = `live-preview:${secret}:${"x".repeat(100_000)}`
  const updates: { readonly details?: unknown }[] = []
  const privateTool: AgentTool = {
    name: "extension.private",
    label: "private",
    description: "Exercise private trace values",
    parameters: Type.Object({ token: Type.String() }),
    execute: async (_id, _input, _signal, onUpdate) => {
      onUpdate?.({ content: [{ type: "text", text: hugePreview }], details: { secret } })
      return { content: [{ type: "text", text: `successful-result:${secret}` }], details: { secret } }
    }
  }
  const result = await createCodeMode(cwd)
    .createTool([privateTool])
    .execute(
      "outer",
      { description: "Test code", code: ` await zi["extension.private"]({ token: "${secret}" }); return "done"; ` },
      undefined,
      update => updates.push(update)
    )

  expect(isCodeModeDetails(result.details)).toBe(true)
  if (!isCodeModeDetails(result.details)) throw new Error("Expected code-mode details")
  expect(result.details.outcome).toBe("success")
  expect(result.details.calls).toEqual([expect.objectContaining({ state: "succeeded", name: "extension.private" })])
  expect(JSON.stringify(result.details)).not.toContain(secret)

  const liveCall = updates
    .flatMap(update =>
      isCodeModeDetails(update.details) && update.details.version === 1 && update.details.outcome === "progress"
        ? update.details.calls
        : []
    )
    .find(call => call.state === "running" && call.preview?.startsWith(`live-preview:${secret}`))
  expect(liveCall?.state).toBe("running")
  if (!liveCall || liveCall.state !== "running") throw new Error("Expected live nested-tool preview")
  expect(liveCall.preview?.length).toBeLessThan(hugePreview.length)
})

test("code durable traces retain safe built-in file metadata without payloads", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-code-mode-trace-redaction-"))
  const writeTool: AgentTool = {
    name: "write",
    label: "write",
    description: "Write content",
    parameters: Type.Object({ path: Type.String(), content: Type.String() }),
    execute: async () => ({ content: [{ type: "text", text: "Wrote secret.txt" }], details: { outcome: "success" } })
  }
  const editTool: AgentTool = {
    name: "edit",
    label: "edit",
    description: "Edit content",
    parameters: Type.Object({
      path: Type.String(),
      edits: Type.Array(Type.Object({ oldText: Type.String(), newText: Type.String() }))
    }),
    execute: async () => ({ content: [{ type: "text", text: "Edited secret.txt" }], details: { outcome: "success" } })
  }
  const tool = createCodeMode(cwd).createTool([writeTool, editTool])
  const result = await tool.execute(
    "outer",
    {
      description: "Test code",
      code: `
  await zi.write({ path: "secret.txt", content: "write-secret-payload" });
  await zi.edit({ path: "secret.txt", edits: [{ oldText: "old-secret", newText: "new-secret" }] });
`
    },
    undefined
  )

  expect(isCodeModeDetails(result.details)).toBe(true)
  if (!isCodeModeDetails(result.details)) throw new Error("Expected code-mode details")
  expect(result.details.calls.map(call => call.arguments)).toEqual([
    { path: "secret.txt", contentBytes: 20 },
    { path: "secret.txt", operations: 1 }
  ])
  expect(JSON.stringify(result.details)).not.toContain("secret-payload")
  expect(JSON.stringify(result.details)).not.toContain("old-secret")
  expect(JSON.stringify(result.details)).not.toContain("new-secret")
})

test("code supports punctuation in extension tool names", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-code-mode-tool-name-"))
  const namedTool: typeof echoTool = { ...echoTool, name: "api.search-v2" }
  const tool = createCodeMode(cwd).createTool([namedTool])
  const result = await tool.execute(
    "outer",
    { description: "Test code", code: `return zi["api.search-v2"]({ value: "found" })` },
    undefined
  )

  expect(result.content).toEqual([{ type: "text", text: "found" }])
})

test("code propagates nested turn termination and rejects later calls", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-code-mode-terminate-"))
  const stopTool: AgentTool = {
    name: "stop",
    label: "stop",
    description: "Terminate the current turn",
    parameters: Type.Object({}),
    execute: async () => ({ content: [{ type: "text", text: "stopped" }], details: {}, terminate: true })
  }
  const tool = createCodeMode(cwd).createTool([stopTool, echoTool])
  const result = await tool.execute(
    "outer",
    { description: "Test code", code: ` await zi.stop({}); return zi.echo({ value: "too late" }); ` },
    undefined
  )

  expect(result.terminate).toBe(true)
  expect(isCodeModeDetails(result.details)).toBe(true)
  if (!isCodeModeDetails(result.details) || result.details.outcome !== "error") {
    throw new Error("Expected terminating code-mode error")
  }
  expect(result.content[0]).toEqual({ type: "text", text: expect.stringContaining("turn termination") })
  expect(result.details.calls.map(call => call.name)).toEqual(["stop"])
})

test("cancelling code aborts its active nested tool and worker", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-code-mode-cancel-"))
  let started!: () => void
  const active = new Promise<void>(resolve => {
    started = resolve
  })
  let nestedAborted = false
  const waitingTool: AgentTool = {
    name: "wait",
    label: "wait",
    description: "Wait for cancellation",
    parameters: Type.Object({}),
    execute: async (_id, _input, signal) => {
      started()
      await new Promise<never>((_, reject) =>
        signal?.addEventListener(
          "abort",
          () => {
            nestedAborted = true
            reject(signal.reason)
          },
          { once: true }
        )
      )
      throw new Error("Unreachable waiting tool completion")
    }
  }
  const tool = createCodeMode(cwd).createTool([waitingTool])
  const controller = new AbortController()
  const execution = tool.execute("outer", { description: "Test code", code: `return zi.wait({})` }, controller.signal)
  await active
  controller.abort(new Error("cancelled by test"))

  expect(await rejectionMessage(execution)).toContain("cancelled by test")
  expect(nestedAborted).toBe(true)
})

test("late nested completion cannot cross a cancelled worker generation", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-code-mode-stale-completion-"))
  let markStarted!: () => void
  const started = new Promise<void>(resolve => {
    markStarted = resolve
  })
  let release!: () => void
  const late = new Promise<void>(resolve => {
    release = resolve
  })
  const updates: string[] = []
  const holdTool: AgentTool = {
    name: "hold",
    label: "hold",
    description: "Ignore cancellation until released",
    parameters: Type.Object({}),
    execute: async (_id, _input, _signal, onUpdate) => {
      markStarted()
      await late
      onUpdate?.({ content: [{ type: "text", text: "stale-preview-secret" }], details: {} })
      return { content: [{ type: "text", text: "late" }], details: {} }
    }
  }
  const tool = createCodeMode(cwd).createTool([holdTool])
  const controller = new AbortController()
  const cancelled = tool.execute(
    "cancelled",
    {
      description: "Test code",
      code: `
  state.generation = "cancelled";
  scratch.generation = "cancelled";
  await zi.hold({});
`
    },
    controller.signal,
    update => updates.push(JSON.stringify(update.details))
  )
  await started
  controller.abort(new Error("replace generation"))
  expect(await rejectionMessage(cancelled)).toContain("replace generation")

  const recovered = await tool.execute(
    "recovered",
    {
      description: "Test code",
      code: `
  state.generation = "current";
  scratch.generation = "current";
  return { state: state.generation, scratch: scratch.generation };
`
    },
    undefined
  )
  release()
  await Bun.sleep(10)
  expect(updates.join("\n")).not.toContain("stale-preview-secret")
  expect(recovered.content).toEqual([{ type: "text", text: '{\n  "state": "current",\n  "scratch": "current"\n}' }])
  const observed = await tool.execute(
    "observed",
    { description: "Test code", code: `return ({ state: state.generation, scratch: scratch.generation })` },
    undefined
  )
  expect(observed.content).toEqual(recovered.content)
}, 7_000)

test("cancelling code terminates a guest that cannot yield to protocol input", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-code-mode-hard-cancel-"))
  const tool = createCodeMode(cwd).createTool([echoTool])
  await tool.execute("warmup", { description: "Test code", code: `return "ready"` }, undefined)
  const controller = new AbortController()
  const execution = tool.execute("outer", { description: "Test code", code: ` while (true) {} ` }, controller.signal)
  await Bun.sleep(50)
  controller.abort(new Error("hard cancellation"))

  expect(await rejectionMessage(execution)).toContain("hard cancellation")
})

test("code rejects unawaited nested calls and cancels their admitted work", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-code-mode-unawaited-"))
  let executions = 0
  const mutatingTool: AgentTool = {
    name: "mutate",
    label: "mutate",
    description: "Record a mutation",
    parameters: Type.Object({ value: Type.Number() }),
    execute: async () => {
      executions++
      return { content: [{ type: "text", text: "mutated" }], details: {} }
    }
  }
  const tool = createCodeMode(cwd).createTool([mutatingTool])
  const result = await tool.execute(
    "outer",
    { description: "Test code", code: ` zi.mutate({ value: 1 }); zi.mutate({ value: 2 }); return "early"; ` },
    undefined
  )

  expect(isCodeModeDetails(result.details)).toBe(true)
  if (!isCodeModeDetails(result.details)) throw new Error("Expected code-mode details")
  if (result.details.outcome !== "error") throw new Error("Expected code-mode error")
  expect(result.content[0]).toEqual({ type: "text", text: expect.stringContaining("unawaited") })
  expect(executions).toBeLessThanOrEqual(2)
  expect(result.details.calls.every(call => call.state !== "running")).toBe(true)
})

test("code contains guest memory exhaustion and aborts active nested work", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-code-mode-memory-"))
  const waitingTool: AgentTool = {
    name: "wait",
    label: "wait",
    description: "Wait for cancellation",
    parameters: Type.Object({}),
    execute: async (_id, _input, signal) => {
      await new Promise<never>((_, reject) => {
        const abort = (): void => reject(signal?.reason ?? new Error("nested work aborted"))
        if (signal?.aborted) abort()
        else signal?.addEventListener("abort", abort, { once: true })
      })
      throw new Error("Unreachable nested completion")
    }
  }
  const tool = createCodeMode(cwd).createTool([waitingTool])
  const result = await tool.execute(
    "outer",
    {
      description: "Test code",
      code: `
  zi.wait({});
  const values = new Array(100_000_000).fill(1);
`
    },
    undefined
  )

  expect(isCodeModeDetails(result.details)).toBe(true)
  if (!isCodeModeDetails(result.details) || result.details.outcome !== "error") {
    throw new Error("Expected code-mode memory error")
  }
  expect(result.details.error).toBe("Code runtime failed")
  expect(result.details.calls.every(call => call.state !== "running")).toBe(true)
  expect(result.content[0]).toEqual({ type: "text", text: expect.stringContaining("Code runtime failed") })
  expect(result.content[0]).toEqual({
    type: "text",
    text: expect.stringContaining(
      "The programmatic worker was replaced. Volatile scratch was cleared; committed state was preserved."
    )
  })

  const recovered = await tool.execute("recovered", { description: "Test code", code: `return "ready"` }, undefined)
  expect(recovered.content).toEqual([{ type: "text", text: "ready" }])
})

test("code enforces compute independently from the wall-clock deadline", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-code-mode-compute-"))
  const codeMode = new CodeMode(cwd, computeWorkerCommand)
  codeModes.add(codeMode)
  const tool = codeMode.createTool([])
  const exhausted = await tool.execute(
    "compute",
    { description: "Exhaust the compute budget", code: `while (true) {}` },
    undefined
  )

  expect(isCodeModeDetails(exhausted.details) && exhausted.details.outcome).toBe("error")
  expect(exhausted.content[0]).toEqual({ type: "text", text: expect.stringContaining("compute budget exhausted") })
  const recovered = await tool.execute(
    "recovered",
    { description: "Verify compute-budget recovery", code: `return "ready"` },
    undefined
  )
  expect(recovered.content).toEqual([{ type: "text", text: "ready" }])
})

test("code restarts cleanly after interrupting an infinite cell", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-code-mode-loop-"))
  const tool = createCodeMode(cwd).createTool([echoTool])
  await tool.execute(
    "warmup",
    { description: "Test code", code: ` state.saved = 7; scratch.volatile = "old worker"; ` },
    undefined
  )
  const controller = new AbortController()
  const blocked = tool.execute("blocked", { description: "Test code", code: ` while (true) {} ` }, controller.signal)
  await Bun.sleep(50)
  controller.abort(new Error("interrupt infinite cell"))

  expect(await rejectionMessage(blocked)).toContain("interrupt infinite cell")
  const recovered = await tool.execute(
    "recovered",
    { description: "Test code", code: `return ({ saved: state.saved, scratch: scratch.volatile ?? null })` },
    undefined
  )
  expect(recovered.content).toEqual([{ type: "text", text: '{\n  "saved": 7,\n  "scratch": null\n}' }])
})
