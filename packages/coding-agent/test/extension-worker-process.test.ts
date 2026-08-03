import { expect, test } from "bun:test"
import { mkdtemp, readFile, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join, resolve } from "node:path"
import { PassThrough, Writable } from "node:stream"
import { pathToFileURL } from "node:url"

import type { ExtensionLoadPlan, ExtensionSource } from "../src/extensions/discovery.js"
import {
  encodeExtensionProtocolFrame,
  ExtensionProtocolDecoder,
  extensionProtocolVersion,
  maxExtensionPendingRequests,
  type HostMessage,
  type WorkerMessage,
  validateWorkerMessage
} from "../src/extensions/protocol.js"
import { runExtensionWorkerProcess } from "../src/extensions/worker.js"
import { testExtensionContext } from "./extension-context.js"

const extensionApi = pathToFileURL(resolve(import.meta.dirname, "../../extension-api/src/index.ts")).href

test("worker process decodes requests without stdout and settles one lifecycle", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-extension-worker-process-"))
  const log = join(root, "lifecycle.log")
  const extension = await fixture(
    root,
    "lifecycle.ts",
    `import { appendFileSync } from "node:fs"
export default function (zi): void {
  zi.on("session_start", event => appendFileSync(${JSON.stringify(log)}, "start:" + event.reason + "\\n"))
  zi.on("session_shutdown", event => appendFileSync(${JSON.stringify(log)}, "stop:" + event.reason + "\\n"))
}
`
  )
  const input = new PassThrough()
  const output = new PassThrough()
  const messages = new WorkerMessageQueue(output)
  const run = runExtensionWorkerProcess(input, output)

  send(input, initialize(extensionPlan(root, [extension])))
  expect(await messages.next()).toMatchObject({ type: "ready", generation: 1, extensions: [{ status: "loaded" }] })

  send(input, { type: "session_start", generation: 1, requestId: 1, reason: "startup", context: testExtensionContext })
  expect(await messages.next()).toEqual({ type: "settled", generation: 1, requestId: 1 })
  send(input, { type: "session_shutdown", generation: 1, requestId: 2, reason: "quit" })
  expect(await messages.next()).toEqual({ type: "settled", generation: 1, requestId: 2 })
  send(input, { type: "stop", generation: 1, requestId: 3 })
  expect(await messages.next()).toEqual({ type: "settled", generation: 1, requestId: 3 })

  await run
  expect(await readFile(log, "utf8")).toBe("start:startup\nstop:quit\n")
  messages.dispose()
  output.destroy()
})

test("worker process serializes bounded agent event notifications", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-extension-worker-agent-events-"))
  const log = join(root, "events.log")
  const extension = await fixture(
    root,
    "events.ts",
    `import { appendFileSync } from "node:fs"
export default function (zi): void {
  zi.on("agent_start", async () => {
    appendFileSync(${JSON.stringify(log)}, "start\\n")
    await new Promise(resolve => setTimeout(resolve, 10))
    appendFileSync(${JSON.stringify(log)}, "start-done\\n")
  })
  zi.on("agent_settled", () => appendFileSync(${JSON.stringify(log)}, "settled\\n"))
}
`
  )
  const input = new PassThrough()
  const output = new PassThrough()
  const messages = new WorkerMessageQueue(output)
  const running = runExtensionWorkerProcess(input, output)

  send(input, {
    type: "initialize",
    protocolVersion: extensionProtocolVersion,
    generation: 1,
    plan: extensionPlan(root, [extension])
  })
  await messages.next()
  send(input, { type: "session_start", generation: 1, requestId: 1, reason: "startup", context: testExtensionContext })
  await messages.next()
  send(input, { type: "agent_start", generation: 1, sequence: 1 })
  send(input, { type: "agent_settled", generation: 1, sequence: 2 })

  expect(await messages.next()).toEqual({ type: "agent_event_settled", generation: 1, sequence: 1 })
  expect(await messages.next()).toEqual({ type: "agent_event_settled", generation: 1, sequence: 2 })
  expect(await readFile(log, "utf8")).toBe("start\nstart-done\nsettled\n")

  send(input, { type: "session_shutdown", generation: 1, requestId: 2, reason: "quit" })
  await messages.next()
  send(input, { type: "stop", generation: 1, requestId: 3 })
  await messages.next()
  await running
  messages.dispose()
})

