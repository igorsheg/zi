import { expect, spyOn, test } from "bun:test"

import {
  BoxRenderable,
  CliRenderEvents,
  MarkdownRenderable,
  type Renderable,
  TextAttributes,
  TextRenderable
} from "@opentui/core"
import { createTestRenderer, type TestRendererSetup } from "@opentui/core/testing"
import type { AgentMessage } from "@with-zi/coding-agent"
import { fauxAssistantMessage, fauxText, fauxThinking, fauxToolCall } from "@with-zi/coding-agent/testing"
import { atom, type WritableAtom } from "nanostores"

import { TuiDiagnosticsOverlay } from "../../src/interactive/diagnostics.js"
import { InteractiveKeybindings } from "../../src/interactive/interactive-keybindings.js"
import type { ActiveTool } from "../../src/interactive/interactive-store.js"
import { createMessageItemView, StreamingAssistantView } from "../../src/interactive/transcript/message-view.js"
import { TranscriptView } from "../../src/interactive/transcript/view.js"
import { createSyntaxStyle, createThinkingSyntaxStyle, defaultTheme } from "../../src/theme.js"
import { renderMarkdownSettled } from "./harness.js"

interface TranscriptHarness {
  readonly setup: TestRendererSetup
  readonly state: { messages: AgentMessage[]; streamingMessage: AgentMessage | undefined }
  readonly revision: WritableAtom<number>
  readonly tools: WritableAtom<ReadonlyMap<string, ActiveTool>>
  readonly view: TranscriptView
  destroy(): void
}

test("transcript notifications coalesce at one renderer lifecycle pass and destruction unregisters it", async () => {
  const harness = await createTranscriptHarness([], { paused: true })
  try {
    harness.revision.set(1)
    harness.revision.set(2)
    harness.revision.set(3)

    expect(harness.view.diagnostics).toMatchObject({ syncRequests: 4, syncPasses: 0, coalescedRequests: 3 })
    expect(harness.setup.renderer.getLifecyclePasses().has(harness.view.root)).toBe(true)

    await harness.setup.renderOnce()
    expect(harness.view.diagnostics.syncPasses).toBe(1)

    harness.revision.set(4)
    const passes = harness.view.diagnostics.syncPasses
    harness.view.destroy()
    expect(harness.setup.renderer.getLifecyclePasses().has(harness.view.root)).toBe(false)
    await harness.setup.renderOnce()
    expect(harness.view.diagnostics.syncPasses).toBe(passes)
  } finally {
    harness.destroy()
  }
})

test("Zi summary messages require post-compaction accounting", () => {
  // @ts-expect-error estimatedTokensAfter is part of Zi's public summary-message contract.
  const invalid: AgentMessage = { role: "compactionSummary", summary: "checkpoint", tokensBefore: 100, timestamp: 1 }
  expect(invalid.role).toBe("compactionSummary")
})

test("compaction summaries render as full-width custom-color dividers without panel chrome", async () => {
  const setup = await createTestRenderer({ width: 80, height: 8, useThread: false })
  const syntaxStyle = createSyntaxStyle(defaultTheme)
  const item = createMessageItemView(
    setup.renderer,
    {
      role: "compactionSummary",
      summary: "Checkpoint summary.",
      tokensBefore: 223_000,
      estimatedTokensAfter: 21_000,
      timestamp: 1
    },
    { theme: defaultTheme, syntaxStyle, expandHint: "Ctrl+O" }
  )
  if (!item) throw new Error("Compaction summary item not created")
  setup.renderer.root.add(item.root)

  try {
    await setup.renderOnce()
    const prefix = "─────── Conversation compacted • 223k → ~21k tokens • Ctrl+O to expand "
    const divider = setup
      .captureCharFrame()
      .split("\n")
      .find(row => row.includes("Conversation compacted"))
    expect(divider).toBe(prefix + "─".repeat(80 - prefix.length))

    const dividerSpans = setup
      .captureSpans()
      .lines.find(line => line.spans.some(span => span.text === "Conversation compacted"))?.spans
    if (!dividerSpans) throw new Error("Compaction divider spans not found")
    for (const dividerSpan of dividerSpans.filter(candidate => candidate.text.trim())) {
      expect(dividerSpan.fg.toInts()).toEqual([147, 138, 169, 255])
    }
    expect(dividerSpans.find(span => span.text === "Conversation compacted")?.attributes).toBe(TextAttributes.BOLD)

    if (!(item.root instanceof BoxRenderable)) throw new Error("Compaction summary root is not a box")
    expect(item.root.backgroundColor.toInts()[3]).toBe(0)
    for (const text of descendantsOfType(item.root, TextRenderable)) expect(text.bg.toInts()[3]).toBe(0)

    setup.resize(48, 8)
    await setup.renderOnce()
    const narrowPrefix = "─────── Compacted • 223k → ~21k • Ctrl+O "
    const narrowDivider = setup
      .captureCharFrame()
      .split("\n")
      .find(row => row.includes("Compacted"))
    expect(narrowDivider).toBe(narrowPrefix + "─".repeat(48 - narrowPrefix.length))

    expect(item.setExpanded?.(true)).toBe(true)
    await renderMarkdownSettled(setup)
    const expandedBackground = descendant(item.root, MarkdownRenderable).bg
    if (!expandedBackground) throw new Error("Expanded compaction background not found")
    expect(expandedBackground.toInts()[3]).toBe(0)
  } finally {
    item.destroy()
    syntaxStyle.destroy()
    setup.renderer.destroy()
  }
})

