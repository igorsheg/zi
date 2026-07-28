import { expect, test } from "bun:test"
import { resolve } from "node:path"
import { PassThrough, Writable } from "node:stream"

import type { ExtensionLoadPlan, ExtensionSource } from "../src/extensions/discovery.js"
import {
  ExtensionHost,
  type ExtensionHostTimeouts,
  type ExtensionWorkerExit,
  type ExtensionWorkerProcess,
  type SpawnExtensionWorker
} from "../src/extensions/host.js"
import {
  encodeExtensionProtocolFrame,
  ExtensionProtocolDecoder,
  extensionProtocolVersion,
  maxExtensionDiagnostics,
  maxExtensionLogBytesPerStream,
  type HostMessage,
  type WorkerMessage,
  validateHostMessage
} from "../src/extensions/protocol.js"

const testTimeouts: ExtensionHostTimeouts = Object.freeze({
  startupMs: 100,
  lifecycleMs: 100,
  shutdownMs: 90,
  toolMs: 100,
  toolCancellationMs: 20
})

const sourceOne = extensionSource("one")
const sourceTwo = extensionSource("two")

const emptyPlan: ExtensionLoadPlan = Object.freeze({ cwd: resolve("extension-host-empty"), sources: Object.freeze([]) })
const planOne = extensionPlan("one", [sourceOne])
const planTwo = extensionPlan("two", [sourceTwo])

test("empty extension plans stay lazy through lifecycle and disposal", async () => {
  const workers = new TestWorkerSpawner()
  const host = await ExtensionHost.create(emptyPlan, workers.spawn, testTimeouts)

  expect(host.snapshot()).toMatchObject({ status: "disabled", lifecycle: "unbound", extensions: [] })
  expect(workers.processes).toHaveLength(0)
  await host.sessionStart("startup")
  expect(host.snapshot()).toMatchObject({ status: "disabled", lifecycle: "started" })
  await host.reload(emptyPlan)
  expect(workers.processes).toHaveLength(0)
  await host.dispose()
  await host.dispose()
  expect(host.snapshot()).toMatchObject({ status: "disposed", lifecycle: "stopped" })
})

test("host startup owns lifecycle requests, bounded logs, and process cleanup", async () => {
  const workers = new TestWorkerSpawner()
  const host = await ExtensionHost.create(planOne, workers.spawn, testTimeouts)
  const worker = workers.processes[0]!

  expect(host.snapshot()).toMatchObject({ status: "ready", lifecycle: "unbound" })
  await host.sessionStart("startup")
  expect(worker.messages.map(message => message.type)).toEqual(["initialize", "session_start"])
  expect(host.sessionStart("startup")).rejects.toThrow("cannot start while started")

  worker.stdout.write(Buffer.alloc(maxExtensionLogBytesPerStream + 17, 0x61))
  worker.stderr.write("stderr evidence")
  expect(host.snapshot()).toMatchObject({
    stdout: { retainedBytes: maxExtensionLogBytesPerStream, omittedBytes: 17 },
    stderr: { text: "stderr evidence", omittedBytes: 0 }
  })

  await host.sessionShutdown("quit")
  await host.dispose()
  expect(worker.messages.map(message => message.type)).toEqual([
    "initialize",
    "session_start",
    "session_shutdown",
    "stop"
  ])
  expect(worker.disposed).toBe(true)
  expect(host.snapshot()).toMatchObject({ status: "disposed", lifecycle: "stopped" })
})

