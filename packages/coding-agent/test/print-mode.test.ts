import { expect, test } from "bun:test"

import { Type } from "@earendil-works/pi-ai"

import {
  maxPendingJsonlRecords,
  maxPrintOutputBytes,
  maxPrintOutputChunks,
  maxPrintPromptBytes,
  maxPrintPromptCount,
  runPrintMode
} from "../src/print-mode.js"
import { createAgentSession } from "../src/services.js"
import { SessionManager } from "../src/session-manager.js"
import {
  createModels,
  createTestAgentRuntime as createAgentRuntime,
  fauxAssistantMessage,
  fauxProvider,
  fauxText,
  fauxThinking,
  fauxToolCall
} from "../src/testing.js"

/* oxlint-disable no-await-in-loop */

test("JSON print mode emits the session header then source-ordered events", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  faux.setResponses([fauxAssistantMessage("hello")])
  const { session } = await createAgentRuntime({ cwd: "/work", models, persist: false })
  const sourceEvents: string[] = []
  const chunks: string[] = []
  const unsubscribe = session.subscribe(event => sourceEvents.push(event.type))

  try {
    const result = await runPrintMode(session, {
      output: "json",
      prompts: ["start"],
      writer: {
        write(chunk) {
          chunks.push(chunk)
        }
      }
    })

    expect(result).toEqual({ type: "success" })
    expect(chunks.every(chunk => chunk.endsWith("\n") && !chunk.slice(0, -1).includes("\n"))).toBe(true)
    const records = chunks.map(parseJson)
    expect(records[0]).toEqual(session.sessionManager.header)
    expect(records.slice(1).map(recordType)).toEqual(sourceEvents)
    const completedChunks = chunks.length
    session.setSteeringMode("all", "global")
    expect(chunks).toHaveLength(completedChunks)
  } finally {
    unsubscribe()
    session.dispose()
  }
})

test("JSON mode preserves automatic compaction start, durable entry, and end ordering", async () => {
  const models = createModels()
  const faux = fauxProvider({ models: [{ id: "small", contextWindow: 500, maxTokens: 100 }] })
  models.setProvider(faux.provider)
  faux.setResponses([
    fauxAssistantMessage("final answer"),
    ...Array.from({ length: 8 }, () => fauxAssistantMessage("z"))
  ])
  const { session } = await createAgentRuntime({
    cwd: "/work",
    model: `${faux.provider.id}/small`,
    models,
    persist: false,
    settings: { compactionReserveTokens: 100, compactionKeepRecentTokens: 1 }
  })
  const chunks: string[] = []

  try {
    const result = await runPrintMode(session, {
      output: "json",
      prompts: ["x".repeat(2_000)],
      writer: {
        write(chunk) {
          chunks.push(chunk)
        }
      }
    })
    expect(result).toEqual({ type: "success" })
    const records = chunks.map(parseJson)
    const start = records.findIndex(record => recordType(record) === "compaction_start")
    const entry = records.findIndex(record => recordType(record) === "entry_appended" && isCompactionEntryEvent(record))
    const end = records.findIndex(record => recordType(record) === "compaction_end")
    expect(start).toBeGreaterThan(0)
    expect(entry).toBeGreaterThan(start)
    expect(end).toBeGreaterThan(entry)
  } finally {
    session.dispose()
  }
})

test("JSON mode closes failed and cancelled automatic compactions without a marker", async () => {
  for (const outcome of ["failed", "cancelled"] as const) {
    const { session, faux } = await compactionPrintSession()
    if (outcome === "failed") faux.setResponses([fauxAssistantMessage("   "), fauxAssistantMessage("continued")])
    else {
      session.subscribe(event => {
        if (event.type === "compaction_start") void session.abort()
      })
    }
    const chunks: string[] = []

    try {
      const result = await runPrintMode(session, {
        output: "json",
        prompts: ["continue"],
        writer: { write: chunk => void chunks.push(chunk) }
      })
      const records = chunks.map(parseJson)
      const end = records.find(record => recordType(record) === "compaction_end")

      expect(result.type).toBe("success")
      expect(end).toMatchObject({ outcome: { type: outcome } })
      expect(records.some(isCompactionEntryEvent)).toBe(false)
      expect(session.sessionManager.latestCompaction()).toBeUndefined()
    } finally {
      session.dispose()
    }
  }
})

