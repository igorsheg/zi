/* oxlint-disable unicorn/prefer-add-event-listener -- MCP Transport exposes callback properties, not EventTarget. */
import { afterEach, expect, test } from "bun:test"
import { fileURLToPath } from "node:url"

import {
  isJSONRPCResultResponse,
  type JSONRPCMessage,
  type JSONRPCNotification,
  type JSONRPCRequest
} from "@modelcontextprotocol/client"

import { maxMcpProtocolMessageBytes, maxMcpStderrBytes, OwnedStdioTransport } from "../src/mcp/stdio-transport.js"
import { createProcessTreeTracker, type ProcessScope, type ProcessTreeTracker } from "../src/processes/process-tree.js"

const fixture = fileURLToPath(new URL("./fixtures/mcp-server.ts", import.meta.url))
const cleanups = new Set<() => Promise<void>>()

afterEach(async () => {
  await Promise.all([...cleanups].map(cleanup => cleanup()))
  cleanups.clear()
})

test("owned stdio exchanges bounded MCP JSONL and closes idempotently", async () => {
  const owner = createTransport("echo")
  const messages: JSONRPCMessage[] = []
  owner.transport.onmessage = message => messages.push(message)
  let closes = 0
  owner.transport.onclose = () => closes++

  await owner.transport.start()
  await owner.transport.send(initializeRequest)
  await waitUntil(() => messages.length === 1)

  expect(messages[0]).toEqual({
    jsonrpc: "2.0",
    id: 1,
    result: {
      protocolVersion: "2025-03-26",
      capabilities: { tools: {} },
      serverInfo: { name: "zi-mcp-fixture", version: "1.0.0" }
    }
  })
  const first = owner.transport.close()
  const second = owner.transport.close()
  expect(second).toBe(first)
  await first
  expect(closes).toBe(1)
  await owner.transport.close()
  expect(closes).toBe(1)
})

test("owned stdio rejects outbound protocol messages over one MiB", async () => {
  const owner = createTransport("echo")
  await owner.transport.start()
  const message: JSONRPCNotification = {
    jsonrpc: "2.0",
    method: "notifications/message",
    params: { value: "x".repeat(maxMcpProtocolMessageBytes) }
  }

  expect(owner.transport.send(message)).rejects.toThrow(
    `MCP protocol messages cannot exceed ${maxMcpProtocolMessageBytes} encoded bytes`
  )
})

test.each(["malformed-utf8", "malformed-json", "unterminated", "oversized"])(
  "owned stdio closes on invalid server output: %s",
  async mode => {
    const owner = createTransport(mode)
    const errors: Error[] = []
    const closed = deferred<void>()
    owner.transport.onerror = error => errors.push(error)
    owner.transport.onclose = () => closed.resolve()

    await owner.transport.start().catch(() => undefined)
    await closed.promise

    expect(errors).toHaveLength(1)
    if (mode === "oversized") {
      expect(errors[0]?.message).toContain(`cannot exceed ${maxMcpProtocolMessageBytes}`)
    } else if (mode === "unterminated") {
      expect(errors[0]?.message).toContain("unterminated")
    } else {
      expect(errors[0]?.message).toMatch(/invalid protocol message|stdout/)
    }
  }
)

test("owned stdio retains only the bounded stderr tail", async () => {
  const owner = createTransport("stderr")
  owner.transport.onmessage = () => {}
  await owner.transport.start()
  await owner.transport.send(initializeRequest)
  await waitUntil(() => owner.transport.stderrTail().endsWith("STDERR_TAIL_MARKER"))

  const tail = owner.transport.stderrTail()
  expect(Buffer.byteLength(tail)).toBe(maxMcpStderrBytes)
  expect(tail.endsWith("STDERR_TAIL_MARKER")).toBe(true)
})

test("owned stdio reports process exit and publishes one close", async () => {
  const owner = createTransport("exit")
  const errors: Error[] = []
  let closes = 0
  const closed = deferred<void>()
  owner.transport.onerror = error => errors.push(error)
  owner.transport.onclose = () => {
    closes++
    closed.resolve()
  }

  await owner.transport.start().catch(() => undefined)
  await closed.promise

  expect(errors).toHaveLength(1)
  expect(errors[0]?.message).toMatch(/exited|stdout closed/)
  expect(closes).toBe(1)
})

test("owned stdio disposal removes a detached server descendant", async () => {
  const tracker = capturingTracker()
  const owner = createTransport("descendant", tracker.tracker)
  let descendantPid = 0
  owner.transport.onmessage = message => {
    if (!isJSONRPCResultResponse(message)) return
    const result = message.result
    if (typeof result === "object" && result !== null && "descendantPid" in result) {
      descendantPid = Number(result.descendantPid)
    }
  }

  await owner.transport.start()
  await owner.transport.send(initializeRequest)
  await waitUntil(() => descendantPid > 0)
  await tracker.scope().refresh()
  expect(isAlive(descendantPid)).toBe(true)

  await owner.transport.close()
  await waitUntil(() => !isAlive(descendantPid), 2_000)
  expect(isAlive(descendantPid)).toBe(false)
})

const initializeRequest: JSONRPCRequest = {
  jsonrpc: "2.0",
  id: 1,
  method: "initialize",
  params: { protocolVersion: "2025-03-26", capabilities: {}, clientInfo: { name: "zi-test", version: "1.0.0" } }
}

function createTransport(mode: string, tracker = createProcessTreeTracker()) {
  const transport = new OwnedStdioTransport(
    { command: [process.execPath, fixture, mode], cwd: process.cwd(), environment: process.env },
    tracker
  )
  const cleanup = async (): Promise<void> => {
    await transport.close().catch(() => undefined)
    await tracker.dispose().catch(() => undefined)
  }
  cleanups.add(cleanup)
  return { transport, tracker }
}

function capturingTracker(): { readonly tracker: ProcessTreeTracker; scope(): ProcessScope } {
  const owner = createProcessTreeTracker()
  let captured: ProcessScope | undefined
  const tracker: ProcessTreeTracker = {
    track(pid, onFailure) {
      captured = owner.track(pid, onFailure)
      return captured
    },
    dispose: () => owner.dispose()
  }
  return {
    tracker,
    scope() {
      if (!captured) throw new Error("Expected the MCP process scope to be admitted")
      return captured
    }
  }
}

async function waitUntil(predicate: () => boolean, timeoutMs = 1_000): Promise<void> {
  const deadline = Date.now() + timeoutMs
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error("Timed out waiting for MCP fixture state")
    // oxlint-disable-next-line no-await-in-loop -- bounded poll of process and stream settlement
    await Bun.sleep(5)
  }
}

function deferred<T>(): { readonly promise: Promise<T>; resolve(value: T): void } {
  let resolve!: (value: T) => void
  const promise = new Promise<T>(complete => {
    resolve = complete
  })
  return { promise, resolve }
}

function isAlive(pid: number): boolean {
  try {
    process.kill(pid, 0)
    return true
  } catch {
    return false
  }
}
