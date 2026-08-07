import { expect, test } from "bun:test"

import { PeerMessenger } from "../src/subagents/peer-messenger.js"
import { decodePeerRequestFrame, decodePeerResponse } from "../src/subagents/peer-protocol.js"

test("PeerMessenger exposes bounded list and queue-only send tools over one correlated transport", async () => {
  const messenger = new PeerMessenger()
  const requests: Array<Parameters<Parameters<PeerMessenger["bind"]>[0]>[0]> = []
  const unbind = messenger.bind(request => requests.push(request))
  const [list, send] = messenger.createTools()
  if (!list || !send) throw new Error("Expected peer tools")

  const listed = list.execute("list", {}, undefined)
  expect(requests).toEqual([{ id: "peer-1", operation: "list" }])
  expect(
    messenger.accept({
      id: "peer-1",
      operation: "list",
      ok: true,
      result: { peers: [{ name: "worker-b", lifecycle: "running" }] }
    })
  ).toBe(true)
  expect((await listed).content).toEqual([
    { type: "text", text: '{"peers":[{"name":"worker-b","lifecycle":"running"}]}' }
  ])

  const delivered = send.execute("send", { name: "worker-b", text: "context" }, undefined)
  expect(requests.at(-1)).toEqual({ id: "peer-2", operation: "send", target: "worker-b", text: "context" })
  expect(messenger.accept({ id: "peer-2", operation: "send", ok: true, result: { delivered: true } })).toBe(true)
  expect((await delivered).content).toEqual([{ type: "text", text: "Sent context to sibling worker-b." }])

  unbind()
  messenger.dispose()
})

test("PeerMessenger rejects failed, mismatched, and disconnected relay requests", async () => {
  const messenger = new PeerMessenger()
  let requestId = ""
  const unbind = messenger.bind(request => {
    requestId = request.id
  })
  const send = messenger.createTools().find(tool => tool.name === "send_peer_message")
  if (!send) throw new Error("Expected send_peer_message")

  const failed = send.execute("send", { name: "worker-b", text: "context" }, undefined)
  expect(() => messenger.accept({ id: requestId, operation: "list", ok: true, result: { peers: [] } })).toThrow(
    "operation mismatch"
  )
  expect(messenger.accept({ id: requestId, operation: "send", ok: false, error: "target closed" })).toBe(true)
  expect(failed).rejects.toThrow("target closed")

  unbind()
  expect(send.execute("late", { name: "worker-b", text: "context" }, undefined)).rejects.toThrow("relay is unavailable")
  messenger.dispose()
})

test("PeerMessenger bounds pending relay work", async () => {
  const messenger = new PeerMessenger()
  messenger.bind(() => {})
  const list = messenger.createTools().find(tool => tool.name === "list_peer_subagents")
  if (!list) throw new Error("Expected list_peer_subagents")
  const pending = Array.from({ length: 8 }, (_, index) => list.execute(`list-${index}`, {}, undefined))

  expect(list.execute("overflow", {}, undefined)).rejects.toThrow("At most 8 peer requests")
  messenger.dispose()
  await Promise.all(pending.map(operation => operation.catch(() => undefined)))
})

test("PeerMessenger rejects a pending tool when a successful response has malformed data", async () => {
  const messenger = new PeerMessenger()
  let requestId = ""
  messenger.bind(request => {
    requestId = request.id
  })
  const list = messenger.createTools().find(tool => tool.name === "list_peer_subagents")
  if (!list) throw new Error("Expected list_peer_subagents")
  const pending = list.execute("list", {}, undefined)

  expect(() => messenger.accept({ id: requestId, operation: "list", ok: true, result: { peers: "invalid" } })).toThrow(
    "Peer list"
  )
  expect(pending).rejects.toThrow("Peer list")
  await pending.catch(() => undefined)
  messenger.dispose()
})

test("PeerMessenger absorbs a correlated response that arrives after caller cancellation", async () => {
  const messenger = new PeerMessenger()
  let requestId = ""
  messenger.bind(request => {
    requestId = request.id
  })
  const send = messenger.createTools().find(tool => tool.name === "send_peer_message")
  if (!send) throw new Error("Expected send_peer_message")
  const controller = new AbortController()
  const delivery = send.execute("send", { name: "worker-b", text: "context" }, controller.signal)
  controller.abort(new Error("sender cancelled"))

  expect(delivery).rejects.toThrow("sender cancelled")
  await delivery.catch(() => undefined)
  expect(messenger.accept({ id: requestId, operation: "send", ok: true, result: { delivered: true } })).toBe(true)
  messenger.dispose()
})

test("peer protocol validates child requests and parent responses as closed bounded records", () => {
  expect(
    decodePeerRequestFrame({
      version: 1,
      sequence: 4,
      type: "peer_request",
      id: "peer-1",
      operation: "send",
      target: "worker-b",
      text: "context"
    })
  ).toEqual({ id: "peer-1", operation: "send", target: "worker-b", text: "context" })
  expect(() =>
    decodePeerRequestFrame({
      version: 1,
      sequence: 4,
      type: "peer_request",
      id: "peer-1",
      operation: "send",
      target: "worker-b",
      text: "context",
      sender: "spoofed"
    })
  ).toThrow("Unexpected peer protocol field")
  expect(() =>
    decodePeerResponse({
      version: 1,
      type: "peer_response",
      id: "peer-1",
      operation: "send",
      ok: true,
      result: { delivered: true },
      error: "both"
    })
  ).toThrow("Invalid successful peer response")
})
