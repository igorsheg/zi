import { expect, test } from "bun:test"
import { mkdtemp, readFile, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { PassThrough, Writable } from "node:stream"

import type { ExtensionLoadPlan, ExtensionSource } from "../src/extensions/discovery.js"
import {
  encodeExtensionProtocolFrame,
  ExtensionProtocolDecoder,
  extensionProtocolVersion,
  type HostMessage,
  type WorkerMessage,
  validateWorkerMessage
} from "../src/extensions/protocol.js"
import { runExtensionWorkerProcess } from "../src/extensions/worker.js"

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

  send(input, { type: "session_start", generation: 1, requestId: 1, reason: "startup" })
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

test("worker process commits transitions before publishing their acknowledgements", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-extension-worker-ack-"))
  const extension = await fixture(root, "loaded.ts", `export default function () {}\n`)
  const input = new PassThrough()
  const output = new ControlledWorkerOutput()
  const run = runExtensionWorkerProcess(input, output)

  send(input, initialize(extensionPlan(root, [extension])))
  expect((await output.next()).type).toBe("ready")
  send(input, { type: "session_start", generation: 1, requestId: 1, reason: "startup" })
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
  send(input, { type: "session_start", generation: 1, requestId: 1, reason: "startup" })
  send(input, { type: "session_start", generation: 1, requestId: 2, reason: "reload" })

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
  send(input, { type: "session_start", generation: 1, requestId: 1, reason: "startup" })
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
  send(input, { type: "session_start", generation: 2, requestId: 1, reason: "startup" })
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
    return new Promise(resolve => this.#waiters.push(resolve))
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
    return new Promise(resolve => this.#waiters.push(resolve))
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