test("authoritative message-array replacement rebuilds an equal-length transcript", async () => {
  const harness = await createTranscriptHarness([{ role: "user", content: "old transcript", timestamp: 1 }])
  try {
    await harness.setup.flush()
    const oldRoot = harness.view.scroll.getChildren()[0]
    harness.state.messages = [
      {
        role: "compactionSummary",
        summary: "checkpoint summary",
        tokensBefore: 100,
        estimatedTokensAfter: 20,
        timestamp: 2
      }
    ]
    harness.revision.set(1)
    await harness.setup.flush()

    expect(harness.view.scroll.getChildren()[0]).not.toBe(oldRoot)
    const collapsed = harness.setup.captureCharFrame()
    expect(collapsed).toContain("Conversation compacted • 100 → ~20 • Ctrl+O expand")
    expect(collapsed).not.toContain("[compaction]")
    expect(collapsed).not.toContain("checkpoint summary")
    expect(harness.view.scroll.stickyScroll).toBe(true)
  } finally {
    harness.destroy()
  }
})

test("compaction summaries stay collapsed until tools expand, then reveal the checkpoint body", async () => {
  const harness = await createTranscriptHarness([
    {
      role: "compactionSummary",
      summary: "Recovered auth flow and kept recent tool results.",
      tokensBefore: 12345,
      estimatedTokensAfter: 2400,
      timestamp: 1
    }
  ])
  try {
    await harness.setup.flush()
    const collapsed = harness.setup.captureCharFrame()
    expect(collapsed).toContain("Conversation compacted • 12k → ~2k • Ctrl+O expand")
    expect(collapsed).not.toContain("[compaction]")
    expect(collapsed).not.toContain("Recovered auth flow")

    harness.setup.mockInput.pressKey("o", { ctrl: true })
    await harness.setup.flush()
    const expanded = harness.setup.captureCharFrame()
    expect(expanded).toContain("Conversation compacted • 12k → ~2k tokens")
    expect(expanded).toContain("Recovered auth flow and kept recent tool results.")
    expect(expanded).not.toContain("Ctrl+O")

    harness.setup.mockInput.pressKey("o", { ctrl: true })
    await harness.setup.flush()
    const recoollapsed = harness.setup.captureCharFrame()
    expect(recoollapsed).toContain("Ctrl+O expand")
    expect(recoollapsed).not.toContain("Recovered auth flow")
  } finally {
    harness.destroy()
  }
})

test("post-compaction presentation keeps the marker at the transcript tail", async () => {
  const harness = await createTranscriptHarness([
    { role: "user", content: "old work that stays in the exact tail", timestamp: 1 },
    {
      role: "compactionSummary",
      summary: "checkpoint after compact",
      tokensBefore: 89000,
      estimatedTokensAfter: 21000,
      timestamp: 2
    }
  ])
  try {
    await harness.setup.flush()
    const frame = harness.setup.captureCharFrame()
    expect(frame).toContain("old work that stays in the exact tail")
    expect(frame).toContain("Conversation compacted • 89k → ~21k • Ctrl+O expand")
    expect(frame.indexOf("Conversation compacted")).toBeGreaterThan(
      frame.indexOf("old work that stays in the exact tail")
    )
  } finally {
    harness.destroy()
  }
})

test("branch summaries keep their expandable panel chrome", async () => {
  const setup = await createTestRenderer({ width: 56, height: 10, useThread: false })
  const syntaxStyle = createSyntaxStyle(defaultTheme)
  const item = createMessageItemView(
    setup.renderer,
    { role: "branchSummary", summary: "Switched after the failed deploy.", fromId: "leaf-1", timestamp: 1 },
    { theme: defaultTheme, syntaxStyle, expandHint: "Ctrl+O" }
  )
  if (!item) throw new Error("Branch summary item not created")
  setup.renderer.root.add(item.root)
  try {
    await setup.renderOnce()
    const collapsed = setup.captureCharFrame()
    expect(collapsed).toContain("[branch]")
    expect(collapsed).toContain("Branch summary (Ctrl+O to expand)")
    expect(collapsed).not.toContain("failed deploy")

    expect(item.setExpanded?.(true)).toBe(true)
    await setup.renderOnce()
    const expanded = setup.captureCharFrame()
    expect(expanded).toContain("Branch Summary")
    expect(expanded).toContain("Switched after the failed deploy.")
  } finally {
    item.destroy()
    syntaxStyle.destroy()
    setup.renderer.destroy()
  }
})

test("a started user message promotes its native root when committed", async () => {
  const message: AgentMessage = { role: "user", content: [{ type: "text", text: "Keep this root." }], timestamp: 1 }
  const harness = await createTranscriptHarness([], { streamingMessage: message })
  try {
    await harness.setup.flush()
    const root = harness.view.scroll.getChildren()[0]
    if (!root) throw new Error("Streaming user root not found")

    harness.state.messages.push(message)
    harness.state.streamingMessage = undefined
    harness.revision.set(1)
    await harness.setup.flush()

    expect(harness.view.scroll.getChildren()[0]).toBe(root)
  } finally {
    harness.destroy()
  }
})

