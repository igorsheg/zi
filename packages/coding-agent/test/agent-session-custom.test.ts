import { expect, test } from "bun:test"

import { Type, type Context } from "@earendil-works/pi-ai"

import { QueueCapacityError, maxPendingInputCount, type AgentSession, type QueuedInputs } from "../src/agent-session.js"
import {
  createModels,
  createTestAgentRuntime as createAgentRuntime,
  fauxAssistantMessage,
  fauxProvider,
  fauxToolCall
} from "../src/testing.js"

const noParameters = Type.Object({})

test("idle custom appends publish committed order and keep display independent from context", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  const contexts: Context[] = []
  faux.setResponses([
    (context: Context) => {
      contexts.push(context)
      return fauxAssistantMessage("done")
    }
  ])
  const { session } = await createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })
  const events: string[] = []
  session.subscribe(event => {
    if (event.type === "entry_appended") events.push(`entry:${event.entry.type}`)
    if (event.type === "message_end") events.push(`message:${event.message.role}`)
  })

  const state = session.appendCustomEntry("example.counter", { count: 1 })
  const admission = session.sendCustomMessage(
    { customType: "example.policy", content: "hidden policy", display: false },
    { type: "append" }
  )

  expect(admission).toMatchObject({ type: "appended", entry: { type: "custom_message" } })
  expect(session.getCustomEntries("example.counter")).toEqual([state])
  expect(session.messages).toEqual([])
  expect(session.sessionManager.activeMessages()).toEqual([
    expect.objectContaining({ role: "custom", customType: "example.policy", content: "hidden policy" })
  ])
  expect(events).toEqual(["entry:custom", "entry:custom_message", "message:custom"])

  await session.prompt("continue")
  expect(contextTexts(contexts[0]!)).toEqual(expect.arrayContaining(["hidden policy", "continue"]))
  session.dispose()
})

test("trigger-turn commits a custom message before admitting one provider continuation", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  let session: AgentSession
  faux.setResponses([
    (context: Context) => {
      expect(session.sessionManager.entries().map(entry => entry.type)).toContain("custom_message")
      expect(contextTexts(context)).toContain("external event")
      return fauxAssistantMessage("handled")
    }
  ])
  ;({ session } = await createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } }))

  const admission = session.sendCustomMessage(
    { customType: "example.event", content: "external event", display: true },
    { type: "trigger_turn" }
  )
  expect(admission.type).toBe("turn_started")
  if (admission.type !== "turn_started") throw new Error("Expected a triggered turn")
  expect(session.sessionManager.entries().filter(entry => entry.type === "custom_message")).toHaveLength(1)
  expect(session.messages).toEqual([
    expect.objectContaining({ role: "custom", customType: "example.event", content: "external event" })
  ])

  await admission.settled
  expect(faux.state.callCount).toBe(1)
  expect(
    session.sessionManager.entries().filter(entry => entry.type === "custom_message" || entry.type === "message")
  ).toHaveLength(2)
  session.dispose()
})

test("streaming custom deliveries share the bounded queue and persist exactly once when delivered", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  const contexts: Context[] = []
  faux.setResponses([
    fauxAssistantMessage(fauxToolCall("hold", {}, { id: "hold-custom" }), { stopReason: "toolUse" }),
    (context: Context) => {
      contexts.push(context)
      return fauxAssistantMessage("steered")
    },
    (context: Context) => {
      contexts.push(context)
      return fauxAssistantMessage("followed")
    }
  ])
  const { session } = await createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })
  const started = deferred<void>()
  const release = deferred<void>()
  session.setActiveTools([
    {
      name: "hold",
      label: "hold",
      description: "Wait for release",
      parameters: noParameters,
      async execute() {
        started.resolve()
        await release.promise
        return { content: [{ type: "text" as const, text: "released" }], details: undefined }
      }
    }
  ])

  const run = session.prompt("start")
  await started.promise
  expect(
    session.sendCustomMessage(
      { customType: "example.steer", content: "steered context", display: true },
      { type: "steer" }
    )
  ).toEqual({ type: "queued", delivery: "steer" })
  expect(
    session.sendCustomMessage(
      { customType: "example.follow", content: "follow-up context", display: false },
      { type: "follow_up" }
    )
  ).toEqual({ type: "queued", delivery: "follow_up" })
  expect(session.queuedInputs).toEqual({ steering: [], followUp: [] })
  expect(session.memoryDiagnostics.queuedInputs).toBe(2)

  release.resolve()
  await run

  expect(contextTexts(contexts[0]!)).toContain("steered context")
  expect(contextTexts(contexts[1]!)).toContain("follow-up context")
  expect(session.sessionManager.entries().filter(entry => entry.type === "custom_message")).toHaveLength(2)
  expect(session.messages.filter(message => message.role === "custom")).toEqual([
    expect.objectContaining({ customType: "example.steer", content: "steered context" })
  ])
  session.dispose()
})

