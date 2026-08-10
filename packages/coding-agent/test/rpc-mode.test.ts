import { expect, test } from "bun:test"

import { isRecord } from "../src/guards.js"
import { runRpcMode, type RpcMessagePage, type RpcServerFrame } from "../src/rpc/rpc-mode.js"
import {
  createModels,
  createTestAgentRuntime,
  fauxAssistantMessage,
  fauxProvider,
  fauxToolCall
} from "../src/testing.js"

test("depth-one RPC sessions relay correlated peer requests through the parent connection", async () => {
  const models = createModels()
  const faux = fauxProvider({ provider: "rpc", models: [{ id: "model", name: "RPC Model", reasoning: true }] })
  models.setProvider(faux.provider)
  faux.setResponses([
    fauxAssistantMessage(fauxToolCall("list_peer_subagents", {}, { id: "list-peers" }), { stopReason: "toolUse" }),
    fauxAssistantMessage(
      fauxToolCall("send_peer_message", { name: "worker-b", text: "Use the parser result." }, { id: "send-peer" }),
      { stopReason: "toolUse" }
    ),
    fauxAssistantMessage("peer coordination complete")
  ])
  const runtime = await createTestAgentRuntime({
    cwd: "/work",
    model: "rpc/model",
    apiKey: "test",
    models,
    internalSubagentDepth: 1,
    session: { type: "new", persist: false }
  })
  const input = new RpcTestInput()
  const output = new RpcTestOutput()
  const running = runRpcMode(runtime.session, { input, writer: output })

  try {
    await output.frame(frame => frame.type === "ready")
    input.send({
      version: 1,
      id: "prompt",
      method: "session.prompt",
      params: { delivery: "direct", text: "coordinate", completionId: "work-1" }
    })
    await output.response("prompt")

    const list = await output.frame(
      (frame): frame is Extract<RpcServerFrame, { type: "peer_request" }> =>
        frame.type === "peer_request" && frame.operation === "list"
    )
    input.send({
      version: 1,
      type: "peer_response",
      id: list.id,
      operation: "list",
      ok: true,
      result: { peers: [{ name: "worker-b", lifecycle: "running" }] }
    })

    const send = await output.frame(
      (frame): frame is Extract<RpcServerFrame, { type: "peer_request" }> =>
        frame.type === "peer_request" && frame.operation === "send"
    )
    expect(send).toMatchObject({ target: "worker-b", text: "Use the parser result." })
    expect(send).not.toHaveProperty("sender")
    input.send({
      version: 1,
      type: "peer_response",
      id: send.id,
      operation: "send",
      ok: true,
      result: { delivered: true }
    })
    input.send({ version: 1, id: "idle", method: "session.await_idle", params: { completionId: "work-1" } })
    expect(await output.response("idle")).toMatchObject({
      ok: true,
      result: { completion: { text: "peer coordination complete" } }
    })
  } finally {
    input.close()
    await running
    runtime.session.dispose()
    await runtime.session.waitForIdle()
  }
}, 15_000)

test("queue-only RPC delivery remains pending without waking an idle child session", async () => {
  const models = createModels()
  const runtime = await createTestAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })
  const input = new RpcTestInput()
  const output = new RpcTestOutput()
  const running = runRpcMode(runtime.session, { input, writer: output })

  try {
    await output.frame(frame => frame.type === "ready")
    input.send({
      version: 1,
      id: "peer-context",
      method: "session.prompt",
      params: { delivery: "follow_up", text: "[Peer message from worker-a]\ncontext" }
    })
    expect(await output.response("peer-context")).toMatchObject({ ok: true, result: { delivery: "follow_up" } })
    input.send({ version: 1, id: "state", method: "session.get_state" })
    expect(await output.response("state")).toMatchObject({
      ok: true,
      result: {
        activity: { type: "idle" },
        queuedInputs: { followUp: [{ text: "[Peer message from worker-a]\ncontext" }] }
      }
    })
  } finally {
    input.close()
    await running
    runtime.session.dispose()
    await runtime.session.waitForIdle()
  }
})