test("user image parts render as inline numbered markers", async () => {
  const message: AgentMessage = {
    role: "user",
    content: [
      { type: "text", text: "Compare" },
      { type: "image", mimeType: "image/png", data: "AAAA" },
      { type: "text", text: "with" },
      { type: "image", mimeType: "image/jpeg", data: "BBBB" }
    ],
    timestamp: 1
  }
  const harness = await createTranscriptHarness([message])
  try {
    await harness.setup.flush()
    expect(harness.setup.captureCharFrame()).toContain("Compare [image #1] with [image #2]")
  } finally {
    harness.destroy()
  }
})

test("assistant sequences coalesce adjacent semantic parts and give every item one trailing row", async () => {
  const setup = await createTestRenderer({ width: 60, height: 20, useThread: false })
  const syntaxStyle = createSyntaxStyle(defaultTheme)
  const thinkingSyntaxStyle = createThinkingSyntaxStyle(defaultTheme)
  const message = {
    ...fauxAssistantMessage(
      [
        { type: "thinking" as const, thinking: "first" },
        { type: "thinking" as const, thinking: " second" },
        fauxText("answer"),
        fauxText(" continued"),
        fauxToolCall("read", { path: "file.ts" }, { id: "item-tool" }),
        fauxText("after")
      ],
      { stopReason: "error" }
    ),
    errorMessage: "Assistant failed"
  }
  const view = new StreamingAssistantView(
    setup.renderer,
    message,
    defaultTheme,
    syntaxStyle,
    thinkingSyntaxStyle,
    undefined,
    "/work"
  )
  setup.renderer.root.add(view.root)

  try {
    await setup.renderOnce()
    const items = view.root.getChildren()
    expect(items).toHaveLength(5)
    expect(descendantsOfType(view.root, MarkdownRenderable)).toHaveLength(3)
    const rows = setup
      .captureCharFrame()
      .split("\n")
      .map(row => row.trim())
    const thinking = rows.indexOf("first second")
    const answer = rows.indexOf("answer continued")
    const after = rows.indexOf("after")
    const error = rows.indexOf("Assistant failed")
    expect(answer - thinking).toBe(2)
    expect(rows[answer + 1]).toBe("")
    expect(rows[after - 1]).toBe("")
    expect(error - after).toBe(2)
    expect(rows[error + 1]).toBe("")
    expect(view.toolCallIds).toEqual(["item-tool"])
  } finally {
    view.destroy()
    syntaxStyle.destroy()
    thinkingSyntaxStyle.destroy()
    setup.renderer.destroy()
  }
})

test("empty historical Bash failures stay header-only", async () => {
  const setup = await createTestRenderer({ width: 48, height: 8, useThread: false })
  const syntaxStyle = createSyntaxStyle(defaultTheme)
  const item = createMessageItemView(
    setup.renderer,
    {
      role: "bashExecution",
      command: "false",
      output: "",
      truncated: false,
      exitCode: 1,
      cancelled: false,
      timestamp: 1
    },
    { theme: defaultTheme, syntaxStyle, cwd: "/work" }
  )
  if (!item) throw new Error("Historical Bash item not created")
  setup.renderer.root.add(item.root)

  try {
    await setup.renderOnce()
    const frame = setup.captureCharFrame()
    expect(frame).toContain("◆ Run false · exit 1")
    expect(frame).not.toContain("│")
    expect(frame).not.toContain("╰───")
  } finally {
    item.destroy()
    syntaxStyle.destroy()
    setup.renderer.destroy()
  }
})

test("displayed custom messages use labelled default chrome while hidden messages allocate nothing", async () => {
  const setup = await createTestRenderer({ width: 48, height: 8, useThread: false })
  const syntaxStyle = createSyntaxStyle(defaultTheme)
  const displayed = createMessageItemView(
    setup.renderer,
    {
      role: "custom",
      customType: "example.notice",
      content: [
        { type: "text", text: "custom body" },
        { type: "image", mimeType: "image/png", data: "aW1hZ2U=" }
      ],
      display: true,
      timestamp: 1
    },
    { theme: defaultTheme, syntaxStyle }
  )
  const hidden = createMessageItemView(
    setup.renderer,
    { role: "custom", customType: "example.hidden", content: "hidden body", display: false, timestamp: 2 },
    { theme: defaultTheme, syntaxStyle }
  )
  if (!displayed) throw new Error("Displayed custom item not created")
  setup.renderer.root.add(displayed.root)

  try {
    await setup.renderOnce()
    const frame = setup.captureCharFrame()
    expect(frame).toContain("[example.notice]")
    expect(frame).toContain("custom body")
    expect(frame).toContain("[image: image/png]")
    expect(hidden).toBeUndefined()
  } finally {
    displayed.destroy()
    syntaxStyle.destroy()
    setup.renderer.destroy()
  }
})