test("next-turn custom delivery stays ephemeral until a user batch and is discarded with queued input", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  const contexts: Context[] = []
  faux.setResponses([
    (context: Context) => {
      contexts.push(context)
      return fauxAssistantMessage("done")
    },
    (context: Context) => {
      contexts.push(context)
      return fauxAssistantMessage("done again")
    }
  ])
  const { session } = await createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })

  expect(
    session.sendCustomMessage(
      { customType: "example.next", content: "next context", display: true },
      { type: "next_turn" }
    )
  ).toEqual({ type: "queued", delivery: "next_turn" })
  expect(session.sessionManager.entries().some(entry => entry.type === "custom_message")).toBe(false)
  await session.prompt("first user prompt")
  expect(contextTexts(contexts[0]!)).toEqual(expect.arrayContaining(["next context", "first user prompt"]))
  expect(session.sessionManager.entries().filter(entry => entry.type === "custom_message")).toHaveLength(1)

  session.sendCustomMessage(
    { customType: "example.discard", content: "discarded context", display: true },
    { type: "next_turn" }
  )
  expect(session.takeQueuedInputs()).toEqual({ steering: [], followUp: [] })
  await session.prompt("second user prompt")
  expect(contextTexts(contexts[1]!)).not.toContain("discarded context")
  expect(session.sessionManager.entries().filter(entry => entry.type === "custom_message")).toHaveLength(1)
  session.dispose()
})

test("public interruption discards custom delivery while preserving queued user input", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  const contexts: Context[] = []
  faux.setResponses([
    fauxAssistantMessage(fauxToolCall("hold", {}, { id: "hold-interrupt" }), { stopReason: "toolUse" }),
    (context: Context) => {
      contexts.push(context)
      return fauxAssistantMessage("continued")
    }
  ])
  const { session } = await createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })
  const started = deferred<void>()
  const release = deferred<void>()
  session.setActiveTools([
    {
      name: "hold",
      label: "hold",
      description: "Wait for release",
      parameters: noParameters,
      async execute() {
        started.resolve()
        await release.promise
        return { content: [{ type: "text" as const, text: "released" }], details: undefined }
      }
    }
  ])

  const run = session.prompt("start")
  await started.promise
  session.steer("preserved user input")
  session.sendCustomMessage(
    { customType: "example.discard", content: "discarded custom input", display: true },
    { type: "steer" }
  )
  const interrupted = session.abort()
  release.resolve()
  await interrupted
  await run

  expect(contextTexts(contexts[0]!)).toContain("preserved user input")
  expect(contextTexts(contexts[0]!)).not.toContain("discarded custom input")
  expect(session.sessionManager.entries().some(entry => entry.type === "custom_message")).toBe(false)
  session.dispose()
})

test("queued custom persistence failure removes Pi's uncommitted runtime message", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  const providerStarted = deferred<void>()
  const releaseProvider = deferred<void>()
  const contexts: Context[] = []
  faux.setResponses([
    async () => {
      providerStarted.resolve()
      await releaseProvider.promise
      return fauxAssistantMessage("first response")
    },
    (context: Context) => {
      contexts.push(context)
      return fauxAssistantMessage("next response")
    }
  ])
  const { session } = await createAgentRuntime({
    cwd: "/work",
    models,
    settings: { retryEnabled: false },
    session: { type: "new", persist: false }
  })
  const run = session.prompt("start")
  await providerStarted.promise
  session.sendCustomMessage(
    { customType: "example.failure", content: "must not survive", display: true },
    { type: "steer" }
  )
  const manager = session.sessionManager
  const appendCustomMessage = manager.appendCustomMessage.bind(manager)
  Object.defineProperty(manager, "appendCustomMessage", {
    configurable: true,
    value() {
      throw new Error("forced custom persistence failure")
    }
  })

  releaseProvider.resolve()
  await run
  Object.defineProperty(manager, "appendCustomMessage", { configurable: true, value: appendCustomMessage })

  expect(manager.entries().some(entry => entry.type === "custom_message")).toBe(false)
  expect(session.messages.some(message => message.role === "custom")).toBe(false)
  expect(manager.activeMessages().some(message => message.role === "custom")).toBe(false)

  await session.prompt("next")
  expect(contextTexts(contexts[0]!)).not.toContain("must not survive")
  session.dispose()
})