test("JSON mode keeps multiple prompts in one continuous stream", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  faux.setResponses([fauxAssistantMessage("first"), fauxAssistantMessage("second")])
  const { session } = await createAgentRuntime({ cwd: "/work", models, persist: false })
  const chunks: string[] = []

  try {
    const result = await runPrintMode(session, {
      output: "json",
      prompts: ["one", "two"],
      writer: {
        write(chunk) {
          chunks.push(chunk)
        }
      }
    })
    expect(result).toEqual({ type: "success" })
    const records = chunks.map(parseJson)
    expect(records.filter(record => recordType(record) === "session")).toHaveLength(1)
    expect(records.filter(isUserMessageStart)).toHaveLength(2)
  } finally {
    session.dispose()
  }
})

test("JSON output never includes runtime or stored credentials", async () => {
  const models = createModels()
  const faux = fauxProvider({ provider: "private", models: [{ id: "model" }] })
  models.setProvider(faux.provider)
  faux.setResponses([fauxAssistantMessage("done")])
  const runtime = await createAgentRuntime({
    cwd: "/work",
    models,
    model: "private/model",
    apiKey: "runtime-secret",
    persist: false
  })
  const chunks: string[] = []

  try {
    await runtime.services.credentialStore.modify("stored", async () => ({ type: "api_key", key: "stored-secret" }))
    const result = await runPrintMode(runtime.session, {
      output: "json",
      prompts: ["start"],
      writer: {
        write(chunk) {
          chunks.push(chunk)
        }
      }
    })
    expect(result).toEqual({ type: "success" })
    expect(chunks.join("")).not.toContain("runtime-secret")
    expect(chunks.join("")).not.toContain("stored-secret")
  } finally {
    runtime.session.dispose()
  }
})

test("JSONL framing preserves Unicode separators without creating extra records", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  faux.setResponses([fauxAssistantMessage("line one\nline two\u2028paragraph\u2029end")])
  const { session } = await createAgentRuntime({ cwd: "/work", models, persist: false })
  const chunks: string[] = []

  try {
    const result = await runPrintMode(session, {
      output: "json",
      prompts: ["start"],
      writer: {
        write(chunk) {
          chunks.push(chunk)
        }
      }
    })
    expect(result).toEqual({ type: "success" })
    expect(chunks.every(chunk => chunk.split("\n").length === 2)).toBe(true)
    expect(chunks.every(chunk => JSON.parse(chunk) !== undefined)).toBe(true)
    expect(chunks.join("")).toContain("\u2028")
    expect(chunks.join("")).toContain("\u2029")
  } finally {
    session.dispose()
  }
})

test("JSON mode fails a slow writer at its pending-record bound", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  const started = deferred<void>()
  faux.setResponses([
    async () => {
      started.resolve()
      return fauxAssistantMessage(Array.from({ length: maxPendingJsonlRecords + 64 }, () => fauxText("x")))
    }
  ])
  const { session } = await createAgentRuntime({ cwd: "/work", models, persist: false })
  const release = deferred<void>()
  let writes = 0

  try {
    const run = runPrintMode(session, {
      output: "json",
      prompts: ["start"],
      writer: {
        async write() {
          writes++
          if (writes === 2) await release.promise
        }
      }
    })
    await started.promise
    await session.waitForIdle()
    release.resolve()

    expect(await run).toEqual({ type: "output_error", message: "JSONL output exceeded its pending-write bound" })
    expect(writes).toBe(2)
  } finally {
    release.resolve()
    session.dispose()
  }
})