test("streaming assistant and markdown roots keep identity across deltas", async () => {
  const harness = await createTranscriptHarness([], {
    streamingMessage: fauxAssistantMessage([fauxThinking("first **thought**"), fauxText("first")])
  })
  try {
    await harness.setup.flush()
    const root = harness.setup.renderer.root.findDescendantById("streaming-assistant")
    if (!root) throw new Error("Streaming assistant root not found")
    const [thinkingMarkdown, answerMarkdown] = descendantsOfType(root, MarkdownRenderable)
    if (!thinkingMarkdown || !answerMarkdown) throw new Error("Assistant Markdown roots not found")

    harness.state.streamingMessage = fauxAssistantMessage([
      fauxThinking("first **thought** and second"),
      fauxText("first and second")
    ])
    harness.revision.set(1)
    await harness.setup.flush()

    expect(harness.setup.renderer.root.findDescendantById("streaming-assistant")).toBe(root)
    const updatedMarkdown = descendantsOfType(root, MarkdownRenderable)
    expect(updatedMarkdown).toEqual([thinkingMarkdown, answerMarkdown])
    expect(thinkingMarkdown.content).toBe("first **thought** and second")
    expect(answerMarkdown.content).toBe("first and second")
    expect(thinkingMarkdown.streaming).toBe(true)
    expect(answerMarkdown.streaming).toBe(true)
    expect(harness.view.diagnostics).toMatchObject({ streamingCreates: 1, streamingUpdates: 1 })
    await renderMarkdownSettled(harness.setup)
  } finally {
    harness.destroy()
  }
})

test("committing a streamed assistant keeps Markdown visible without replacing the native root", async () => {
  const message = fauxAssistantMessage("## Done\n\nFinal **answer**.")
  const harness = await createTranscriptHarness([], { streamingMessage: message })
  try {
    await harness.setup.renderOnce()
    const root = harness.setup.renderer.root.findDescendantById("streaming-assistant")
    if (!root) throw new Error("Streaming assistant root not found")
    const markdown = descendant(root, MarkdownRenderable)

    harness.state.messages.push(message)
    harness.state.streamingMessage = undefined
    harness.revision.set(1)
    await harness.setup.renderOnce()

    expect(harness.setup.renderer.root.findDescendantById("assistant-message:0")).toBe(root)
    expect(descendant(root, MarkdownRenderable)).toBe(markdown)
    expect(markdown.streaming).toBe(true)
    const frame = harness.setup.captureCharFrame()
    expect(frame).toContain("Done")
    expect(frame).toContain("Final answer.")
    expect(frame).not.toContain("## Done")
    expect(frame).not.toContain("**answer**")
    await renderMarkdownSettled(harness.setup)
  } finally {
    harness.destroy()
  }
})

test("restored assistant Markdown is visible on its first frame", async () => {
  const harness = await createTranscriptHarness([fauxAssistantMessage("## Restored\n\nFinal **answer**.")])
  try {
    await harness.setup.renderOnce()
    const root = harness.setup.renderer.root.findDescendantById("assistant-message:0")
    if (!root) throw new Error("Committed assistant root not found")
    expect(descendant(root, MarkdownRenderable).streaming).toBe(true)
    const frame = harness.setup.captureCharFrame()
    expect(frame).toContain("Restored")
    expect(frame).toContain("Final answer.")
    expect(frame).not.toContain("## Restored")
    expect(frame).not.toContain("**answer**")
    await renderMarkdownSettled(harness.setup)
  } finally {
    harness.destroy()
  }
})

test("a streamed tool root keeps identity through argument, execution, and committed result phases", async () => {
  const assistant = fauxAssistantMessage(
    [
      fauxText("Before the tool."),
      fauxToolCall("bash", { command: "printf hello" }, { id: "bash-life" }),
      fauxText("After the tool.")
    ],
    { stopReason: "toolUse" }
  )
  const preparing: ActiveTool = { id: "bash-life", name: "bash", args: { command: "printf hel" }, status: "preparing" }
  const harness = await createTranscriptHarness([], {
    streamingMessage: assistant,
    tools: new Map([[preparing.id, preparing]])
  })
  try {
    await harness.setup.flush()
    const root = requiredRenderable(harness, "active-tool:bash-life")
    const frame = harness.setup.captureCharFrame()
    expect(frame.indexOf("Before the tool.")).toBeLessThan(frame.indexOf("Run printf hel"))
    expect(frame.indexOf("Run printf hel")).toBeLessThan(frame.indexOf("After the tool."))

    const ready: ActiveTool = { ...preparing, args: { command: "printf hello" }, status: "ready" }
    harness.state.messages.push(assistant)
    harness.state.streamingMessage = undefined
    harness.tools.set(new Map([[ready.id, ready]]))
    harness.revision.set(1)
    await harness.setup.flush()
    expect(requiredRenderable(harness, "active-tool:bash-life")).toBe(root)

    const running: ActiveTool = { ...ready, status: "running", result: { content: [{ type: "text", text: "hel" }] } }
    harness.tools.set(new Map([[running.id, running]]))
    harness.revision.set(2)
    await harness.setup.flush()
    expect(requiredRenderable(harness, "active-tool:bash-life")).toBe(root)
    expect(harness.setup.captureCharFrame()).toContain("hel")

    harness.state.messages.push({
      role: "toolResult",
      toolCallId: "bash-life",
      toolName: "bash",
      content: [{ type: "text", text: "hello" }],
      details: undefined,
      isError: false,
      timestamp: 2
    })
    harness.tools.set(new Map())
    harness.revision.set(3)
    await harness.setup.flush()

    expect(requiredRenderable(harness, "active-tool:bash-life")).toBe(root)
    expect(harness.setup.captureCharFrame()).toContain("hello")
    expect(harness.view.diagnostics.activeToolDestroys).toBe(0)
  } finally {
    harness.destroy()
  }
})

