import { expect, test } from "bun:test"

import { BoxRenderable, ScrollBoxRenderable, TextareaRenderable } from "@opentui/core"
import { createAgentSession, type AgentMessage, type AgentSession, SessionManager } from "@with-zi/coding-agent"
import {
  createModels,
  createTestAgentRuntime as createAgentRuntime,
  fauxAssistantMessage,
  fauxProvider,
  fauxThinking,
  fauxToolCall
} from "@with-zi/coding-agent/testing"

import { createInteractiveTest, type InteractiveTestSetup, renderMarkdownSettled, renderSettled } from "./harness.js"

/* oxlint-disable no-await-in-loop */

test("manual page and line navigation detaches, coalesces unseen output, and returns to follow", async () => {
  const session = await createTranscriptSession(4)
  const setup = await createInteractiveTest(session, { width: 48, height: 12, kittyKeyboard: true })

  try {
    await renderSettled(setup)
    const scroll = transcriptScroll(setup.renderer)
    const input = promptInput(setup.renderer)
    const initialMaximum = maximumScroll(scroll)
    expect(initialMaximum).toBeGreaterThan(0)
    expect(scroll.scrollTop).toBe(initialMaximum)
    expect(scroll.stickyScroll).toBe(true)
    expect(setup.renderer.currentFocusedRenderable === input).toBe(true)

    const pageStart = scroll.scrollTop
    await pressRaw(setup, "\x1b[5~")
    expect(scroll.scrollTop).toBe(Math.max(0, Math.round(pageStart - scroll.viewport.height / 2)))
    expect(scroll.stickyScroll).toBe(false)
    expect(setup.renderer.currentFocusedRenderable === input).toBe(true)

    await pressModifiedArrow(setup, "up")
    expect(scroll.scrollTop).toBe(Math.max(0, Math.round(pageStart - scroll.viewport.height / 2) - 1))

    const detachedTop = scroll.scrollTop
    const detachedViewportHeight = scroll.viewport.height
    session.setThinkingLevel("low")
    await renderSettled(setup)
    expect(scroll.scrollTop).toBe(detachedTop)
    expect(setup.captureCharFrame()).not.toContain("New output (Ctrl+End to jump)")

    await promptAndRender(session, setup, "first update")
    expect(scroll.scrollTop).toBe(detachedTop)
    expect(scroll.viewport.height).toBe(detachedViewportHeight)
    expect(scroll.stickyScroll).toBe(false)
    expect(occurrences(setup.captureCharFrame(), "New output (Ctrl+End to jump)")).toBe(1)

    await promptAndRender(session, setup, "second update")
    expect(scroll.scrollTop).toBe(detachedTop)
    expect(occurrences(setup.captureCharFrame(), "New output (Ctrl+End to jump)")).toBe(1)

    const pageDownStart = scroll.scrollTop
    const pageDownMaximum = maximumScroll(scroll)
    await pressRaw(setup, "\x1b[6~")
    expect(scroll.scrollTop).toBe(Math.min(pageDownMaximum, Math.round(pageDownStart + scroll.viewport.height / 2)))
    for (let index = 0; index < 20 && scroll.scrollTop < maximumScroll(scroll); index++) {
      await pressRaw(setup, "\x1b[6~")
    }
    expect(scroll.scrollTop).toBe(maximumScroll(scroll))
    expect(scroll.stickyScroll).toBe(true)
    expect(setup.captureCharFrame()).not.toContain("New output (Ctrl+End to jump)")

    await promptAndRender(session, setup, "following update")
    expect(scroll.scrollTop).toBe(maximumScroll(scroll))
    expect(scroll.stickyScroll).toBe(true)
  } finally {
    session.dispose()
    setup.destroy()
  }
})

