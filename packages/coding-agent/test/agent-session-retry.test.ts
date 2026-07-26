import { expect, test } from "bun:test"
import { mkdirSync, renameSync, rmSync } from "node:fs"
import { mkdtemp } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type { Context } from "@earendil-works/pi-ai"
/* oxlint-disable no-await-in-loop -- table scenarios are intentionally isolated and sequential. */

import {
  createModels,
  createTestAgentRuntime as createAgentRuntime,
  fauxAssistantMessage,
  fauxProvider
} from "../src/testing.js"

test("a transient assistant failure retries inside one logical prompt", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  faux.setResponses([
    fauxAssistantMessage("", { stopReason: "error", errorMessage: "overloaded_error" }),
    fauxAssistantMessage("recovered")
  ])
  const { session } = await createAgentRuntime({
    cwd: "/work",
    models,
    session: { type: "new", persist: false },
    settings: { retryEnabled: true, retryMaxRetries: 3, retryBaseDelayMs: 0 }
  })
  const events: string[] = []
  const agentEnds: boolean[] = []
  session.subscribe(event => {
    if (event.type === "agent_end") agentEnds.push(event.willRetry)
    if (event.type === "auto_retry_start") events.push(`start:${event.attempt}`)
    if (event.type === "auto_retry_end") events.push(`end:${event.success}`)
    if (event.type === "agent_settled") events.push("settled")
  })

  await session.prompt("try once")

  expect(faux.state.callCount).toBe(2)
  expect(events).toEqual(["start:1", "end:true", "settled"])
  expect(agentEnds).toEqual([true, false])
  expect(session.messages.filter(message => message.role === "assistant")).toHaveLength(2)
  expect(session.messages.at(-1)).toMatchObject({ role: "assistant", content: [{ type: "text", text: "recovered" }] })
  session.dispose()
})

test("disabled retry and quota exhaustion fail without another provider call", async () => {
  for (const scenario of [
    { retryEnabled: false, errorMessage: "server error" },
    { retryEnabled: true, errorMessage: "429 insufficient_quota" }
  ]) {
    const models = createModels()
    const faux = fauxProvider()
    models.setProvider(faux.provider)
    faux.setResponses([
      fauxAssistantMessage("", { stopReason: "error", errorMessage: scenario.errorMessage }),
      fauxAssistantMessage("should not run")
    ])
    const { session } = await createAgentRuntime({
      cwd: "/work",
      models,
      session: { type: "new", persist: false },
      settings: { retryEnabled: scenario.retryEnabled, retryBaseDelayMs: 0 }
    })
    const retryEvents: string[] = []
    session.subscribe(event => {
      if (event.type === "auto_retry_start" || event.type === "auto_retry_end") retryEvents.push(event.type)
    })

    await session.prompt("try once")

    expect(faux.state.callCount).toBe(1)
    expect(retryEvents).toEqual([])
    expect(session.sessionManager.entries().some(entry => entry.type === "retry")).toBe(false)
    session.dispose()
  }
})

test("retry exhaustion keeps the final failure and closes one attempt sequence", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  faux.setResponses([
    fauxAssistantMessage("", { stopReason: "error", errorMessage: "server error 1" }),
    fauxAssistantMessage("", { stopReason: "error", errorMessage: "server error 2" }),
    fauxAssistantMessage("", { stopReason: "error", errorMessage: "server error 3" })
  ])
  const { session } = await createAgentRuntime({
    cwd: "/work",
    models,
    session: { type: "new", persist: false },
    settings: { retryEnabled: true, retryMaxRetries: 2, retryBaseDelayMs: 0 }
  })
  const events: string[] = []
  session.subscribe(event => {
    if (event.type === "auto_retry_start") events.push(`start:${event.attempt}`)
    if (event.type === "auto_retry_end") events.push(`end:${event.success}:${event.attempt}`)
    if (event.type === "agent_settled") events.push("settled")
  })

  await session.prompt("keep trying")

  expect(faux.state.callCount).toBe(3)
  expect(events).toEqual(["start:1", "start:2", "end:false:2", "settled"])
  expect(session.messages.at(-1)).toMatchObject({ role: "assistant", errorMessage: "server error 3" })
  expect(session.sessionManager.entries().filter(entry => entry.type === "message")).toHaveLength(4)
  session.dispose()
})