test("retry attempts retain separate tool roots when a provider reuses a call ID", async () => {
  const failed = {
    ...fauxAssistantMessage(fauxToolCall("bash", { command: "echo failed-attempt" }, { id: "reused-call" }), {
      stopReason: "error"
    }),
    errorMessage: "network error"
  }
  const retry = fauxAssistantMessage(fauxToolCall("bash", { command: "echo retry-attempt" }, { id: "reused-call" }), {
    stopReason: "toolUse"
  })
  const harness = await createTranscriptHarness([failed, retry])
  try {
    await harness.setup.flush()
    const first = requiredRenderable(harness, "assistant-message:0").findDescendantById(
      "active-tool:failed:0:reused-call"
    )
    const second = requiredRenderable(harness, "assistant-message:1").findDescendantById("active-tool:reused-call")

    expect(first).toBeDefined()
    expect(second).toBeDefined()
    expect(first).not.toBe(second)
    expect(harness.setup.captureCharFrame()).toContain("echo failed-attempt")
    expect(harness.setup.captureCharFrame()).toContain("echo retry-attempt")
  } finally {
    harness.destroy()
  }
})

test("consecutive failed retries render terminal tool data from their own messages", async () => {
  const first = {
    ...fauxAssistantMessage(fauxToolCall("bash", { command: "echo first-attempt" }, { id: "reused-failure" }), {
      stopReason: "error"
    }),
    errorMessage: "first failure"
  }
  const second = {
    ...fauxAssistantMessage(fauxToolCall("bash", { command: "echo second-attempt" }, { id: "reused-failure" }), {
      stopReason: "error"
    }),
    errorMessage: "second failure"
  }
  const stale: ActiveTool = {
    id: "reused-failure",
    name: "bash",
    args: { command: "echo first-attempt" },
    status: "failed",
    result: { content: [{ type: "text", text: "first failure" }] }
  }
  const harness = await createTranscriptHarness([first, second], { tools: new Map([[stale.id, stale]]) })
  try {
    await harness.setup.flush()
    const frame = harness.setup.captureCharFrame()

    expect(
      requiredRenderable(harness, "assistant-message:0").findDescendantById("active-tool:failed:0:reused-failure")
    ).toBeDefined()
    expect(
      requiredRenderable(harness, "assistant-message:1").findDescendantById("active-tool:failed:1:reused-failure")
    ).toBeDefined()
    expect(frame).toContain("echo first-attempt")
    expect(frame).toContain("first failure")
    expect(frame).toContain("echo second-attempt")
    expect(frame).toContain("second failure")
  } finally {
    harness.destroy()
  }
})

test("live eviction promotes a still-retained tool result out of its assistant root", async () => {
  const assistant = fauxAssistantMessage(fauxToolCall("bash", { command: "printf kept" }, { id: "boundary" }), {
    stopReason: "toolUse"
  })
  const result: AgentMessage = {
    role: "toolResult",
    toolCallId: "boundary",
    toolName: "bash",
    content: [{ type: "text", text: "kept result" }],
    isError: false,
    timestamp: 1
  }
  const messages = [assistant, result, ...userMessages(198, 2)]
  const harness = await createTranscriptHarness(messages)
  try {
    await harness.setup.flush()
    const root = requiredRenderable(harness, "active-tool:boundary")

    harness.state.messages.push(...userMessages(1, 200))
    harness.revision.set(1)
    await harness.setup.flush()

    expect(requiredRenderable(harness, "active-tool:boundary")).toBe(root)
    expect(root.isDestroyed).toBe(false)
    harness.view.scroll.scrollTo(0)
    await harness.setup.renderOnce()
    expect(harness.setup.captureCharFrame()).toContain("kept result")
    expect(harness.view.diagnostics).toMatchObject({ projectedMessages: 200, omittedMessages: 1 })
  } finally {
    harness.destroy()
  }
})

test("embedded tool views share one hard transcript projection bound", async () => {
  const calls = Array.from({ length: 65 }, (_, index) =>
    fauxToolCall("bash", { command: `echo ${index}` }, { id: `bounded-${index}` })
  )
  const assistant = fauxAssistantMessage(calls, { stopReason: "toolUse" })
  const harness = await createTranscriptHarness([assistant], { height: 100 })
  try {
    await harness.setup.flush()

    expect(harness.view.retainedToolCount).toBe(64)
    expect(harness.setup.renderer.root.findDescendantById("active-tool:bounded-0")).toBeUndefined()
    expect(requiredRenderable(harness, "active-tool:bounded-64")).toBeDefined()
    harness.view.scroll.scrollTo(0)
    await harness.setup.renderOnce()
    expect(harness.setup.captureCharFrame()).toContain("1 tool invocation not rendered")
  } finally {
    harness.destroy()
  }
})