test("startup and teardown deadlines terminate unresponsive workers", async () => {
  const timeouts: ExtensionHostTimeouts = {
    startupMs: 10,
    lifecycleMs: 10,
    shutdownMs: 9,
    toolMs: 10,
    toolCancellationMs: 5
  }
  const startupWorkers = new TestWorkerSpawner()
  startupWorkers.behaviors.push({ type: "pending" })
  const failed = await ExtensionHost.create(planOne, startupWorkers.spawn, timeouts)
  expect(failed.snapshot()).toMatchObject({
    status: "failed",
    diagnostics: [{ phase: "handshake", message: "Extension worker startup deadline exceeded" }]
  })
  expect(startupWorkers.processes[0]!.terminated).toEqual(["SIGTERM"])

  const shutdownWorkers = new TestWorkerSpawner()
  shutdownWorkers.behaviors.push({ type: "resist_terminate" })
  const host = await ExtensionHost.create(planOne, shutdownWorkers.spawn, timeouts)
  await host.dispose()
  expect(shutdownWorkers.processes[0]!.terminated).toEqual(["SIGTERM", "SIGKILL"])
  expect(host.snapshot().diagnostics).toContainEqual(
    expect.objectContaining({ phase: "shutdown", severity: "warning" })
  )
})

test("ready barriers must describe the exact admitted load plan", async () => {
  const workers = new TestWorkerSpawner()
  workers.behaviors.push({ type: "wrong_ready" })
  const host = await ExtensionHost.create(planOne, workers.spawn, testTimeouts)

  expect(host.snapshot()).toMatchObject({
    status: "failed",
    extensions: [],
    diagnostics: [
      { phase: "handshake", message: "Extension worker ready results did not match its admitted load plan" }
    ]
  })
  await host.dispose()
})

test("fatal startup failure leaves a diagnosable retryable host", async () => {
  const workers = new TestWorkerSpawner()
  workers.behaviors.push({ type: "fatal", message: "factory barrier crashed" })
  const host = await ExtensionHost.create(planOne, workers.spawn, testTimeouts)

  expect(host.snapshot()).toMatchObject({
    status: "failed",
    lifecycle: "unbound",
    diagnostics: [{ phase: "handshake", message: "factory barrier crashed" }]
  })
  expect(workers.processes[0]!.terminated).toEqual(["SIGTERM"])
  expect(workers.processes[0]!.disposed).toBe(true)

  await host.sessionStart("startup")
  workers.behaviors.push({ type: "ready" })
  await host.reload(planTwo)
  expect(host.snapshot()).toMatchObject({ status: "ready", lifecycle: "started" })
  expect(workers.processes[1]!.messages.map(message => message.type)).toEqual(["initialize", "session_start"])
  await host.dispose()
})

test("failed lifecycle requests preserve the session's desired lifecycle", async () => {
  const workers = new TestWorkerSpawner()
  workers.behaviors.push({ type: "fatal_start" })
  const host = await ExtensionHost.create(planOne, workers.spawn, testTimeouts)

  await host.sessionStart("startup")
  expect(host.snapshot()).toMatchObject({ status: "failed", lifecycle: "started" })
  await host.dispose()
})

test("host tool invocation is correlated, cancellable, and generation-reusable", async () => {
  const workers = new TestWorkerSpawner()
  workers.behaviors.push({ type: "tools" })
  const host = await ExtensionHost.create(planOne, workers.spawn, testTimeouts)
  await host.sessionStart("startup")

  expect(host.toolCatalog()).toMatchObject([{ name: "echo_message", source: { id: sourceOne.id } }])
  expect(await host.invokeTool("echo_message", { message: "hello" })).toBe("HELLO")
  expect(host.invokeTool("echo_message", { message: "error" })).rejects.toThrow("tool failed")

  const controller = new AbortController()
  const cancelled = host.invokeTool("echo_message", { message: "pending" }, controller.signal)
  controller.abort()
  expect(cancelled).rejects.toMatchObject({ name: "AbortError" })
  expect(await host.invokeTool("echo_message", { message: "again" })).toBe("AGAIN")
  expect(host.snapshot()).toMatchObject({ status: "ready", lifecycle: "started" })
  await host.dispose()
})