test("durable marker failure closes an active retry sequence", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-retry-marker-failure-"))
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  faux.setResponses([
    fauxAssistantMessage("", { stopReason: "error", errorMessage: "network error 1" }),
    fauxAssistantMessage("", { stopReason: "error", errorMessage: "network error 2" })
  ])
  const { session } = await createAgentRuntime({
    cwd: root,
    agentDir: join(root, "agent"),
    models,
    settings: { retryBaseDelayMs: 0 }
  })
  const events: string[] = []
  let errorEntries = 0
  let file: string | undefined
  let backup: string | undefined
  session.subscribe(event => {
    if (event.type === "auto_retry_start") events.push("start")
    if (event.type === "auto_retry_end") events.push(`end:${event.success}`)
    if (event.type === "agent_settled") events.push("settled")
    if (
      event.type === "entry_appended" &&
      event.entry.type === "message" &&
      event.entry.message.role === "assistant" &&
      event.entry.message.stopReason === "error" &&
      ++errorEntries === 2
    ) {
      file = session.sessionManager.file
      if (!file) throw new Error("Persistent session file was not created")
      backup = `${file}.backup`
      renameSync(file, backup)
      mkdirSync(file)
    }
  })

  try {
    const failure = await session.prompt("keep trying").then(
      () => undefined,
      cause => cause
    )

    expect(failure).toBeInstanceOf(Error)
    expect(events).toEqual(["start", "end:false", "settled"])
    expect(session.retryStatus).toEqual({ type: "idle" })
  } finally {
    if (file && backup) {
      rmSync(file, { recursive: true })
      renameSync(backup, file)
    }
    session.dispose()
  }
})

test("terminal overflow closes an active retry sequence", async () => {
  const models = createModels()
  const faux = fauxProvider({ models: [{ id: "small", contextWindow: 1_000 }] })
  models.setProvider(faux.provider)
  faux.setResponses([
    fauxAssistantMessage("", { stopReason: "error", errorMessage: "network error" }),
    fauxAssistantMessage("", { stopReason: "error", errorMessage: "prompt is too long: 1001 tokens > 1000 maximum" })
  ])
  const { session } = await createAgentRuntime({
    cwd: "/work",
    model: "faux/small",
    models,
    session: { type: "new", persist: false },
    settings: { retryBaseDelayMs: 0, compactionEnabled: false }
  })
  const events: string[] = []
  session.subscribe(event => {
    if (event.type === "auto_retry_start") events.push("start")
    if (event.type === "auto_retry_end") events.push(`end:${event.success}`)
    if (event.type === "agent_settled") events.push("settled")
  })

  await session.prompt("try once")

  expect(events).toEqual(["start", "end:false", "settled"])
  expect(session.retryStatus).toEqual({ type: "idle" })
  session.dispose()
})

test("cancelling retry backoff restores queued input and settles the logical prompt", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  faux.setResponses([
    fauxAssistantMessage("", { stopReason: "error", errorMessage: "network error" }),
    fauxAssistantMessage("should not run")
  ])
  const { session } = await createAgentRuntime({
    cwd: "/work",
    models,
    session: { type: "new", persist: false },
    settings: { retryEnabled: true, retryMaxRetries: 3, retryBaseDelayMs: 15_000 }
  })
  const retryStarted = deferred<void>()
  const events: string[] = []
  let retryStatus: typeof session.retryStatus | undefined
  session.subscribe(event => {
    if (event.type === "auto_retry_start") {
      events.push("start")
      retryStatus = session.retryStatus
      retryStarted.resolve()
    }
    if (event.type === "auto_retry_end") events.push(`end:${event.success}`)
    if (event.type === "agent_settled") events.push("settled")
  })

  const run = session.prompt("try once")
  await retryStarted.promise
  session.followUp("keep this draft")
  const aborted = session.takeQueuedInputsAndAbort()
  await aborted.settled
  await run

  expect(faux.state.callCount).toBe(1)
  expect(aborted.followUp.map(entry => entry.text)).toEqual(["keep this draft"])
  expect(events).toEqual(["start", "end:false", "settled"])
  expect(retryStatus).toMatchObject({ type: "waiting", source: "agent", attempt: 1, maxAttempts: 3 })
  expect(session.retryStatus).toEqual({ type: "idle" })
  expect(session.isStreaming).toBe(false)

  let nextContext: Context | undefined
  faux.setResponses([
    (context: Context) => {
      nextContext = context
      return fauxAssistantMessage("continued")
    }
  ])
  await session.prompt("continue manually")
  expect(nextContext?.messages.some(message => message.role === "assistant" && message.stopReason === "error")).toBe(
    false
  )
  session.dispose()
})

test("cancelling a started retry reports unsuccessful completion", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  const retryCallStarted = deferred<void>()
  faux.setResponses([
    fauxAssistantMessage("", { stopReason: "error", errorMessage: "network error" }),
    (_, options) => {
      retryCallStarted.resolve()
      return new Promise(resolve => {
        const finish = () => resolve(fauxAssistantMessage("", { stopReason: "aborted" }))
        if (options?.signal?.aborted) finish()
        else options?.signal?.addEventListener("abort", finish, { once: true })
      })
    }
  ])
  const { session } = await createAgentRuntime({
    cwd: "/work",
    models,
    session: { type: "new", persist: false },
    settings: { retryBaseDelayMs: 0 }
  })
  const retryEnds: boolean[] = []
  session.subscribe(event => {
    if (event.type === "auto_retry_end") retryEnds.push(event.success)
  })

  const run = session.prompt("try once")
  await retryCallStarted.promise
  await session.abort()
  await run

  expect(faux.state.callCount).toBe(2)
  expect(retryEnds).toEqual([false])
  expect(session.messages.at(-1)).toMatchObject({ role: "assistant", stopReason: "aborted" })
  session.dispose()
})