test("detached streaming composes one stable activity and unseen-output row", async () => {
  const pending = await createPendingTranscriptSession()
  const setup = await createInteractiveTest(pending.session, { width: 60, height: 12, kittyKeyboard: true })

  try {
    await renderSettled(setup)
    const scroll = transcriptScroll(setup.renderer)
    await pressRaw(setup, "\x1b[5~")
    const detachedTop = scroll.scrollTop
    const idleViewportHeight = scroll.viewport.height

    const completion = pending.session.prompt("stream while detached")
    await pending.providerStarted.promise
    await renderSettled(setup)

    expect(setup.captureCharFrame()).toContain("Working… • New output (Ctrl+End to jump)")
    expect(scroll.scrollTop).toBe(detachedTop)
    expect(scroll.viewport.height).toBe(idleViewportHeight)

    pending.releaseProvider.resolve()
    await completion
    await renderSettled(setup)

    expect(setup.captureCharFrame()).not.toContain("Working…")
    expect(setup.captureCharFrame()).toContain("New output (Ctrl+End to jump)")
    expect(scroll.scrollTop).toBe(detachedTop)
    expect(scroll.viewport.height).toBe(idleViewportHeight)

    setup.mockInput.pressKey("END", { ctrl: true })
    await renderSettled(setup)
    expect(setup.captureCharFrame()).not.toContain("New output (Ctrl+End to jump)")
    expect(scroll.viewport.height).toBe(idleViewportHeight)
  } finally {
    pending.releaseProvider.resolve()
    pending.session.dispose()
    setup.destroy()
  }
})

test("transcript navigation follows mode-owned keybinding overrides", async () => {
  const session = await createTranscriptSession(4)
  const setup = await createInteractiveTest(session, { width: 48, height: 12, kittyKeyboard: true }, undefined, {
    "app.transcript.pageUp": ["ctrl+b"],
    "app.transcript.tail": ["ctrl+t"]
  })

  try {
    await renderSettled(setup)
    const scroll = transcriptScroll(setup.renderer)
    const tail = scroll.scrollTop
    await pressRaw(setup, "\x1b[5~")
    expect(scroll.scrollTop).toBe(tail)

    setup.mockInput.pressKey("b", { ctrl: true })
    await renderSettled(setup)
    expect(scroll.scrollTop).toBe(Math.max(0, Math.round(tail - scroll.viewport.height / 2)))
    expect(scroll.stickyScroll).toBe(false)
    await promptAndRender(session, setup, "remapped tail hint")
    expect(setup.captureCharFrame()).toContain("Ctrl+T to jump")
  } finally {
    session.dispose()
    setup.destroy()
  }
})

test("one line above the tail stays detached when output commits", async () => {
  const session = await createTranscriptSession(1)
  const setup = await createInteractiveTest(session, { width: 48, height: 12, kittyKeyboard: true })

  try {
    await renderSettled(setup)
    const scroll = transcriptScroll(setup.renderer)
    const tail = maximumScroll(scroll)
    expect(tail).toBeGreaterThan(1)

    await pressModifiedArrow(setup, "up")
    expect(scroll.scrollTop).toBe(tail - 1)
    expect(scroll.stickyScroll).toBe(false)
    const detachedTop = scroll.scrollTop

    await promptAndRender(session, setup, "output beyond one-row gap")
    expect(scroll.scrollTop).toBe(detachedTop)
    expect(scroll.scrollTop).toBeLessThan(maximumScroll(scroll))
    expect(scroll.stickyScroll).toBe(false)
    expect(setup.captureCharFrame()).toContain("New output (Ctrl+End to jump)")
  } finally {
    session.dispose()
    setup.destroy()
  }
})

test("unseen status yields to a one-row transcript viewport", async () => {
  const session = await createTranscriptSession(1)
  const setup = await createInteractiveTest(session, { width: 20, height: 4, kittyKeyboard: true })

  try {
    await renderSettled(setup)
    const scroll = transcriptScroll(setup.renderer)
    let visibleRow = ""
    for (let index = 0; index < 10 && visibleRow === ""; index++) {
      await pressModifiedArrow(setup, "up")
      visibleRow = (setup.captureCharFrame().split("\n")[0] ?? "").trimEnd()
    }
    expect(scroll.stickyScroll).toBe(false)
    expect(visibleRow).not.toBe("")
    const detachedTop = scroll.scrollTop

    await promptAndRender(session, setup, "constrained unseen output")
    expect(scroll.scrollTop).toBe(detachedTop)
    expect((setup.captureCharFrame().split("\n")[0] ?? "").trimEnd()).toBe(visibleRow)
    expect(setup.captureCharFrame()).not.toContain("New output (Ctrl+End to jump)")

    setup.resize(48, 12)
    await renderSettled(setup)
    expect(scroll.stickyScroll).toBe(false)
    expect(setup.captureCharFrame()).toContain("New output (Ctrl+End to jump)")
  } finally {
    session.dispose()
    setup.destroy()
  }
})

