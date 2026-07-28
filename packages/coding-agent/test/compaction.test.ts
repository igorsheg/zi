import { expect, test } from "bun:test"

import { fauxAssistantMessage, fauxProvider } from "@earendil-works/pi-ai"

import {
  effectiveCompactionSettings,
  estimateContextTokens,
  estimateMessageTokens,
  generateCompactionSummary,
  maxSerializedToolResultChars,
  prepareCompaction,
  serializeCompactionMessage,
  splitUtf8,
  validateCompactionReduction,
  validateSummaryResponse,
  type CompactionPlan
} from "../src/compaction.js"
import type { AgentMessage } from "../src/messages.js"
import { SessionManager } from "../src/session-manager.js"

test("context estimates anchor at provider usage and mark trailing work", () => {
  const assistant = {
    ...fauxAssistantMessage("answer"),
    usage: {
      input: 80,
      output: 20,
      cacheRead: 0,
      cacheWrite: 0,
      totalTokens: 100,
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 }
    }
  }
  const trailing: AgentMessage = { role: "user", content: "12345678", timestamp: 2 }

  expect(estimateContextTokens([assistant, trailing])).toEqual({
    tokens: 102,
    usageTokens: 100,
    trailingTokens: 2,
    lastUsageIndex: 0
  })
  expect(
    estimateMessageTokens({
      role: "user",
      content: [{ type: "image", mimeType: "image/png", data: "a".repeat(10_000) }],
      timestamp: 3
    })
  ).toBe(1_200)
})

test("model-relative settings clamp reserve, retained tail, and output", () => {
  expect(
    effectiveCompactionSettings(
      { contextWindow: 4_000, maxTokens: 10_000 },
      { reserveTokens: 16_384, keepRecentTokens: 20_000 }
    )
  ).toEqual({ reserveTokens: 1_000, keepRecentTokens: 1_500, triggerTokens: 3_000, summaryMaxTokens: 800 })
  expect(
    effectiveCompactionSettings({ contextWindow: 0, maxTokens: 0 }, { reserveTokens: 1, keepRecentTokens: 1 })
  ).toBeUndefined()
})

test("cut planning keeps assistant and parallel tool results structurally intact", () => {
  const session = SessionManager.inMemory("/work")
  session.appendMessage({ role: "user", content: "old request", timestamp: 1 })
  const toolAssistant = session.appendMessage(
    fauxAssistantMessage(
      [
        { type: "toolCall", id: "one", name: "read", arguments: { path: "a.ts" } },
        { type: "toolCall", id: "two", name: "edit", arguments: { path: "b.ts" } }
      ],
      { stopReason: "toolUse" }
    )
  )
  session.appendMessage({
    role: "toolResult",
    toolCallId: "one",
    toolName: "read",
    content: [{ type: "text", text: "read" }],
    isError: false,
    timestamp: 3
  })
  session.appendMessage({
    role: "toolResult",
    toolCallId: "two",
    toolName: "edit",
    content: [{ type: "text", text: "edited" }],
    isError: false,
    timestamp: 4
  })
  const settings = effectiveCompactionSettings(
    { contextWindow: 100, maxTokens: 20 },
    { reserveTokens: 20, keepRecentTokens: 1 }
  )!

  const preparation = prepareCompaction(session.entries(), settings, { tokens: 50, quality: "estimated" })
  expect(preparation.type).toBe("ready")
  if (preparation.type !== "ready") return
  expect(preparation.plan.firstKeptEntryId).toBe(toolAssistant.id)
  expect(preparation.plan.retainedMessages.map(message => message.role)).toEqual([
    "assistant",
    "toolResult",
    "toolResult"
  ])
})

test("custom messages participate in compaction budgeting and cut points", () => {
  const session = SessionManager.inMemory("/work")
  session.appendCustomMessage({ customType: "example.context", content: "old custom context", display: false })
  const kept = session.appendCustomMessage({
    customType: "example.context",
    content: "recent custom context",
    display: true
  })
  const settings = effectiveCompactionSettings(
    { contextWindow: 100, maxTokens: 20 },
    { reserveTokens: 20, keepRecentTokens: 1 }
  )!

  const preparation = prepareCompaction(session.entries(), settings, { tokens: 50, quality: "estimated" })
  if (preparation.type !== "ready") throw new Error("Expected custom-message compaction plan")
  expect(preparation.plan.firstKeptEntryId).toBe(kept.id)
  expect(preparation.plan.sourceMessages).toEqual([
    expect.objectContaining({ role: "custom", content: "old custom context", display: false })
  ])
  expect(preparation.plan.retainedMessages).toEqual([
    expect.objectContaining({ role: "custom", content: "recent custom context", display: true })
  ])
})

test("repeated planning carries only the latest previous summary", () => {
  const session = SessionManager.inMemory("/work")
  session.appendMessage({ role: "user", content: "old", timestamp: 1 })
  const kept = session.appendMessage({ role: "user", content: "kept", timestamp: 2 })
  session.appendCompaction({
    reason: "manual",
    summary: "previous checkpoint",
    firstKeptEntryId: kept.id,
    tokensBefore: 100,
    estimatedTokensAfter: 20,
    details: { readFiles: [], modifiedFiles: [], omittedReadFiles: 0, omittedModifiedFiles: 0 }
  })
  session.appendMessage(fauxAssistantMessage("recent answer"))
  const latest = session.appendMessage({ role: "user", content: "latest", timestamp: 3 })
  const settings = effectiveCompactionSettings(
    { contextWindow: 100, maxTokens: 20 },
    { reserveTokens: 20, keepRecentTokens: 1 }
  )!

  const preparation = prepareCompaction(session.entries(), settings, { tokens: 50, quality: "estimated" })
  if (preparation.type !== "ready") throw new Error("Expected repeated compaction plan")
  expect(preparation.plan.previousSummary).toBe("previous checkpoint")
  expect(preparation.plan.firstKeptEntryId).toBe(latest.id)
  expect(preparation.plan.sourceMessages.map(message => message.role)).toEqual(["user", "assistant"])
})

