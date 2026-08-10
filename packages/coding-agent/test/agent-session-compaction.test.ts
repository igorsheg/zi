import { expect, test } from "bun:test"

import { Type, type Context, type StreamOptions } from "@earendil-works/pi-ai"

import { maxCompactionErrorBytes } from "../src/compaction.js"
import { createAgentSession } from "../src/sdk.js"
import { SessionManager } from "../src/session-manager.js"
import {
  createModels,
  createTestAgentRuntime as createAgentRuntime,
  fauxAssistantMessage,
  fauxProvider,
  fauxToolCall
} from "../src/testing.js"

/* oxlint-disable no-await-in-loop */

const noParameters = Type.Object({})

test("manual compaction samples, commits, replaces active context, and orders lifecycle events", async () => {
  const setup = await compactionSession()
  const { session, faux } = setup
  faux.setResponses([fauxAssistantMessage("## Goal\nKeep working\n\n## Next Steps\n1. Continue")])
  const order: string[] = []
  session.subscribe(event => {
    if (event.type === "compaction_start") order.push("start")
    if (event.type === "entry_appended" && event.entry.type === "compaction") order.push("entry")
    if (event.type === "compaction_end") order.push(`end:${event.outcome.type}`)
  })
  session.subscribe(event => {
    if (event.type === "entry_appended" && event.entry.type === "compaction") {
      throw new Error("observer failed after commit")
    }
  })

  const result = await session.compact("preserve exact paths")

  expect(result.reason).toBe("manual")
  expect(result.compactedEntries).toBeGreaterThan(0)
  expect(result.estimatedTokensAfter).toBeLessThan(result.tokensBefore)
  expect(session.messages.at(-1)).toMatchObject({ role: "compactionSummary" })
  expect(session.sessionManager.activeMessages()[0]).toMatchObject({ role: "compactionSummary" })
  expect(session.sessionManager.entries().at(-1)).toMatchObject({ type: "compaction", reason: "manual" })
  expect(order).toEqual(["start", "entry", "end:completed"])
  expect(session.contextUsage.type).toBe("estimated")
  session.dispose()
})

test("manual compaction retries a transient summary failure inside one isolated request session", async () => {
  const setup = await compactionSession({ retryBaseDelayMs: 0 })
  const requests: StreamOptions[] = []
  setup.faux.setResponses([
    (_context, options) => {
      if (options) requests.push(options)
      return fauxAssistantMessage("", { stopReason: "error", errorMessage: "terminated" })
    },
    (_context, options) => {
      if (options) requests.push(options)
      return fauxAssistantMessage("recovered checkpoint")
    }
  ])
  const events: string[] = []
  let retryStatus: typeof setup.session.retryStatus | undefined
  setup.session.subscribe(event => {
    if (event.type === "summarization_retry_scheduled") {
      events.push(`scheduled:${event.attempt}`)
      retryStatus = setup.session.retryStatus
    }
    if (event.type === "summarization_retry_attempt_start") events.push("attempt")
    if (event.type === "summarization_retry_finished") events.push("finished")
  })

  const result = await setup.session.compact()

  expect(result.summary).toBe("recovered checkpoint")
  expect(setup.faux.state.callCount).toBe(2)
  expect(events).toEqual(["scheduled:1", "attempt", "finished"])
  expect(retryStatus).toMatchObject({ type: "waiting", source: "compaction", reason: "manual", attempt: 1 })
  expect(requests).toHaveLength(2)
  expect(requests.every(options => options.cacheRetention === "none")).toBe(true)
  expect(requests[0]?.sessionId).toBeTruthy()
  expect(requests[1]?.sessionId).toBe(requests[0]?.sessionId)
  expect(requests[0]?.sessionId).not.toBe(setup.session.sessionId)
  expect(setup.session.retryStatus).toEqual({ type: "idle" })
  setup.session.dispose()
})

