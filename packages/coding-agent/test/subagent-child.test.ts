import { expect, test } from "bun:test"
import { mkdir, mkdtemp, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { maxPendingInputCount } from "../src/agent-session.js"
import { ZiPaths } from "../src/paths.js"
import {
  maxChildTranscriptBytes,
  maxChildTranscriptMessages,
  SubagentChild,
  type SubagentCompletion
} from "../src/subagents/child.js"
import type { PeerRelay } from "../src/subagents/peer.js"
import { createTestChildSessionFactory, waitFor } from "./subagent-harness.js"

test("SubagentChild runs and reuses one in-process AgentSession", async () => {
  const harness = await createChildHarness("cycle", { reply: "finished", delayMs: 10 })
  const completions: SubagentCompletion[] = []
  const child = new SubagentChild({
    name: "worker",
    owner: harness.owner,
    onCompletion: completion => completions.push(completion)
  })
  try {
    child.queueCycle("first")
    child.startQueuedCycle()
    await waitFor(() => child.state.type === "idle")
    expect(completions[0]).toMatchObject({ workCycle: 1, status: "completed", text: "finished" })
    expect(child.transcript().messages.map(message => message.role)).toEqual(["user", "assistant"])

    child.assign("second")
    child.startQueuedCycle()
    await waitFor(() => child.state.type === "idle" && child.snapshot().workCycle === 2)
    expect(completions[1]).toMatchObject({ workCycle: 2, status: "completed", text: "finished" })
    expect(child.snapshot().sessionId).toBe(harness.owner.session.sessionId)
  } finally {
    await child.close()
    await harness.dispose()
  }
})

test("transcript messages keep stable identity until a visible commit", async () => {
  const harness = await createChildHarness("transcript-identity", { reply: "finished" })
  const child = new SubagentChild({ name: "worker", owner: harness.owner })
  try {
    const initial = child.transcript().messages
    expect(child.transcript().messages).toBe(initial)

    child.queueCycle("first")
    child.startQueuedCycle()
    await waitFor(() => child.state.type === "idle")

    const committed = child.transcript().messages
    expect(committed).not.toBe(initial)
    expect(child.transcript().messages).toBe(committed)
    expect(committed.at(-1)).toBe(harness.owner.session.messages.at(-1))
  } finally {
    await child.close()
    await harness.dispose()
  }
})

test("transcript append projection does not reserialize unchanged prefixes and rebuilds after compaction", async () => {
  const harness = await createChildHarness("transcript-tail", { reply: "finished" })
  let prefixSerializations = 0
  const prefix = {
    role: "user" as const,
    get content() {
      prefixSerializations++
      return "prefix"
    },
    timestamp: 0
  }
  harness.owner.session.sessionManager.appendMessage(prefix)
  const child = new SubagentChild({ name: "worker", owner: harness.owner })
  try {
    expect(child.transcript().messages).toEqual([prefix])
    prefixSerializations = 0

    child.queueCycle("append")
    child.startQueuedCycle()
    await waitFor(() => child.state.type === "idle")
    expect(child.transcript().messages.at(0)).toBe(prefix)
    expect(prefixSerializations).toBe(0)

    const kept = harness.owner.session.sessionManager.retainedEntries().findLast(entry => entry.type === "message")
    if (!kept) throw new Error("Missing retained message for compaction")
    harness.owner.session.sessionManager.appendCompaction({
      reason: "manual",
      summary: "compacted",
      firstKeptEntryId: kept.id,
      tokensBefore: 100,
      estimatedTokensAfter: 10,
      details: { readFiles: [], modifiedFiles: [], omittedReadFiles: 0, omittedModifiedFiles: 0 }
    })
    child.assign("after compaction")
    child.startQueuedCycle()
    await waitFor(() => child.state.type === "idle" && child.snapshot().workCycle === 2)

    const rebuilt = child.transcript()
    expect(rebuilt.messages).toEqual(harness.owner.session.messages)
    expect(rebuilt.messages).not.toContain(prefix)
    expect(rebuilt.omittedMessages).toBe(0)
    expect(rebuilt.omittedBytes).toBe(0)
  } finally {
    await child.close()
    await harness.dispose()
  }
})

test("a continuation admitted after session settlement remains in the current work cycle", async () => {
  const harness = await createChildHarness("stale-settlement", { reply: "finished" })
  const completions: SubagentCompletion[] = []
  const child = new SubagentChild({
    name: "worker",
    owner: harness.owner,
    onCompletion: completion => completions.push(completion)
  })
  let admitted = false
  const unsubscribe = harness.owner.session.subscribe(event => {
    if (event.type !== "agent_settled" || admitted) return
    admitted = true
    child.assign("joined")
  })
  try {
    child.queueCycle("first")
    child.startQueuedCycle()
    await waitFor(() => child.state.type === "idle")
    expect(completions).toHaveLength(1)
    expect(completions[0]).toMatchObject({ workCycle: 1, status: "completed", text: "finished" })
    expect(child.transcript().messages.map(message => message.role)).toEqual(["user", "assistant", "user", "assistant"])
  } finally {
    unsubscribe()
    await child.close()
    await harness.dispose()
  }
})

test("queue-only context keeps an idle child idle until continuation", async () => {
  const harness = await createChildHarness("send", { reply: "done" })
  const child = new SubagentChild({ name: "worker", owner: harness.owner })
  try {
    child.queueCycle("first")
    child.startQueuedCycle()
    await waitFor(() => child.state.type === "idle")
    await child.send("context")
    expect(child.state).toMatchObject({ type: "idle", nextWorkCycle: 2 })

    child.assign("wake")
    child.startQueuedCycle()
    await waitFor(() => child.state.type === "idle" && child.snapshot().workCycle === 2)
    expect(child.transcript().messages.filter(message => message.role === "user")).toHaveLength(3)
  } finally {
    await child.close()
    await harness.dispose()
  }
})

test("queued waiting does not consume the work deadline", async () => {
  const harness = await createChildHarness("queued-timeout", { reply: "on-time" })
  const completions: SubagentCompletion[] = []
  const child = new SubagentChild({
    name: "worker",
    owner: harness.owner,
    workTimeoutMs: 20,
    onCompletion: completion => completions.push(completion)
  })
  try {
    child.queueCycle("wait first")
    await Bun.sleep(50)
    expect(child.state.type).toBe("queued")
    expect(child.snapshot()).toMatchObject({ lifecycle: "queued", workCycle: 1 })

    child.startQueuedCycle()
    await waitFor(() => child.state.type === "idle")
    expect(completions).toEqual([expect.objectContaining({ workCycle: 1, status: "completed", text: "on-time" })])
  } finally {
    await child.close()
    await harness.dispose()
  }
})

test("queued interruption discards the cancelled cycle inputs and reclaims queue capacity", async () => {
  const harness = await createChildHarness("queued-interrupt", { reply: "reused" })
  const completions: SubagentCompletion[] = []
  const child = new SubagentChild({
    name: "worker",
    owner: harness.owner,
    onCompletion: completion => completions.push(completion)
  })
  try {
    child.queueCycle("cancel before start")
    await child.send("stale context")
    expect(child.assign("stale assignment")).toBe("follow_up")
    expect(harness.owner.session.queuedInputs.followUp).toHaveLength(2)

    expect(await child.interrupt()).toBe("interrupted")
    expect(child.state).toEqual({ type: "idle", nextWorkCycle: 2 })
    expect(harness.owner.session.queuedInputs.followUp).toEqual([])
    expect(completions).toEqual([
      expect.objectContaining({ workCycle: 1, status: "cancelled", text: "", originalBytes: 0 })
    ])

    child.queueCycle("reuse")
    await Promise.all(Array.from({ length: maxPendingInputCount }, (_, index) => child.send(`fresh ${index}`)))
    expect(harness.owner.session.queuedInputs.followUp).toHaveLength(maxPendingInputCount)
    child.startQueuedCycle()
    await waitFor(() => child.state.type === "idle")

    const transcript = JSON.stringify(child.transcript().messages)
    expect(transcript).not.toContain("stale context")
    expect(transcript).not.toContain("stale assignment")
    expect(transcript).toContain(`fresh ${maxPendingInputCount - 1}`)
    expect(completions[1]).toMatchObject({ workCycle: 2, status: "completed", text: "reused" })
  } finally {
    await child.close()
    await harness.dispose()
  }
})

test("direct interruption publishes cancelled evidence and close settles disposal", async () => {
  const harness = await createChildHarness("interrupt", { reply: "late", delayMs: 250 })
  const completions: SubagentCompletion[] = []
  const child = new SubagentChild({
    name: "worker",
    owner: harness.owner,
    onCompletion: completion => completions.push(completion)
  })
  try {
    child.queueCycle("long")
    child.startQueuedCycle()
    expect(await child.interrupt()).toBe("interrupted")
    await waitFor(() => child.state.type === "idle")
    expect(completions[0]).toMatchObject({ status: "cancelled", workCycle: 1 })

    await child.close()
    expect(child.state).toEqual({ type: "exited", outcome: { type: "closed", code: 0 } })
    expect(() => harness.owner.session.prompt("disposed")).toThrow("AgentSession is disposed")
  } finally {
    await child.close().catch(() => {})
    await harness.dispose()
  }
})

test("child close forces bounded failed settlement when disposal never settles", async () => {
  const harness = await createChildHarness("forced-close", { reply: "late", delayMs: 100 })
  let disposeCalls = 0
  const transitions: string[] = []
  let presentationChanges = 0
  const owner = {
    session: harness.owner.session,
    dispose(): Promise<void> {
      disposeCalls++
      harness.owner.session.dispose()
      return new Promise<void>(() => {})
    }
  }
  let child: SubagentChild
  child = new SubagentChild({
    name: "worker",
    owner,
    closeSettlementMs: 20,
    onStateChange: () => transitions.push(child.state.type),
    onPresentationChange: () => presentationChanges++
  })
  try {
    child.queueCycle("active")
    child.startQueuedCycle()
    const closing = child.close()
    expect(disposeCalls).toBe(1)
    expect(() => harness.owner.session.prompt("disposed")).toThrow("AgentSession is disposed")
    await closing
    expect(child.state).toEqual({
      type: "exited",
      outcome: { type: "forced", message: "Subagent worker disposal did not settle within 20ms" }
    })
    expect(transitions.filter(state => state === "exited")).toHaveLength(1)

    const settledPresentationChanges = presentationChanges
    await Bun.sleep(150)
    expect(child.state.type).toBe("exited")
    expect(transitions.filter(state => state === "exited")).toHaveLength(1)
    expect(presentationChanges).toBe(settledPresentationChanges)
  } finally {
    await child.close().catch(() => {})
    await harness.dispose()
  }
})

test("transcript keeps the newest 200 message references", async () => {
  const harness = await createChildHarness("transcript-count", { reply: "unused" })
  const seeded = Array.from({ length: maxChildTranscriptMessages + 10 }, (_, index) => ({
    role: "user" as const,
    content: `message-${index}`,
    timestamp: index
  }))
  for (const message of seeded) harness.owner.session.sessionManager.appendMessage(message)
  const child = new SubagentChild({ name: "worker", owner: harness.owner })
  try {
    const transcript = child.transcript()
    expect(transcript.messages).toHaveLength(maxChildTranscriptMessages)
    expect(transcript.messages).toEqual(seeded.slice(10))
    expect(transcript.messages.at(-1)).toBe(seeded.at(-1))
    expect(transcript.omittedMessages).toBe(10)
    expect(transcript.omittedBytes).toBe(serializedMessageBytes(seeded.slice(0, 10)))
  } finally {
    await child.close()
    await harness.dispose()
  }
})

test("transcript byte bound keeps the newest suffix with exact omission facts", async () => {
  const harness = await createChildHarness("transcript-bytes", { reply: "unused" })
  const seeded = Array.from({ length: maxChildTranscriptMessages }, (_, index) => ({
    role: "user" as const,
    content: `${index}:${"x".repeat(45_000)}`,
    timestamp: index
  }))
  for (const message of seeded) harness.owner.session.sessionManager.appendMessage(message)
  const child = new SubagentChild({ name: "worker", owner: harness.owner })
  try {
    const transcript = child.transcript()
    const retainedBytes = serializedMessageBytes(transcript.messages)
    expect(transcript.messages.length).toBeLessThan(maxChildTranscriptMessages)
    expect(retainedBytes).toBeLessThanOrEqual(maxChildTranscriptBytes)
    expect(transcript.messages).toEqual(seeded.slice(transcript.omittedMessages))
    expect(transcript.messages.at(-1)).toBe(seeded.at(-1))
    expect(transcript.omittedMessages).toBeGreaterThan(0)
    expect(transcript.omittedBytes).toBe(serializedMessageBytes(seeded.slice(0, transcript.omittedMessages)))
  } finally {
    await child.close()
    await harness.dispose()
  }
})

test("one oversized newest message omits the entire transcript suffix", async () => {
  const oversized = "x".repeat(maxChildTranscriptBytes + 1)
  const harness = await createChildHarness("transcript-oversized", { reply: oversized })
  const child = new SubagentChild({ name: "worker", owner: harness.owner })
  try {
    child.queueCycle("large")
    child.startQueuedCycle()
    await waitFor(() => child.state.type === "idle", 15_000)
    const transcript = child.transcript()
    expect(transcript.messages).toEqual([])
    expect(transcript.omittedMessages).toBe(harness.owner.session.messages.length)
    expect(transcript.omittedBytes).toBe(serializedMessageBytes(harness.owner.session.messages))
  } finally {
    await child.close()
    await harness.dispose()
  }
}, 20_000)

function serializedMessageBytes(messages: readonly object[]): number {
  return messages.reduce((bytes, message) => bytes + Buffer.byteLength(JSON.stringify(message)), 0)
}

const unavailablePeerRelay: PeerRelay = () => Promise.reject(new Error("Peer relay unavailable in child unit test"))

async function createChildHarness(name: string, options: { readonly reply: string; readonly delayMs?: number }) {
  const root = await mkdtemp(join(tmpdir(), `zi-child-${name}-`))
  const paths = new ZiPaths(join(root, "project"), join(root, "agent"))
  await mkdir(paths.cwd, { recursive: true })
  const owner = await createTestChildSessionFactory(
    paths,
    options
  )({
    name: "worker",
    model: "faux/faux-1",
    thinkingLevel: "off",
    toolSurface: "direct-and-code",
    peerRelay: unavailablePeerRelay
  })
  return {
    owner,
    async dispose(): Promise<void> {
      await owner.dispose("quit").catch(() => {})
      await rm(root, { recursive: true, force: true })
    }
  }
}