test("RPC mode projects work plan state and its ordered durable events", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  faux.setResponses([
    fauxAssistantMessage(
      fauxToolCall("update_plan", { steps: [{ text: "Verify RPC", status: "in_progress" }] }, { id: "rpc-plan" }),
      { stopReason: "toolUse" }
    ),
    fauxAssistantMessage("Plan visible.")
  ])
  const runtime = await createTestAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })
  const input = new RpcTestInput()
  const output = new RpcTestOutput()
  const running = runRpcMode(runtime.session, { input, writer: output })

  try {
    await output.frame(frame => frame.type === "ready")
    input.send({
      version: 1,
      id: "prompt-plan",
      method: "session.prompt",
      params: { delivery: "direct", text: "Plan the RPC test.", completionId: "rpc-plan-cycle" }
    })
    await output.response("prompt-plan")
    input.send({
      version: 1,
      id: "idle-plan",
      method: "session.await_idle",
      params: { completionId: "rpc-plan-cycle" }
    })
    await output.response("idle-plan")

    const workEvents = output.frames.filter(
      (frame): frame is Extract<RpcServerFrame, { type: "session_event" }> =>
        frame.type === "session_event" &&
        (frame.event.type === "work_plan_changed" ||
          (frame.event.type === "entry_appended" && frame.event.entry.type === "work_plan"))
    )
    expect(workEvents.map(frame => frame.event.type)).toEqual(["entry_appended", "work_plan_changed"])
    expect(workEvents[1]).toMatchObject({
      event: {
        type: "work_plan_changed",
        plan: { revision: 1, steps: [{ text: "Verify RPC", status: "in_progress" }] }
      }
    })

    input.send({ version: 1, id: "state-plan", method: "session.get_state" })
    expect(await output.response("state-plan")).toMatchObject({
      ok: true,
      result: { workPlan: { revision: 1, steps: [{ text: "Verify RPC", status: "in_progress" }] } }
    })
  } finally {
    input.close()
    await running
    runtime.session.dispose()
    await runtime.session.waitForIdle()
  }
})

test("RPC mode sequences authoritative events, concurrent interruption, and paged session state", async () => {
  const models = createModels()
  const faux = fauxProvider({ provider: "rpc", models: [{ id: "model", name: "RPC Model", reasoning: true }] })
  models.setProvider(faux.provider)
  const providerStarted = deferred<void>()
  faux.setResponses([
    async (_context, request) => {
      providerStarted.resolve()
      await new Promise<void>(resolve => request?.signal?.addEventListener("abort", () => resolve(), { once: true }))
      return fauxAssistantMessage("interrupted", { stopReason: "aborted" })
    }
  ])
  const runtime = await createTestAgentRuntime({
    cwd: "/work",
    model: "rpc/model",
    apiKey: "test",
    models,
    session: { type: "new", persist: false }
  })
  const input = new RpcTestInput()
  const output = new RpcTestOutput()
  const running = runRpcMode(runtime.session, { input, writer: output })

  try {
    const ready = await output.frame(frame => frame.type === "ready")
    expect(ready).toMatchObject({
      version: 1,
      sequence: 1,
      type: "ready",
      state: {
        sessionId: runtime.session.sessionId,
        activity: { type: "idle" },
        workPlan: { revision: 0, steps: [] },
        model: { type: "selected", model: { provider: "rpc", id: "model", name: "RPC Model" } }
      }
    })
    expect(JSON.stringify(ready)).not.toContain("baseUrl")

    input.send({
      version: 1,
      id: "prompt",
      method: "session.prompt",
      params: { delivery: "direct", text: "start", completionId: "work-1" }
    })
    await providerStarted.promise
    await output.response("prompt")

    input.send(
      {
        version: 1,
        id: "steer",
        method: "session.prompt",
        params: { delivery: "steer", text: "steer", completionId: "work-1" }
      },
      {
        version: 1,
        id: "follow",
        method: "session.prompt",
        params: { delivery: "follow_up", text: "follow", completionId: "work-1" }
      }
    )
    expect((await output.response("steer")).ok).toBe(true)
    expect((await output.response("follow")).ok).toBe(true)

    input.send(
      { version: 1, id: "idle", method: "session.await_idle", params: { completionId: "work-1" } },
      { version: 1, id: "interrupt", method: "session.interrupt" }
    )
    expect((await output.response("interrupt")).ok).toBe(true)
    expect(await output.response("idle")).toMatchObject({
      ok: true,
      result: {
        completionRevision: 3,
        messageCount: expect.any(Number),
        completion: {
          text: expect.any(String),
          stopReason: expect.any(String),
          originalBytes: expect.any(Number),
          omittedBytes: expect.any(Number)
        }
      }
    })

    input.send({ version: 1, id: "state", method: "session.get_state" })
    const state = await output.response("state")
    expect(state).toMatchObject({
      ok: true,
      result: { activity: { type: "idle" }, queuedInputs: { steering: [], followUp: [] } }
    })

    input.send({ version: 1, id: "messages", method: "session.get_messages", params: { start: 0, limit: 100 } })
    const page = await output.response("messages")
    expect(page).toMatchObject({
      ok: true,
      result: { start: 0, total: runtime.session.messages.length, nextStart: null }
    })
    if (!page.ok || !isMessagePage(page.result)) throw new Error("Expected message page")
    expect(page.result.messages.map(message => message.role)).toContain("user")
    expect(page.result.messages.map(message => message.role)).toContain("assistant")

    input.close()
    expect(await running).toEqual({ type: "eof" })
    expect(runtime.session.queuedInputs).toEqual({ steering: [], followUp: [] })

    const sequences = output.frames.map(frame => frame.sequence)
    expect(sequences).toEqual(sequences.map((_, index) => index + 1))
    expect(output.frames).toContainEqual(
      expect.objectContaining({ type: "session_event", event: expect.objectContaining({ type: "agent_settled" }) })
    )
  } finally {
    input.close()
    runtime.session.dispose()
    await runtime.session.waitForIdle()
  }
})