test("manual compaction cancellation owns its retry backoff", async () => {
  const setup = await compactionSession({ retryBaseDelayMs: 15_000 })
  setup.faux.setResponses([
    fauxAssistantMessage("", { stopReason: "error", errorMessage: "terminated" }),
    fauxAssistantMessage("should not run")
  ])
  const scheduled = deferred<void>()
  const events: string[] = []
  setup.session.subscribe(event => {
    if (event.type === "summarization_retry_scheduled") scheduled.resolve()
    if (event.type === "summarization_retry_finished") events.push("finished")
    if (event.type === "compaction_end") events.push(event.outcome.type)
  })

  const compacting = setup.session.compact()
  await scheduled.promise
  await setup.session.abort().catch(() => {})
  const failure = await rejection(compacting)

  expect(failure.message).toContain("cancelled")
  expect(setup.faux.state.callCount).toBe(1)
  expect(events).toEqual(["finished", "cancelled"])
  expect(setup.session.retryStatus).toEqual({ type: "idle" })
  setup.session.dispose()
})

test("manual compaction closes retry events when an active sample is aborted", async () => {
  const setup = await compactionSession({ retryBaseDelayMs: 0 })
  setup.faux.setResponses([
    fauxAssistantMessage("", { stopReason: "error", errorMessage: "terminated" }),
    (_, options) =>
      new Promise(resolve => {
        const finish = () => resolve(fauxAssistantMessage("", { stopReason: "aborted" }))
        if (options?.signal?.aborted) finish()
        else options?.signal?.addEventListener("abort", finish, { once: true })
      })
  ])
  const attemptStarted = deferred<void>()
  const events: string[] = []
  setup.session.subscribe(event => {
    if (event.type === "summarization_retry_scheduled") events.push("scheduled")
    if (event.type === "summarization_retry_attempt_start") {
      events.push("attempt")
      attemptStarted.resolve()
    }
    if (event.type === "summarization_retry_finished") events.push("finished")
    if (event.type === "compaction_end") events.push(event.outcome.type)
  })

  const compacting = setup.session.compact()
  await attemptStarted.promise
  await setup.session.abort().catch(() => {})
  const failure = await rejection(compacting)

  expect(failure.message).toContain("cancelled")
  expect(events).toEqual(["scheduled", "attempt", "finished", "cancelled"])
  setup.session.dispose()
})

test("manual compaction remains completed when observers abort or dispose after commit", async () => {
  for (const action of ["abort", "dispose"] as const) {
    const setup = await compactionSession()
    setup.faux.setResponses([fauxAssistantMessage("committed checkpoint")])
    const outcomes: string[] = []
    setup.session.subscribe(event => {
      if (event.type === "entry_appended" && event.entry.type === "compaction") {
        if (action === "abort") void setup.session.abort()
        else setup.session.dispose()
      }
      if (event.type === "compaction_end") outcomes.push(event.outcome.type)
    })

    const result = await setup.session.compact()

    expect(result.summary).toBe("committed checkpoint")
    expect(setup.session.sessionManager.latestCompaction()).toBeDefined()
    if (action === "abort") {
      expect(outcomes).toEqual(["completed"])
      setup.session.dispose()
    }
  }
})

test("manual compaction rejects no-work and busy admission without aborting the run", async () => {
  const empty = await compactionSession({ history: false })
  expect(() => empty.session.compact()).toThrow("Nothing to compact")
  empty.session.dispose()

  const setup = await compactionSession({ history: false })
  const started = deferred<void>()
  const release = deferred<void>()
  setup.faux.setResponses([
    async () => {
      started.resolve()
      await release.promise
      return fauxAssistantMessage("done")
    }
  ])
  const run = setup.session.prompt("active")
  await started.promise
  expect(() => setup.session.compact()).toThrow("Cannot compact context while the agent is running")
  release.resolve()
  await run
  setup.session.dispose()

  const queued = await compactionSession()
  queued.session.steer("pending")
  expect(() => queued.session.compact()).toThrow("queued input is pending")
  queued.session.dispose()
})