test("visible running tools refresh their marker and elapsed time from the renderer lifecycle", async () => {
  let now = 1_000
  const nowSpy = spyOn(performance, "now").mockImplementation(() => now)
  const tool: ActiveTool = { id: "elapsed", name: "bash", args: { command: "sleep 30" }, status: "running" }
  const harness = await createTranscriptHarness([], { tools: new Map([[tool.id, tool]]) })
  try {
    await harness.setup.flush()
    expect(harness.setup.captureCharFrame()).toContain("Run sleep 30 · 0.0s")
    expect(
      harness.setup
        .captureSpans()
        .lines.flatMap(line => line.spans)
        .find(span => span.text === "◈ ")
        ?.fg.toInts()
    ).toEqual([114, 139, 133, 255])

    now = 2_300
    await harness.setup.renderOnce()
    expect(harness.setup.captureCharFrame()).toContain("Run sleep 30 · 1.3s")
    expect(
      harness.setup
        .captureSpans()
        .lines.flatMap(line => line.spans)
        .find(span => span.text === "◈ ")
        ?.fg.toInts()
    ).toEqual([110, 124, 120, 255])
    expect(harness.setup.renderer.liveRequestCount).toBe(1)

    const done: ActiveTool = { ...tool, status: "done", result: { content: [{ type: "text", text: "finished" }] } }
    harness.tools.set(new Map([[done.id, done]]))
    harness.revision.set(1)
    await harness.setup.flush()
    // Duration stays visible after completion; only the live refresh stops.
    expect(harness.setup.captureCharFrame()).toContain("1.3s")
    expect(harness.setup.renderer.liveRequestCount).toBe(0)
  } finally {
    harness.destroy()
    nowSpy.mockRestore()
  }
})

test("transcript destruction releases its running-tool live request", async () => {
  const tool: ActiveTool = { id: "elapsed-dispose", name: "bash", args: { command: "sleep 30" }, status: "running" }
  const harness = await createTranscriptHarness([], { tools: new Map([[tool.id, tool]]) })
  try {
    await harness.setup.flush()
    expect(harness.setup.renderer.liveRequestCount).toBe(1)
    harness.view.destroy()
    expect(harness.setup.renderer.liveRequestCount).toBe(0)
  } finally {
    harness.destroy()
  }
})

test("a coalesced agent end renders skipped sequential calls as aborted", async () => {
  const assistant = fauxAssistantMessage(
    [
      fauxToolCall("bash", { command: "sleep 10" }, { id: "finished-first" }),
      fauxToolCall("read", { path: "never-read.txt" }, { id: "skipped-second" })
    ],
    { stopReason: "toolUse" }
  )
  const result: AgentMessage = {
    role: "toolResult",
    toolCallId: "finished-first",
    toolName: "bash",
    content: [{ type: "text", text: "Operation aborted" }],
    isError: true,
    timestamp: 2
  }
  const skipped: ActiveTool = {
    id: "skipped-second",
    name: "read",
    args: { path: "never-read.txt" },
    status: "aborted",
    result: { content: [{ type: "text", text: "Operation aborted" }] }
  }
  const harness = await createTranscriptHarness([assistant, result], { tools: new Map([[skipped.id, skipped]]) })
  try {
    await harness.setup.flush()
    const frame = harness.setup.captureCharFrame()
    expect(frame).toContain("Read never-read.txt · aborted")
    expect(frame).toContain("never-read.txt")
    expect(frame).not.toContain("preparing")
  } finally {
    harness.destroy()
  }
})

test("an aborted committed tool call remains terminal after transient state clears", async () => {
  const message = fauxAssistantMessage(fauxToolCall("bash", { command: "sleep 10" }, { id: "bash-aborted" }), {
    stopReason: "aborted"
  })
  const harness = await createTranscriptHarness([message])
  try {
    await harness.setup.flush()
    const frame = harness.setup.captureCharFrame()
    expect(frame).toContain("Run sleep 10 · aborted")
    expect(frame).toContain("Operation aborted before execution")
    expect(frame).not.toContain("preparing")
  } finally {
    harness.destroy()
  }
})

test("the semantic tool binding expands bounded previews without replacing roots", async () => {
  const tool: ActiveTool = {
    id: "write-expand",
    name: "write",
    args: { path: "large.txt", content: "x".repeat(800) },
    status: "preparing"
  }
  const harness = await createTranscriptHarness([], { width: 30, height: 20, tools: new Map([[tool.id, tool]]) })
  try {
    await harness.setup.flush()
    const root = requiredRenderable(harness, "active-tool:write-expand")
    expect(harness.setup.captureCharFrame()).toContain("Write large.txt")
    expect(harness.setup.captureCharFrame()).not.toContain("xxxxxxxx")

    harness.setup.mockInput.pressKey("o", { ctrl: true })
    await harness.setup.flush()
    expect(requiredRenderable(harness, "active-tool:write-expand")).toBe(root)
    expect(harness.setup.captureCharFrame()).toContain("xxxxxxxx")
    expect(harness.setup.captureCharFrame()).not.toContain("Ctrl+O details")
  } finally {
    harness.destroy()
  }
})

test("streaming text updates do not reproject unchanged tool invocations", async () => {
  const first = activeTool("cached-first", "one")
  const second = activeTool("cached-second", "two")
  const streaming = (text: string) =>
    fauxAssistantMessage([
      fauxToolCall("bash", { command: "echo cached-first" }, { id: first.id }),
      fauxToolCall("bash", { command: "echo cached-second" }, { id: second.id }),
      fauxText(text)
    ])
  const harness = await createTranscriptHarness([], {
    streamingMessage: streaming("before"),
    tools: new Map([
      [first.id, first],
      [second.id, second]
    ])
  })
  try {
    await harness.setup.flush()
    const projections = harness.view.diagnostics.toolProjections

    harness.state.streamingMessage = streaming("after")
    harness.revision.set(1)
    await harness.setup.flush()

    expect(harness.setup.captureCharFrame()).toContain("after")
    expect(harness.view.diagnostics.toolProjections).toBe(projections)
  } finally {
    harness.destroy()
  }
})