test("JSON mode contains unserializable events and releases its subscription", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  faux.setResponses([
    fauxAssistantMessage(fauxToolCall("inspect", {}, { id: "inspect-json" }), { stopReason: "toolUse" }),
    fauxAssistantMessage("unused")
  ])
  const { session } = await createAgentRuntime({ cwd: "/work", models, persist: false })
  session.setActiveTools([
    {
      name: "inspect",
      label: "inspect",
      description: "inspect",
      parameters: Type.Object({}),
      async execute() {
        return { content: [{ type: "text", text: "done" }], details: 1n }
      }
    }
  ])
  const chunks: string[] = []

  try {
    const result = await runPrintMode(session, {
      output: "json",
      prompts: ["start"],
      writer: {
        write(chunk) {
          chunks.push(chunk)
        }
      }
    })
    expect(result).toEqual({ type: "output_error", message: "Could not serialize JSONL output" })
    expect(chunks.every(chunk => JSON.parse(chunk) !== undefined)).toBe(true)
    const completedChunks = chunks.length
    session.setFollowUpMode("all", "global")
    expect(chunks).toHaveLength(completedChunks)
  } finally {
    session.dispose()
  }
})

test("JSON writer failure stops before provider work", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  faux.setResponses([fauxAssistantMessage("unused")])
  const { session } = await createAgentRuntime({ cwd: "/work", models, persist: false })

  try {
    const result = await runPrintMode(session, {
      output: "json",
      prompts: ["start"],
      writer: {
        write() {
          throw new Error("closed")
        }
      }
    })
    expect(result).toEqual({ type: "output_error", message: "Could not write JSONL output" })
    expect(faux.state.callCount).toBe(0)
  } finally {
    session.dispose()
  }
})

test("text print mode writes the final assistant text through a caller-owned session", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  faux.setResponses([fauxAssistantMessage("hello")])
  const { session } = await createAgentRuntime({ cwd: "/work", models, persist: false })
  const chunks: string[] = []

  try {
    const result = await runPrintMode(session, {
      output: "text",
      prompts: ["start"],
      writer: {
        write(chunk) {
          chunks.push(chunk)
        }
      }
    })

    expect(result).toEqual({ type: "success" })
    expect(chunks).toEqual(["hello\n"])
    expect(session.messages.map(message => message.role)).toEqual(["user", "assistant"])
  } finally {
    session.dispose()
  }
})

test("text mode omits thinking, tools, and intermediate assistant output", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  faux.setResponses([
    fauxAssistantMessage([fauxThinking("intermediate thought"), fauxToolCall("inspect", {}, { id: "inspect-1" })], {
      stopReason: "toolUse"
    }),
    fauxAssistantMessage([fauxThinking("final thought"), fauxText("visible")])
  ])
  const { session } = await createAgentRuntime({ cwd: "/work", models, persist: false })
  session.setActiveTools([
    {
      name: "inspect",
      label: "inspect",
      description: "inspect",
      parameters: Type.Object({}),
      async execute() {
        return { content: [{ type: "text", text: "tool output" }], details: undefined }
      }
    }
  ])
  const chunks: string[] = []

  try {
    const result = await runPrintMode(session, {
      output: "text",
      prompts: ["start"],
      writer: {
        write(chunk) {
          chunks.push(chunk)
        }
      }
    })
    expect(result).toEqual({ type: "success" })
    expect(chunks).toEqual(["visible\n"])
    expect(faux.state.callCount).toBe(2)
  } finally {
    session.dispose()
  }
})

test("multiple prompts run sequentially and print only the final response", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  faux.setResponses([fauxAssistantMessage("first"), fauxAssistantMessage("final"), fauxAssistantMessage("reused")])
  const { session } = await createAgentRuntime({ cwd: "/work", models, persist: false })
  const chunks: string[] = []

  try {
    const result = await runPrintMode(session, {
      output: "text",
      prompts: ["one", "two"],
      writer: {
        write(chunk) {
          chunks.push(chunk)
        }
      }
    })
    expect(result).toEqual({ type: "success" })
    expect(chunks).toEqual(["final\n"])

    await session.prompt("three")
    expect(faux.state.callCount).toBe(3)
  } finally {
    session.dispose()
  }
})

test("text output is rejected before writing when it exceeds the chunk bound", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  faux.setResponses([fauxAssistantMessage(Array.from({ length: maxPrintOutputChunks + 1 }, () => fauxText("")))])
  const { session } = await createAgentRuntime({ cwd: "/work", models, persist: false })
  let writes = 0

  try {
    const result = await runPrintMode(session, {
      output: "text",
      prompts: ["start"],
      writer: {
        write() {
          writes++
        }
      }
    })
    expect(result).toEqual({
      type: "output_error",
      message: `Print output cannot exceed ${maxPrintOutputChunks} chunks`
    })
    expect(writes).toBe(0)
  } finally {
    session.dispose()
  }
})