test("manual compaction cancellation emits one closed cancelled outcome and settles", async () => {
  const setup = await compactionSession()
  const started = deferred<void>()
  setup.faux.setResponses([
    async (_context, options) => {
      started.resolve()
      await new Promise<void>(resolve => {
        if (options?.signal?.aborted) resolve()
        else options?.signal?.addEventListener("abort", () => resolve(), { once: true })
      })
      return fauxAssistantMessage("cancelled", { stopReason: "aborted" })
    }
  ])
  const outcomes: string[] = []
  setup.session.subscribe(event => {
    if (event.type === "compaction_end") outcomes.push(event.outcome.type)
  })

  const compacting = setup.session.compact()
  await started.promise
  const settled = setup.session.abort()
  expect((await rejection(compacting)).message.toLowerCase()).toContain("cancelled")
  await settled.catch(() => {})

  expect(outcomes).toEqual(["cancelled"])
  expect(setup.session.compactionStatus.type).toBe("idle")
  expect(setup.session.sessionManager.latestCompaction()).toBeUndefined()
  setup.session.dispose()
})

test("disposal rejects a stale manual completion before journal mutation", async () => {
  const setup = await compactionSession()
  const started = deferred<void>()
  const release = deferred<void>()
  setup.faux.setResponses([
    async () => {
      started.resolve()
      await release.promise
      return fauxAssistantMessage("late summary")
    }
  ])

  const compacting = setup.session.compact()
  await started.promise
  setup.session.dispose()
  expect((await rejection(compacting)).message).toContain("cancelled")
  release.resolve()
  await Bun.sleep(0)

  expect(setup.session.sessionManager.latestCompaction()).toBeUndefined()
})

test("manual failures expose one bounded error across rejection and lifecycle", async () => {
  for (const source of ["provider", "append"] as const) {
    const setup = await compactionSession()
    const oversized = `failure-${"💥".repeat(4_000)}`
    setup.faux.setResponses([
      source === "provider"
        ? fauxAssistantMessage("", { stopReason: "error", errorMessage: oversized })
        : fauxAssistantMessage("valid checkpoint")
    ])
    if (source === "append") {
      setup.session.sessionManager.appendCompaction = () => {
        throw new Error(oversized)
      }
    }
    const failures: string[] = []
    setup.session.subscribe(event => {
      if (event.type === "compaction_end" && event.outcome.type === "failed") failures.push(event.outcome.message)
    })

    const failure = await rejection(setup.session.compact())

    expect(Buffer.byteLength(failure.message)).toBeLessThanOrEqual(maxCompactionErrorBytes)
    expect(failures).toEqual([failure.message])
    expect(setup.session.sessionManager.latestCompaction()).toBeUndefined()
    setup.session.dispose()
  }
})

test("automatic cancellation and disposal reject late pre-commit summaries", async () => {
  for (const action of ["abort", "dispose"] as const) {
    const setup = await compactionSession({ contextWindow: 4_000, reportedTokens: 3_900 })
    const started = deferred<void>()
    const release = deferred<void>()
    setup.faux.setResponses([
      async () => {
        started.resolve()
        await release.promise
        return fauxAssistantMessage("late checkpoint")
      }
    ])

    const run = setup.session.prompt("new prompt")
    await started.promise
    if (action === "abort") await setup.session.abort()
    else setup.session.dispose()
    await run
    release.resolve()
    await Bun.sleep(0)

    expect(setup.session.sessionManager.latestCompaction()).toBeUndefined()
    if (action === "abort") setup.session.dispose()
  }
})

test("automatic compaction retries a transient summary failure before continuing the prompt", async () => {
  const setup = await compactionSession({ contextWindow: 4_000, reportedTokens: 3_900, retryBaseDelayMs: 0 })
  setup.faux.setResponses([
    fauxAssistantMessage("", { stopReason: "error", errorMessage: "terminated" }),
    fauxAssistantMessage("recovered checkpoint"),
    fauxAssistantMessage("answer")
  ])
  const retryReasons: string[] = []
  setup.session.subscribe(event => {
    if (event.type === "summarization_retry_scheduled") retryReasons.push(event.reason)
  })

  await setup.session.prompt("new prompt")

  expect(setup.faux.state.callCount).toBe(3)
  expect(retryReasons).toEqual(["threshold"])
  expect(setup.session.sessionManager.latestCompaction()?.reason).toBe("threshold")
  setup.session.dispose()
})