test("worker session requests are source-attributed and domain refusals keep the generation ready", async () => {
  const workers = new TestWorkerSpawner()
  const host = await ExtensionHost.create(planOne, workers.spawn, testTimeouts)
  const release = host.bindSessionOperations({
    getEntries: customType => [{ id: "state-1", timestamp: new Date(0).toISOString(), customType, data: { count: 1 } }],
    appendEntry: (customType, data) => ({
      id: "state-2",
      timestamp: new Date(1).toISOString(),
      customType,
      ...(data === undefined ? {} : { data })
    }),
    sendMessage: () => {}
  })
  await host.sessionStart("startup")
  const worker = workers.processes[0]!

  worker.send({
    type: "custom_entries_get",
    generation: 1,
    requestId: 41,
    extensionId: sourceOne.id,
    customType: "example.counter"
  })
  await Bun.sleep(0)
  expect(worker.messages).toContainEqual({
    type: "custom_entries_result",
    generation: 1,
    requestId: 41,
    entries: [
      { id: "state-1", timestamp: new Date(0).toISOString(), customType: "example.counter", data: { count: 1 } }
    ]
  })

  worker.send({
    type: "custom_entries_get",
    generation: 1,
    requestId: 42,
    extensionId: "unknown-source",
    customType: "example.counter"
  })
  await Bun.sleep(0)
  expect(worker.messages).toContainEqual(expect.objectContaining({ type: "session_operation_error", requestId: 42 }))
  expect(host.snapshot()).toMatchObject({ status: "ready", lifecycle: "started" })

  release()
  worker.send({
    type: "custom_entry_append",
    generation: 1,
    requestId: 43,
    extensionId: sourceOne.id,
    customType: "example.counter",
    data: { count: 2 }
  })
  await Bun.sleep(0)
  expect(worker.messages).toContainEqual(expect.objectContaining({ type: "session_operation_error", requestId: 43 }))
  expect(host.snapshot()).toMatchObject({ status: "ready", lifecycle: "started" })
  await host.dispose()
})

test("a tool result crossing host cancellation settles as cancellation", async () => {
  const workers = new TestWorkerSpawner()
  workers.behaviors.push({ type: "tool_cancel_crossing" })
  const host = await ExtensionHost.create(planOne, workers.spawn, testTimeouts)
  await host.sessionStart("startup")
  const controller = new AbortController()
  const invocation = host.invokeTool("echo_message", { message: "pending" }, controller.signal)

  controller.abort()
  expect(invocation).rejects.toMatchObject({ name: "AbortError" })
  expect(host.snapshot()).toMatchObject({ status: "ready", lifecycle: "started" })
  await host.dispose()
})

test("a malformed tool result fails its generation without escaping the host", async () => {
  const workers = new TestWorkerSpawner()
  workers.behaviors.push({ type: "malformed_tool" })
  const host = await ExtensionHost.create(planOne, workers.spawn, testTimeouts)
  await host.sessionStart("startup")

  expect(host.invokeTool("echo_message", { message: "invalid" })).rejects.toThrow("tool result")
  await Bun.sleep(0)
  expect(host.snapshot()).toMatchObject({ status: "failed", failure: { phase: "protocol" } })
  await host.dispose()
})

test("a cancellation deadline fails a tool generation with source attribution", async () => {
  const workers = new TestWorkerSpawner()
  workers.behaviors.push({ type: "tool_hang" })
  const timeouts = { ...testTimeouts, toolMs: 1_000, toolCancellationMs: 10 }
  const host = await ExtensionHost.create(planOne, workers.spawn, timeouts)
  await host.sessionStart("startup")
  const controller = new AbortController()
  const invocation = host.invokeTool("echo_message", { message: "pending" }, controller.signal)

  controller.abort()
  expect(invocation).rejects.toThrow("cancellation deadline exceeded")
  await Bun.sleep(15)
  expect(host.snapshot()).toMatchObject({
    status: "failed",
    failure: { phase: "tool", extensionId: sourceOne.id, path: sourceOne.entryPath }
  })
  expect(workers.processes[0]!.terminated).toEqual(["SIGTERM"])
  await host.dispose()
})

