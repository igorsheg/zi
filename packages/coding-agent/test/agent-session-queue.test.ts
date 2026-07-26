import { expect, test } from "bun:test"
import { mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { Type, type Context, type ImageContent } from "@earendil-works/pi-ai"

import {
  type AgentSession,
  maxPendingInputBytes,
  maxPendingInputCount,
  QueueCapacityError
} from "../src/agent-session.js"
import {
  createModels,
  createTestAgentRuntime as createAgentRuntime,
  fauxAssistantMessage,
  fauxProvider,
  fauxToolCall
} from "../src/testing.js"

const noParameters = Type.Object({})

test("steering waits for the current tool batch and leaves the pending queue before transcript delivery", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  faux.setResponses([
    fauxAssistantMessage([fauxToolCall("hold", {}, { id: "hold-1" }), fauxToolCall("hold", {}, { id: "hold-2" })], {
      stopReason: "toolUse"
    }),
    fauxAssistantMessage("steered")
  ])

  const started = deferred<void>()
  const release = deferred<void>()
  let startedTools = 0
  const { session } = await createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })
  session.setActiveTools([
    {
      name: "hold",
      label: "hold",
      description: "Wait until the test releases the tool",
      parameters: noParameters,
      async execute() {
        startedTools++
        if (startedTools === 2) started.resolve()
        await release.promise
        return { content: [{ type: "text", text: "released" }], details: undefined }
      }
    }
  ])

  const deliveryOrder: string[] = []
  session.subscribe(event => {
    if (event.type === "tool_execution_end") deliveryOrder.push(`tool:${event.toolCallId}`)
    if (event.type === "queue_update") deliveryOrder.push(`queue:${event.steering.length}`)
    if (event.type === "message_start" && event.message.role === "user" && messageText(event.message) === "queued") {
      deliveryOrder.push(`message:${session.queuedInputs.steering.length}`)
    }
  })

  const run = session.prompt("start")
  await started.promise
  session.steer("queued")
  expect(session.queuedInputs.steering.map(entry => entry.text)).toEqual(["queued"])
  expect(session.messages.some(message => message.role === "user" && messageText(message) === "queued")).toBe(false)

  release.resolve()
  await run

  expect(faux.state.callCount).toBe(2)
  expect(deliveryOrder).toEqual(["queue:1", "tool:hold-1", "tool:hold-2", "queue:0", "message:0"])
  expect(session.messages.some(message => message.role === "user" && messageText(message) === "queued")).toBe(true)
  session.dispose()
})

test("default queue modes deliver steering first and one entry per assistant response", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  const requests: string[][] = []
  faux.setResponses([
    fauxAssistantMessage(fauxToolCall("hold", {}, { id: "hold-order" }), { stopReason: "toolUse" }),
    ...Array.from({ length: 4 }, (_, index) => (context: Context) => {
      requests.push(userTexts(context))
      return fauxAssistantMessage(`response-${index}`)
    })
  ])

  const { session } = await createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })
  const hold = installHoldingTool(session)
  const run = session.prompt("start")
  await hold.started.promise
  session.followUp("follow-1")
  session.steer("steer-1")
  session.followUp("follow-2")
  session.steer("steer-2")
  hold.release.resolve()
  await run

  expect(requests.map(texts => texts.at(-1))).toEqual(["steer-1", "steer-2", "follow-1", "follow-2"])
  expect(faux.state.callCount).toBe(5)
  session.dispose()
})

test("all queue modes batch each selected queue while preserving steering priority", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  const requests: string[][] = []
  faux.setResponses([
    fauxAssistantMessage(fauxToolCall("hold", {}, { id: "hold-all" }), { stopReason: "toolUse" }),
    (context: Context) => {
      requests.push(userTexts(context))
      return fauxAssistantMessage("steering batch")
    },
    (context: Context) => {
      requests.push(userTexts(context))
      return fauxAssistantMessage("follow-up batch")
    }
  ])

  const { session } = await createAgentRuntime({
    cwd: "/work",
    models,
    session: { type: "new", persist: false },
    settings: { steeringMode: "all", followUpMode: "all" }
  })
  const hold = installHoldingTool(session)
  const run = session.prompt("start")
  await hold.started.promise
  session.followUp("follow-1")
  session.steer("steer-1")
  session.followUp("follow-2")
  session.steer("steer-2")
  hold.release.resolve()
  await run

  expect(requests).toHaveLength(2)
  expect(requests[0]?.slice(-2)).toEqual(["steer-1", "steer-2"])
  expect(requests[1]?.slice(-2)).toEqual(["follow-1", "follow-2"])
  session.dispose()
})

