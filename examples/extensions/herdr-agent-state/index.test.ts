import { afterEach, expect, test } from "bun:test"
import { rm } from "node:fs/promises"
import { createServer } from "node:net"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type { ExtensionContext, ExtensionEvent } from "@with-zi/extension-api"

import install, { herdrSocketEndpoint } from "./index.js"

const originalEnvironment = {
  HERDR_ENV: process.env.HERDR_ENV,
  HERDR_PANE_ID: process.env.HERDR_PANE_ID,
  HERDR_SOCKET_PATH: process.env.HERDR_SOCKET_PATH
}

let closeServer: (() => Promise<void>) | undefined
let socketPath: string | undefined

afterEach(async () => {
  await closeServer?.()
  closeServer = undefined
  if (socketPath) {
    await rm(socketPath, { force: true })
    socketPath = undefined
  }
  for (const [name, value] of Object.entries(originalEnvironment)) {
    if (value === undefined) delete process.env[name]
    else process.env[name] = value
  }
})

test.serial("Herdr socket endpoints use Windows named-pipe syntax", () => {
  expect(herdrSocketEndpoint("herdr.sock", "win32")).toBe("\\\\.\\pipe\\herdr.sock")
  expect(herdrSocketEndpoint("/tmp/herdr.sock", "darwin")).toBe("/tmp/herdr.sock")
})

test.serial("the Herdr extension stays dormant without its complete environment", () => {
  process.env.HERDR_ENV = "1"
  delete process.env.HERDR_SOCKET_PATH
  process.env.HERDR_PANE_ID = "w1:p1"
  const handlers = extensionHarness()

  install(handlers.api)

  expect(handlers.events.size).toBe(0)
})

test.serial("the Herdr extension reports interactive session and settled agent state", async () => {
  const requests = await startRecordingServer()
  const handlers = extensionHarness()
  install(handlers.api)
  const context: ExtensionContext = Object.freeze({
    mode: "interactive",
    cwd: "/work/project",
    session: Object.freeze({ type: "journal", id: "zi-session", file: "/work/session.jsonl" })
  })

  await handlers.call("session_start", { type: "session_start", reason: "startup" }, context)
  await waitFor(() => requests.length === 2)
  await handlers.call("agent_start", { type: "agent_start" }, context)
  await waitFor(() => requests.length === 3)
  await handlers.call("agent_settled", { type: "agent_settled" }, context)
  await waitFor(() => requests.length === 4)
  await handlers.call("session_shutdown", { type: "session_shutdown", reason: "quit" }, context)

  expect(requests.map(request => request.method)).toEqual([
    "pane.report_agent_session",
    "pane.report_agent",
    "pane.report_agent",
    "pane.report_agent"
  ])
  expect(requests[0]?.params).toMatchObject({
    pane_id: "w1:p1",
    source: "herdr:zi",
    agent: "zi",
    session_start_source: "startup",
    agent_session_path: "/work/session.jsonl"
  })
  expect(requests.slice(1).map(request => request.params.state)).toEqual(["idle", "working", "idle"])
  expect(requests.slice(1).every(request => request.params.agent_session_path === "/work/session.jsonl")).toBe(true)
  const sequences = requests.map(request => request.params.seq)
  expect(sequences).toEqual(sequences.toSorted((left, right) => left - right))
  expect(new Set(sequences).size).toBe(sequences.length)
})

test.serial("the Herdr extension ignores headless Zi modes", async () => {
  const requests = await startRecordingServer()
  const handlers = extensionHarness()
  install(handlers.api)
  const context: ExtensionContext = Object.freeze({
    mode: "rpc",
    cwd: "/work/project",
    session: Object.freeze({ type: "memory", id: "zi-memory" })
  })

  await handlers.call("session_start", { type: "session_start", reason: "startup" }, context)
  await handlers.call("agent_start", { type: "agent_start" }, context)
  await handlers.call("agent_settled", { type: "agent_settled" }, context)

  expect(requests).toEqual([])
})

interface RecordedRequest {
  readonly method: string
  readonly params: Readonly<Record<string, unknown>> & { readonly seq: number }
}

type Handler = (event: ExtensionEvent, context: ExtensionContext) => unknown

function extensionHarness(): {
  readonly api: Pick<Parameters<typeof install>[0], "on">
  readonly events: Map<ExtensionEvent["type"], Handler>
  call(type: ExtensionEvent["type"], event: ExtensionEvent, context: ExtensionContext): Promise<void>
} {
  const events = new Map<ExtensionEvent["type"], Handler>()
  const api: Parameters<typeof install>[0] = {
    on(type, handler): void {
      // The harness invokes handlers only with the matching closed event type below.
      // oxlint-disable-next-line typescript/no-unsafe-type-assertion
      events.set(type, handler as Handler)
    }
  }
  return {
    api,
    events,
    async call(type, event, context): Promise<void> {
      await events.get(type)?.(event, context)
    }
  }
}

async function startRecordingServer(): Promise<RecordedRequest[]> {
  socketPath = join(tmpdir(), `zi-herdr-${process.pid}-${Date.now()}.sock`)
  await rm(socketPath, { force: true })
  const requests: RecordedRequest[] = []
  const server = createServer(socket => {
    let input = ""
    socket.setEncoding("utf8")
    socket.on("data", chunk => {
      input += chunk
      const newline = input.indexOf("\n")
      if (newline === -1) return
      requests.push(parseRecordedRequest(input.slice(0, newline)))
      socket.end("{}\n")
    })
  })
  closeServer = () =>
    new Promise<void>((resolve, reject) =>
      server.close(error => {
        if (error) {
          reject(error)
          return
        }
        resolve()
      })
    )
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject)
    server.listen(socketPath, resolve)
  })
  process.env.HERDR_ENV = "1"
  process.env.HERDR_SOCKET_PATH = socketPath
  process.env.HERDR_PANE_ID = "w1:p1"
  return requests
}

function parseRecordedRequest(input: string): RecordedRequest {
  const value: unknown = JSON.parse(input)
  if (!isRecord(value) || typeof value.method !== "string" || !isRecord(value.params)) {
    throw new Error("Herdr request is malformed")
  }
  if (typeof value.params.seq !== "number") throw new Error("Herdr request sequence is malformed")
  return { method: value.method, params: { ...value.params, seq: value.params.seq } }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}

async function waitFor(predicate: () => boolean): Promise<void> {
  for (let attempt = 0; attempt < 1_000; attempt++) {
    if (predicate()) return
    // oxlint-disable-next-line no-await-in-loop -- bounded poll of recorded socket delivery
    await Bun.sleep(1)
  }
  throw new Error("Herdr request was not delivered")
}