test("worker process commits transitions before publishing their acknowledgements", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-extension-worker-ack-"))
  const extension = await fixture(root, "loaded.ts", `export default function () {}\n`)
  const input = new PassThrough()
  const output = new ControlledWorkerOutput()
  const run = runExtensionWorkerProcess(input, output)

  send(input, initialize(extensionPlan(root, [extension])))
  expect((await output.next()).type).toBe("ready")
  send(input, { type: "session_start", generation: 1, requestId: 1, reason: "startup", context: testExtensionContext })
  output.releaseWrite()

  expect(await output.next()).toEqual({ type: "settled", generation: 1, requestId: 1 })
  send(input, { type: "session_shutdown", generation: 1, requestId: 2, reason: "quit" })
  output.releaseWrite()

  expect(await output.next()).toEqual({ type: "settled", generation: 1, requestId: 2 })
  send(input, { type: "stop", generation: 1, requestId: 3 })
  output.releaseWrite()

  expect(await output.next()).toEqual({ type: "settled", generation: 1, requestId: 3 })
  output.releaseWrite()
  await run
  output.endProtocol()
})

test("worker process keeps reading while a lifecycle handler is pending", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-extension-worker-reentrant-"))
  const extension = await fixture(
    root,
    "pending.ts",
    `export default function (zi): void {
  zi.on("session_start", async () => { await new Promise(() => {}) })
}
`
  )
  const input = new PassThrough()
  const output = new PassThrough()
  const messages = new WorkerMessageQueue(output)
  const run = runExtensionWorkerProcess(input, output)

  send(input, initialize(extensionPlan(root, [extension])))
  expect((await messages.next()).type).toBe("ready")
  send(input, { type: "session_start", generation: 1, requestId: 1, reason: "startup", context: testExtensionContext })
  send(input, { type: "session_start", generation: 1, requestId: 2, reason: "reload", context: testExtensionContext })

  expect(await messages.next()).toMatchObject({
    type: "fatal",
    generation: 1,
    diagnostic: { phase: "protocol", message: "Extension worker cannot receive session_start while dispatching" }
  })
  expect(run).rejects.toThrow("cannot receive session_start while dispatching")
  messages.dispose()
  output.destroy()
})

test("worker process correlates cancellation without treating it as shutdown", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-extension-worker-cancel-"))
  const extension = await fixture(
    root,
    "cancel.ts",
    `export default function (zi): void {
  zi.on("session_start", async () => { await new Promise(resolve => setTimeout(resolve, 20)) })
}
`
  )
  const input = new PassThrough()
  const output = new PassThrough()
  const messages = new WorkerMessageQueue(output)
  const run = runExtensionWorkerProcess(input, output)

  send(input, initialize(extensionPlan(root, [extension])))
  expect((await messages.next()).type).toBe("ready")
  send(input, { type: "session_start", generation: 1, requestId: 1, reason: "startup", context: testExtensionContext })
  send(input, { type: "cancel", generation: 1, requestId: 1 })
  expect(await messages.next()).toEqual({ type: "settled", generation: 1, requestId: 1 })
  send(input, { type: "session_shutdown", generation: 1, requestId: 2, reason: "quit" })
  expect(await messages.next()).toEqual({ type: "settled", generation: 1, requestId: 2 })
  send(input, { type: "stop", generation: 1, requestId: 3 })
  expect(await messages.next()).toEqual({ type: "settled", generation: 1, requestId: 3 })

  await run
  messages.dispose()
  output.destroy()
})