test("automatic pre-prompt compaction includes prospective input and changes the provider context", async () => {
  const requests: Context[] = []
  const setup = await compactionSession({ contextWindow: 4_000, reportedTokens: 3_900 })
  setup.faux.setResponses([
    fauxAssistantMessage("short checkpoint"),
    (context: Context) => {
      requests.push(context)
      return fauxAssistantMessage("answer")
    }
  ])

  await setup.session.prompt("new prompt")

  expect(setup.faux.state.callCount).toBe(2)
  expect(setup.session.sessionManager.latestCompaction()?.reason).toBe("threshold")
  expect(requests[0]?.messages[0]).toMatchObject({ role: "user" })
  expect(JSON.stringify(requests[0]?.messages[0])).toContain("short checkpoint")
  expect(userTexts(requests[0]!)).toContain("new prompt")
  setup.session.dispose()
})

test("post-commit automatic abort and disposal do not continue provider work", async () => {
  for (const action of ["abort", "dispose"] as const) {
    const setup = await compactionSession({ contextWindow: 4_000, reportedTokens: 3_900 })
    setup.faux.setResponses([fauxAssistantMessage("committed checkpoint"), fauxAssistantMessage("must not run")])
    const outcomes: string[] = []
    setup.session.subscribe(event => {
      if (event.type === "entry_appended" && event.entry.type === "compaction") {
        if (action === "abort") void setup.session.abort()
        else setup.session.dispose()
      }
      if (event.type === "compaction_end") outcomes.push(event.outcome.type)
    })

    await setup.session.prompt("new prompt")

    expect(setup.faux.state.callCount).toBe(1)
    expect(setup.session.sessionManager.latestCompaction()).toBeDefined()
    if (action === "abort") {
      expect(outcomes).toEqual(["completed"])
      setup.session.dispose()
    }
  }
})

test("disabled automatic compaction leaves provider context untouched", async () => {
  const setup = await compactionSession({ contextWindow: 4_000, reportedTokens: 3_900 })
  setup.session.setCompactionEnabled(false, "global")
  setup.faux.setResponses([fauxAssistantMessage("answer")])
  const starts: string[] = []
  setup.session.subscribe(event => {
    if (event.type === "compaction_start") starts.push(event.reason)
  })

  await setup.session.prompt("new prompt")

  expect(setup.faux.state.callCount).toBe(1)
  expect(starts).toEqual([])
  expect(setup.session.sessionManager.latestCompaction()).toBeUndefined()
  setup.session.dispose()
})

test("automatic thresholds follow the newly selected model window", async () => {
  const models = createModels()
  const faux = fauxProvider({
    provider: "window-change",
    models: [
      { id: "small", contextWindow: 4_000, maxTokens: 500 },
      { id: "large", contextWindow: 16_000, maxTokens: 500 }
    ]
  })
  models.setProvider(faux.provider)
  const bootstrap = await createAgentRuntime({
    cwd: "/work",
    model: "window-change/small",
    models,
    session: { type: "new", persist: false },
    settings: { compactionReserveTokens: 100, compactionKeepRecentTokens: 1 }
  })
  const small = bootstrap.session.model
  const large = faux.getModel("large")
  if (!large) throw new Error("Large model not found")
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
  const { session } = await createAgentSession({
    services: bootstrap.services,
    sessionManager: history,
    model: small,
    tools: []
  })
  await session.setModel(large)
  faux.setResponses([fauxAssistantMessage("continued")])

  await session.prompt("new prompt")

  expect(faux.state.callCount).toBe(1)
  expect(session.sessionManager.latestCompaction()).toBeUndefined()
  session.dispose()
})