test("RPC completion watches return bounded terminal evidence with the admitted revision", async () => {
  const models = createModels()
  const faux = fauxProvider({ provider: "rpc", models: [{ id: "model", name: "RPC Model", reasoning: false }] })
  models.setProvider(faux.provider)
  const fullCompletion = "x".repeat(60 * 1024)
  const secondStarted = deferred<void>()
  const finishSecond = deferred<void>()
  faux.setResponses([
    fauxAssistantMessage(fullCompletion),
    async () => {
      secondStarted.resolve()
      await finishSecond.promise
      return fauxAssistantMessage("second completion")
    },
    fauxAssistantMessage("untracked completion")
  ])
  const runtime = await createTestAgentRuntime({
    cwd: "/work",
    model: "rpc/model",
    apiKey: "test",
    models,
    session: { type: "new", persist: false }
  })
  const input = new RpcTestInput()
  const output = new RpcTestOutput()
  const running = runRpcMode(runtime.session, { input, writer: output })

  try {
    await output.frame(frame => frame.type === "ready")
    input.send({
      version: 1,
      id: "prompt",
      method: "session.prompt",
      params: { delivery: "direct", text: "start", completionId: "cycle-1" }
    })
    expect(await output.response("prompt")).toMatchObject({
      ok: true,
      result: { delivery: "direct", completionRevision: 1 }
    })

    input.send({ version: 1, id: "idle", method: "session.await_idle", params: { completionId: "cycle-1" } })
    expect(await output.response("idle")).toMatchObject({
      ok: true,
      result: {
        completionRevision: 1,
        completion: {
          text: "x".repeat(50 * 1024),
          stopReason: "stop",
          originalBytes: 60 * 1024,
          omittedBytes: 10 * 1024
        }
      }
    })

    input.send({
      version: 1,
      id: "continue",
      method: "session.prompt",
      params: { delivery: "continue", text: "continue", completionId: "cycle-1" }
    })
    expect(await output.response("continue")).toMatchObject({
      ok: true,
      result: { delivery: "continue", completionRevision: 2 }
    })
    await secondStarted.promise
    input.send({
      version: 1,
      id: "rejected-direct",
      method: "session.prompt",
      params: { delivery: "direct", text: "reject while running", completionId: "cycle-1" }
    })
    expect(await output.response("rejected-direct")).toMatchObject({ ok: false })
    finishSecond.resolve()

    input.send({ version: 1, id: "idle-2", method: "session.await_idle", params: { completionId: "cycle-1" } })
    expect(await output.response("idle-2")).toMatchObject({
      ok: true,
      result: { completionRevision: 2, completion: { text: "second completion", stopReason: "stop" } }
    })

    input.send({
      version: 1,
      id: "untracked",
      method: "session.prompt",
      params: { delivery: "direct", text: "untracked" }
    })
    expect(await output.response("untracked")).toMatchObject({ ok: true })
    input.send({ version: 1, id: "untracked-idle", method: "session.await_idle" })
    expect(await output.response("untracked-idle")).toMatchObject({ ok: true })
    input.send({
      version: 1,
      id: "invalidated-watch",
      method: "session.await_idle",
      params: { completionId: "cycle-1" }
    })
    expect(await output.response("invalidated-watch")).toMatchObject({ ok: false })

    input.close()
    expect(await running).toEqual({ type: "eof" })
  } finally {
    input.close()
    runtime.session.dispose()
    await runtime.session.waitForIdle()
  }
})