test("steering mode mutation persists globally and updates live behavior", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-steering-mode-"))
  const cwd = join(root, "project")
  const agentDir = join(root, "global")
  await mkdir(cwd, { recursive: true })
  await mkdir(agentDir, { recursive: true })
  await writeFile(
    join(agentDir, "settings.json"),
    JSON.stringify({ steeringMode: "one-at-a-time", future: { enabled: true } })
  )

  const models = createModels()
  models.setProvider(fauxProvider().provider)
  const { session } = await createAgentRuntime({ cwd, agentDir, models, session: { type: "new", persist: false } })

  expect(session.steeringMode).toBe("one-at-a-time")
  const entriesBefore = session.sessionManager.entries()
  expect(session.setSteeringMode("all", "global")).toEqual({ scope: "global", requested: "all", effective: "all" })
  expect(session.steeringMode).toBe("all")
  expect(JSON.parse(await readFile(join(agentDir, "settings.json"), "utf8"))).toEqual({
    steeringMode: "all",
    future: { enabled: true }
  })
  expect(session.sessionManager.entries()).toEqual(entriesBefore)
  session.dispose()
})

test("follow-up mode mutation persists project scope and updates live behavior", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-follow-up-mode-"))
  const cwd = join(root, "project")
  const agentDir = join(root, "global")
  const projectDir = join(cwd, ".zi")
  await mkdir(projectDir, { recursive: true })
  await mkdir(agentDir, { recursive: true })
  await writeFile(join(projectDir, "settings.json"), JSON.stringify({ futureProject: 1 }))

  const models = createModels()
  models.setProvider(fauxProvider().provider)
  const { session } = await createAgentRuntime({ cwd, agentDir, models, session: { type: "new", persist: false } })

  expect(session.followUpMode).toBe("one-at-a-time")
  expect(session.setFollowUpMode("all", "project")).toEqual({ scope: "project", requested: "all", effective: "all" })
  expect(session.followUpMode).toBe("all")
  expect(JSON.parse(await readFile(join(projectDir, "settings.json"), "utf8"))).toEqual({
    futureProject: 1,
    followUpMode: "all"
  })
  session.dispose()
})

test("queue mode events publish only effective layered changes", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-shadowed-mode-"))
  const cwd = join(root, "project")
  const agentDir = join(root, "global")
  const projectDir = join(cwd, ".zi")
  await mkdir(projectDir, { recursive: true })
  await mkdir(agentDir, { recursive: true })
  await writeFile(join(agentDir, "settings.json"), JSON.stringify({ steeringMode: "one-at-a-time" }))
  await writeFile(join(projectDir, "settings.json"), JSON.stringify({ steeringMode: "all" }))

  const models = createModels()
  models.setProvider(fauxProvider().provider)
  const { session } = await createAgentRuntime({ cwd, agentDir, models, session: { type: "new", persist: false } })
  const changes: string[] = []
  session.subscribe(event => {
    if (event.type === "steering_mode_changed") changes.push(event.mode)
  })

  expect(session.setSteeringMode("all", "global")).toEqual({ scope: "global", requested: "all", effective: "all" })
  expect(changes).toEqual([])
  expect(session.setSteeringMode("one-at-a-time", "project").effective).toBe("one-at-a-time")
  expect(session.steeringMode).toBe("one-at-a-time")
  expect(changes).toEqual(["one-at-a-time"])
  session.dispose()
})

test("subscriber failure cannot roll back a committed follow-up mode change", async () => {
  const models = createModels()
  models.setProvider(fauxProvider().provider)
  const { session } = await createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })
  let calls = 0
  session.subscribe(event => {
    if (event.type !== "follow_up_mode_changed") return
    calls++
    throw new Error("observer failed")
  })

  expect(() => session.setFollowUpMode("all", "global")).not.toThrow()
  expect(calls).toBe(1)
  expect(session.followUpMode).toBe("all")
  expect(session.settingsManager.get().followUpMode).toBe("all")
  session.dispose()
})