test("worker process executes, rejects, cancels, and reuses registered commands", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-extension-worker-command-"))
  const extension = await fixture(
    root,
    "command.ts",
    `export default function (zi): void {
  zi.registerCommand({
    name: "echo",
    description: "Echo command arguments",
    argumentHint: "[text]",
    async execute(arguments_, { signal }) {
      if (arguments_ === "throw") throw new Error("command exploded")
      if (arguments_ === "wait") {
        if (!signal.aborted) await new Promise(resolve => signal.addEventListener("abort", resolve, { once: true }))
        return "late"
      }
      return arguments_.toUpperCase()
    }
  })
}
`
  )
  const input = new PassThrough()
  const output = new PassThrough()
  const messages = new WorkerMessageQueue(output)
  const run = runExtensionWorkerProcess(input, output)

  send(input, initialize(extensionPlan(root, [extension])))
  expect(await messages.next()).toMatchObject({
    type: "ready",
    commands: [{ name: "echo", source: { id: extension.id } }]
  })
  send(input, { type: "session_start", generation: 1, requestId: 1, reason: "startup", context: testExtensionContext })
  expect((await messages.next()).type).toBe("settled")

  send(input, { type: "command_invoke", generation: 1, requestId: 2, name: "echo", arguments: "hello" })
  expect(await messages.next()).toEqual({ type: "command_result", generation: 1, requestId: 2, message: "HELLO" })
  send(input, { type: "command_invoke", generation: 1, requestId: 3, name: "echo", arguments: "throw" })
  expect(await messages.next()).toEqual({
    type: "command_error",
    generation: 1,
    requestId: 3,
    message: "command exploded"
  })
  send(input, { type: "command_invoke", generation: 1, requestId: 4, name: "echo", arguments: "wait" })
  send(input, { type: "cancel", generation: 1, requestId: 4 })
  expect(await messages.next()).toEqual({ type: "command_cancelled", generation: 1, requestId: 4 })
  send(input, { type: "command_invoke", generation: 1, requestId: 5, name: "echo", arguments: "again" })
  expect(await messages.next()).toEqual({ type: "command_result", generation: 1, requestId: 5, message: "AGAIN" })

  send(input, { type: "session_shutdown", generation: 1, requestId: 6, reason: "quit" })
  expect((await messages.next()).type).toBe("settled")
  send(input, { type: "stop", generation: 1, requestId: 7 })
  expect((await messages.next()).type).toBe("settled")
  await run
  messages.dispose()
  output.destroy()
})

test("worker process rejects command replay after bounded settled-request eviction", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-extension-worker-command-replay-"))
  const calls = join(root, "calls.log")
  const extension = await fixture(
    root,
    "command.ts",
    `import { appendFileSync } from "node:fs"
export default zi => zi.registerCommand({
  name: "record",
  description: "Record one call",
  execute: () => {
    appendFileSync(${JSON.stringify(calls)}, "called\\n")
    return "done"
  }
})
`
  )
  const input = new PassThrough()
  const output = new PassThrough()
  const messages = new WorkerMessageQueue(output)
  const run = runExtensionWorkerProcess(input, output)

  send(input, initialize(extensionPlan(root, [extension])))
  expect((await messages.next()).type).toBe("ready")
  send(input, { type: "session_start", generation: 1, requestId: 1, reason: "startup", context: testExtensionContext })
  expect((await messages.next()).type).toBe("settled")
  send(input, { type: "command_invoke", generation: 1, requestId: 2, name: "record", arguments: "" })
  expect(await messages.next()).toEqual({ type: "command_result", generation: 1, requestId: 2, message: "done" })
  for (let requestId = 3; requestId < maxExtensionPendingRequests + 3; requestId++) {
    send(input, { type: "command_invoke", generation: 1, requestId, name: "record", arguments: "" })
    // Sequential settlement intentionally advances beyond the bounded cancellation-crossing window.
    // oxlint-disable-next-line no-await-in-loop
    expect(await messages.next()).toEqual({ type: "command_result", generation: 1, requestId, message: "done" })
  }

  send(input, { type: "command_invoke", generation: 1, requestId: 2, name: "record", arguments: "" })
  expect(await messages.next()).toMatchObject({
    type: "fatal",
    diagnostic: { phase: "protocol", message: "Extension worker received a replayed invocation request" }
  })
  expect(run).rejects.toThrow("replayed invocation request")
  expect(await readFile(calls, "utf8")).toBe("called\n".repeat(maxExtensionPendingRequests + 1))
  messages.dispose()
  output.destroy()
})