test("RPC lists and invokes extension commands without slash parsing", async () => {
  const runtime = await createTestAgentRuntime({
    cwd: "/work",
    models: createModels(),
    session: { type: "new", persist: false }
  })
  const input = new RpcTestInput()
  const output = new RpcTestOutput()
  let invocation: { name: string; arguments: string } | undefined
  runtime.session.listExtensionCommands = () => [
    { name: "counter", description: "Manage counter", argumentHint: "[show|increment]", extensionId: "counter" }
  ]
  runtime.session.invokeExtensionCommand = async (name, arguments_) => {
    invocation = { name, arguments: arguments_ }
    return "Counter: 1"
  }
  const running = runRpcMode(runtime.session, { input, writer: output })

  try {
    await output.frame(frame => frame.type === "ready")
    input.send(
      { version: 1, id: "list", method: "command.list" },
      { version: 1, id: "invoke", method: "command.invoke", params: { name: "counter", arguments: "increment" } },
      { version: 1, id: "missing", method: "command.invoke", params: { name: "missing", arguments: "" } }
    )
    expect(await output.response("list")).toMatchObject({
      ok: true,
      result: { commands: [{ name: "counter", extensionId: "counter" }] }
    })
    expect(await output.response("invoke")).toMatchObject({ ok: true, result: { message: "Counter: 1" } })
    expect(invocation).toEqual({ name: "counter", arguments: "increment" })
    expect(await output.response("missing")).toMatchObject({ ok: false, error: { code: "not_found" } })

    input.close()
    expect(await running).toEqual({ type: "eof" })
  } finally {
    input.close()
    runtime.session.dispose()
    await runtime.session.waitForIdle()
  }
})

test("RPC rejects duplicate in-flight request IDs across ordinary and interruption slots", async () => {
  const runtime = await createTestAgentRuntime({
    cwd: "/work",
    models: createModels(),
    session: { type: "new", persist: false }
  })
  const input = new RpcTestInput()
  const output = new RpcTestOutput()
  const gates = [deferred<void>(), deferred<void>()]
  let invocationCount = 0
  runtime.session.listExtensionCommands = () => [
    { name: "blocking", description: "Block", argumentHint: "", extensionId: "blocking" }
  ]
  runtime.session.invokeExtensionCommand = async () => {
    const gate = gates[invocationCount]
    invocationCount++
    if (!gate) throw new Error("Unexpected invocation")
    await gate.promise
    return `Invocation ${invocationCount}`
  }
  const running = runRpcMode(runtime.session, { input, writer: output })

  try {
    await output.frame(frame => frame.type === "ready")
    input.send(blockingCommandRequest("ordinary-duplicate"), blockingCommandRequest("ordinary-duplicate"))
    expect(
      await output.frame(frame => frame.type === "protocol_error" && frame.id === "ordinary-duplicate")
    ).toMatchObject({ code: "invalid_request", id: "ordinary-duplicate" })
    expect(invocationCount).toBe(1)
    gates[0]!.resolve()
    expect(await output.response("ordinary-duplicate")).toMatchObject({ ok: true })
    expect(output.frames.filter(frame => frame.type === "response" && frame.id === "ordinary-duplicate")).toHaveLength(
      1
    )

    input.send(blockingCommandRequest("cross-slot"), { version: 1, id: "cross-slot", method: "session.interrupt" })
    expect(await output.frame(frame => frame.type === "protocol_error" && frame.id === "cross-slot")).toMatchObject({
      code: "invalid_request",
      id: "cross-slot"
    })
    expect(invocationCount).toBe(2)
    gates[1]!.resolve()
    expect(await output.response("cross-slot")).toMatchObject({ ok: true, method: "command.invoke" })
    expect(output.frames.filter(frame => frame.type === "response" && frame.id === "cross-slot")).toHaveLength(1)

    input.close()
    expect(await running).toEqual({ type: "eof" })
  } finally {
    for (const gate of gates) gate.resolve()
    input.close()
    runtime.session.dispose()
    await runtime.session.waitForIdle()
  }
})

test("RPC retains request IDs until their correlated response is written", async () => {
  const runtime = await createTestAgentRuntime({
    cwd: "/work",
    models: createModels(),
    session: { type: "new", persist: false }
  })
  const input = new RpcTestInput()
  const output = new RpcTestOutput()
  const responseWriteStarted = deferred<void>()
  const releaseResponseWrite = deferred<void>()
  const secondInvocation = deferred<void>()
  let heldResponse = false
  let invocationCount = 0
  runtime.session.listExtensionCommands = () => [
    { name: "blocking", description: "Block", argumentHint: "", extensionId: "blocking" }
  ]
  runtime.session.invokeExtensionCommand = async () => {
    invocationCount++
    if (invocationCount === 2) secondInvocation.resolve()
    return `Invocation ${invocationCount}`
  }
  const running = runRpcMode(runtime.session, {
    input,
    writer: {
      write: async line => {
        const frame: unknown = JSON.parse(line)
        if (isRecord(frame) && frame.type === "response" && frame.id === "held" && !heldResponse) {
          heldResponse = true
          responseWriteStarted.resolve()
          await releaseResponseWrite.promise
        }
        output.write(line)
      }
    }
  })

  try {
    await output.frame(frame => frame.type === "ready")
    input.send(blockingCommandRequest("held"))
    await responseWriteStarted.promise

    input.send(blockingCommandRequest("held"), blockingCommandRequest("probe"))
    await secondInvocation.promise
    expect(invocationCount).toBe(2)

    releaseResponseWrite.resolve()
    expect(await output.response("held")).toMatchObject({ ok: true })
    expect(await output.frame(frame => frame.type === "protocol_error" && frame.id === "held")).toMatchObject({
      code: "invalid_request"
    })
    expect(await output.response("probe")).toMatchObject({ ok: true })

    input.close()
    expect(await running).toEqual({ type: "eof" })
  } finally {
    releaseResponseWrite.resolve()
    input.close()
    runtime.session.dispose()
    await runtime.session.waitForIdle()
  }
})

