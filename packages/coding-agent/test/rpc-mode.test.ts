import { expect, test } from "bun:test"

import { runRpcMode, type RpcMessagePage, type RpcServerFrame } from "../src/rpc/rpc-mode.js"
import { createModels, createTestAgentRuntime, fauxAssistantMessage, fauxProvider } from "../src/testing.js"

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
        model: { type: "selected", model: { provider: "rpc", id: "model", name: "RPC Model" } }
      }
    })
    expect(JSON.stringify(ready)).not.toContain("baseUrl")

    input.send({ version: 1, id: "prompt", method: "session.prompt", params: { delivery: "direct", text: "start" } })
    await providerStarted.promise
    await output.response("prompt")

    input.send(
      { version: 1, id: "steer", method: "session.prompt", params: { delivery: "steer", text: "steer" } },
      { version: 1, id: "follow", method: "session.prompt", params: { delivery: "follow_up", text: "follow" } }
    )
    expect((await output.response("steer")).ok).toBe(true)
    expect((await output.response("follow")).ok).toBe(true)

    input.send(
      { version: 1, id: "idle", method: "session.await_idle" },
      { version: 1, id: "interrupt", method: "session.interrupt" }
    )
    expect((await output.response("interrupt")).ok).toBe(true)
    expect((await output.response("idle")).ok).toBe(true)

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
      ...Array.from({ length: 33 }, (_, index) => ({ version: 1, id: `wait-${index}`, method: "session.await_idle" })),
      { version: 1, id: "interrupt", method: "session.interrupt" }
    )

    expect(await output.response("wait-32")).toMatchObject({ ok: false, error: { code: "capacity" } })
    expect(await output.response("interrupt")).toMatchObject({ ok: true })
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
      value.type === "session_event" ||
      value.type === "protocol_error" ||
      value.type === "response")
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