test("queue mode mutations reject unknown scopes without changing live state", async () => {
  const models = createModels()
  models.setProvider(fauxProvider().provider)
  const { session } = await createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })

  // oxlint-disable-next-line typescript/unbound-method -- Reflect models an untyped JavaScript SDK caller.
  expect(() => Reflect.apply(session.setSteeringMode, session, ["all", "workspace"])).toThrow(
    "Invalid settings scope: workspace"
  )
  expect(session.steeringMode).toBe("one-at-a-time")
  expect(session.settingsManager.get().steeringMode).toBe("one-at-a-time")
  session.dispose()
})

test("queue mode mutations reject unknown modes without changing settings", async () => {
  const models = createModels()
  models.setProvider(fauxProvider().provider)
  const { session } = await createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })

  // oxlint-disable-next-line typescript/unbound-method -- Reflect models an untyped JavaScript SDK caller.
  expect(() => Reflect.apply(session.setFollowUpMode, session, ["grouped", "global"])).toThrow(
    "Invalid queue mode: grouped"
  )
  expect(session.followUpMode).toBe("one-at-a-time")
  expect(session.settingsManager.get().followUpMode).toBe("one-at-a-time")
  session.dispose()
})

test("settings persistence failure leaves live queue modes unchanged", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-invalid-queue-mode-"))
  const cwd = join(root, "project")
  const agentDir = join(root, "global")
  const projectDir = join(cwd, ".zi")
  await mkdir(projectDir, { recursive: true })
  await writeFile(join(projectDir, "settings.json"), JSON.stringify({ followUpMode: "grouped" }))

  const models = createModels()
  models.setProvider(fauxProvider().provider)
  const { session } = await createAgentRuntime({ cwd, agentDir, models, session: { type: "new", persist: false } })
  let changes = 0
  session.subscribe(event => {
    if (event.type === "follow_up_mode_changed") changes++
  })

  expect(() => session.setFollowUpMode("all", "project")).toThrow("Cannot update invalid project settings")
  expect(session.followUpMode).toBe("one-at-a-time")
  expect(session.settingsManager.get().followUpMode).toBe("one-at-a-time")
  expect(changes).toBe(0)
  session.dispose()
})

test("recreated runtimes restore persisted queue modes", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-restored-queue-mode-"))
  const cwd = join(root, "project")
  const agentDir = join(root, "global")
  await mkdir(cwd, { recursive: true })

  const firstModels = createModels()
  firstModels.setProvider(fauxProvider().provider)
  const first = await createAgentRuntime({
    cwd,
    agentDir,
    models: firstModels,
    session: { type: "new", persist: false }
  })
  first.session.setSteeringMode("all", "global")
  first.session.setFollowUpMode("all", "project")
  first.session.dispose()

  const secondModels = createModels()
  secondModels.setProvider(fauxProvider().provider)
  const second = await createAgentRuntime({
    cwd,
    agentDir,
    models: secondModels,
    session: { type: "new", persist: false }
  })
  expect(second.session.steeringMode).toBe("all")
  expect(second.session.followUpMode).toBe("all")
  second.session.dispose()
})

test("queue mode mutations during a run control the next eligible drains", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  const requests: string[][] = []
  faux.setResponses([
    fauxAssistantMessage(fauxToolCall("hold", {}, { id: "hold-mode-change" }), { stopReason: "toolUse" }),
    (context: Context) => {
      requests.push(userTexts(context))
      return fauxAssistantMessage("steering batch")
    },
    (context: Context) => {
      requests.push(userTexts(context))
      return fauxAssistantMessage("follow-up batch")
    }
  ])

  const { session } = await createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })
  const hold = installHoldingTool(session)
  const run = session.prompt("start")
  await hold.started.promise
  session.steer("steer-1")
  session.steer("steer-2")
  session.followUp("follow-1")
  session.followUp("follow-2")
  session.setSteeringMode("all", "global")
  session.setFollowUpMode("all", "global")
  hold.release.resolve()
  await run

  expect(requests).toHaveLength(2)
  expect(requests[0]?.slice(-2)).toEqual(["steer-1", "steer-2"])
  expect(requests[1]?.slice(-2)).toEqual(["follow-1", "follow-2"])
  session.dispose()
})

