import { expect, test } from "bun:test"

import { fauxAssistantMessage } from "@earendil-works/pi-ai"
import { InvariantError, InvariantRegistry } from "@with-zi/invariants"

import { AgentSessionInvariant } from "../src/agent-session-invariant.js"
import type { AgentSessionEvent } from "../src/agent-session.js"

const assistant = fauxAssistantMessage("done")

function createInvariant(): { readonly invariant: AgentSessionInvariant; readonly registry: InvariantRegistry } {
  const registry = new InvariantRegistry()
  return { invariant: new AgentSessionInvariant(registry), registry }
}

function accept(invariant: AgentSessionInvariant, events: readonly AgentSessionEvent[]): void {
  for (const event of events) invariant.accept(event)
}

test("accepts a complete agent, message, tool, retry, and compaction lifecycle", () => {
  const { invariant, registry } = createInvariant()

  accept(invariant, [
    { type: "agent_start" },
    { type: "turn_start" },
    { type: "message_start", message: assistant },
    {
      type: "message_update",
      message: assistant,
      assistantMessageEvent: { type: "text_delta", contentIndex: 0, delta: "done", partial: assistant }
    },
    { type: "message_end", message: assistant },
    { type: "tool_execution_start", toolCallId: "call-1", toolName: "read", args: {} },
    { type: "tool_execution_update", toolCallId: "call-1", toolName: "read", args: {}, partialResult: {} },
    { type: "tool_execution_end", toolCallId: "call-1", toolName: "read", result: {}, isError: false },
    { type: "turn_end", message: assistant, toolResults: [] },
    { type: "agent_end", messages: [assistant], willRetry: false },
    { type: "auto_retry_start", attempt: 1, maxAttempts: 3, delayMs: 100, retryAt: 100, errorMessage: "retry" },
    { type: "auto_retry_end", success: false, attempt: 1, finalError: "stopped" },
    { type: "compaction_start", operationId: 1, reason: "manual" },
    { type: "compaction_end", operationId: 1, reason: "manual", outcome: { type: "cancelled" } },
    { type: "agent_settled" }
  ])

  invariant.dispose()
  registry.dispose()
})

test("rejects tool updates and terminal events without matching starts", () => {
  const { invariant } = createInvariant()
  invariant.accept({ type: "agent_start" })

  expect(() =>
    invariant.accept({
      type: "tool_execution_update",
      toolCallId: "missing",
      toolName: "read",
      args: {},
      partialResult: {}
    })
  ).toThrow(InvariantError)
})

test("interrupted message publication admits the provider's synthetic failure sequence", () => {
  const { invariant } = createInvariant()
  invariant.accept({ type: "agent_start" })
  invariant.accept({ type: "turn_start" })
  invariant.accept({ type: "message_start", message: assistant })

  invariant.interruptMessage()
  const failure = { ...assistant, timestamp: assistant.timestamp + 1 }
  invariant.accept({ type: "message_start", message: failure })
  invariant.accept({ type: "message_end", message: failure })
})

test("projected message identity is validated before its terminal event", () => {
  const { invariant } = createInvariant()
  const projected = { ...assistant, timestamp: assistant.timestamp + 1 }
  invariant.accept({ type: "agent_start" })
  invariant.accept({ type: "message_start", message: assistant })

  invariant.projectMessage(assistant, projected)
  expect(() => invariant.accept({ type: "message_end", message: projected })).not.toThrow()
})

test("settlement recovers an attempt whose terminal event stream was interrupted", () => {
  const { invariant } = createInvariant()
  invariant.accept({ type: "agent_start" })
  invariant.accept({ type: "turn_start" })
  invariant.accept({ type: "message_start", message: assistant })

  expect(() => invariant.accept({ type: "agent_settled" })).not.toThrow()
  expect(() => invariant.accept({ type: "agent_start" })).not.toThrow()
})

test("rejects queue identities duplicated across delivery modes", () => {
  const { invariant } = createInvariant()
  const shared = { id: 1, text: "queued", images: [], bytes: 6 } as const

  expect(() =>
    invariant.accept({
      type: "queue_update",
      steering: [{ ...shared, delivery: "steer" }],
      followUp: [{ ...shared, delivery: "followUp" }]
    })
  ).toThrow("queue contains duplicate input 1")
})

test("tracks logical message identity across copied assistant stream values", () => {
  const { invariant } = createInvariant()
  const start = { ...assistant }
  const update = { ...assistant }
  const end = { ...assistant }

  invariant.accept({ type: "agent_start" })
  invariant.accept({ type: "turn_start" })
  invariant.accept({ type: "message_start", message: start })
  invariant.accept({
    type: "message_update",
    message: update,
    assistantMessageEvent: { type: "text_delta", contentIndex: 0, delta: "done", partial: update }
  })
  expect(() => invariant.accept({ type: "message_end", message: end })).not.toThrow()
})

test("rejects overlapping, mismatched, and unpaired message events", () => {
  const mismatch = { ...assistant, timestamp: assistant.timestamp + 1 }

  {
    const { invariant } = createInvariant()
    invariant.accept({ type: "agent_start" })
    invariant.accept({ type: "message_start", message: assistant })
    expect(() => invariant.accept({ type: "message_start", message: assistant })).toThrow("another message is open")
  }
  {
    const { invariant } = createInvariant()
    invariant.accept({ type: "agent_start" })
    invariant.accept({ type: "message_start", message: assistant })
    expect(() => invariant.accept({ type: "message_end", message: mismatch })).toThrow("does not match")
  }
  {
    const { invariant } = createInvariant()
    invariant.accept({ type: "agent_start" })
    expect(() => invariant.accept({ type: "message_end", message: assistant })).toThrow("without message_start")
  }
})

test("accepts committed standalone custom message ends without closing a streamed message", () => {
  const { invariant } = createInvariant()
  const custom = { role: "custom" as const, customType: "test", content: "committed", display: true, timestamp: 1 }

  expect(() => invariant.accept({ type: "message_end", message: custom })).not.toThrow()
  invariant.accept({ type: "agent_start" })
  invariant.accept({ type: "message_start", message: assistant })
  expect(() => invariant.accept({ type: "message_end", message: custom })).not.toThrow()
  expect(() => invariant.accept({ type: "message_end", message: assistant })).not.toThrow()
})

test("disabled registration has no protocol effect", () => {
  const registry = new InvariantRegistry({ enabled: false })
  const invariant = new AgentSessionInvariant(registry)

  expect(() => invariant.accept({ type: "agent_end", messages: [], willRetry: false })).not.toThrow()
})