test("interrupting a triggered turn before Pi starts prevents provider work", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  faux.setResponses([fauxAssistantMessage("must not run")])
  const { session } = await createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })
  let interrupted: Promise<void> | undefined
  const unsubscribe = session.subscribe(event => {
    if (event.type === "message_end" && event.message.role === "custom") interrupted = session.abort()
  })

  const admission = session.sendCustomMessage(
    { customType: "example.trigger", content: "committed event", display: true },
    { type: "trigger_turn" }
  )
  if (admission.type !== "turn_started") throw new Error("Expected triggered turn")
  if (!interrupted) throw new Error("Expected message observer interruption")
  await interrupted
  await admission.settled

  expect(faux.state.callCount).toBe(0)
  expect(session.isStreaming).toBe(false)
  expect(session.sessionManager.entries().filter(entry => entry.type === "custom_message")).toHaveLength(1)
  unsubscribe()
  session.dispose()
})

test("interruption after Pi queue drain cancels custom input and requeues user input once", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  const providerStarted = deferred<void>()
  const releaseProvider = deferred<void>()
  const contexts: Context[] = []
  faux.setResponses([
    async () => {
      providerStarted.resolve()
      await releaseProvider.promise
      return fauxAssistantMessage("first response")
    },
    (context: Context) => {
      contexts.push(context)
      return fauxAssistantMessage("continued")
    }
  ])
  const { session } = await createAgentRuntime({
    cwd: "/work",
    models,
    settings: { retryEnabled: false },
    session: { type: "new", persist: false }
  })
  let turnStarts = 0
  let interrupted: Promise<void> | undefined
  session.subscribe(event => {
    if (event.type !== "turn_start" || ++turnStarts !== 2) return
    interrupted = session.abort()
  })

  const run = session.prompt("start")
  await providerStarted.promise
  session.steer("preserved once")
  session.sendCustomMessage(
    { customType: "example.cancelled", content: "cancelled after drain", display: true },
    { type: "steer" }
  )
  releaseProvider.resolve()
  await run
  if (!interrupted) throw new Error("Expected queue-drain interruption")
  await interrupted

  expect(faux.state.callCount).toBe(2)
  expect(contextTexts(contexts[0]!).filter(text => text === "preserved once")).toHaveLength(1)
  expect(contextTexts(contexts[0]!)).not.toContain("cancelled after drain")
  expect(session.sessionManager.entries().filter(entry => entry.type === "custom_message")).toHaveLength(0)
  expect(
    session.sessionManager
      .messages()
      .filter(message => message.role === "user" && contextTexts({ messages: [message] })[0] === "preserved once")
  ).toHaveLength(1)
  session.dispose()
})