test("worker process executes, rejects, cancels, and reuses registered tools", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-extension-worker-tool-"))
  const extension = await fixture(
    root,
    "tool.ts",
    `import { Schema } from ${JSON.stringify(extensionApi)}
export default function (zi): void {
  zi.registerTool({
    name: "echo_message",
    description: "Echo a message",
    parameters: Schema.object({ message: Schema.string() }),
    async execute({ message }, { signal }) {
      if (message === "throw") throw new Error("tool exploded")
      if (message === "wait") {
        if (!signal.aborted) await new Promise(resolve => signal.addEventListener("abort", resolve, { once: true }))
        return "late"
      }
      return message.toUpperCase()
    }
  })
}
`
  )
  const input = new PassThrough()
  const output = new PassThrough()
  const messages = new WorkerMessageQueue(output)
  const run = runExtensionWorkerProcess(input, output)

  send(input, initialize(extensionPlan(root, [extension])))
  expect(await messages.next()).toMatchObject({
    type: "ready",
    tools: [{ name: "echo_message", source: { id: extension.id } }]
  })
  send(input, { type: "session_start", generation: 1, requestId: 1, reason: "startup", context: testExtensionContext })
  expect((await messages.next()).type).toBe("settled")

  send(input, {
    type: "tool_invoke",
    generation: 1,
    requestId: 2,
    name: "echo_message",
    arguments: { message: "hello" }
  })
  expect(await messages.next()).toEqual({ type: "tool_result", generation: 1, requestId: 2, value: "HELLO" })
  send(input, { type: "tool_invoke", generation: 1, requestId: 3, name: "echo_message", arguments: { message: 42 } })
  expect(await messages.next()).toMatchObject({
    type: "tool_error",
    requestId: 3,
    message: expect.stringContaining("Invalid arguments")
  })
  send(input, {
    type: "tool_invoke",
    generation: 1,
    requestId: 4,
    name: "echo_message",
    arguments: { message: "throw" }
  })
  expect(await messages.next()).toMatchObject({ type: "tool_error", requestId: 4, message: "tool exploded" })
  send(input, {
    type: "tool_invoke",
    generation: 1,
    requestId: 5,
    name: "echo_message",
    arguments: { message: "wait" }
  })
  send(input, { type: "cancel", generation: 1, requestId: 5 })
  expect(await messages.next()).toEqual({ type: "tool_cancelled", generation: 1, requestId: 5 })
  send(input, {
    type: "tool_invoke",
    generation: 1,
    requestId: 6,
    name: "echo_message",
    arguments: { message: "again" }
  })
  expect(await messages.next()).toEqual({ type: "tool_result", generation: 1, requestId: 6, value: "AGAIN" })

  send(input, {
    type: "tool_invoke",
    generation: 1,
    requestId: 7,
    name: "echo_message",
    arguments: { message: "wait" }
  })
  send(input, { type: "session_shutdown", generation: 1, requestId: 8, reason: "quit" })
  expect(await messages.next()).toMatchObject({
    type: "fatal",
    diagnostic: { phase: "protocol", message: "Extension worker cannot shut down with active invocations" }
  })
  expect(run).rejects.toThrow("cannot shut down with active invocations")
  messages.dispose()
  output.destroy()
})