test("RPC releases request IDs after failed and successful settlement", async () => {
  const runtime = await createTestAgentRuntime({
    cwd: "/work",
    models: createModels(),
    session: { type: "new", persist: false }
  })
  const input = new RpcTestInput()
  const output = new RpcTestOutput()
  let invocationCount = 0
  runtime.session.listExtensionCommands = () => [
    { name: "reusable", description: "Reuse", argumentHint: "", extensionId: "reusable" }
  ]
  runtime.session.invokeExtensionCommand = async () => {
    invocationCount++
    if (invocationCount === 1) throw new Error("First invocation failed")
    return `Invocation ${invocationCount}`
  }
  const running = runRpcMode(runtime.session, { input, writer: output })
  const request = { version: 1, id: "reusable", method: "command.invoke", params: { name: "reusable", arguments: "" } }

  try {
    await output.frame(frame => frame.type === "ready")
    input.send(request)
    const failed = await output.response("reusable")
    expect(failed).toMatchObject({ ok: false, error: { code: "operation_failed" } })

    input.send(request)
    const succeeded = await output.frame(
      (frame): frame is Extract<RpcServerFrame, { type: "response" }> =>
        frame.type === "response" && frame.id === "reusable" && frame.sequence > failed.sequence
    )
    expect(succeeded).toMatchObject({ ok: true, result: { message: "Invocation 2" } })

    input.send(request)
    const reused = await output.frame(
      (frame): frame is Extract<RpcServerFrame, { type: "response" }> =>
        frame.type === "response" && frame.id === "reusable" && frame.sequence > succeeded.sequence
    )
    expect(reused).toMatchObject({ ok: true, result: { message: "Invocation 3" } })
    expect(invocationCount).toBe(3)

    input.close()
    expect(await running).toEqual({ type: "eof" })
  } finally {
    input.close()
    runtime.session.dispose()
    await runtime.session.waitForIdle()
  }
})

test("RPC exposes committed custom entries while message pages retain presentation policy", async () => {
  const models = createModels()
  const runtime = await createTestAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })
  const input = new RpcTestInput()
  const output = new RpcTestOutput()
  const running = runRpcMode(runtime.session, { input, writer: output })

  try {
    await output.frame(frame => frame.type === "ready")
    runtime.session.appendCustomEntry("example.state", { enabled: true })
    runtime.session.sendCustomMessage(
      { customType: "example.visible", content: "visible", display: true },
      { type: "append" }
    )
    runtime.session.sendCustomMessage(
      { customType: "example.hidden", content: "hidden", display: false },
      { type: "append" }
    )
    await output.frame(
      frame =>
        frame.type === "session_event" &&
        frame.event.type === "entry_appended" &&
        frame.event.entry.type === "custom_message" &&
        frame.event.entry.customType === "example.hidden"
    )

    const appended = output.frames.flatMap(frame =>
      frame.type === "session_event" && frame.event.type === "entry_appended" ? [frame.event.entry.type] : []
    )
    expect(appended).toEqual(["custom", "custom_message", "custom_message"])

    input.send({ version: 1, id: "messages", method: "session.get_messages", params: { start: 0, limit: 100 } })
    const page = await output.response("messages")
    if (!page.ok || !isMessagePage(page.result)) throw new Error("Expected custom message page")
    expect(page.result.messages).toEqual([
      expect.objectContaining({ role: "custom", customType: "example.visible", content: "visible" })
    ])

    input.close()
    expect(await running).toEqual({ type: "eof" })
  } finally {
    input.close()
    runtime.session.dispose()
    await runtime.session.waitForIdle()
  }
})