test("active tool updates retain sibling roots and skip unchanged native presentation", async () => {
  const first = activeTool("first", "one")
  const second = activeTool("second", "two")
  const harness = await createTranscriptHarness([], {
    tools: new Map([
      [first.id, first],
      [second.id, second]
    ])
  })
  try {
    await harness.setup.flush()
    const firstRoot = requiredRenderable(harness, "active-tool:first")
    const secondRoot = requiredRenderable(harness, "active-tool:second")
    const initial = harness.view.diagnostics

    const changedSecond = activeTool("second", "two updated")
    harness.tools.set(
      new Map([
        [first.id, first],
        [changedSecond.id, changedSecond]
      ])
    )
    harness.revision.set(1)
    await harness.setup.flush()

    expect(requiredRenderable(harness, "active-tool:first")).toBe(firstRoot)
    expect(requiredRenderable(harness, "active-tool:second")).toBe(secondRoot)
    expect(harness.view.diagnostics.activeToolCreates).toBe(initial.activeToolCreates)
    expect(harness.view.diagnostics.activeToolUpdates).toBe(initial.activeToolUpdates + 1)
  } finally {
    harness.destroy()
  }
})

test("initial and live transcript projection retain only the newest 200 messages", async () => {
  const messages = userMessages(250)
  const harness = await createTranscriptHarness(messages)
  try {
    await harness.setup.flush()
    expect(harness.state.messages).toHaveLength(250)
    expect(harness.view.diagnostics).toMatchObject({ projectedMessages: 200, omittedMessages: 50 })
    expect(harness.view.retainedRootCount).toBe(201)
    expect(harness.setup.renderer.root.findDescendantById("transcript-omitted-history")).toBeDefined()
    expect(harness.view.scroll.getChildren()).toHaveLength(201)
    const retainedRoot = harness.view.scroll.getChildren().at(-1)
    if (!retainedRoot) throw new Error("Newest committed root not found")

    harness.state.messages.push(...userMessages(25, 250))
    harness.revision.set(1)
    await harness.setup.flush()

    expect(harness.state.messages).toHaveLength(275)
    expect(harness.view.diagnostics).toMatchObject({ projectedMessages: 200, omittedMessages: 75 })
    expect(harness.view.retainedRootCount).toBe(201)
    expect(harness.view.scroll.getChildren()).toHaveLength(201)
    expect(harness.view.scroll.getChildren()).toContain(retainedRoot)
  } finally {
    harness.destroy()
  }
})

test("live eviction clears selection and preserves detached viewport intent", async () => {
  const harness = await createTranscriptHarness(userMessages(200), { width: 44, height: 10 })
  try {
    await harness.setup.flush()
    harness.setup.mockInput.pressArrow("up", { ctrl: true, meta: true })
    await harness.setup.flush()
    expect(harness.view.scroll.stickyScroll).toBe(false)
    const firstVisibleMessage = visibleMessage(harness.setup.captureCharFrame())

    const oldest = harness.view.scroll.getChildren()[0]
    if (!oldest) throw new Error("Oldest committed root not found")
    const selectable = descendant(oldest, TextRenderable)
    harness.setup.renderer.startSelection(selectable, selectable.x, selectable.y)
    expect(harness.setup.renderer.hasSelection).toBe(true)

    harness.state.messages.push(...userMessages(1, 200))
    harness.revision.set(1)
    await harness.setup.flush()

    expect(harness.setup.renderer.hasSelection).toBe(false)
    expect(harness.view.scroll.stickyScroll).toBe(false)
    expect(visibleMessage(harness.setup.captureCharFrame())).toBe(firstVisibleMessage)
    expect(harness.view.diagnostics).toMatchObject({ projectedMessages: 200, omittedMessages: 1 })
  } finally {
    harness.destroy()
  }
})

test("a detached viewport inside an evicted root lands on the omission marker", async () => {
  const harness = await createTranscriptHarness(userMessages(200), { width: 44, height: 10 })
  try {
    await harness.setup.flush()
    harness.view.scroll.scrollTo(0)
    harness.setup.mockInput.pressArrow("up", { ctrl: true, meta: true })
    await harness.setup.flush()
    expect(harness.view.scroll.stickyScroll).toBe(false)

    harness.state.messages.push(...userMessages(1, 200))
    harness.revision.set(1)
    await harness.setup.flush()

    expect(harness.view.scroll.stickyScroll).toBe(false)
    expect(harness.setup.captureCharFrame()).toContain("… 1 earlier messages are not rendered")
  } finally {
    harness.destroy()
  }
})