test("worker process tolerates cancellation crossing a completed tool response", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-extension-worker-tool-crossing-"))
  const extension = await fixture(
    root,
    "tool.ts",
    `import { Schema } from ${JSON.stringify(extensionApi)}
export default zi => zi.registerTool({
  name: "echo_message",
  description: "Echo",
  parameters: Schema.object({ message: Schema.string() }),
  execute: ({ message }) => message
})
`
  )
  const input = new PassThrough()
  const output = new ControlledWorkerOutput()
  const run = runExtensionWorkerProcess(input, output)

  send(input, initialize(extensionPlan(root, [extension])))
  expect((await output.next()).type).toBe("ready")
  output.releaseWrite()
  send(input, { type: "session_start", generation: 1, requestId: 1, reason: "startup", context: testExtensionContext })
  expect((await output.next()).type).toBe("settled")
  output.releaseWrite()

  send(input, {
    type: "tool_invoke",
    generation: 1,
    requestId: 2,
    name: "echo_message",
    arguments: { message: "done" }
  })
  expect(await output.next()).toEqual({ type: "tool_result", generation: 1, requestId: 2, value: "done" })
  send(input, { type: "cancel", generation: 1, requestId: 2 })
  send(input, { type: "session_shutdown", generation: 1, requestId: 3, reason: "quit" })
  await Bun.sleep(0)
  output.releaseWrite()
  expect((await output.next()).type).toBe("settled")
  send(input, { type: "cancel", generation: 1, requestId: 2 })
  output.releaseWrite()
  send(input, { type: "stop", generation: 1, requestId: 4 })
  expect((await output.next()).type).toBe("settled")
  output.releaseWrite()
  await run
  output.endProtocol()
})

test("worker process rejects stale-generation cancellation after an invocation settles", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-extension-worker-stale-cancel-"))
  const extension = await fixture(
    root,
    "tool.ts",
    `import { Schema } from ${JSON.stringify(extensionApi)}
export default zi => zi.registerTool({
  name: "echo_message",
  description: "Echo",
  parameters: Schema.object({ message: Schema.string() }),
  execute: ({ message }) => message
})
`
  )
  const input = new PassThrough()
  const output = new PassThrough()
  const messages = new WorkerMessageQueue(output)
  const run = runExtensionWorkerProcess(input, output)

  send(input, initialize(extensionPlan(root, [extension])))
  expect((await messages.next()).type).toBe("ready")
  send(input, { type: "session_start", generation: 1, requestId: 1, reason: "startup", context: testExtensionContext })
  expect((await messages.next()).type).toBe("settled")
  send(input, {
    type: "tool_invoke",
    generation: 1,
    requestId: 2,
    name: "echo_message",
    arguments: { message: "done" }
  })
  expect(await messages.next()).toEqual({ type: "tool_result", generation: 1, requestId: 2, value: "done" })

  send(input, { type: "cancel", generation: 2, requestId: 2 })
  expect(await messages.next()).toMatchObject({
    type: "fatal",
    diagnostic: { phase: "protocol", message: "Extension worker received cancellation for a stale generation" }
  })
  expect(run).rejects.toThrow("cancellation for a stale generation")
  messages.dispose()
  output.destroy()
})