test("text output is rejected before writing when it exceeds the byte bound", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  faux.setResponses([fauxAssistantMessage("x".repeat(maxPrintOutputBytes))])
  const { session } = await createAgentRuntime({ cwd: "/work", models, persist: false })
  let writes = 0

  try {
    const result = await runPrintMode(session, {
      output: "text",
      prompts: ["start"],
      writer: {
        write() {
          writes++
        }
      }
    })

    expect(result).toEqual({ type: "output_error", message: `Print output cannot exceed ${maxPrintOutputBytes} bytes` })
    expect(writes).toBe(0)
  } finally {
    session.dispose()
  }
})

test("output failures return a bounded result and leave the session reusable", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  faux.setResponses([fauxAssistantMessage("first"), fauxAssistantMessage("second")])
  const { session } = await createAgentRuntime({ cwd: "/work", models, persist: false })

  try {
    const result = await runPrintMode(session, {
      output: "text",
      prompts: ["start"],
      writer: {
        write() {
          throw new Error("closed")
        }
      }
    })

    expect(result).toEqual({ type: "output_error", message: "Could not write print output" })
    await session.prompt("still open")
    expect(faux.state.callCount).toBe(2)
  } finally {
    session.dispose()
  }
})

test("external cancellation settles print mode without disposing its session", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  const started = deferred<void>()
  faux.setResponses([
    async (_context, options) => {
      started.resolve()
      await new Promise<void>(resolve => options?.signal?.addEventListener("abort", () => resolve(), { once: true }))
      return fauxAssistantMessage("partial", { stopReason: "aborted" })
    },
    fauxAssistantMessage("after abort")
  ])
  const { session } = await createAgentRuntime({ cwd: "/work", models, persist: false })

  try {
    const run = runPrintMode(session, { output: "text", prompts: ["start"], writer: { write() {} } })
    await started.promise
    await session.abort()
    expect(await run).toEqual({ type: "aborted", message: "Request was aborted" })

    await session.prompt("reuse")
    expect(faux.state.callCount).toBe(2)
  } finally {
    session.dispose()
  }
})

test("JSON provider errors stay parseable and return a non-success result", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  faux.setResponses([fauxAssistantMessage("partial", { stopReason: "error", errorMessage: "provider failed" })])
  const { session } = await createAgentRuntime({ cwd: "/work", models, persist: false })
  const chunks: string[] = []

  try {
    const result = await runPrintMode(session, {
      output: "json",
      prompts: ["start"],
      writer: {
        write(chunk) {
          chunks.push(chunk)
        }
      }
    })
    expect(result).toEqual({ type: "provider_error", message: "provider failed" })
    expect(chunks.every(chunk => JSON.parse(chunk) !== undefined)).toBe(true)
  } finally {
    session.dispose()
  }
})

test("assistant provider errors return a failure without writing response text", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  faux.setResponses([fauxAssistantMessage("partial", { stopReason: "error", errorMessage: "provider failed" })])
  const { session } = await createAgentRuntime({ cwd: "/work", models, persist: false })
  const chunks: string[] = []

  try {
    const result = await runPrintMode(session, {
      output: "text",
      prompts: ["start"],
      writer: {
        write(chunk) {
          chunks.push(chunk)
        }
      }
    })

    expect(result).toEqual({ type: "provider_error", message: "provider failed" })
    expect(chunks).toEqual([])
  } finally {
    session.dispose()
  }
})

test("aborted assistant responses return a distinct failure", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  faux.setResponses([fauxAssistantMessage("partial", { stopReason: "aborted" })])
  const { session } = await createAgentRuntime({ cwd: "/work", models, persist: false })

  try {
    const result = await runPrintMode(session, { output: "text", prompts: ["start"], writer: { write() {} } })

    expect(result).toEqual({ type: "aborted", message: "Request aborted" })
  } finally {
    session.dispose()
  }
})