test("large tool results compact before the next model request", async () => {
  const requests: Context[] = []
  const setup = await compactionSession({ history: false, contextWindow: 500 })
  setup.session.setActiveTools([
    {
      name: "large",
      label: "large",
      description: "Return a large result",
      parameters: noParameters,
      async execute() {
        return { content: [{ type: "text" as const, text: "x".repeat(3_000) }], details: undefined }
      }
    }
  ])
  setup.faux.setResponses([
    fauxAssistantMessage(fauxToolCall("large", {}, { id: "large-1" }), { stopReason: "toolUse" }),
    fauxAssistantMessage("tool checkpoint"),
    (context: Context) => {
      requests.push(context)
      return fauxAssistantMessage("finished")
    },
    ...Array.from({ length: 8 }, () => fauxAssistantMessage("z"))
  ])

  await setup.session.prompt("y".repeat(500))

  expect(setup.faux.state.callCount).toBeGreaterThanOrEqual(3)
  expect(setup.faux.state.callCount).toBeLessThanOrEqual(11)
  expect(setup.session.sessionManager.latestCompaction()?.reason).toBe("threshold")
  expect(requests[0]?.messages.map(message => message.role)).toEqual(["user", "assistant", "toolResult"])
  setup.session.dispose()
})

test("one run admits at most four automatic compactions", async () => {
  const setup = await compactionSession({ contextWindow: 4_000, reportedTokens: 3_900 })
  const responses = []
  for (let index = 0; index < 4; index++) {
    responses.push(fauxAssistantMessage(`checkpoint ${index}`))
    responses.push(() => {
      setup.session.followUp(`queued ${index} ${"x".repeat(20_000)}`)
      return fauxAssistantMessage(`turn ${index}`)
    })
  }
  responses.push(fauxAssistantMessage("finished"))
  setup.faux.setResponses(responses)
  const starts: string[] = []
  setup.session.subscribe(event => {
    if (event.type === "compaction_start") starts.push(event.reason)
  })

  await setup.session.prompt("start")

  expect(starts).toHaveLength(4)
  expect(
    setup.session.sessionManager.entries().filter(entry => entry.type === "compaction").length
  ).toBeLessThanOrEqual(4)
  setup.session.dispose()
})

test("queued steering continues after automatic context replacement", async () => {
  const setup = await compactionSession({ history: false, contextWindow: 500 })
  setup.session.setActiveTools([
    {
      name: "large-queued",
      label: "large queued",
      description: "Return a large result",
      parameters: noParameters,
      async execute() {
        return { content: [{ type: "text" as const, text: "x".repeat(3_000) }], details: undefined }
      }
    }
  ])
  const summaryStarted = deferred<void>()
  const releaseSummary = deferred<void>()
  const contexts: Context[] = []
  setup.faux.setResponses([
    fauxAssistantMessage(fauxToolCall("large-queued", {}, { id: "large-queued-1" }), { stopReason: "toolUse" }),
    async () => {
      summaryStarted.resolve()
      await releaseSummary.promise
      return fauxAssistantMessage("queued checkpoint")
    },
    (context: Context) => {
      contexts.push(context)
      return fauxAssistantMessage("finished")
    },
    ...Array.from({ length: 8 }, () => fauxAssistantMessage("z"))
  ])

  const run = setup.session.prompt("y".repeat(500))
  await summaryStarted.promise
  setup.session.steer("queued steering")
  releaseSummary.resolve()
  await run

  expect(userTexts(contexts[0]!)).toContain("queued steering")
  expect(setup.session.queuedInputs.steering).toHaveLength(0)
  expect(
    setup.session.sessionManager
      .messages()
      .some(message => message.role === "user" && JSON.stringify(message).includes("queued steering"))
  ).toBe(true)
  setup.session.dispose()
})