test("same-text entries retain identity, images, and grouped dequeue order", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  faux.setResponses([
    fauxAssistantMessage(fauxToolCall("hold", {}, { id: "hold-identity" }), { stopReason: "toolUse" }),
    fauxAssistantMessage("done")
  ])
  const { session } = await createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })
  const hold = installHoldingTool(session)
  const firstImage: ImageContent = { type: "image", mimeType: "image/png", data: "AAAA" }
  const secondImage: ImageContent = { type: "image", mimeType: "image/jpeg", data: "BBBB" }
  const run = session.prompt("start")
  await hold.started.promise
  session.followUp("same", [firstImage])
  session.steer("same", [secondImage])
  session.steer("same", [firstImage])

  const before = session.queuedInputs
  expect(new Set([...before.steering, ...before.followUp].map(entry => entry.id)).size).toBe(3)
  expect(before.steering.map(entry => entry.images[0]?.mimeType)).toEqual(["image/jpeg", "image/png"])
  const taken = session.takeQueuedInputs()
  expect(taken.steering.map(entry => entry.text)).toEqual(["same", "same"])
  expect(taken.followUp.map(entry => entry.text)).toEqual(["same"])
  expect(taken.followUp[0]?.images).toEqual([firstImage])

  hold.release.resolve()
  await run
  expect(faux.state.callCount).toBe(2)
  expect(userTextsFromMessages(session.messages)).toEqual(["start"])
  session.dispose()
})

test("delivery commits the exact entry before a concurrent clear detaches the remainder", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  faux.setResponses([
    fauxAssistantMessage(fauxToolCall("hold", {}, { id: "hold-boundary" }), { stopReason: "toolUse" }),
    fauxAssistantMessage("done")
  ])
  const { session } = await createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })
  const hold = installHoldingTool(session)
  let takenAtDelivery: ReturnType<AgentSession["takeQueuedInputs"]> | undefined
  session.subscribe(event => {
    if (event.type === "message_start" && event.message.role === "user" && messageText(event.message) === "committed") {
      takenAtDelivery = session.takeQueuedInputs()
    }
  })

  const run = session.prompt("start")
  await hold.started.promise
  session.followUp("remaining")
  session.steer("committed")
  hold.release.resolve()
  await run

  expect(takenAtDelivery?.steering).toHaveLength(0)
  expect(takenAtDelivery?.followUp.map(entry => entry.text)).toEqual(["remaining"])
  expect(userTextsFromMessages(session.messages)).toEqual(["start", "committed"])
  session.dispose()
})

test("queue bounds are aggregate, exact, and reject without mutation or events", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  const response = deferred<ReturnType<typeof fauxAssistantMessage>>()
  const providerStarted = deferred<void>()
  faux.setResponses([
    async () => {
      providerStarted.resolve()
      return response.promise
    }
  ])
  const { session } = await createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })
  let updates = 0
  session.subscribe(event => {
    if (event.type === "queue_update") updates++
  })
  const run = session.prompt("start")
  await providerStarted.promise

  for (let index = 0; index < maxPendingInputCount; index++) {
    if (index % 2 === 0) session.steer(`message-${index}`)
    else session.followUp(`message-${index}`)
  }
  expect(session.queuedInputs.steering.length + session.queuedInputs.followUp.length).toBe(maxPendingInputCount)
  expect(() => session.steer("overflow")).toThrow(QueueCapacityError)
  expect(updates).toBe(maxPendingInputCount)
  expect(session.queuedInputs.steering.length + session.queuedInputs.followUp.length).toBe(maxPendingInputCount)

  session.takeQueuedInputs()
  const exactText = "界".repeat(Math.floor(maxPendingInputBytes / 3)) + "aa"
  expect(Buffer.byteLength(exactText)).toBe(maxPendingInputBytes)
  session.followUp(exactText)
  expect(session.queuedInputs.followUp[0]?.bytes).toBe(maxPendingInputBytes)
  expect(() => session.steer("x")).toThrow(QueueCapacityError)
  expect(session.queuedInputs.followUp).toHaveLength(1)

  session.takeQueuedInputs()
  expect(() => session.followUp(`${exactText}x`)).toThrow(QueueCapacityError)
  expect(session.queuedInputs.followUp).toHaveLength(0)
  response.resolve(fauxAssistantMessage("done"))
  await run
  session.dispose()
})