test("a tool deadline fails and terminates its generation", async () => {
  const workers = new TestWorkerSpawner()
  workers.behaviors.push({ type: "tool_hang" })
  const timeouts = { ...testTimeouts, toolMs: 10 }
  const host = await ExtensionHost.create(planOne, workers.spawn, timeouts)
  await host.sessionStart("startup")

  expect(host.invokeTool("echo_message", { message: "pending" })).rejects.toThrow("deadline exceeded")
  await Bun.sleep(15)
  expect(host.snapshot()).toMatchObject({
    status: "failed",
    failure: { phase: "tool", extensionId: sourceOne.id, path: sourceOne.entryPath }
  })
  expect(workers.processes[0]!.terminated).toEqual(["SIGTERM"])
  await host.dispose()
})

test("tool completion from a retired generation cannot cross replacement", async () => {
  const workers = new TestWorkerSpawner()
  workers.behaviors.push({ type: "tools" }, { type: "tools" })
  const host = await ExtensionHost.create(planOne, workers.spawn, testTimeouts)
  const retired = workers.processes[0]!
  await host.sessionStart("startup")
  const invocation = host.invokeTool("echo_message", { message: "pending" })

  await host.reload(planTwo)
  expect(invocation).rejects.toThrow("disposed during tool invocation")
  retired.send({ type: "tool_result", generation: 1, requestId: 2, content: "stale" })
  expect(host.snapshot()).toMatchObject({
    status: "ready",
    lifecycle: "started",
    tools: [{ source: { id: sourceTwo.id }, name: "echo_message" }]
  })
  expect(await host.invokeTool("echo_message", { message: "current" })).toBe("CURRENT")
  await host.dispose()
})

test("replacement preserves current on candidate failure and commits one successful candidate", async () => {
  const workers = new TestWorkerSpawner()
  const host = await ExtensionHost.create(planOne, workers.spawn, testTimeouts)
  const current = workers.processes[0]!
  await host.sessionStart("startup")

  workers.behaviors.push({ type: "spawn_error", message: "candidate spawn failed" })
  await host.reload(planTwo)
  expect(host.snapshot()).toMatchObject({ status: "ready", lifecycle: "started" })
  expect(current.messages.map(message => message.type)).toEqual(["initialize", "session_start"])

  workers.behaviors.push({ type: "fatal", message: "candidate failed" })
  await host.reload(planTwo)
  expect(host.snapshot()).toMatchObject({
    status: "ready",
    lifecycle: "started",
    extensions: [{ source: { id: sourceOne.id } }]
  })
  expect(current.messages.map(message => message.type)).toEqual(["initialize", "session_start"])

  workers.behaviors.push({ type: "ready" })
  await host.reload(planTwo)
  const candidate = workers.processes[2]!
  expect(host.snapshot()).toMatchObject({
    status: "ready",
    lifecycle: "started",
    extensions: [{ source: { id: sourceTwo.id } }]
  })
  expect(current.messages.map(message => message.type)).toEqual([
    "initialize",
    "session_start",
    "session_shutdown",
    "stop"
  ])
  expect(current.disposed).toBe(true)
  expect(candidate.messages.map(message => message.type)).toEqual(["initialize", "session_start"])

  candidate.send({
    type: "diagnostic",
    generation: 999,
    diagnostic: { phase: "protocol", severity: "warning", message: "stale" }
  })
  expect(host.snapshot()).toMatchObject({ status: "ready", staleFrames: 1 })
  await host.dispose()
})