test("threshold failure keeps the original tool-loop context and suppresses repeats for the run", async () => {
  const setup = await compactionSession({ history: false, contextWindow: 1_000 })
  setup.session.setActiveTools([
    {
      name: "small",
      label: "small",
      description: "Return a result",
      parameters: noParameters,
      async execute() {
        return { content: [{ type: "text" as const, text: "x".repeat(3_600) }], details: undefined }
      }
    }
  ])
  const toolCall = fauxAssistantMessage(fauxToolCall("small", {}, { id: "small-1" }), { stopReason: "toolUse" })
  const contexts: Context[] = []
  setup.faux.setResponses([
    {
      ...toolCall,
      usage: {
        input: 490,
        output: 0,
        cacheRead: 0,
        cacheWrite: 0,
        totalTokens: 490,
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 }
      }
    },
    fauxAssistantMessage("   "),
    (context: Context) => {
      contexts.push(context)
      return fauxAssistantMessage("finished")
    }
  ])
  const outcomes: string[] = []
  setup.session.subscribe(event => {
    if (event.type === "compaction_end") outcomes.push(`${event.reason}:${event.outcome.type}`)
  })

  await setup.session.prompt("run")

  expect(setup.faux.state.callCount).toBeGreaterThanOrEqual(3)
  expect(outcomes.filter(outcome => outcome.startsWith("threshold:"))).toEqual(["threshold:failed"])
  expect(contexts[0]?.messages.map(message => message.role)).toEqual(["user", "assistant", "toolResult"])
  expect(setup.session.sessionManager.latestCompaction()).toBeUndefined()
  setup.session.dispose()
})

test("Codex context-window failure stays durable while one compact-and-continue recovery succeeds", async () => {
  const setup = await compactionSession({ oldTextBytes: 100, contextWindow: 4_000 })
  setup.faux.setResponses([
    fauxAssistantMessage("", {
      stopReason: "error",
      errorMessage:
        "Codex error: Your input exceeds the context window of this model. Please adjust your input and try again."
    }),
    fauxAssistantMessage("overflow checkpoint"),
    fauxAssistantMessage("recovered")
  ])
  const starts: string[] = []
  setup.session.subscribe(event => {
    if (event.type === "compaction_start") starts.push(event.reason)
  })

  await setup.session.prompt("retry input")

  expect(setup.faux.state.callCount).toBe(3)
  expect(starts).toEqual(["overflow"])
  const marker = setup.session.sessionManager.latestCompaction()
  expect(marker).toMatchObject({ reason: "overflow" })
  const failure = setup.session.sessionManager.entries().find(entry => entry.id === marker?.excludedFailureEntryId)
  expect(failure).toMatchObject({ type: "message", message: { role: "assistant", stopReason: "error" } })
  expect(setup.session.messages.some(message => failure?.type === "message" && message === failure.message)).toBe(false)
  expect(setup.session.messages.at(-1)).toMatchObject({ role: "assistant", content: [{ text: "recovered" }] })
  setup.session.dispose()
})

test("a previous overflow failure is compacted before the next prompt without counting as that prompt's retry", async () => {
  const setup = await compactionSession({ oldTextBytes: 100, contextWindow: 1_000 })
  const sessionManager = setup.session.sessionManager
  const model = setup.session.model
  const overflow = sessionManager.appendMessage({
    ...fauxAssistantMessage("", {
      stopReason: "error",
      errorMessage:
        "Codex error: Your input exceeds the context window of this model. Please adjust your input and try again."
    }),
    provider: "compaction",
    model: "model"
  })
  setup.session.dispose()

  const { session } = await createAgentSession({ services: setup.services, sessionManager, model, tools: [] })
  setup.faux.setResponses([
    fauxAssistantMessage("overflow checkpoint"),
    fauxAssistantMessage("", { stopReason: "error", errorMessage: "prompt is too long: 1001 tokens > 1000 maximum" }),
    fauxAssistantMessage("retry checkpoint"),
    fauxAssistantMessage("recovered")
  ])
  expect(session.model.provider).toBe("compaction")
  expect(session.model.id).toBe("model")
  expect(session.messages.at(-1)).toBe(overflow.message)
  expect(session.messages.at(-1)).toMatchObject({ provider: "compaction", model: "model" })
  await session.prompt("next input")

  const markers = session.sessionManager.entries().filter(entry => entry.type === "compaction")
  expect(markers).toHaveLength(2)
  expect(markers[0]).toMatchObject({ reason: "overflow", excludedFailureEntryId: overflow.id })
  expect(markers[1]).toMatchObject({ reason: "overflow" })
  expect(session.messages.some(message => message === overflow.message)).toBe(false)
  expect(session.messages.at(-1)).toMatchObject({ role: "assistant", content: [{ text: "recovered" }] })
  session.dispose()
})