test("queue operations enforce activity transitions and Escape abort shares settlement", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  const response = deferred<ReturnType<typeof fauxAssistantMessage>>()
  const providerStarted = deferred<void>()
  faux.setResponses([
    async () => {
      providerStarted.resolve()
      return response.promise
    }
  ])
  const { session } = await createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })
  session.steer("idle")
  expect(session.takeQueuedInputs().steering.map(entry => entry.text)).toEqual(["idle"])
  const run = session.prompt("start")
  await providerStarted.promise
  expect(() => session.prompt("missing mode")).toThrow("streamingBehavior is required")
  session.steer("restore me")
  const firstAbort = session.takeQueuedInputsAndAbort()
  const secondAbort = session.takeQueuedInputsAndAbort()
  expect(firstAbort.steering.map(entry => entry.text)).toEqual(["restore me"])
  expect(secondAbort.settled).toBe(firstAbort.settled)
  expect(() => session.followUp("too late")).toThrow("Cannot queue input while the agent is aborting")
  response.resolve(fauxAssistantMessage("aborted", { stopReason: "aborted" }))
  await firstAbort.settled
  await run
  expect(session.isStreaming).toBe(false)

  session.dispose()
  expect(() => session.prompt("disposed")).toThrow("AgentSession is disposed")
  expect(() => session.takeQueuedInputs()).toThrow("AgentSession is disposed")
  expect(() => session.setSteeringMode("all", "global")).toThrow("AgentSession is disposed")
  expect(() => session.setFollowUpMode("all", "project")).toThrow("AgentSession is disposed")
})

test("queue detachment is published before abort reaches the active provider", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  const providerStarted = deferred<void>()
  const release = deferred<void>()
  const order: string[] = []
  faux.setResponses([
    async (_context, options) => {
      options?.signal?.addEventListener("abort", () => order.push("abort"), { once: true })
      providerStarted.resolve()
      await release.promise
      return fauxAssistantMessage("aborted", { stopReason: "aborted" })
    }
  ])
  const { session } = await createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })
  session.subscribe(event => {
    if (event.type === "queue_update") order.push(`queue:${event.steering.length + event.followUp.length}`)
  })
  const run = session.prompt("start")
  await providerStarted.promise
  session.steer("queued")
  order.length = 0

  const aborted = session.takeQueuedInputsAndAbort()
  expect(order).toEqual(["queue:0", "abort"])
  expect(aborted.steering.map(entry => entry.text)).toEqual(["queued"])
  release.resolve()
  await aborted.settled
  await run
  expect(userTextsFromMessages(session.messages)).toEqual(["start"])
  session.dispose()
})

test("waitForIdle captures its run when an agent-settled listener starts the next run", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  const firstStarted = deferred<void>()
  const firstRelease = deferred<void>()
  const secondStarted = deferred<void>()
  const secondRelease = deferred<void>()
  faux.setResponses([
    async () => {
      firstStarted.resolve()
      await firstRelease.promise
      return fauxAssistantMessage("first done")
    },
    async () => {
      secondStarted.resolve()
      await secondRelease.promise
      return fauxAssistantMessage("second done")
    }
  ])
  const { session } = await createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })
  let secondRun: Promise<void> | undefined
  session.subscribe(event => {
    if (event.type === "agent_settled" && !secondRun) secondRun = session.prompt("second")
  })

  const firstRun = session.prompt("first")
  await firstStarted.promise
  const capturedFirstRun = session.waitForIdle()
  firstRelease.resolve()
  await capturedFirstRun
  await firstRun
  await secondStarted.promise
  expect(session.isStreaming).toBe(true)
  secondRelease.resolve()
  await secondRun
  expect(session.isStreaming).toBe(false)
  session.dispose()
})

test("agent-end admission and provider errors continue within one logical run", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  const firstResponse = deferred<ReturnType<typeof fauxAssistantMessage>>()
  const providerStarted = deferred<void>()
  faux.setResponses([
    async () => {
      providerStarted.resolve()
      return firstResponse.promise
    },
    fauxAssistantMessage("after error"),
    fauxAssistantMessage("late continuation")
  ])
  const { session } = await createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })
  let admittedLate = false
  let settled = 0
  session.subscribe(event => {
    if (event.type === "agent_end" && faux.state.callCount === 2 && !admittedLate) {
      admittedLate = true
      session.followUp("from agent end")
    }
    if (event.type === "agent_settled") settled++
  })

  const run = session.prompt("start")
  await providerStarted.promise
  session.followUp("survive error")
  firstResponse.resolve(fauxAssistantMessage("failed", { stopReason: "error", errorMessage: "provider failed" }))
  await run

  expect(faux.state.callCount).toBe(3)
  expect(userTextsFromMessages(session.messages)).toEqual(["start", "survive error", "from agent end"])
  expect(settled).toBe(1)
  session.dispose()
})