test("Ctrl+End jumps to the tail and a later manual operation cancels a queued jump", async () => {
  const session = await createTranscriptSession(2)
  const setup = await createInteractiveTest(session, { width: 48, height: 12, kittyKeyboard: true })

  try {
    await renderSettled(setup)
    const scroll = transcriptScroll(setup.renderer)

    const tail = scroll.scrollTop
    await pressModifiedArrow(setup, "up")
    expect(scroll.scrollTop).toBe(tail - 1)
    await pressModifiedArrow(setup, "up")
    expect(scroll.scrollTop).toBe(tail - 2)
    expect(scroll.stickyScroll).toBe(false)
    await pressModifiedArrow(setup, "down")
    expect(scroll.scrollTop).toBe(tail - 1)
    expect(scroll.stickyScroll).toBe(false)
    await pressModifiedArrow(setup, "up")
    expect(scroll.scrollTop).toBe(tail - 2)
    expect(scroll.stickyScroll).toBe(false)

    await promptAndRender(session, setup, "unseen before jump")
    expect(setup.captureCharFrame()).toContain("New output (Ctrl+End to jump)")
    await pressKey(setup, "END", { ctrl: true })
    expect(scroll.scrollTop).toBe(maximumScroll(scroll))
    expect(scroll.stickyScroll).toBe(true)
    expect(setup.captureCharFrame()).not.toContain("New output (Ctrl+End to jump)")

    await pressRaw(setup, "\x1b[5~")
    const detachedTop = scroll.scrollTop
    setup.mockInput.pressKey("END", { ctrl: true })
    setup.mockInput.pressArrow("up", { ctrl: true, meta: true })
    await Promise.resolve()
    await renderSettled(setup)

    expect(scroll.scrollTop).toBe(detachedTop - 1)
    expect(scroll.scrollTop).toBeLessThan(maximumScroll(scroll))
    expect(scroll.stickyScroll).toBe(false)
  } finally {
    session.dispose()
    setup.destroy()
  }
})