for (const operation of ["take", "take_and_abort"] as const) {
  test(`${operation} cancels a Pi-drained custom message and returns user input exactly once`, async () => {
    const models = createModels()
    const faux = fauxProvider()
    models.setProvider(faux.provider)
    const providerStarted = deferred<void>()
    const releaseProvider = deferred<void>()
    const contexts: Context[] = []
    faux.setResponses([
      async () => {
        providerStarted.resolve()
        await releaseProvider.promise
        return fauxAssistantMessage("first response")
      },
      (context: Context) => {
        contexts.push(context)
        return fauxAssistantMessage("restored response")
      }
    ])
    const { session } = await createAgentRuntime({
      cwd: "/work",
      models,
      settings: { retryEnabled: false, steeringMode: "all" },
      session: { type: "new", persist: false }
    })
    let turnStarts = 0
    let detached: QueuedInputs | undefined
    let interrupted: Promise<void> | undefined
    session.subscribe(event => {
      if (event.type !== "turn_start" || ++turnStarts !== 2) return
      if (operation === "take") {
        detached = session.takeQueuedInputs()
      } else {
        const result = session.takeQueuedInputsAndAbort()
        detached = result
        interrupted = result.settled
      }
    })

    const run = session.prompt("start")
    await providerStarted.promise
    session.sendCustomMessage(
      { customType: "example.detached", content: "must be detached", display: true },
      { type: "steer" }
    )
    session.steer("restored user")
    releaseProvider.resolve()
    await run
    await interrupted
    if (!detached) throw new Error("Expected drained queue detachment")

    expect(detached.steering.map(entry => entry.text)).toEqual(["restored user"])
    expect(session.sessionManager.entries().filter(entry => entry.type === "custom_message")).toHaveLength(0)
    expect(session.messages.some(message => message.role === "custom")).toBe(false)
    expect(userTexts(session).filter(text => text === "restored user")).toHaveLength(0)
    if (operation === "take") {
      expect(
        session.sessionManager.entries().filter(entry => entry.type === "message" && entry.message.role === "assistant")
      ).toMatchObject([{ message: { stopReason: "stop" } }])
    }

    await session.prompt(detached.steering[0]!.text)
    expect(faux.state.callCount).toBe(2)
    expect(contextTexts(contexts[0]!)).not.toContain("must be detached")
    expect(contextTexts(contexts[0]!).filter(text => text === "restored user")).toHaveLength(1)
    expect(userTexts(session).filter(text => text === "restored user")).toHaveLength(1)
    if (operation === "take") {
      expect(contexts[0]!.messages.map(message => message.role)).toEqual(["user", "assistant", "user"])
      expect(JSON.stringify(contexts[0])).not.toContain("Queued input was cancelled")
    }
    session.dispose()
  })
}

test("custom admission rejects forbidden activity and shares queue count capacity", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  faux.setResponses([fauxAssistantMessage(fauxToolCall("hold", {}, { id: "hold-bounds" }), { stopReason: "toolUse" })])
  const { session } = await createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })
  expect(() =>
    session.sendCustomMessage({ customType: "example.idle", content: "idle", display: true }, { type: "steer" })
  ).toThrow("requires an active agent run")

  const started = deferred<void>()
  const release = deferred<void>()
  session.setActiveTools([
    {
      name: "hold",
      label: "hold",
      description: "Wait for release",
      parameters: noParameters,
      async execute() {
        started.resolve()
        await release.promise
        return { content: [{ type: "text" as const, text: "released" }], details: undefined }
      }
    }
  ])
  const run = session.prompt("start")
  await started.promise
  expect(() =>
    session.sendCustomMessage({ customType: "example.append", content: "busy", display: true }, { type: "append" })
  ).toThrow("only append while the agent is idle")
  expect(() =>
    session.sendCustomMessage(
      { customType: "example.trigger", content: "busy", display: true },
      { type: "trigger_turn" }
    )
  ).toThrow("only trigger a turn while the agent is idle")
  const state = session.appendCustomEntry("example.tool-state", { running: true })
  expect(session.getCustomEntries("example.tool-state")).toEqual([state])

  for (let index = 0; index < maxPendingInputCount; index++) {
    session.sendCustomMessage(
      { customType: "example.pending", content: `queued-${index}`, display: false },
      { type: "next_turn" }
    )
  }
  expect(() =>
    session.sendCustomMessage(
      { customType: "example.pending", content: "overflow", display: false },
      { type: "next_turn" }
    )
  ).toThrow(QueueCapacityError)

  const aborted = session.takeQueuedInputsAndAbort()
  release.resolve()
  await aborted.settled
  await run
  expect(session.sessionManager.entries().some(entry => entry.type === "custom_message")).toBe(false)
  session.dispose()
})

function userTexts(session: AgentSession): string[] {
  return userMessageTexts(session.sessionManager.messages())
}

function contextTexts(context: Pick<Context, "messages">): string[] {
  return userMessageTexts(context.messages)
}

function userMessageTexts(messages: readonly { readonly role: string; readonly content?: unknown }[]): string[] {
  return messages.flatMap(message => {
    if (message.role !== "user") return []
    if (typeof message.content === "string") return [message.content]
    if (!Array.isArray(message.content)) return []
    return message.content.flatMap(part =>
      typeof part === "object" && part !== null && "type" in part && part.type === "text" && "text" in part
        ? [String(part.text)]
        : []
    )
  })
}

function deferred<T>() {
  let resolve!: (value: T) => void
  const promise = new Promise<T>(resolvePromise => {
    resolve = resolvePromise
  })
  return { promise, resolve }
}