test("idle inputs queue for the next run and survive public abort", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  const requests: string[][] = []
  faux.setResponses([
    (context: Context) => {
      requests.push(userTexts(context))
      return fauxAssistantMessage("first")
    },
    (context: Context) => {
      requests.push(userTexts(context))
      return fauxAssistantMessage("second")
    }
  ])
  const { session } = await createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })

  session.steer("before prompt")
  session.followUp("after turn")
  await session.abort()
  expect(session.queuedInputs.steering.map(entry => entry.text)).toEqual(["before prompt"])
  expect(session.queuedInputs.followUp.map(entry => entry.text)).toEqual(["after turn"])

  await session.prompt("start")

  expect(requests.map(texts => texts.at(-1))).toEqual(["before prompt", "after turn"])
  expect(userTextsFromMessages(session.messages)).toEqual(["start", "before prompt", "after turn"])
  expect("state" in session).toBe(false)
  session.dispose()
})

test("public abort preserves queued work and continues it after the aborted core run", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  const providerStarted = deferred<void>()
  faux.setResponses([
    async (_context, options) => {
      providerStarted.resolve()
      await new Promise<void>(resolve => {
        if (options?.signal?.aborted) resolve()
        else options?.signal?.addEventListener("abort", () => resolve(), { once: true })
      })
      return fauxAssistantMessage("aborted", { stopReason: "aborted" })
    },
    fauxAssistantMessage("continued")
  ])
  const { session } = await createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })
  const run = session.prompt("start")
  await providerStarted.promise
  session.followUp("preserve me")

  const aborted = session.abort()
  expect(session.isAborting).toBe(false)
  expect(session.queuedInputs.followUp.map(entry => entry.text)).toEqual(["preserve me"])
  await aborted
  await run

  expect(faux.state.callCount).toBe(2)
  expect(userTextsFromMessages(session.messages)).toEqual(["start", "preserve me"])
  expect(session.queuedInputs.followUp).toHaveLength(0)
  session.dispose()
})

test("shutdown abort discards queued work before cancelling the active run", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  const providerStarted = deferred<void>()
  faux.setResponses([
    async (_context, options) => {
      providerStarted.resolve()
      await new Promise<void>(resolve => {
        if (options?.signal?.aborted) resolve()
        else options?.signal?.addEventListener("abort", () => resolve(), { once: true })
      })
      return fauxAssistantMessage("aborted", { stopReason: "aborted" })
    },
    fauxAssistantMessage("must not continue")
  ])
  const { session } = await createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })
  const run = session.prompt("start")
  await providerStarted.promise
  session.followUp("discard me")

  const stopped = session.abortAndDiscardQueuedInputs()
  expect(session.queuedInputs.followUp).toHaveLength(0)
  expect(session.isAborting).toBe(true)
  await stopped
  await run

  expect(faux.state.callCount).toBe(1)
  expect(userTextsFromMessages(session.messages)).toEqual(["start"])
  session.dispose()
})

test("subscriber failures reject their operation without stranding session settlement", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  faux.setResponses([fauxAssistantMessage("first"), fauxAssistantMessage("second")])
  const { session } = await createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })
  let settledEvents = 0
  const unsubscribeQueueFailure = session.subscribe(event => {
    if (event.type === "queue_update") throw new Error("queue listener failed")
  })
  expect(() => session.steer("queued before prompt")).toThrow("queue listener failed")
  expect(session.queuedInputs.steering.map(entry => entry.text)).toEqual(["queued before prompt"])
  unsubscribeQueueFailure()

  const unsubscribeSettlementFailure = session.subscribe(event => {
    if (event.type === "agent_settled") throw new Error("settled listener failed")
  })
  session.subscribe(event => {
    if (event.type === "agent_settled") settledEvents++
  })
  const firstRun = session.prompt("first")
  expect((await rejection(firstRun)).message).toContain("settled listener failed")
  expect(session.isStreaming).toBe(false)
  expect(settledEvents).toBe(1)

  unsubscribeSettlementFailure()
  await session.prompt("second")
  expect(settledEvents).toBe(2)
  expect(session.isStreaming).toBe(false)
  session.dispose()
})