test("native wheel and resize mechanics preserve detached intent until all content fits", async () => {
  const session = await createTranscriptSession(2)
  const setup = await createInteractiveTest(session, { width: 48, height: 12, kittyKeyboard: true })

  try {
    await renderSettled(setup)
    const scroll = transcriptScroll(setup.renderer)

    setup.resize(48, 9)
    await renderSettled(setup)
    expect(scroll.scrollTop).toBe(maximumScroll(scroll))
    setup.resize(48, 14)
    await renderSettled(setup)
    expect(scroll.scrollTop).toBe(maximumScroll(scroll))
    const initialTail = scroll.scrollTop

    for (let index = 0; index < 3 && scroll.stickyScroll; index++) {
      await setup.mockMouse.scroll(2, 2, "up")
      await Promise.resolve()
      await renderSettled(setup)
    }
    expect(scroll.scrollTop).toBeLessThan(initialTail)
    expect(scroll.stickyScroll).toBe(false)

    for (let index = 0; index < 20 && !scroll.stickyScroll; index++) {
      await setup.mockMouse.scroll(2, 2, "down")
      await Promise.resolve()
      await renderSettled(setup)
    }
    expect(scroll.scrollTop).toBe(maximumScroll(scroll))
    expect(scroll.stickyScroll).toBe(true)

    for (let index = 0; index < 3 && scroll.stickyScroll; index++) {
      await setup.mockMouse.scroll(2, 2, "up")
      await Promise.resolve()
      await renderSettled(setup)
    }
    expect(scroll.stickyScroll).toBe(false)

    await promptAndRender(session, setup, "unseen through resize")
    expect(setup.captureCharFrame()).toContain("New output (Ctrl+End to jump)")

    const status = transcriptStatus(setup.renderer)
    const beforeHintWheel = scroll.scrollTop
    await setup.mockMouse.scroll(status.x + 1, status.y, "down")
    await Promise.resolve()
    await renderSettled(setup)
    expect(scroll.scrollTop).toBeGreaterThan(beforeHintWheel)
    expect(scroll.stickyScroll).toBe(false)

    setup.resize(36, 9)
    await renderSettled(setup)
    expect(scroll.stickyScroll).toBe(false)
    expect(setup.captureCharFrame()).toContain("New output (Ctrl+End to jump)")

    setup.resize(52, 14)
    await renderSettled(setup)
    expect(scroll.stickyScroll).toBe(false)
    expect(setup.captureCharFrame()).toContain("New output (Ctrl+End to jump)")

    setup.resize(52, 80)
    await renderSettled(setup)
    expect(scroll.scrollHeight).toBeLessThanOrEqual(scroll.viewport.height)
    expect(scroll.stickyScroll).toBe(true)
    expect(setup.captureCharFrame()).not.toContain("New output (Ctrl+End to jump)")

    setup.resize(48, 10)
    await renderSettled(setup)
    expect(scroll.scrollTop).toBe(maximumScroll(scroll))
    expect(scroll.stickyScroll).toBe(true)
  } finally {
    session.dispose()
    setup.destroy()
  }
})

test("native selection mouse-down detaches before its first drag event", async () => {
  const session = await createTranscriptSession(1)
  const setup = await createInteractiveTest(session, { width: 48, height: 12, kittyKeyboard: true })

  try {
    await renderSettled(setup)
    const scroll = transcriptScroll(setup.renderer)
    const input = promptInput(setup.renderer)
    const target = "history row 7"
    const rows = setup.captureCharFrame().split("\n")
    const y = rows.findIndex(row => row.includes(target))
    const x = y < 0 ? -1 : (rows[y] ?? "").indexOf(target)
    expect(x).toBe(1)
    expect(y).toBeGreaterThanOrEqual(0)

    await setup.mockMouse.pressDown(x, y)
    await Promise.resolve()
    await renderSettled(setup)

    expect(setup.renderer.getSelection()?.isDragging).toBe(true)
    expect(scroll.stickyScroll).toBe(false)
    const detachedTop = scroll.scrollTop

    await promptAndRender(session, setup, "output before selection drag")
    expect(scroll.scrollTop).toBe(detachedTop)
    expect(scroll.scrollTop).toBeLessThan(maximumScroll(scroll))
    expect(setup.captureCharFrame()).toContain("New output (Ctrl+End to jump)")

    await setup.mockMouse.moveTo(x + "history".length, y)
    await setup.mockMouse.release(x + "history".length, y)
    await Promise.resolve()
    await renderSettled(setup)

    const selection = setup.renderer.getSelection()
    expect(selection?.isDragging).toBe(false)
    expect(selection?.getSelectedText()).toBe("history")
    expect(setup.renderer.currentFocusedRenderable === input).toBe(true)
  } finally {
    session.dispose()
    setup.destroy()
  }
})