test("RPC mode bounds concurrent waits while reserving interruption capacity", async () => {
  const models = createModels()
  const faux = fauxProvider({ provider: "rpc-capacity", models: [{ id: "model", name: "Model" }] })
  models.setProvider(faux.provider)
  const providerStarted = deferred<void>()
  faux.setResponses([
    async (_context, request) => {
      providerStarted.resolve()
      await new Promise<void>(resolve => request?.signal?.addEventListener("abort", () => resolve(), { once: true }))
      return fauxAssistantMessage("interrupted", { stopReason: "aborted" })
    }
  ])
  const runtime = await createTestAgentRuntime({
    cwd: "/work",
    model: "rpc-capacity/model",
    apiKey: "test",
    models,
    session: { type: "new", persist: false }
  })
  const input = new RpcTestInput()
  const output = new RpcTestOutput()
  const running = runRpcMode(runtime.session, { input, writer: output })

  try {
    await output.frame(frame => frame.type === "ready")
    input.send({ version: 1, id: "prompt", method: "session.prompt", params: { delivery: "direct", text: "start" } })
    await providerStarted.promise
    await output.response("prompt")

    input.send(
      ...Array.from({ length: 33 }, (_, index) => ({ version: 1, id: `wait-${index}`, method: "session.await_idle" }))
    )

    expect(await output.response("wait-32")).toMatchObject({ ok: false, error: { code: "capacity" } })
    input.send({ version: 1, id: "wait-32", method: "session.interrupt" })
    expect(
      await output.frame(
        (frame): frame is Extract<RpcServerFrame, { type: "response" }> =>
          frame.type === "response" && frame.id === "wait-32" && frame.method === "session.interrupt"
      )
    ).toMatchObject({ ok: true })
    expect(
      (await Promise.all(Array.from({ length: 32 }, (_, index) => output.response(`wait-${index}`)))).every(
        frame => frame.ok
      )
    ).toBe(true)

    input.close()
    expect(await running).toEqual({ type: "eof" })
  } finally {
    input.close()
    runtime.session.dispose()
    await runtime.session.waitForIdle()
  }
})

test("RPC mode cancels blocked input and releases its subscription", async () => {
  const models = createModels()
  const runtime = await createTestAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })
  const input = new RpcTestInput()
  const output = new RpcTestOutput()
  const controller = new AbortController()
  const baselineSubscribers = runtime.session.memoryDiagnostics.subscribers
  const running = runRpcMode(runtime.session, { input, writer: output, signal: controller.signal })

  try {
    await output.frame(frame => frame.type === "ready")
    expect(runtime.session.memoryDiagnostics.subscribers).toBe(baselineSubscribers + 1)
    controller.abort()
    expect(await running).toEqual({ type: "cancelled" })
    expect(runtime.session.memoryDiagnostics.subscribers).toBe(baselineSubscribers)
  } finally {
    input.close()
    runtime.session.dispose()
    await runtime.session.waitForIdle()
  }
})

test("RPC mode turns output failure into connection cancellation", async () => {
  const models = createModels()
  const runtime = await createTestAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })
  const input = new RpcTestInput()

  try {
    expect(
      await runRpcMode(runtime.session, {
        input,
        writer: {
          write() {
            throw new Error("closed")
          }
        }
      })
    ).toEqual({ type: "output_error", message: "Could not write RPC output" })
  } finally {
    input.close()
    runtime.session.dispose()
    await runtime.session.waitForIdle()
  }
})

test("RPC mode validates recoverable records and projects model and thinking selection", async () => {
  const models = createModels()
  const faux = fauxProvider({
    provider: "rpc-select",
    models: [
      { id: "first", name: "First", reasoning: true },
      { id: "second", name: "Second", reasoning: true }
    ]
  })
  models.setProvider(faux.provider)
  models.getAuth = async () => ({ auth: { apiKey: "configured" }, source: "test" })
  const runtime = await createTestAgentRuntime({
    cwd: "/work",
    model: "rpc-select/first",
    models,
    session: { type: "new", persist: false }
  })
  const input = new RpcTestInput()
  const output = new RpcTestOutput()
  const running = runRpcMode(runtime.session, { input, writer: output })

  try {
    await output.frame(frame => frame.type === "ready")
    input.sendLine("not json")
    expect(await output.frame(frame => frame.type === "protocol_error")).toMatchObject({
      type: "protocol_error",
      code: "invalid_json"
    })

    input.send({ version: 1, id: "models", method: "model.list" })
    const listed = await output.response("models")
    expect(listed).toMatchObject({
      ok: true,
      result: {
        models: [
          { provider: "rpc-select", id: "first", configured: true },
          { provider: "rpc-select", id: "second", configured: true }
        ]
      }
    })
    expect(JSON.stringify(listed)).not.toContain("baseUrl")

    input.send({ version: 1, id: "model", method: "model.select", params: { provider: "rpc-select", id: "second" } })
    expect(await output.response("model")).toMatchObject({
      ok: true,
      result: { model: { provider: "rpc-select", id: "second" } }
    })

    input.send({ version: 1, id: "thinking-list", method: "thinking.list" })
    expect(await output.response("thinking-list")).toMatchObject({
      ok: true,
      result: { levels: expect.arrayContaining(["off", "high"]) }
    })

    input.send({ version: 1, id: "thinking", method: "thinking.select", params: { level: "high", scope: "global" } })
    expect(await output.response("thinking")).toMatchObject({
      ok: true,
      result: { requested: "high", effective: "high", scope: "global" }
    })

    input.close()
    expect(await running).toEqual({ type: "eof" })
  } finally {
    input.close()
    runtime.session.dispose()
    await runtime.session.waitForIdle()
  }
})