test("replacement fails instead of restoring a current generation that crashed with its candidate", async () => {
  const workers = new TestWorkerSpawner()
  const host = await ExtensionHost.create(planOne, workers.spawn, testTimeouts)
  await host.sessionStart("startup")
  const current = workers.processes[0]!

  workers.behaviors.push({ type: "pending" })
  const replacement = host.reload(planTwo)
  await Promise.resolve()
  const candidate = workers.processes[1]!
  current.crash(new Error("current crashed"))
  await Promise.resolve()
  candidate.failStartup("candidate crashed")
  await replacement

  expect(host.snapshot()).toMatchObject({ status: "failed", lifecycle: "started", extensions: [] })
  expect(current.disposed).toBe(true)
  expect(candidate.disposed).toBe(true)
  await host.dispose()
})

test("final disposal supersedes startup and replacement without leaking either process", async () => {
  const startupWorkers = new TestWorkerSpawner()
  startupWorkers.behaviors.push({ type: "pending" })
  const startingHost = new ExtensionHost(startupWorkers.spawn, testTimeouts)
  const startup = startingHost.start(planOne)
  await Promise.resolve()
  const startupDisposal = startingHost.dispose()
  await Promise.all([startup, startupDisposal])
  expect(startingHost.snapshot().status).toBe("disposed")
  expect(startupWorkers.processes[0]).toMatchObject({ disposed: true, terminated: ["SIGTERM"] })

  const replacementWorkers = new TestWorkerSpawner()
  const replacingHost = await ExtensionHost.create(planOne, replacementWorkers.spawn, testTimeouts)
  await replacingHost.sessionStart("startup")
  replacementWorkers.behaviors.push({ type: "pending" })
  const replacement = replacingHost.reload(planTwo)
  await Promise.resolve()
  expect(replacingHost.reload(planTwo)).rejects.toThrow("cannot reload while replacing")
  const replacementDisposal = replacingHost.dispose()
  await Promise.all([replacement, replacementDisposal])

  expect(replacingHost.snapshot().status).toBe("disposed")
  expect(replacementWorkers.processes.every(process => process.disposed)).toBe(true)
  expect(replacementWorkers.processes[0]!.messages.map(message => message.type)).toContain("session_shutdown")
})

test("replacement disposal authorizes shutdown state operations from the current generation", async () => {
  const workers = new TestWorkerSpawner()
  workers.behaviors.push({ type: "shutdown_append" })
  const host = await ExtensionHost.create(planOne, workers.spawn, testTimeouts)
  const appended: Array<{ readonly customType: string; readonly data?: unknown }> = []
  host.bindSessionOperations({
    getEntries: () => [],
    appendEntry: (customType, data) => {
      appended.push(data === undefined ? { customType } : { customType, data })
      return {
        id: "shutdown-state",
        timestamp: new Date(0).toISOString(),
        customType,
        ...(data === undefined ? {} : { data })
      }
    },
    sendMessage: () => {}
  })
  await host.sessionStart("startup")
  const current = workers.processes[0]!

  workers.behaviors.push({ type: "pending" })
  const replacement = host.reload(planTwo)
  await Promise.resolve()
  const candidate = workers.processes[1]!
  const disposal = host.dispose()
  await Promise.all([replacement, disposal])

  expect(appended).toEqual([{ customType: "example.shutdown", data: { final: true } }])
  expect(current.messages).toContainEqual(
    expect.objectContaining({ type: "custom_entry_result", requestId: 1, generation: 1 })
  )
  expect(current.disposed).toBe(true)
  expect(candidate.disposed).toBe(true)
})

test("current crashes fail closed, retain bounded diagnostics, and remain disposable", async () => {
  const workers = new TestWorkerSpawner()
  const host = await ExtensionHost.create(planOne, workers.spawn, testTimeouts)
  const worker = workers.processes[0]!
  await host.sessionStart("startup")

  for (let index = 0; index < maxExtensionDiagnostics + 10; index++) {
    worker.send({
      type: "diagnostic",
      generation: 1,
      diagnostic: { phase: "lifecycle", severity: "warning", message: `diagnostic ${index}` }
    })
  }
  worker.crash(new Error("worker crash"))
  await Promise.resolve()

  const snapshot = host.snapshot()
  expect(snapshot).toMatchObject({
    status: "failed",
    failure: { phase: "protocol", severity: "error" },
    omittedDiagnostics: 11
  })
  expect(snapshot.diagnostics).toHaveLength(maxExtensionDiagnostics)
  await host.dispose()
  expect(worker.disposed).toBe(true)
})