test("file details include only successful discarded tool operations", () => {
  const session = SessionManager.inMemory("/work")
  session.appendMessage({ role: "user", content: "old", timestamp: 1 })
  session.appendMessage(
    fauxAssistantMessage(
      [
        { type: "toolCall", id: "read", name: "read", arguments: { path: "z.ts" } },
        { type: "toolCall", id: "write", name: "write", arguments: { path: "a.ts" } },
        { type: "toolCall", id: "failed", name: "edit", arguments: { path: "failed.ts" } }
      ],
      { stopReason: "toolUse" }
    )
  )
  for (const [id, name, isError] of [
    ["read", "read", false],
    ["write", "write", false],
    ["failed", "edit", true]
  ] as const) {
    session.appendMessage({
      role: "toolResult",
      toolCallId: id,
      toolName: name,
      content: [{ type: "text", text: "result" }],
      isError,
      timestamp: 3
    })
  }
  session.appendMessage({ role: "user", content: "recent", timestamp: 4 })
  session.appendMessage(fauxAssistantMessage("done"))
  const settings = effectiveCompactionSettings(
    { contextWindow: 100, maxTokens: 20 },
    { reserveTokens: 20, keepRecentTokens: 1 }
  )!
  const preparation = prepareCompaction(session.entries(), settings, { tokens: 80, quality: "estimated" })
  if (preparation.type !== "ready") throw new Error("Expected compaction plan")

  expect(preparation.plan.details).toEqual({
    readFiles: ["z.ts"],
    modifiedFiles: ["a.ts"],
    omittedReadFiles: 0,
    omittedModifiedFiles: 0
  })
})

test("serialization bounds tool output and UTF-8 splitting preserves source", () => {
  const text = "界".repeat(maxSerializedToolResultChars + 100)
  const serialized = serializeCompactionMessage({
    role: "toolResult",
    toolCallId: "id",
    toolName: "read",
    content: [{ type: "text", text }],
    isError: false,
    timestamp: 1
  })
  expect(serialized).toContain("characters omitted")
  expect(serialized.length).toBeLessThan(text.length)

  const source = "a界🙂b"
  const parts = splitUtf8(source, 4)
  expect(parts.join("")).toBe(source)
  expect(parts.every(part => Buffer.byteLength(part) <= 4)).toBe(true)
})

test("summary generation refuses source beyond eight fitted chunks", async () => {
  const model = fauxProvider({ models: [{ id: "tiny", contextWindow: 1_000, maxTokens: 200 }] }).getModel()
  const settings = effectiveCompactionSettings(model, { reserveTokens: 200, keepRecentTokens: 100 })!
  const plan = directPlan([{ role: "user", content: "x".repeat(100_000), timestamp: 1 }])

  expect(
    generateCompactionSummary(
      plan,
      model,
      settings,
      undefined,
      "off",
      async () => fauxAssistantMessage("summary"),
      new AbortController().signal
    )
  ).rejects.toThrow("8-chunk")
})

test("summary overflow splits the chunk without resending an identical payload", async () => {
  const model = fauxProvider({ models: [{ id: "model", contextWindow: 4_000, maxTokens: 500 }] }).getModel()
  const settings = effectiveCompactionSettings(model, { reserveTokens: 500, keepRecentTokens: 100 })!
  const prompts: string[] = []
  let sample = 0
  const summary = await generateCompactionSummary(
    directPlan([{ role: "user", content: "x".repeat(1_000), timestamp: 1 }]),
    model,
    settings,
    undefined,
    "off",
    async request => {
      prompts.push(JSON.stringify(request.context))
      sample++
      return sample === 1
        ? fauxAssistantMessage("", {
            stopReason: "error",
            errorMessage: "prompt is too long: 4001 tokens > 4000 maximum"
          })
        : fauxAssistantMessage(`summary ${sample}`)
    },
    new AbortController().signal
  )

  expect(summary).toBe("summary 3")
  expect(prompts).toHaveLength(3)
  expect(prompts[1]).not.toBe(prompts[0])
  expect(prompts[2]).not.toBe(prompts[1])
})

test("summary validation rejects empty, non-text, oversized, and non-reducing output", () => {
  expect(() => validateSummaryResponse(fauxAssistantMessage("   "))).toThrow("empty summary")
  expect(() =>
    validateSummaryResponse(
      fauxAssistantMessage({ type: "toolCall", id: "call", name: "read", arguments: {} }, { stopReason: "toolUse" })
    )
  ).toThrow("empty summary")
  expect(() => validateSummaryResponse(fauxAssistantMessage("x".repeat(128 * 1024 + 1)))).toThrow("cannot exceed")

  const plan = directPlan([{ role: "user", content: "short", timestamp: 1 }])
  expect(() => validateCompactionReduction(plan, "a much longer summary than the old active context")).toThrow(
    "did not reduce"
  )
})

function directPlan(sourceMessages: readonly AgentMessage[]): CompactionPlan {
  return {
    firstKeptEntryId: "kept",
    sourceMessages,
    retainedMessages: [],
    tokensBefore: 10,
    estimatedTokensBefore: 1,
    compactedEntries: sourceMessages.length,
    details: { readFiles: [], modifiedFiles: [], omittedReadFiles: 0, omittedModifiedFiles: 0 }
  }
}