test("connection.set_events suppresses only session_event frames in input order", async () => {
  const models = createModels()
  const faux = fauxProvider({ provider: "rpc", models: [{ id: "model", name: "RPC Model", reasoning: false }] })
  models.setProvider(faux.provider)
  let release: (() => void) | undefined
  const gate = new Promise<void>(resolve => {
    release = resolve
  })
  faux.setResponses([
    async () => {
      await gate
      return fauxAssistantMessage("done")
    }
  ])
  const runtime = await createTestAgentRuntime({
    cwd: "/work",
    model: "rpc/model",
    apiKey: "test",
    models,
    session: { type: "new", persist: false }
  })
  const input = new RpcTestInput()
  const output = new RpcTestOutput()
  const running = runRpcMode(runtime.session, { input, writer: output })

  try {
    await output.frame(frame => frame.type === "ready")
    input.send({ version: 1, id: "events-none", method: "connection.set_events", params: { mode: "none" } })
    expect(await output.response("events-none")).toMatchObject({ ok: true, result: { mode: "none" } })

    input.send({ version: 1, id: "prompt", method: "session.prompt", params: { delivery: "direct", text: "start" } })
    expect((await output.response("prompt")).ok).toBe(true)
    release?.()
    input.send({ version: 1, id: "idle", method: "session.await_idle" })
    expect((await output.response("idle")).ok).toBe(true)

    expect(output.frames.some(frame => frame.type === "session_event")).toBe(false)
    expect(output.frames.some(frame => frame.type === "response")).toBe(true)

    input.send({ version: 1, id: "events-all", method: "connection.set_events", params: { mode: "all" } })
    expect(await output.response("events-all")).toMatchObject({ ok: true, result: { mode: "all" } })

    input.close()
    expect(await running).toEqual({ type: "eof" })
  } finally {
    input.close()
    runtime.session.dispose()
    await runtime.session.waitForIdle()
  }
})

test("delivery continue starts idle work and queues follow-up while running", async () => {
  const models = createModels()
  const faux = fauxProvider({ provider: "rpc", models: [{ id: "model", name: "RPC Model", reasoning: false }] })
  models.setProvider(faux.provider)
  const firstStarted = deferred<void>()
  let releaseFirst: (() => void) | undefined
  const firstGate = new Promise<void>(resolve => {
    releaseFirst = resolve
  })
  faux.setResponses([
    async () => {
      firstStarted.resolve()
      await firstGate
      return fauxAssistantMessage("first")
    },
    async () => fauxAssistantMessage("second")
  ])
  const runtime = await createTestAgentRuntime({
    cwd: "/work",
    model: "rpc/model",
    apiKey: "test",
    models,
    session: { type: "new", persist: false }
  })
  const input = new RpcTestInput()
  const output = new RpcTestOutput()
  const running = runRpcMode(runtime.session, { input, writer: output })

  try {
    await output.frame(frame => frame.type === "ready")

    input.send({
      version: 1,
      id: "continue-idle",
      method: "session.prompt",
      params: { delivery: "continue", text: "wake" }
    })
    expect(await output.response("continue-idle")).toMatchObject({ ok: true, result: { delivery: "continue" } })
    await firstStarted.promise

    input.send({
      version: 1,
      id: "continue-running",
      method: "session.prompt",
      params: { delivery: "continue", text: "follow" }
    })
    expect(await output.response("continue-running")).toMatchObject({ ok: true, result: { delivery: "continue" } })
    expect(runtime.session.queuedInputs.followUp.map(entry => entry.text)).toEqual(["follow"])

    releaseFirst?.()
    input.send({ version: 1, id: "idle", method: "session.await_idle" })
    expect((await output.response("idle")).ok).toBe(true)

    input.close()
    expect(await running).toEqual({ type: "eof" })
  } finally {
    input.close()
    runtime.session.dispose()
    await runtime.session.waitForIdle()
  }
})