test("cancelled tools remain owned until execution settles", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-extension-worker-tool-cancel-bound-"))
  const extension = await fixture(
    root,
    "tool.ts",
    `import { Schema } from ${JSON.stringify(extensionApi)}
export default zi => zi.registerTool({
  name: "pending_tool",
  description: "Never settle",
  parameters: Schema.object({}),
  execute: async () => await new Promise(() => {})
})
`
  )
  const input = new PassThrough()
  const output = new PassThrough()
  const messages = new WorkerMessageQueue(output)
  const run = runExtensionWorkerProcess(input, output)

  send(input, initialize(extensionPlan(root, [extension])))
  expect((await messages.next()).type).toBe("ready")
  send(input, { type: "session_start", generation: 1, requestId: 1, reason: "startup", context: testExtensionContext })
  expect((await messages.next()).type).toBe("settled")
  for (let index = 0; index < maxExtensionPendingRequests; index++) {
    const requestId = index + 2
    send(input, { type: "tool_invoke", generation: 1, requestId, name: "pending_tool", arguments: {} })
    send(input, { type: "cancel", generation: 1, requestId })
  }
  send(input, {
    type: "tool_invoke",
    generation: 1,
    requestId: maxExtensionPendingRequests + 2,
    name: "pending_tool",
    arguments: {}
  })

  expect(await messages.next()).toMatchObject({
    type: "fatal",
    diagnostic: {
      phase: "protocol",
      message: `Extension worker cannot run more than ${maxExtensionPendingRequests} invocations`
    }
  })
  expect(run).rejects.toThrow(`more than ${maxExtensionPendingRequests} invocations`)
  messages.dispose()
  output.destroy()
})

test("worker process reports source failures in ready and reserves fatal for generation failure", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-extension-worker-partial-"))
  const failed = await fixture(root, "failed.ts", `throw new Error("source failed")\n`)
  const loaded = await fixture(root, "loaded.ts", `export default function () {}\n`)
  const input = new PassThrough()
  const output = new PassThrough()
  const messages = new WorkerMessageQueue(output)
  const run = runExtensionWorkerProcess(input, output)

  send(input, initialize(extensionPlan(root, [failed, loaded])))
  expect(await messages.next()).toMatchObject({
    type: "ready",
    extensions: [
      { status: "failed", diagnostic: { extensionId: failed.id, phase: "import", message: "source failed" } },
      { status: "loaded" }
    ]
  })
  send(input, { type: "stop", generation: 1, requestId: 1 })
  expect((await messages.next()).type).toBe("settled")
  await run
  messages.dispose()
  output.destroy()
})

test("worker process rejects stale generations and closed host input", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-extension-worker-stale-"))
  const extension = await fixture(root, "loaded.ts", `export default function () {}\n`)
  const input = new PassThrough()
  const output = new PassThrough()
  const messages = new WorkerMessageQueue(output)
  const run = runExtensionWorkerProcess(input, output)

  send(input, initialize(extensionPlan(root, [extension])))
  expect((await messages.next()).type).toBe("ready")
  send(input, { type: "session_start", generation: 2, requestId: 1, reason: "startup", context: testExtensionContext })
  expect(await messages.next()).toMatchObject({
    type: "fatal",
    diagnostic: { phase: "protocol", message: "Extension worker received a stale generation request" }
  })
  expect(run).rejects.toThrow("stale generation")
  messages.dispose()
  output.destroy()

  const closedInput = new PassThrough()
  const closedOutput = new PassThrough()
  const closedMessages = new WorkerMessageQueue(closedOutput)
  const closedRun = runExtensionWorkerProcess(closedInput, closedOutput)
  send(closedInput, initialize(extensionPlan(root, [extension])))
  expect((await closedMessages.next()).type).toBe("ready")
  closedInput.end()
  expect(await closedMessages.next()).toMatchObject({
    type: "fatal",
    diagnostic: { phase: "protocol", message: "Extension host input ended before the worker stopped" }
  })
  expect(closedRun).rejects.toThrow("input ended")
  closedMessages.dispose()
  closedOutput.destroy()
})

test("worker process exits when its protocol output fails while host input stays open", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-extension-worker-output-"))
  const extension = await fixture(root, "loaded.ts", `export default function () {}\n`)
  const input = new PassThrough()
  const output = new PassThrough()
  const messages = new WorkerMessageQueue(output)
  const run = runExtensionWorkerProcess(input, output)

  send(input, initialize(extensionPlan(root, [extension])))
  expect((await messages.next()).type).toBe("ready")
  output.destroy(new Error("protocol output closed"))

  expect(run).rejects.toThrow("protocol output closed")
  messages.dispose()
})

