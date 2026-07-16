import { expect, spyOn, test } from "bun:test"

import { CliRenderEvents, MarkdownRenderable, type Renderable, TextRenderable } from "@opentui/core"
import { createTestRenderer, type TestRendererSetup } from "@opentui/core/testing"
import type { AgentMessage } from "@openzi/coding-agent"
import { fauxAssistantMessage, fauxText, fauxToolCall } from "@openzi/coding-agent/testing"
import { atom, type WritableAtom } from "nanostores"

import { TuiDiagnosticsOverlay } from "../../src/interactive/diagnostics.js"
import { InteractiveKeybindings } from "../../src/interactive/interactive-keybindings.js"
import type { ActiveTool } from "../../src/interactive/interactive-store.js"
import { TranscriptView } from "../../src/interactive/transcript/view.js"
import { createSyntaxStyle, defaultTheme } from "../../src/theme.js"

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

test("streaming assistant and markdown roots keep identity across deltas", async () => {
  const harness = await createTranscriptHarness([], { streamingMessage: fauxAssistantMessage("first") })
  try {
    await harness.setup.flush()
    const root = harness.setup.renderer.root.findDescendantById("streaming-assistant")
    if (!root) throw new Error("Streaming assistant root not found")
    const markdown = descendant(root, MarkdownRenderable)

    harness.state.streamingMessage = fauxAssistantMessage("first and second")
    harness.revision.set(1)
    await harness.setup.flush()

    expect(harness.setup.renderer.root.findDescendantById("streaming-assistant")).toBe(root)
    expect(descendant(root, MarkdownRenderable)).toBe(markdown)
    expect(markdown.content).toBe("first and second")
    expect(markdown.streaming).toBe(true)
    expect(harness.view.diagnostics).toMatchObject({ streamingCreates: 1, streamingUpdates: 1 })
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
    expect(frame.indexOf("Before the tool.")).toBeLessThan(frame.indexOf("$ printf hel"))
    expect(frame.indexOf("$ printf hel")).toBeLessThan(frame.indexOf("After the tool."))

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

test("visible running tools refresh elapsed time from the renderer lifecycle", async () => {
  let now = 1_000
  const nowSpy = spyOn(performance, "now").mockImplementation(() => now)
  const tool: ActiveTool = { id: "elapsed", name: "bash", args: { command: "sleep 30" }, status: "running" }
  const harness = await createTranscriptHarness([], { tools: new Map([[tool.id, tool]]) })
  try {
    await harness.setup.flush()
    expect(harness.setup.captureCharFrame()).toContain("Elapsed 0.0s")

    now = 2_300
    await harness.setup.renderOnce()
    expect(harness.setup.captureCharFrame()).toContain("Elapsed 1.3s")
    expect(harness.setup.renderer.liveRequestCount).toBeGreaterThan(0)

    const done: ActiveTool = { ...tool, status: "done", result: { content: [{ type: "text", text: "finished" }] } }
    harness.tools.set(new Map([[done.id, done]]))
    harness.revision.set(1)
    await harness.setup.flush()
    expect(harness.setup.captureCharFrame()).toContain("Took 1.3s")
    expect(harness.setup.renderer.liveRequestCount).toBe(0)
  } finally {
    harness.destroy()
    nowSpy.mockRestore()
  }
})

test("transcript destruction releases a running elapsed live request", async () => {
  const tool: ActiveTool = { id: "elapsed-dispose", name: "bash", args: { command: "sleep 30" }, status: "running" }
  const harness = await createTranscriptHarness([], { tools: new Map([[tool.id, tool]]) })
  try {
    await harness.setup.flush()
    expect(harness.setup.renderer.liveRequestCount).toBeGreaterThan(0)
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
    expect(frame).toContain("read never-read.txt (aborted)")
    expect(frame).not.toContain("read never-read.txt (preparing)")
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
    expect(frame).toContain("$ sleep 10 (aborted)")
    expect(frame).toContain("Operation aborted")
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
    expect(harness.setup.captureCharFrame()).toContain("Ctrl+O to expand")

    harness.setup.mockInput.pressKey("o", { ctrl: true })
    await harness.setup.flush()
    expect(requiredRenderable(harness, "active-tool:write-expand")).toBe(root)
    expect(harness.setup.captureCharFrame()).not.toContain("Ctrl+O to expand")
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
          subscribers: 1
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
    }
  }
  const revision = atom(0)
  const tools = atom<ReadonlyMap<string, ActiveTool>>(options.tools ?? new Map())
  const interactive = { $transcriptRevision: revision, $activeTools: tools, getSession: () => session }
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