test("a second overflow stops without another compaction loop", async () => {
  const setup = await compactionSession({ oldTextBytes: 100, contextWindow: 1_000 })
  setup.faux.setResponses([overflowResponse(), fauxAssistantMessage("overflow checkpoint"), overflowResponse()])

  const failure = await rejection(setup.session.prompt("retry input"))

  expect(failure.message).toContain("after one recovery")
  expect(setup.faux.state.callCount).toBe(3)
  expect(setup.session.sessionManager.entries().filter(entry => entry.type === "compaction")).toHaveLength(1)
  setup.session.dispose()
})

function overflowResponse() {
  return fauxAssistantMessage("", {
    stopReason: "error",
    errorMessage: "prompt is too long: 1001 tokens > 1000 maximum"
  })
}

async function compactionSession(
  options: {
    readonly history?: boolean
    readonly contextWindow?: number
    readonly oldTextBytes?: number
    readonly reportedTokens?: number
    readonly retryBaseDelayMs?: number
  } = {}
) {
  const models = createModels()
  const faux = fauxProvider({
    provider: "compaction",
    models: [{ id: "model", contextWindow: options.contextWindow ?? 4_000, maxTokens: 500 }]
  })
  models.setProvider(faux.provider)
  const bootstrap = await createAgentRuntime({
    cwd: "/work",
    model: "compaction/model",
    models,
    session: { type: "new", persist: false },
    settings: {
      compactionEnabled: true,
      compactionReserveTokens: 100,
      compactionKeepRecentTokens: 1,
      ...(options.retryBaseDelayMs === undefined ? {} : { retryBaseDelayMs: options.retryBaseDelayMs })
    }
  })
  const model = bootstrap.session.model
  bootstrap.session.dispose()

  const sessionManager = SessionManager.inMemory("/work")
  if (options.history !== false) {
    sessionManager.appendMessage({ role: "user", content: "x".repeat(options.oldTextBytes ?? 1_000), timestamp: 1 })
    sessionManager.appendMessage(fauxAssistantMessage("old answer"))
    sessionManager.appendMessage({ role: "user", content: "recent", timestamp: 3 })
    const recent = fauxAssistantMessage("recent answer")
    sessionManager.appendMessage(
      options.reportedTokens
        ? {
            ...recent,
            usage: {
              input: options.reportedTokens,
              output: 0,
              cacheRead: 0,
              cacheWrite: 0,
              totalTokens: options.reportedTokens,
              cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 }
            }
          }
        : recent
    )
  }
  const { session } = await createAgentSession({ services: bootstrap.services, sessionManager, model, tools: [] })
  return { session, faux, services: bootstrap.services }
}

function userTexts(context: Context): string[] {
  return context.messages.flatMap(message => {
    if (message.role !== "user") return []
    if (typeof message.content === "string") return [message.content]
    return [message.content.flatMap(part => (part.type === "text" ? [part.text] : [])).join("\n")]
  })
}

async function rejection(promise: Promise<unknown>): Promise<Error> {
  try {
    await promise
  } catch (cause) {
    if (cause instanceof Error) return cause
    throw new Error(String(cause), { cause })
  }
  throw new Error("Expected rejection")
}

function deferred<T>() {
  let resolve!: (value: T | PromiseLike<T>) => void
  const promise = new Promise<T>(resolvePromise => {
    resolve = resolvePromise
  })
  return { promise, resolve }
}