test("worker process reports malformed input as fatal after initialization", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-extension-worker-malformed-"))
  const extension = await fixture(root, "loaded.ts", `export default function () {}\n`)
  const input = new PassThrough()
  const output = new PassThrough()
  const messages = new WorkerMessageQueue(output)
  const run = runExtensionWorkerProcess(input, output)

  send(input, initialize(extensionPlan(root, [extension])))
  expect((await messages.next()).type).toBe("ready")
  const malformed = Buffer.alloc(4)
  malformed.writeUInt32BE(0)
  input.write(malformed)

  expect(await messages.next()).toMatchObject({
    type: "fatal",
    diagnostic: { phase: "protocol", message: "Extension protocol frames cannot be empty" }
  })
  expect(run).rejects.toThrow("frames cannot be empty")
  messages.dispose()
  output.destroy()
})

test("worker process rejects malformed input before initialization", async () => {
  const input = new PassThrough()
  const output = new PassThrough()
  const run = runExtensionWorkerProcess(input, output)
  const malformed = Buffer.alloc(4)
  malformed.writeUInt32BE(0)
  input.end(malformed)

  expect(run).rejects.toThrow("frames cannot be empty")
  output.destroy()
})

class ControlledWorkerOutput extends Writable {
  readonly #decoder = new ExtensionProtocolDecoder(validateWorkerMessage)
  readonly #messages: WorkerMessage[] = []
  readonly #waiters: Array<(message: WorkerMessage) => void> = []
  readonly #writes: Array<() => void> = []

  override _write(chunk: Buffer, _encoding: BufferEncoding, callback: (error?: Error | null) => void): void {
    for (const message of this.#decoder.push(chunk)) {
      const waiter = this.#waiters.shift()
      if (waiter) waiter(message)
      else this.#messages.push(message)
    }
    this.#writes.push(callback)
  }

  next(): Promise<WorkerMessage> {
    const message = this.#messages.shift()
    if (message) return Promise.resolve(message)
    return new Promise(resolveMessage => this.#waiters.push(resolveMessage))
  }

  releaseWrite(): void {
    const write = this.#writes.shift()
    if (!write) throw new Error("Extension worker has no protocol write to release")
    write()
  }

  endProtocol(): void {
    this.#decoder.end()
  }
}

class WorkerMessageQueue {
  readonly #stream: PassThrough
  readonly #decoder = new ExtensionProtocolDecoder(validateWorkerMessage)
  readonly #messages: WorkerMessage[] = []
  readonly #waiters: Array<(message: WorkerMessage) => void> = []
  readonly #onData: (chunk: Buffer) => void

  constructor(stream: PassThrough) {
    this.#stream = stream
    this.#onData = chunk => {
      for (const message of this.#decoder.push(chunk)) {
        const waiter = this.#waiters.shift()
        if (waiter) waiter(message)
        else this.#messages.push(message)
      }
    }
    stream.on("data", this.#onData)
  }

  next(): Promise<WorkerMessage> {
    const message = this.#messages.shift()
    if (message) return Promise.resolve(message)
    return new Promise(resolveMessage => this.#waiters.push(resolveMessage))
  }

  dispose(): void {
    this.#stream.off("data", this.#onData)
    this.#decoder.end()
  }
}

function send(input: PassThrough, message: HostMessage): void {
  input.write(encodeExtensionProtocolFrame(message))
}

function initialize(plan: ExtensionLoadPlan): HostMessage {
  return { type: "initialize", protocolVersion: extensionProtocolVersion, generation: 1, plan }
}

async function fixture(root: string, name: string, contents: string): Promise<ExtensionSource> {
  const path = join(root, name)
  await writeFile(path, contents)
  return Object.freeze({ id: name, declaredPath: path, entryPath: path, scope: "temporary", origin: "cli" })
}

function extensionPlan(cwd: string, sources: readonly ExtensionSource[]): ExtensionLoadPlan {
  return Object.freeze({ cwd, sources: Object.freeze([...sources]) })
}