class TestWorkerSpawner {
  readonly behaviors: TestWorkerBehavior[] = []
  readonly processes: TestWorkerProcess[] = []
  readonly spawn: SpawnExtensionWorker = plan => {
    const behavior = this.behaviors.shift() ?? { type: "ready" }
    if (behavior.type === "spawn_error") throw new Error(behavior.message)
    const process = new TestWorkerProcess(plan, behavior)
    this.processes.push(process)
    return process
  }
}

type TestWorkerBehavior =
  | { readonly type: "ready" }
  | { readonly type: "wrong_ready" }
  | { readonly type: "fatal_start" }
  | { readonly type: "tools" | "tool_hang" | "tool_cancel_crossing" | "malformed_tool" }
  | { readonly type: "spawn_error"; readonly message: string }
  | { readonly type: "fatal"; readonly message: string }
  | { readonly type: "pending" }
  | { readonly type: "shutdown_append" }
  | { readonly type: "resist_terminate" }

class TestWorkerProcess implements ExtensionWorkerProcess {
  readonly stdout = new PassThrough()
  readonly stderr = new PassThrough()
  readonly protocol = new PassThrough()
  readonly input: Writable
  readonly exited: Promise<ExtensionWorkerExit>
  readonly messages: HostMessage[] = []
  readonly terminated: Array<"SIGTERM" | "SIGKILL"> = []
  disposed = false
  readonly #plan: ExtensionLoadPlan
  readonly #behavior: TestWorkerBehavior
  readonly #decoder = new ExtensionProtocolDecoder(validateHostMessage)
  readonly #resolveExit: (exit: ExtensionWorkerExit) => void
  #generation = 0
  #shutdownRequestId: number | undefined
  #exited = false