test("delivery continue rejects non-runnable session states without mutation", async () => {
  const models = createModels()
  const runtime = await createTestAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })
  const input = new RpcTestInput()
  const output = new RpcTestOutput()
  const running = runRpcMode(runtime.session, { input, writer: output })

  try {
    await output.frame(frame => frame.type === "ready")
    runtime.session.dispose()

    input.send({
      version: 1,
      id: "continue-disposed",
      method: "session.prompt",
      params: { delivery: "continue", text: "nope" }
    })
    const response = await output.response("continue-disposed")
    expect(response).toMatchObject({ ok: false, error: { code: "operation_failed" } })

    input.close()
    expect(await running).toEqual({ type: "eof" })
  } finally {
    input.close()
  }
})

function blockingCommandRequest(id: string) {
  return { version: 1, id, method: "command.invoke", params: { name: "blocking", arguments: "" } }
}

class RpcTestInput implements AsyncIterable<Uint8Array> {
  readonly #chunks: Uint8Array[] = []
  readonly #waiters: Array<(result: IteratorResult<Uint8Array>) => void> = []
  #closed = false

  send(...records: readonly unknown[]): void {
    this.sendLine(records.map(record => JSON.stringify(record)).join("\n"))
  }

  sendLine(lines: string): void {
    if (this.#closed) throw new Error("RPC test input is closed")
    this.#deliver(new TextEncoder().encode(`${lines}\n`))
  }

  close(): void {
    if (this.#closed) return
    this.#closed = true
    for (const waiter of this.#waiters.splice(0)) waiter({ done: true, value: undefined })
  }

  [Symbol.asyncIterator](): AsyncIterator<Uint8Array> {
    return {
      next: () => {
        const chunk = this.#chunks.shift()
        if (chunk) return Promise.resolve({ done: false, value: chunk })
        if (this.#closed) return Promise.resolve({ done: true, value: undefined })
        return new Promise(resolve => this.#waiters.push(resolve))
      },
      return: async () => {
        this.close()
        return { done: true, value: undefined }
      }
    }
  }

  #deliver(chunk: Uint8Array): void {
    const waiter = this.#waiters.shift()
    if (waiter) waiter({ done: false, value: chunk })
    else this.#chunks.push(chunk)
  }
}

class RpcTestOutput {
  readonly frames: RpcServerFrame[] = []
  readonly #waiters: Array<{
    readonly predicate: (frame: RpcServerFrame) => boolean
    readonly resolve: (frame: RpcServerFrame) => void
  }> = []

  write = (line: string): void => {
    const frame: unknown = JSON.parse(line)
    if (!isServerFrame(frame)) throw new Error("Invalid RPC server frame")
    this.frames.push(frame)
    const waiter = this.#waiters.find(candidate => candidate.predicate(frame))
    if (!waiter) return
    this.#waiters.splice(this.#waiters.indexOf(waiter), 1)
    waiter.resolve(frame)
  }

  response(id: string): Promise<Extract<RpcServerFrame, { type: "response" }>> {
    return this.frame(
      (frame): frame is Extract<RpcServerFrame, { type: "response" }> => frame.type === "response" && frame.id === id
    )
  }

  frame<T extends RpcServerFrame>(predicate: (frame: RpcServerFrame) => frame is T): Promise<T>
  frame(predicate: (frame: RpcServerFrame) => boolean): Promise<RpcServerFrame>
  frame(predicate: (frame: RpcServerFrame) => boolean): Promise<RpcServerFrame> {
    const existing = this.frames.find(predicate)
    if (existing) return Promise.resolve(existing)
    return new Promise(resolve => this.#waiters.push({ predicate, resolve }))
  }
}

function isMessagePage(value: unknown): value is RpcMessagePage {
  return (
    isRecord(value) &&
    typeof value.start === "number" &&
    typeof value.total === "number" &&
    (value.nextStart === null || typeof value.nextStart === "number") &&
    Array.isArray(value.messages)
  )
}

function isServerFrame(value: unknown): value is RpcServerFrame {
  return (
    isRecord(value) &&
    value.version === 1 &&
    typeof value.sequence === "number" &&
    (value.type === "ready" ||
      value.type === "peer_request" ||
      value.type === "session_event" ||
      value.type === "protocol_error" ||
      value.type === "response")
  )
}

function deferred<T>() {
  let resolve!: (value: T | PromiseLike<T>) => void
  const promise = new Promise<T>(resolvePromise => {
    resolve = resolvePromise
  })
  return { promise, resolve }
}