test("native selection edge-scrolls in visual order and detaches before streamed output", async () => {
  const session = await createTranscriptSession(1)
  const setup = await createInteractiveTest(session, { width: 48, height: 14, kittyKeyboard: true })

  try {
    await renderSettled(setup)
    const scroll = transcriptScroll(setup.renderer)
    const input = promptInput(setup.renderer)
    const startY = setup
      .captureCharFrame()
      .split("\n")
      .findIndex(row => row.includes("history row"))
    expect(startY).toBeGreaterThanOrEqual(0)

    await setup.mockMouse.pressDown(1, startY)
    await setup.mockMouse.moveTo(13, startY)
    await Promise.resolve()
    await renderSettled(setup)

    expect(setup.renderer.getSelection()?.isDragging).toBe(true)
    expect(scroll.stickyScroll).toBe(false)
    const detachedTop = scroll.scrollTop

    await promptAndRender(session, setup, "output during selection")
    expect(scroll.scrollTop).toBe(detachedTop)
    expect(scroll.scrollTop).toBeLessThan(maximumScroll(scroll))
    expect(setup.captureCharFrame()).toContain("New output (Ctrl+End to jump)")

    await setup.mockMouse.release(13, startY)
    await Promise.resolve()
    await renderSettled(setup)

    const selection = setup.renderer.getSelection()
    expect(selection?.isDragging).toBe(false)
    expect(selection?.getSelectedText()).toBe(
      "history row 2\nhistory row 3\nhistory row 4\nhistory row 5\nhistory row 6"
    )
    expect(setup.renderer.currentFocusedRenderable === input).toBe(true)
  } finally {
    session.dispose()
    setup.destroy()
  }
})

test("streamed tool execution leaves a detached native viewport anchored", async () => {
  const models = createModels()
  const faux = fauxProvider()
  const providerStarted = deferred<void>()
  const releaseToolCall = deferred<void>()
  models.setProvider(faux.provider)
  faux.setResponses([
    fauxAssistantMessage(Array.from({ length: 30 }, (_, index) => `history line ${index + 1}`).join("\n")),
    async () => {
      providerStarted.resolve()
      await releaseToolCall.promise
      return fauxAssistantMessage(fauxToolCall("bash", { command: "printf 'one\\ntwo\\n'" }, { id: "nav-bash" }), {
        stopReason: "toolUse"
      })
    },
    fauxAssistantMessage(fauxThinking("tool complete"))
  ])
  const { session } = await createAgentRuntime({ cwd: process.cwd(), models, session: { type: "new", persist: false } })
  await session.prompt("seed history")
  const setup = await createInteractiveTest(session, { width: 48, height: 12, kittyKeyboard: true })

  try {
    await renderSettled(setup)
    const scroll = transcriptScroll(setup.renderer)
    let operation!: Promise<void>
    operation = session.prompt("run the tool")
    await providerStarted.promise
    await setup.renderOnce()
    setup.renderer.stdin.emit("data", Buffer.from("\x1b[5~"))
    await Promise.resolve()
    // Live provider work owns a frame request, so visual idle is not an admissible wait here.
    await setup.renderOnce()
    const detachedTop = scroll.scrollTop

    releaseToolCall.resolve()
    await operation
    await renderMarkdownSettled(setup)

    expect(session.messages.some(message => message.role === "toolResult" && message.toolCallId === "nav-bash")).toBe(
      true
    )
    expect(scroll.scrollTop).toBe(detachedTop)
    expect(scroll.stickyScroll).toBe(false)
    expect(occurrences(setup.captureCharFrame(), "New output (Ctrl+End to jump)")).toBe(1)
  } finally {
    session.dispose()
    setup.destroy()
  }
})

test("queued native callbacks cannot leak across a session replacement", async () => {
  const first = await createTranscriptSession(1)
  const second = await createTranscriptSession(1)
  const setup = await createInteractiveTest(first, { width: 48, height: 12, kittyKeyboard: true })

  try {
    await renderSettled(setup)
    const oldScroll = transcriptScroll(setup.renderer)
    await pressRaw(setup, "\x1b[5~")
    expect(oldScroll.stickyScroll).toBe(false)

    oldScroll.onSizeChange?.()
    setup.mockInput.pressKey("END", { ctrl: true })
    const wheel = setup.mockMouse.scroll(2, 2, "up")
    setup.mode.replaceSession(second)
    await wheel
    await renderSettled(setup)

    const newScroll = transcriptScroll(setup.renderer)
    expect(oldScroll.isDestroyed).toBe(true)
    expect(newScroll === oldScroll).toBe(false)
    expect(newScroll.scrollTop).toBe(maximumScroll(newScroll))
    expect(newScroll.stickyScroll).toBe(true)
    expect(setup.captureCharFrame()).not.toContain("New output (Ctrl+End to jump)")
  } finally {
    first.dispose()
    second.dispose()
    setup.destroy()
  }
})