test("diagnostic overlay samples at a bounded rate and releases its frame listener", async () => {
  const harness = await createTranscriptHarness([])
  const before = harness.setup.renderer.listenerCount(CliRenderEvents.FRAME)
  let memoryCaptures = 0
  const overlay = new TuiDiagnosticsOverlay(
    harness.setup.renderer,
    { showTimeToFirstDraw: true, showStats: true, showMemory: true },
    () => harness.view,
    () => {
      memoryCaptures++
      return {
        process: { rssBytes: 100, heapUsedBytes: 50, heapTotalBytes: 75, externalBytes: 10, arrayBufferBytes: 5 },
        session: {
          committedMessages: 0,
          committedMessageBytes: 0,
          streamingMessageBytes: 0,
          queuedInputs: 0,
          queuedInputBytes: 0,
          subscribers: 1,
          journal: {
            entries: 2,
            residentEntries: 0,
            coldEntries: 2,
            journalBytes: 100,
            residentEntryBytes: 0,
            imageBlobBytes: 0,
            customStateEntries: 0,
            customStateBytes: 0,
            coldMemoryBytes: 50,
            coldMemoryLogicalBytes: 100,
            coldMemoryBlocks: 1
          }
        },
        renderer: {
          reachableRenderables: 4,
          registeredRenderables: 5,
          transcriptRoots: 0,
          bufferBytes: 100,
          lifecyclePasses: 0,
          liveRequests: 0
        },
        listeners: { renderer: 1, keyInput: 1 }
      }
    },
    defaultTheme
  )
  harness.setup.renderer.root.add(overlay.root)

  try {
    expect(harness.setup.renderer.listenerCount(CliRenderEvents.FRAME)).toBe(before + 1)
    expect(harness.setup.renderer.root.findDescendantById("tui-time-to-first-draw")).toBeDefined()
    expect(harness.setup.renderer.root.findDescendantById("tui-performance-stats")).toBeDefined()
    expect(harness.setup.renderer.root.findDescendantById("tui-memory-stats")).toBeDefined()
    await harness.setup.flush()
    await harness.setup.renderOnce()
    const frame = harness.setup.captureCharFrame()
    expect(frame).toContain("Overall avg")
    expect(frame).toContain("heapUsed")
    expect(frame).toContain("heapTotal")
    expect(frame).toContain("cold 2 50B/100B")
    expect(frame).not.toContain(" native ")
    expect(memoryCaptures).toBe(1)
  } finally {
    overlay.destroy()
    expect(harness.setup.renderer.listenerCount(CliRenderEvents.FRAME)).toBe(before)
    harness.destroy()
  }
})

async function createTranscriptHarness(
  messages: AgentMessage[],
  options: {
    readonly width?: number
    readonly height?: number
    readonly paused?: boolean
    readonly streamingMessage?: AgentMessage
    readonly tools?: ReadonlyMap<string, ActiveTool>
  } = {}
): Promise<TranscriptHarness> {
  const setup = await createTestRenderer({
    width: options.width ?? 60,
    height: options.height ?? 20,
    useThread: false,
    gatherStats: true
  })
  if (options.paused) setup.renderer.pause()

  const state = { messages, streamingMessage: options.streamingMessage }
  const session = {
    get messages() {
      return state.messages
    },
    get streamingMessage() {
      return state.streamingMessage
    },
    isStreaming: false,
    isAborting: false,
    retryStatus: { type: "idle" } as const,
    compactionStatus: { type: "idle" } as const,
    workPlan: { revision: 0, steps: [] } as const
  }
  const revision = atom(0)
  const promptRevision = atom(0)
  const tools = atom<ReadonlyMap<string, ActiveTool>>(options.tools ?? new Map())
  const interactive = {
    $promptRevision: promptRevision,
    $transcriptRevision: revision,
    $activeTools: tools,
    getSession: () => session
  }
  const syntaxStyle = createSyntaxStyle(defaultTheme)
  const view = new TranscriptView(setup.renderer, interactive, new InteractiveKeybindings(), defaultTheme, syntaxStyle)
  setup.renderer.root.add(view.root)
  let destroyed = false

  return {
    setup,
    state,
    revision,
    tools,
    view,
    destroy() {
      if (destroyed) return
      destroyed = true
      view.destroy()
      syntaxStyle.destroy()
      if (!setup.renderer.isDestroyed) setup.renderer.destroy()
    }
  }
}

function activeTool(id: string, output: string): ActiveTool {
  return {
    id,
    name: "bash",
    args: { command: `echo ${id}` },
    status: "running",
    result: { content: [{ type: "text", text: output }] }
  }
}

function userMessages(count: number, start = 0): AgentMessage[] {
  return Array.from({ length: count }, (_, offset) => ({
    role: "user" as const,
    content: [{ type: "text" as const, text: `message ${start + offset}` }],
    timestamp: start + offset
  }))
}

function visibleMessage(frame: string): string | undefined {
  return frame.match(/message \d+/)?.[0]
}

function requiredRenderable(harness: TranscriptHarness, id: string): Renderable {
  const renderable = harness.setup.renderer.root.findDescendantById(id)
  if (!renderable) throw new Error(`Renderable not found: ${id}`)
  return renderable
}

function descendantsOfType<T extends Renderable>(root: Renderable, type: abstract new (...args: never[]) => T): T[] {
  const matches: T[] = []
  const pending = [...root.getChildren()]
  while (pending.length > 0) {
    const candidate = pending.shift()
    if (!candidate) continue
    if (candidate instanceof type) matches.push(candidate)
    pending.push(...candidate.getChildren())
  }
  return matches
}

function descendant<T extends Renderable>(root: Renderable, type: abstract new (...args: never[]) => T): T {
  const pending = [...root.getChildren()]
  while (pending.length > 0) {
    const candidate = pending.shift()
    if (!candidate) continue
    if (candidate instanceof type) return candidate
    pending.push(...candidate.getChildren())
  }
  throw new Error(`Descendant not found: ${type.name}`)
}