test("a failed run detaches the core queue and requires explicit recovery before reprompting", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  const providerStarted = deferred<void>()
  const firstResponse = deferred<ReturnType<typeof fauxAssistantMessage>>()
  const requests: string[][] = []
  faux.setResponses([
    async () => {
      providerStarted.resolve()
      return firstResponse.promise
    },
    (context: Context) => {
      requests.push(userTexts(context))
      return fauxAssistantMessage("fresh response")
    }
  ])
  const { session } = await createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })
  const appendMessage = session.sessionManager.appendMessage.bind(session.sessionManager)
  let failPersistence = false
  session.sessionManager.appendMessage = message => {
    if (failPersistence) throw new Error("persistence failed")
    return appendMessage(message)
  }

  const failedRun = session.prompt("first")
  await providerStarted.promise
  session.steer("stale queued")
  failPersistence = true
  firstResponse.resolve(fauxAssistantMessage("cannot persist"))
  expect((await rejection(failedRun)).message).toContain("persistence failed")

  expect(session.queuedInputs.steering.map(entry => entry.text)).toEqual(["stale queued"])
  expect(() => session.prompt("second fresh")).toThrow("Restore or discard queued inputs")
  failPersistence = false
  const recovered = session.takeQueuedInputs()
  expect(recovered.steering.map(entry => entry.text)).toEqual(["stale queued"])

  await session.prompt("second fresh")
  expect(requests).toEqual([["first", "second fresh"]])
  expect(userTextsFromMessages(session.messages)).not.toContain("stale queued")
  expect(session.queuedInputs.steering).toHaveLength(0)
  session.dispose()
})

test("same-text delivery acknowledges only the committed identity", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  faux.setResponses([
    fauxAssistantMessage(fauxToolCall("hold", {}, { id: "hold-duplicate-boundary" }), { stopReason: "toolUse" }),
    fauxAssistantMessage("done")
  ])
  const { session } = await createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })
  const hold = installHoldingTool(session)
  const steeringImage: ImageContent = { type: "image", mimeType: "image/jpeg", data: "steering" }
  const followUpImage: ImageContent = { type: "image", mimeType: "image/png", data: "follow-up" }
  let takenAtDelivery: ReturnType<AgentSession["takeQueuedInputs"]> | undefined
  session.subscribe(event => {
    if (event.type === "message_start" && event.message.role === "user" && messageText(event.message) === "same") {
      takenAtDelivery = session.takeQueuedInputs()
    }
  })

  const run = session.prompt("start")
  await hold.started.promise
  session.followUp("same", [followUpImage])
  session.steer("same", [steeringImage])
  const identities = session.queuedInputs
  expect(identities.steering[0]?.id).not.toBe(identities.followUp[0]?.id)
  hold.release.resolve()
  await run

  expect(takenAtDelivery?.steering).toHaveLength(0)
  expect(takenAtDelivery?.followUp[0]?.images).toEqual([followUpImage])
  expect(userTextsFromMessages(session.messages)).toEqual(["start", "same"])
  session.dispose()
})

test("Escape abort at queued message commit returns only the undelivered remainder", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  faux.setResponses([
    fauxAssistantMessage(fauxToolCall("hold", {}, { id: "hold-abort-boundary" }), { stopReason: "toolUse" }),
    fauxAssistantMessage("aborted", { stopReason: "aborted" })
  ])
  const { session } = await createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })
  const hold = installHoldingTool(session)
  let aborted: ReturnType<AgentSession["takeQueuedInputsAndAbort"]> | undefined
  let settlements = 0
  session.subscribe(event => {
    if (event.type === "message_start" && event.message.role === "user" && messageText(event.message) === "committed") {
      aborted = session.takeQueuedInputsAndAbort()
    }
    if (event.type === "agent_settled") settlements++
  })

  const run = session.prompt("start")
  await hold.started.promise
  session.followUp("remaining follow-up")
  session.steer("committed")
  session.steer("remaining steering")
  hold.release.resolve()
  await run
  if (!aborted) throw new Error("Queued message did not reach the commit boundary")
  await aborted.settled

  expect(aborted.steering.map(entry => entry.text)).toEqual(["remaining steering"])
  expect(aborted.followUp.map(entry => entry.text)).toEqual(["remaining follow-up"])
  expect(userTextsFromMessages(session.messages)).toEqual(["start", "committed"])
  expect(settlements).toBe(1)
  session.dispose()
})

