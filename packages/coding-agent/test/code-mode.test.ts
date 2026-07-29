import { expect, test } from "bun:test"
import { mkdtemp } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { fileURLToPath } from "node:url"

import type { AgentTool } from "@earendil-works/pi-agent-core"
import { Type } from "@earendil-works/pi-ai"

import { CodeMode, isCodeModeDetails } from "../src/code-mode/code-mode.js"
import { createModels, createTestAgentRuntime, fauxAssistantMessage, fauxProvider } from "../src/testing.js"

const workerCommand = Object.freeze([
  process.execPath,
  fileURLToPath(new URL("../src/code-mode/worker-entry.ts", import.meta.url))
])

const echoParameters = Type.Object({ value: Type.String() })

const echoTool: AgentTool<typeof echoParameters, { readonly echoed: string }> = {
  name: "echo",
  label: "echo",
  description: "Echo a value",
  parameters: echoParameters,
  execute: async (_id, input) => ({ content: [{ type: "text", text: input.value }], details: { echoed: input.value } })
}

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
    expect(catalog).toEqual(["read", "bash", "edit", "write", "task_output", "kill_task", "code"])
  } finally {
    runtime.session.dispose()
  }
})

test("code executes serial nested calls in an isolated worker", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-code-mode-execute-"))
  const tool = new CodeMode(cwd, workerCommand).createTool([echoTool])
  const result = await tool.execute(
    "outer",
    {
      code: `async () => {
  const output = [];
  for (const value of ["a", "b", "c"]) output.push((await zi.echo({ value })).text);
  return output.join(",");
}`
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
  const tool = new CodeMode(cwd, workerCommand).createTool([serialTool])
  const result = await tool.execute(
    "outer",
    { code: `async () => Promise.all([1, 2, 3].map(value => zi.serial({ value })))` },
    undefined
  )

  expect(isCodeModeDetails(result.details) && result.details.outcome).toBe("success")
  expect(maximumActive).toBe(1)
  expect(order).toEqual([1, 2, 3])
})

test("code preserves nested schema failures as bounded trace evidence", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-code-mode-schema-"))
  const tool = new CodeMode(cwd, workerCommand).createTool([echoTool])
  const result = await tool.execute("outer", { code: `async () => zi.echo({})` }, undefined)

  expect(isCodeModeDetails(result.details)).toBe(true)
  if (!isCodeModeDetails(result.details)) throw new Error("Expected code-mode details")
  expect(result.details.outcome).toBe("error")
  expect(result.details.calls).toHaveLength(1)
  expect(result.details.calls[0]?.state).toBe("failed")
  expect(result.content[0]).toMatchObject({ type: "text" })
})

test("code guest has no ambient process, filesystem, module, credential, or network authority", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-code-mode-isolation-"))
  const tool = new CodeMode(cwd, workerCommand).createTool([echoTool])
  const result = await tool.execute(
    "outer",
    {
      code: `async () => ({
  process: typeof process,
  bun: typeof Bun,
  require: typeof require,
  fetch: typeof fetch,
  bridge: typeof __ziHostCall
})`
    },
    undefined
  )

  expect(result.content).toEqual([
    {
      type: "text",
      text: '{\n  "process": "undefined",\n  "bun": "undefined",\n  "require": "undefined",\n  "fetch": "undefined",\n  "bridge": "undefined"\n}'
    }
  ])
})

test("code enforces its nested call bound", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-code-mode-call-bound-"))
  const tool = new CodeMode(cwd, workerCommand).createTool([echoTool])
  const result = await tool.execute(
    "outer",
    { code: `async () => { for (let index = 0; index < 65; index++) await zi.echo({ value: String(index) }); }` },
    undefined
  )

  expect(isCodeModeDetails(result.details)).toBe(true)
  if (!isCodeModeDetails(result.details)) throw new Error("Expected code-mode details")
  if (result.details.outcome !== "error") throw new Error("Expected code-mode error")
  expect(result.details.calls).toHaveLength(64)
  expect(result.details.error).toContain("64 tool calls")
})

test("code supports punctuation in extension tool names", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-code-mode-tool-name-"))
  const namedTool: typeof echoTool = { ...echoTool, name: "api.search-v2" }
  const tool = new CodeMode(cwd, workerCommand).createTool([namedTool])
  const result = await tool.execute(
    "outer",
    { code: `async () => (await zi["api.search-v2"]({ value: "found" })).text` },
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
  const tool = new CodeMode(cwd, workerCommand).createTool([stopTool, echoTool])
  const result = await tool.execute(
    "outer",
    { code: `async () => { await zi.stop({}); return zi.echo({ value: "too late" }); }` },
    undefined
  )

  expect(result.terminate).toBe(true)
  expect(isCodeModeDetails(result.details)).toBe(true)
  if (!isCodeModeDetails(result.details) || result.details.outcome !== "error") {
    throw new Error("Expected terminating code-mode error")
  }
  expect(result.details.error).toContain("turn termination")
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
  const tool = new CodeMode(cwd, workerCommand).createTool([waitingTool])
  const controller = new AbortController()
  const execution = tool.execute("outer", { code: `async () => zi.wait({})` }, controller.signal)
  await active
  controller.abort(new Error("cancelled by test"))

  expect(execution).rejects.toThrow("cancelled by test")
  expect(nestedAborted).toBe(true)
})

test("cancelling code terminates a guest that cannot yield to protocol input", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-code-mode-hard-cancel-"))
  const tool = new CodeMode(cwd, workerCommand).createTool([echoTool])
  const controller = new AbortController()
  const execution = tool.execute("outer", { code: `async () => { while (true) {} }` }, controller.signal)
  await Bun.sleep(50)
  controller.abort(new Error("hard cancellation"))

  expect(execution).rejects.toThrow("hard cancellation")
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
  const tool = new CodeMode(cwd, workerCommand).createTool([mutatingTool])
  const result = await tool.execute(
    "outer",
    { code: `async () => { zi.mutate({ value: 1 }); zi.mutate({ value: 2 }); return "early"; }` },
    undefined
  )

  expect(isCodeModeDetails(result.details)).toBe(true)
  if (!isCodeModeDetails(result.details)) throw new Error("Expected code-mode details")
  if (result.details.outcome !== "error") throw new Error("Expected code-mode error")
  expect(result.details.error).toContain("unawaited")
  expect(executions).toBeLessThanOrEqual(2)
  expect(result.details.calls.every(call => call.state !== "running")).toBe(true)
})

test("code contains guest memory exhaustion in its worker", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-code-mode-memory-"))
  const tool = new CodeMode(cwd, workerCommand).createTool([echoTool])
  const result = await tool.execute(
    "outer",
    {
      code: `async () => {
  const values = new Array(100_000_000).fill(1);
}`
    },
    undefined
  )

  expect(isCodeModeDetails(result.details)).toBe(true)
  if (!isCodeModeDetails(result.details) || result.details.outcome !== "error") {
    throw new Error("Expected code-mode memory error")
  }
  expect(result.details.error.toLowerCase()).toContain("memory")
})

test("code interrupts an infinite guest loop", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-code-mode-loop-"))
  const tool = new CodeMode(cwd, workerCommand).createTool([echoTool])
  const result = await tool.execute("outer", { code: `async () => { while (true) {} }` }, undefined)

  expect(isCodeModeDetails(result.details)).toBe(true)
  if (!isCodeModeDetails(result.details)) throw new Error("Expected code-mode details")
  if (result.details.outcome !== "error") throw new Error("Expected code-mode error")
  expect(result.details.error.length).toBeGreaterThan(0)
})