async function createPendingTranscriptSession(): Promise<{
  readonly session: AgentSession
  readonly providerStarted: ReturnType<typeof deferred<void>>
  readonly releaseProvider: ReturnType<typeof deferred<void>>
}> {
  const models = createModels()
  const faux = fauxProvider()
  const providerStarted = deferred<void>()
  const releaseProvider = deferred<void>()
  models.setProvider(faux.provider)
  faux.setResponses([
    async () => {
      providerStarted.resolve()
      await releaseProvider.promise
      return fauxAssistantMessage(fauxThinking("streamed thought"))
    }
  ])
  const bootstrap = await createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })
  const model = bootstrap.session.model
  bootstrap.session.dispose()

  const sessionManager = SessionManager.inMemory("/work")
  for (const message of transcriptMessages()) sessionManager.appendMessage(message)
  const session = (await createAgentSession({ services: bootstrap.services, sessionManager, model, tools: [] })).session
  return { session, providerStarted, releaseProvider }
}

async function createTranscriptSession(responseCount: number): Promise<AgentSession> {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  faux.setResponses(
    Array.from({ length: responseCount }, (_, index) =>
      fauxAssistantMessage(fauxThinking(`streamed thought ${index + 1}`))
    )
  )
  const bootstrap = await createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })
  const model = bootstrap.session.model
  bootstrap.session.dispose()

  const sessionManager = SessionManager.inMemory("/work")
  for (const message of transcriptMessages()) sessionManager.appendMessage(message)
  return (await createAgentSession({ services: bootstrap.services, sessionManager, model, tools: [] })).session
}

function transcriptMessages(): AgentMessage[] {
  return Array.from({ length: 8 }, (_, index) => ({
    role: "user" as const,
    content: [{ type: "text" as const, text: `history row ${index + 1}` }],
    timestamp: index + 1
  }))
}

async function pressRaw(setup: InteractiveTestSetup, sequence: string): Promise<void> {
  setup.renderer.stdin.emit("data", Buffer.from(sequence))
  await Promise.resolve()
  await renderSettled(setup)
}

async function pressModifiedArrow(setup: InteractiveTestSetup, direction: "up" | "down"): Promise<void> {
  setup.mockInput.pressArrow(direction, { ctrl: true, meta: true })
  await Promise.resolve()
  await renderSettled(setup)
}

async function pressKey(setup: InteractiveTestSetup, key: "END", modifiers: { ctrl: boolean }): Promise<void> {
  setup.mockInput.pressKey(key, modifiers)
  await Promise.resolve()
  await renderSettled(setup)
}

async function promptAndRender(session: AgentSession, setup: InteractiveTestSetup, text: string): Promise<void> {
  await session.prompt(text)
  await renderSettled(setup)
}

function transcriptScroll(renderer: InteractiveTestSetup["renderer"]): ScrollBoxRenderable {
  const scroll = renderer.root.findDescendantById("transcript-scroll")
  if (!(scroll instanceof ScrollBoxRenderable)) throw new Error("Transcript scrollbox not found")
  return scroll
}

function promptInput(renderer: InteractiveTestSetup["renderer"]): TextareaRenderable {
  const input = renderer.root.findDescendantById("prompt-input")
  if (!(input instanceof TextareaRenderable)) throw new Error("Prompt textarea not found")
  return input
}

function transcriptStatus(renderer: InteractiveTestSetup["renderer"]): BoxRenderable {
  const status = renderer.root.findDescendantById("transcript-status")
  if (!(status instanceof BoxRenderable)) throw new Error("Transcript status not found")
  return status
}

function maximumScroll(scroll: ScrollBoxRenderable): number {
  return Math.max(0, scroll.scrollHeight - scroll.viewport.height)
}

function occurrences(text: string, needle: string): number {
  return text.split(needle).length - 1
}

function deferred<T>() {
  let resolve!: (value: T | PromiseLike<T>) => void
  const promise = new Promise<T>(resolvePromise => {
    resolve = resolvePromise
  })
  return { promise, resolve }
}