test("delivery acknowledgement reclaims queue count capacity", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  faux.setResponses([
    fauxAssistantMessage(fauxToolCall("hold", {}, { id: "hold-count-reclaim" }), { stopReason: "toolUse" }),
    fauxAssistantMessage("done")
  ])
  const { session } = await createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })
  const hold = installHoldingTool(session)
  let remainder: ReturnType<AgentSession["takeQueuedInputs"]> | undefined
  session.subscribe(event => {
    if (event.type === "message_start" && event.message.role === "user" && messageText(event.message) === "message-0") {
      session.steer("replacement")
      remainder = session.takeQueuedInputs()
    }
  })

  const run = session.prompt("start")
  await hold.started.promise
  for (let index = 0; index < maxPendingInputCount; index++) session.steer(`message-${index}`)
  hold.release.resolve()
  await run

  expect(remainder?.steering).toHaveLength(maxPendingInputCount)
  expect(remainder?.steering.at(-1)?.text).toBe("replacement")
  session.dispose()
})

test("delivery acknowledgement reclaims UTF-8 byte capacity", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  faux.setResponses([
    fauxAssistantMessage(fauxToolCall("hold", {}, { id: "hold-byte-reclaim" }), { stopReason: "toolUse" }),
    fauxAssistantMessage("done")
  ])
  const { session } = await createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })
  const hold = installHoldingTool(session)
  const exactText = "界".repeat(Math.floor(maxPendingInputBytes / 3)) + "aa"
  let replacement: ReturnType<AgentSession["takeQueuedInputs"]> | undefined
  session.subscribe(event => {
    if (event.type === "message_start" && event.message.role === "user" && messageText(event.message) === exactText) {
      session.followUp(exactText)
      replacement = session.takeQueuedInputs()
    }
  })

  const run = session.prompt("start")
  await hold.started.promise
  session.steer(exactText)
  hold.release.resolve()
  await run

  expect(replacement?.followUp[0]?.bytes).toBe(maxPendingInputBytes)
  session.dispose()
})

function messageText(message: { role: string; content?: unknown }): string {
  if (message.role !== "user") return ""
  if (typeof message.content === "string") return message.content
  if (!Array.isArray(message.content)) return ""
  return message.content
    .flatMap(part => {
      if (typeof part !== "object" || part === null) return []
      if (!("type" in part) || part.type !== "text" || !("text" in part) || typeof part.text !== "string") return []
      return part.text
    })
    .join("\n")
}

function userTexts(context: Context): string[] {
  return context.messages.filter(message => message.role === "user").map(message => messageText(message))
}

function userTextsFromMessages(messages: readonly { role: string; content?: unknown }[]): string[] {
  return messages.filter(message => message.role === "user").map(message => messageText(message))
}

function installHoldingTool(session: Pick<AgentSession, "setActiveTools">) {
  const started = deferred<void>()
  const release = deferred<void>()
  session.setActiveTools([
    {
      name: "hold",
      label: "hold",
      description: "Wait until the test releases the tool",
      parameters: noParameters,
      async execute() {
        started.resolve()
        await release.promise
        return { content: [{ type: "text" as const, text: "released" }], details: undefined }
      }
    }
  ])
  return { started, release }
}

async function rejection(promise: Promise<unknown>): Promise<Error> {
  try {
    await promise
  } catch (cause) {
    if (cause instanceof Error) return cause
    throw new Error(`Promise rejected with a non-Error value: ${String(cause)}`, { cause })
  }
  throw new Error("Expected promise to reject")
}

function deferred<T>() {
  let resolve!: (value: T | PromiseLike<T>) => void
  let reject!: (reason?: unknown) => void
  const promise = new Promise<T>((resolvePromise, rejectPromise) => {
    resolve = resolvePromise
    reject = rejectPromise
  })
  return { promise, resolve, reject }
}