test("queued follow-up input waits for retry recovery inside the logical prompt", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  const providerStarted = deferred<void>()
  const firstResponse = deferred<ReturnType<typeof fauxAssistantMessage>>()
  const continuationContexts: Context[] = []
  faux.setResponses([
    async () => {
      providerStarted.resolve()
      return firstResponse.promise
    },
    (context: Context) => {
      continuationContexts.push(context)
      return fauxAssistantMessage("recovered")
    },
    (context: Context) => {
      continuationContexts.push(context)
      return fauxAssistantMessage("answered follow-up")
    }
  ])
  const { session } = await createAgentRuntime({
    cwd: "/work",
    models,
    session: { type: "new", persist: false },
    settings: { retryBaseDelayMs: 0 }
  })

  const run = session.prompt("start")
  await providerStarted.promise
  session.followUp("more context")
  firstResponse.resolve(fauxAssistantMessage("", { stopReason: "error", errorMessage: "network error" }))
  await run

  expect(continuationContexts).toHaveLength(2)
  expect(hasUserText(continuationContexts[0]!, "more context")).toBe(false)
  expect(hasUserText(continuationContexts[1]!, "more context")).toBe(true)
  expect(session.queuedInputs).toEqual({ steering: [], followUp: [] })
  session.dispose()
})

test("compaction never folds excluded retry failures back into summarized context", async () => {
  const models = createModels()
  const faux = fauxProvider({
    provider: "retry-compaction",
    models: [{ id: "model", contextWindow: 4_000, maxTokens: 500 }]
  })
  models.setProvider(faux.provider)
  let summaryInput = ""
  faux.setResponses([
    fauxAssistantMessage("", { stopReason: "error", errorMessage: "network error should stay excluded" }),
    fauxAssistantMessage("recovered"),
    (context: Context) => {
      summaryInput = context.messages
        .flatMap(message =>
          message.role === "user"
            ? typeof message.content === "string"
              ? [message.content]
              : message.content.flatMap(part => (part.type === "text" ? [part.text] : []))
            : []
        )
        .join("\n")
      return fauxAssistantMessage("checkpoint")
    }
  ])
  const { session } = await createAgentRuntime({
    cwd: "/work",
    model: "retry-compaction/model",
    models,
    session: { type: "new", persist: false },
    settings: {
      retryBaseDelayMs: 0,
      compactionEnabled: true,
      compactionReserveTokens: 100,
      compactionKeepRecentTokens: 1
    }
  })

  await session.prompt("remember this")
  await session.compact()

  expect(summaryInput).not.toContain("network error should stay excluded")
  session.dispose()
})

test("resuming a successful retry never restores failed attempts to provider context", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-retry-resume-"))
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  faux.setResponses([
    fauxAssistantMessage("", { stopReason: "error", errorMessage: "network error" }),
    fauxAssistantMessage("recovered")
  ])
  const created = await createAgentRuntime({
    cwd: root,
    agentDir: join(root, "agent"),
    models,
    settings: { retryBaseDelayMs: 0 }
  })
  await created.session.prompt("persist this")
  const sessionFile = created.session.sessionManager.file
  if (!sessionFile) throw new Error("Persistent session file was not created")
  created.session.dispose()

  let resumedContext: Context | undefined
  faux.setResponses([
    (context: Context) => {
      resumedContext = context
      return fauxAssistantMessage("continued")
    }
  ])
  const resumed = await createAgentRuntime({
    cwd: "/ignored",
    agentDir: join(root, "agent"),
    session: { type: "resume", file: sessionFile },
    models,
    settings: { retryBaseDelayMs: 0 }
  })
  expect(resumed.session.messages.some(message => message.role === "assistant" && message.stopReason === "error")).toBe(
    true
  )

  await resumed.session.prompt("continue")

  expect(resumedContext?.messages.some(message => message.role === "assistant" && message.stopReason === "error")).toBe(
    false
  )
  expect(resumed.session.sessionManager.entries().some(entry => entry.type === "retry")).toBe(true)
  resumed.session.dispose()
})

function hasUserText(context: Context, text: string): boolean {
  return context.messages.some(
    message =>
      message.role === "user" &&
      (typeof message.content === "string"
        ? message.content === text
        : message.content.some(part => part.type === "text" && part.text === text))
  )
}

function deferred<T>() {
  let resolve!: (value: T | PromiseLike<T>) => void
  const promise = new Promise<T>(resolvePromise => {
    resolve = resolvePromise
  })
  return { promise, resolve }
}
