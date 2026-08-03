import { expect, test } from "bun:test"
import { spawn } from "node:child_process"
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join, resolve } from "node:path"
import { Readable } from "node:stream"

import type { ExtensionLoadPlan, ExtensionSource } from "../src/extensions/discovery.js"
import {
  encodeExtensionProtocolFrame,
  ExtensionProtocolDecoder,
  extensionProtocolVersion,
  type HostMessage,
  type WorkerMessage,
  validateWorkerMessage
} from "../src/extensions/protocol.js"
import { extensionWorkerArgument } from "../src/extensions/worker-entry.js"
import { testExtensionContext } from "./extension-context.js"

test("the CLI internal mode runs one external TypeScript worker generation on its dedicated pipe", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-extension-worker-entry-"))
  const extensionPath = join(root, "extension.ts")
  const lifecyclePath = join(root, "lifecycle.log")
  await writeFile(
    extensionPath,
    `import { appendFileSync } from "node:fs"
import type { ExtensionAPI } from "@with-zi/extension-api"
export default async function (zi: ExtensionAPI): Promise<void> {
  await Promise.resolve()
  console.log("extension stdout")
  console.error("extension stderr")
  zi.on("session_start", event => appendFileSync(${JSON.stringify(lifecyclePath)}, "start:" + event.reason + "\\n"))
  zi.on("session_shutdown", event => appendFileSync(${JSON.stringify(lifecyclePath)}, "stop:" + event.reason + "\\n"))
}
`
  )
  const source: ExtensionSource = Object.freeze({
    id: "entry-fixture",
    declaredPath: extensionPath,
    entryPath: extensionPath,
    scope: "temporary",
    origin: "cli"
  })
  const plan: ExtensionLoadPlan = Object.freeze({ cwd: root, sources: Object.freeze([source]) })
  const entrypoint = resolve(import.meta.dirname, "../../cli/src/main.ts")
  const child = spawn(process.execPath, [entrypoint, extensionWorkerArgument], {
    stdio: ["pipe", "pipe", "pipe", "pipe"],
    windowsHide: true
  })
  const protocol = child.stdio[3]
  if (!child.stdin || !child.stdout || !child.stderr || !(protocol instanceof Readable)) {
    child.kill("SIGKILL")
    throw new Error("Extension worker test did not create all protocol streams")
  }
  const messages = new WorkerMessageQueue(protocol)
  const stdout = readStream(child.stdout)
  const stderr = readStream(child.stderr)
  const closed = new Promise<number>((resolveClose, reject) => {
    child.once("error", reject)
    child.once("close", (code, signal) => resolveClose(code ?? (signal ? 1 : 0)))
  })

  try {
    send(child.stdin, { type: "initialize", protocolVersion: extensionProtocolVersion, generation: 1, plan })
    expect(await messages.next()).toMatchObject({ type: "ready", extensions: [{ status: "loaded" }] })
    send(child.stdin, {
      type: "session_start",
      generation: 1,
      requestId: 1,
      reason: "startup",
      context: testExtensionContext
    })
    expect(await messages.next()).toEqual({ type: "settled", generation: 1, requestId: 1 })
    send(child.stdin, { type: "session_shutdown", generation: 1, requestId: 2, reason: "quit" })
    expect(await messages.next()).toEqual({ type: "settled", generation: 1, requestId: 2 })
    send(child.stdin, { type: "stop", generation: 1, requestId: 3 })
    expect(await messages.next()).toEqual({ type: "settled", generation: 1, requestId: 3 })

    expect(await closed).toBe(0)
    expect(await stdout).toBe("extension stdout\n")
    expect(await stderr).toBe("extension stderr\n")
    expect(await readFile(lifecyclePath, "utf8")).toBe("start:startup\nstop:quit\n")
    messages.dispose()
  } finally {
    if (child.exitCode === null) child.kill("SIGKILL")
    await rm(root, { recursive: true, force: true })
  }
}, 10_000)

class WorkerMessageQueue {
  readonly #stream: Readable
  readonly #decoder = new ExtensionProtocolDecoder(validateWorkerMessage)
  readonly #messages: WorkerMessage[] = []
  readonly #waiters: Array<(message: WorkerMessage) => void> = []
  readonly #onData: (chunk: Buffer) => void

  constructor(stream: Readable) {
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

function send(stream: NodeJS.WritableStream, message: HostMessage): void {
  stream.write(encodeExtensionProtocolFrame(message))
}

async function readStream(stream: Readable): Promise<string> {
  const chunks: Buffer[] = []
  for await (const chunk of stream) chunks.push(Buffer.from(chunk))
  return Buffer.concat(chunks).toString("utf8")
}