  constructor(plan: ExtensionLoadPlan, behavior: TestWorkerBehavior) {
    this.#plan = plan
    this.#behavior = behavior
    let resolveExit!: (exit: ExtensionWorkerExit) => void
    this.exited = new Promise(resolveProcessExit => {
      resolveExit = resolveProcessExit
    })
    this.#resolveExit = resolveExit
    this.input = new Writable({
      write: (chunk: Buffer, _encoding, callback) => {
        try {
          for (const message of this.#decoder.push(chunk)) this.#receive(message)
          callback()
        } catch (cause) {
          callback(cause instanceof Error ? cause : new Error(String(cause)))
        }
      }
    })
  }

  send(message: WorkerMessage): void {
    if (!this.#exited) this.protocol.write(encodeExtensionProtocolFrame(message))
  }

  failStartup(message: string): void {
    this.send({
      type: "fatal",
      generation: this.#generation,
      diagnostic: { phase: "handshake", severity: "error", message }
    })
  }

  crash(error: Error): void {
    this.#finish({ code: 1, signal: null, error })
  }

  terminate(force: boolean): void {
    this.terminated.push(force ? "SIGKILL" : "SIGTERM")
    if (this.#behavior.type === "resist_terminate" && !force) return
    this.#finish({ code: null, signal: force ? "SIGKILL" : "SIGTERM" })
  }

  dispose(): void {
    this.disposed = true
  }

  #receive(message: HostMessage): void {
    this.messages.push(message)
    if (
      message.type === "custom_entries_result" ||
      message.type === "custom_entry_result" ||
      message.type === "custom_message_result" ||
      message.type === "session_operation_error"
    ) {
      if (this.#behavior.type === "shutdown_append" && this.#shutdownRequestId !== undefined) {
        const requestId = this.#shutdownRequestId
        this.#shutdownRequestId = undefined
        this.send({ type: "settled", generation: this.#generation, requestId })
      }
      return
    }
    if (message.type === "initialize") {
      this.#generation = message.generation
      if (this.#behavior.type === "pending") return
      if (this.#behavior.type === "fatal") {
        this.send({
          type: "fatal",
          generation: message.generation,
          diagnostic: { phase: "handshake", severity: "error", message: this.#behavior.message }
        })
        return
      }
      this.send({
        type: "ready",
        protocolVersion: extensionProtocolVersion,
        generation: message.generation,
        extensions:
          this.#behavior.type === "wrong_ready" ? [] : this.#plan.sources.map(source => ({ source, status: "loaded" })),
        tools:
          this.#behavior.type === "tools" ||
          this.#behavior.type === "tool_hang" ||
          this.#behavior.type === "tool_cancel_crossing" ||
          this.#behavior.type === "malformed_tool"
            ? [toolRegistration(this.#plan.sources[0]!)]
            : []
      })
      return
    }
    if (message.type === "cancel") {
      if (this.#behavior.type === "tools") {
        this.send({ type: "tool_cancelled", generation: message.generation, requestId: message.requestId })
      } else if (this.#behavior.type === "tool_cancel_crossing") {
        this.send({
          type: "tool_result",
          generation: message.generation,
          requestId: message.requestId,
          content: "late"
        })
      }
      return
    }
    if (message.type === "tool_invoke") {
      if (this.#behavior.type === "malformed_tool") {
        this.protocol.write(
          encodeExtensionProtocolFrame({
            type: "tool_result",
            generation: message.generation,
            requestId: message.requestId,
            content: { invalid: true }
          })
        )
        return
      }
      if (this.#behavior.type === "tool_hang" || message.arguments.message === "pending") return
      if (message.arguments.message === "error") {
        this.send({
          type: "tool_error",
          generation: message.generation,
          requestId: message.requestId,
          message: "tool failed"
        })
        return
      }
      const content = message.arguments.message
      if (typeof content !== "string") throw new Error("Test tool expected a string message")
      this.send({
        type: "tool_result",
        generation: message.generation,
        requestId: message.requestId,
        content: content.toUpperCase()
      })
      return
    }
    if (message.type === "session_start" && this.#behavior.type === "fatal_start") {
      this.send({
        type: "fatal",
        generation: message.generation,
        diagnostic: { phase: "lifecycle", severity: "error", message: "start failed" }
      })
      return
    }
    if (message.type === "session_shutdown" && this.#behavior.type === "shutdown_append") {
      this.#shutdownRequestId = message.requestId
      this.send({
        type: "custom_entry_append",
        generation: message.generation,
        requestId: 1,
        extensionId: this.#plan.sources[0]!.id,
        customType: "example.shutdown",
        data: { final: true }
      })
      return
    }
    if (message.type === "stop" && this.#behavior.type === "resist_terminate") return
    this.send({ type: "settled", generation: message.generation, requestId: message.requestId })
    if (message.type === "stop") queueMicrotask(() => this.#finish({ code: 0, signal: null }))
  }

  #finish(exit: ExtensionWorkerExit): void {
    if (this.#exited) return
    this.#exited = true
    this.protocol.end()
    this.stdout.end()
    this.stderr.end()
    this.#resolveExit(exit)
  }
}

function toolRegistration(source: ExtensionSource) {
  return {
    source,
    name: "echo_message",
    label: "Echo",
    description: "Echo a message",
    parameters: { type: "object", required: ["message"], properties: { message: { type: "string" } } }
  } as const
}

function extensionSource(id: string): ExtensionSource {
  const path = resolve(`extension-host-${id}.ts`)
  return Object.freeze({ id, declaredPath: path, entryPath: path, scope: "temporary", origin: "cli" })
}

function extensionPlan(name: string, sources: readonly ExtensionSource[]): ExtensionLoadPlan {
  return Object.freeze({ cwd: resolve(`extension-host-${name}`), sources: Object.freeze([...sources]) })
}