test("prompt admission failures return a deterministic result", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  const { session } = await createAgentRuntime({ cwd: "/work", models, persist: false })
  session.dispose()

  const result = await runPrintMode(session, { output: "text", prompts: ["start"], writer: { write() {} } })
  expect(result).toEqual({ type: "provider_error", message: "AgentSession is disposed" })
})

test("print mode rejects an unselected session before provider work", async () => {
  const models = createModels()
  const { session } = await createAgentRuntime({ cwd: "/work", models, persist: false })
  let writes = 0

  try {
    const result = await runPrintMode(session, {
      output: "text",
      prompts: ["start"],
      writer: {
        write() {
          writes++
        }
      }
    })

    expect(result).toEqual({ type: "missing_model", message: "No model selected. Use /login, then /model." })
    expect(writes).toBe(0)
    expect(session.messages).toEqual([])
  } finally {
    session.dispose()
  }
})

test("print mode requires at least one prompt", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  const { session } = await createAgentRuntime({ cwd: "/work", models, persist: false })

  try {
    const result = await runPrintMode(session, { output: "text", prompts: [], writer: { write() {} } })
    expect(result).toEqual({ type: "invalid_input", message: "Print mode requires at least one prompt" })
    expect(faux.state.callCount).toBe(0)
  } finally {
    session.dispose()
  }
})

test("print mode bounds the number of prompts before provider work", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  const { session } = await createAgentRuntime({ cwd: "/work", models, persist: false })

  try {
    const result = await runPrintMode(session, {
      output: "text",
      prompts: Array.from({ length: maxPrintPromptCount + 1 }, () => "prompt"),
      writer: { write() {} }
    })
    expect(result.type).toBe("invalid_input")
    expect(faux.state.callCount).toBe(0)
  } finally {
    session.dispose()
  }
})

test("print mode bounds aggregate UTF-8 prompt bytes", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  const { session } = await createAgentRuntime({ cwd: "/work", models, persist: false })
  const oversized = "界".repeat(Math.floor(maxPrintPromptBytes / 3) + 1)

  try {
    const result = await runPrintMode(session, { output: "text", prompts: [oversized], writer: { write() {} } })
    expect(result.type).toBe("invalid_input")
    expect(faux.state.callCount).toBe(0)
  } finally {
    session.dispose()
  }
})

async function compactionPrintSession() {
  const models = createModels()
  const faux = fauxProvider({ provider: "print-compaction", models: [{ id: "model", contextWindow: 4_000 }] })
  models.setProvider(faux.provider)
  const bootstrap = await createAgentRuntime({
    cwd: "/work",
    models,
    persist: false,
    settings: { compactionReserveTokens: 100, compactionKeepRecentTokens: 1 }
  })
  const model = bootstrap.session.model
  bootstrap.session.dispose()
  const history = SessionManager.inMemory("/work")
  history.appendMessage({ role: "user", content: "old context", timestamp: 1 })
  const answer = fauxAssistantMessage("old answer")
  history.appendMessage({
    ...answer,
    usage: {
      input: 3_900,
      output: 0,
      cacheRead: 0,
      cacheWrite: 0,
      totalTokens: 3_900,
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 }
    }
  })
  const session = await createAgentSession({ services: bootstrap.services, sessionManager: history, model, tools: [] })
  return { session, faux }
}

function isCompactionEntryEvent(value: unknown): boolean {
  return (
    typeof value === "object" &&
    value !== null &&
    "entry" in value &&
    typeof value.entry === "object" &&
    value.entry !== null &&
    "type" in value.entry &&
    value.entry.type === "compaction"
  )
}

function parseJson(line: string): unknown {
  return JSON.parse(line)
}

function recordType(value: unknown): string | undefined {
  return isRecord(value) && typeof value.type === "string" ? value.type : undefined
}

function isUserMessageStart(value: unknown): boolean {
  return (
    recordType(value) === "message_start" && isRecord(value) && isRecord(value.message) && value.message.role === "user"
  )
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}

function deferred<T>() {
  let resolve!: (value: T | PromiseLike<T>) => void
  const promise = new Promise<T>(resolvePromise => {
    resolve = resolvePromise
  })
  return { promise, resolve }
}
