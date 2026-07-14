import { expect, test } from "bun:test"

import { BoxRenderable, ScrollBoxRenderable, TextareaRenderable } from "@opentui/core"
import { testRender } from "@opentui/react/test-utils"
import {
  createAgentRuntime,
  createAgentSession,
  type AgentMessage,
  type AgentSession,
  SessionManager
} from "@openzi/coding-agent"
import {
  createModels,
  fauxAssistantMessage,
  fauxProvider,
  fauxThinking,
  fauxToolCall
} from "@openzi/coding-agent/testing"
import { act, useState } from "react"

import { App } from "../src/app.js"

/* oxlint-disable no-await-in-loop */

test("manual page and line navigation detaches, coalesces unseen output, and returns to follow", async () => {
  const session = await createTranscriptSession(4)
  const setup = await testRender(<App session={session} onExit={() => {}} />, {
    width: 48,
    height: 12,
    kittyKeyboard: true
  })

  try {
    await renderSettled(setup)
    const scroll = transcriptScroll(setup.renderer)
    const input = promptInput(setup.renderer)
    const initialMaximum = maximumScroll(scroll)
    expect(initialMaximum).toBeGreaterThan(0)
    expect(scroll.scrollTop).toBe(initialMaximum)
    expect(scroll.stickyScroll).toBe(true)
    expect(setup.renderer.currentFocusedRenderable).toBe(input)

    const pageStart = scroll.scrollTop
    await pressRaw(setup, "\x1b[5~")
    expect(scroll.scrollTop).toBe(Math.max(0, Math.round(pageStart - scroll.viewport.height / 2)))
    expect(scroll.stickyScroll).toBe(false)
    expect(setup.renderer.currentFocusedRenderable).toBe(input)

    await pressModifiedArrow(setup, "up")
    expect(scroll.scrollTop).toBe(Math.max(0, Math.round(pageStart - scroll.viewport.height / 2) - 1))

    const detachedTop = scroll.scrollTop
    const detachedViewportHeight = scroll.viewport.height
    act(() => session.setThinkingLevel("low"))
    await renderSettled(setup)
    expect(scroll.scrollTop).toBe(detachedTop)
    expect(setup.captureCharFrame()).not.toContain("New output · Ctrl+End to jump")

    await promptAndRender(session, setup, "first update")
    expect(scroll.scrollTop).toBe(detachedTop)
    expect(scroll.viewport.height).toBe(detachedViewportHeight)
    expect(scroll.stickyScroll).toBe(false)
    expect(occurrences(setup.captureCharFrame(), "New output · Ctrl+End to jump")).toBe(1)

    await promptAndRender(session, setup, "second update")
    expect(scroll.scrollTop).toBe(detachedTop)
    expect(occurrences(setup.captureCharFrame(), "New output · Ctrl+End to jump")).toBe(1)

    const pageDownStart = scroll.scrollTop
    const pageDownMaximum = maximumScroll(scroll)
    await pressRaw(setup, "\x1b[6~")
    expect(scroll.scrollTop).toBe(Math.min(pageDownMaximum, Math.round(pageDownStart + scroll.viewport.height / 2)))
    for (let index = 0; index < 20 && scroll.scrollTop < maximumScroll(scroll); index++) {
      await pressRaw(setup, "\x1b[6~")
    }
    expect(scroll.scrollTop).toBe(maximumScroll(scroll))
    expect(scroll.stickyScroll).toBe(true)
    expect(setup.captureCharFrame()).not.toContain("New output · Ctrl+End to jump")

    await promptAndRender(session, setup, "following update")
    expect(scroll.scrollTop).toBe(maximumScroll(scroll))
    expect(scroll.stickyScroll).toBe(true)
  } finally {
    session.dispose()
    act(() => setup.renderer.destroy())
  }
})

test("one line above the tail stays detached when output commits", async () => {
  const session = await createTranscriptSession(1)
  const setup = await testRender(<App session={session} onExit={() => {}} />, {
    width: 48,
    height: 12,
    kittyKeyboard: true
  })

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
    expect(setup.captureCharFrame()).toContain("New output · Ctrl+End to jump")
  } finally {
    session.dispose()
    act(() => setup.renderer.destroy())
  }
})

test("unseen status yields to a one-row transcript viewport", async () => {
  const session = await createTranscriptSession(1)
  const setup = await testRender(<App session={session} onExit={() => {}} />, {
    width: 20,
    height: 4,
    kittyKeyboard: true
  })

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
    expect(setup.captureCharFrame()).not.toContain("New output · Ctrl+End to jump")

    act(() => setup.resize(48, 12))
    await renderSettled(setup)
    expect(scroll.stickyScroll).toBe(false)
    expect(setup.captureCharFrame()).toContain("New output · Ctrl+End to jump")
  } finally {
    session.dispose()
    act(() => setup.renderer.destroy())
  }
})

test("Ctrl+End jumps to the tail and a later manual operation cancels a queued jump", async () => {
  const session = await createTranscriptSession(2)
  const setup = await testRender(<App session={session} onExit={() => {}} />, {
    width: 48,
    height: 12,
    kittyKeyboard: true
  })

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
    expect(setup.captureCharFrame()).toContain("New output · Ctrl+End to jump")
    await pressKey(setup, "END", { ctrl: true })
    expect(scroll.scrollTop).toBe(maximumScroll(scroll))
    expect(scroll.stickyScroll).toBe(true)
    expect(setup.captureCharFrame()).not.toContain("New output · Ctrl+End to jump")

    await pressRaw(setup, "\x1b[5~")
    const detachedTop = scroll.scrollTop
    await act(async () => {
      setup.mockInput.pressKey("END", { ctrl: true })
      setup.mockInput.pressArrow("up", { ctrl: true, meta: true })
      await Promise.resolve()
    })
    await renderSettled(setup)

    expect(scroll.scrollTop).toBe(detachedTop - 1)
    expect(scroll.scrollTop).toBeLessThan(maximumScroll(scroll))
    expect(scroll.stickyScroll).toBe(false)
  } finally {
    session.dispose()
    act(() => setup.renderer.destroy())
  }
})

test("native wheel and resize mechanics preserve detached intent until all content fits", async () => {
  const session = await createTranscriptSession(2)
  const setup = await testRender(<App session={session} onExit={() => {}} />, {
    width: 48,
    height: 12,
    kittyKeyboard: true
  })

  try {
    await renderSettled(setup)
    const scroll = transcriptScroll(setup.renderer)

    act(() => setup.resize(48, 9))
    await renderSettled(setup)
    expect(scroll.scrollTop).toBe(maximumScroll(scroll))
    act(() => setup.resize(48, 14))
    await renderSettled(setup)
    expect(scroll.scrollTop).toBe(maximumScroll(scroll))
    const initialTail = scroll.scrollTop

    for (let index = 0; index < 3 && scroll.stickyScroll; index++) {
      await act(async () => {
        await setup.mockMouse.scroll(2, 2, "up")
        await Promise.resolve()
      })
      await renderSettled(setup)
    }
    expect(scroll.scrollTop).toBeLessThan(initialTail)
    expect(scroll.stickyScroll).toBe(false)

    for (let index = 0; index < 20 && !scroll.stickyScroll; index++) {
      await act(async () => {
        await setup.mockMouse.scroll(2, 2, "down")
        await Promise.resolve()
      })
      await renderSettled(setup)
    }
    expect(scroll.scrollTop).toBe(maximumScroll(scroll))
    expect(scroll.stickyScroll).toBe(true)

    for (let index = 0; index < 3 && scroll.stickyScroll; index++) {
      await act(async () => {
        await setup.mockMouse.scroll(2, 2, "up")
        await Promise.resolve()
      })
      await renderSettled(setup)
    }
    expect(scroll.stickyScroll).toBe(false)

    await promptAndRender(session, setup, "unseen through resize")
    expect(setup.captureCharFrame()).toContain("New output · Ctrl+End to jump")

    const status = transcriptStatus(setup.renderer)
    const beforeHintWheel = scroll.scrollTop
    await act(async () => {
      await setup.mockMouse.scroll(status.x + 1, status.y, "down")
      await Promise.resolve()
    })
    await renderSettled(setup)
    expect(scroll.scrollTop).toBeGreaterThan(beforeHintWheel)
    expect(scroll.stickyScroll).toBe(false)

    act(() => setup.resize(36, 9))
    await renderSettled(setup)
    expect(scroll.stickyScroll).toBe(false)
    expect(setup.captureCharFrame()).toContain("New output · Ctrl+End to jump")

    act(() => setup.resize(52, 14))
    await renderSettled(setup)
    expect(scroll.stickyScroll).toBe(false)
    expect(setup.captureCharFrame()).toContain("New output · Ctrl+End to jump")

    act(() => setup.resize(52, 80))
    await renderSettled(setup)
    expect(scroll.scrollHeight).toBeLessThanOrEqual(scroll.viewport.height)
    expect(scroll.stickyScroll).toBe(true)
    expect(setup.captureCharFrame()).not.toContain("New output · Ctrl+End to jump")

    act(() => setup.resize(48, 10))
    await renderSettled(setup)
    expect(scroll.scrollTop).toBe(maximumScroll(scroll))
    expect(scroll.stickyScroll).toBe(true)
  } finally {
    session.dispose()
    act(() => setup.renderer.destroy())
  }
})

test("native selection mouse-down detaches before its first drag event", async () => {
  const session = await createTranscriptSession(1)
  const setup = await testRender(<App session={session} onExit={() => {}} />, {
    width: 48,
    height: 12,
    kittyKeyboard: true
  })

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

    await act(async () => {
      await setup.mockMouse.pressDown(x, y)
      await Promise.resolve()
    })
    await renderSettled(setup)

    expect(setup.renderer.getSelection()?.isDragging).toBe(true)
    expect(scroll.stickyScroll).toBe(false)
    const detachedTop = scroll.scrollTop

    await promptAndRender(session, setup, "output before selection drag")
    expect(scroll.scrollTop).toBe(detachedTop)
    expect(scroll.scrollTop).toBeLessThan(maximumScroll(scroll))
    expect(setup.captureCharFrame()).toContain("New output · Ctrl+End to jump")

    await act(async () => {
      await setup.mockMouse.moveTo(x + "history".length, y)
      await setup.mockMouse.release(x + "history".length, y)
      await Promise.resolve()
    })
    await renderSettled(setup)

    const selection = setup.renderer.getSelection()
    expect(selection?.isDragging).toBe(false)
    expect(selection?.getSelectedText()).toBe("history")
    expect(setup.renderer.currentFocusedRenderable).toBe(input)
  } finally {
    session.dispose()
    act(() => setup.renderer.destroy())
  }
})

test("native selection edge-scrolls in visual order and detaches before streamed output", async () => {
  const session = await createTranscriptSession(1)
  const setup = await testRender(<App session={session} onExit={() => {}} />, {
    width: 48,
    height: 12,
    kittyKeyboard: true
  })

  try {
    await renderSettled(setup)
    const scroll = transcriptScroll(setup.renderer)
    const input = promptInput(setup.renderer)
    const startY = setup
      .captureCharFrame()
      .split("\n")
      .findIndex(row => row.includes("history row"))
    expect(startY).toBeGreaterThanOrEqual(0)

    await act(async () => {
      await setup.mockMouse.pressDown(1, startY)
      await setup.mockMouse.moveTo(13, startY)
      await Promise.resolve()
    })
    await renderSettled(setup)

    expect(setup.renderer.getSelection()?.isDragging).toBe(true)
    expect(scroll.stickyScroll).toBe(false)
    const detachedTop = scroll.scrollTop

    await promptAndRender(session, setup, "output during selection")
    expect(scroll.scrollTop).toBe(detachedTop)
    expect(scroll.scrollTop).toBeLessThan(maximumScroll(scroll))
    expect(setup.captureCharFrame()).toContain("New output · Ctrl+End to jump")

    await act(async () => {
      await setup.mockMouse.release(13, startY)
      await Promise.resolve()
    })
    await renderSettled(setup)

    const selection = setup.renderer.getSelection()
    expect(selection?.isDragging).toBe(false)
    expect(selection?.getSelectedText()).toBe(
      "history row 2\nhistory row 3\nhistory row 4\nhistory row 5\nhistory row 6"
    )
    expect(setup.renderer.currentFocusedRenderable).toBe(input)
  } finally {
    session.dispose()
    act(() => setup.renderer.destroy())
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
  const { session } = await createAgentRuntime({ cwd: process.cwd(), models, persist: false })
  await session.prompt("seed history")
  const setup = await testRender(<App session={session} onExit={() => {}} />, {
    width: 48,
    height: 12,
    kittyKeyboard: true
  })

  try {
    await renderSettled(setup)
    const scroll = transcriptScroll(setup.renderer)
    let operation!: Promise<void>
    await act(async () => {
      operation = session.prompt("run the tool")
      await providerStarted.promise
    })
    await renderSettled(setup)
    await pressRaw(setup, "\x1b[5~")
    const detachedTop = scroll.scrollTop

    await act(async () => {
      releaseToolCall.resolve()
      await operation
    })
    await renderSettled(setup)

    expect(session.messages.some(message => message.role === "toolResult" && message.toolCallId === "nav-bash")).toBe(
      true
    )
    expect(scroll.scrollTop).toBe(detachedTop)
    expect(scroll.stickyScroll).toBe(false)
    expect(occurrences(setup.captureCharFrame(), "New output · Ctrl+End to jump")).toBe(1)
  } finally {
    session.dispose()
    act(() => setup.renderer.destroy())
  }
})

test("queued native callbacks cannot leak across a session replacement", async () => {
  const first = await createTranscriptSession(1)
  const second = await createTranscriptSession(1)
  let replaceSession!: (session: AgentSession) => void

  function SwitchingApp() {
    const [session, setSession] = useState(first)
    replaceSession = setSession
    return <App session={session} onExit={() => {}} />
  }

  const setup = await testRender(<SwitchingApp />, { width: 48, height: 12, kittyKeyboard: true })

  try {
    await renderSettled(setup)
    const oldScroll = transcriptScroll(setup.renderer)
    await pressRaw(setup, "\x1b[5~")
    expect(oldScroll.stickyScroll).toBe(false)

    await act(async () => {
      oldScroll.onSizeChange?.()
      setup.mockInput.pressKey("END", { ctrl: true })
      const wheel = setup.mockMouse.scroll(2, 2, "up")
      replaceSession(second)
      await wheel
    })
    await renderSettled(setup)

    const newScroll = transcriptScroll(setup.renderer)
    expect(oldScroll.isDestroyed).toBe(true)
    expect(newScroll).not.toBe(oldScroll)
    expect(newScroll.scrollTop).toBe(maximumScroll(newScroll))
    expect(newScroll.stickyScroll).toBe(true)
    expect(setup.captureCharFrame()).not.toContain("New output · Ctrl+End to jump")
  } finally {
    first.dispose()
    second.dispose()
    act(() => setup.renderer.destroy())
  }
})

async function createTranscriptSession(responseCount: number): Promise<AgentSession> {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  faux.setResponses(
    Array.from({ length: responseCount }, (_, index) =>
      fauxAssistantMessage(fauxThinking(`streamed thought ${index + 1}`))
    )
  )
  const bootstrap = await createAgentRuntime({ cwd: "/work", models, persist: false })
  const model = bootstrap.session.model
  bootstrap.session.dispose()

  const sessionManager = new SessionManager({ cwd: "/work", sessionDir: "/unused", persist: false })
  for (const message of transcriptMessages()) sessionManager.appendMessage(message)
  return createAgentSession({ services: bootstrap.services, sessionManager, model, tools: [] })
}

function transcriptMessages(): AgentMessage[] {
  return Array.from({ length: 8 }, (_, index) => ({
    role: "user" as const,
    content: [{ type: "text" as const, text: `history row ${index + 1}` }],
    timestamp: index + 1
  }))
}

type Setup = Awaited<ReturnType<typeof testRender>>

async function renderSettled(setup: Setup): Promise<void> {
  await act(async () => {
    await setup.flush()
  })
  await act(async () => {
    await setup.flush()
  })
}

async function pressRaw(setup: Setup, sequence: string): Promise<void> {
  await act(async () => {
    setup.renderer.stdin.emit("data", Buffer.from(sequence))
    await Promise.resolve()
  })
  await renderSettled(setup)
}

async function pressModifiedArrow(setup: Setup, direction: "up" | "down"): Promise<void> {
  await act(async () => {
    setup.mockInput.pressArrow(direction, { ctrl: true, meta: true })
    await Promise.resolve()
  })
  await renderSettled(setup)
}

async function pressKey(setup: Setup, key: "END", modifiers: { ctrl: boolean }): Promise<void> {
  await act(async () => {
    setup.mockInput.pressKey(key, modifiers)
    await Promise.resolve()
  })
  await renderSettled(setup)
}

async function promptAndRender(session: AgentSession, setup: Setup, text: string): Promise<void> {
  await act(async () => {
    await session.prompt(text)
  })
  await renderSettled(setup)
}

function transcriptScroll(renderer: Setup["renderer"]): ScrollBoxRenderable {
  const scroll = renderer.root.findDescendantById("transcript-scroll")
  if (!(scroll instanceof ScrollBoxRenderable)) throw new Error("Transcript scrollbox not found")
  return scroll
}

function promptInput(renderer: Setup["renderer"]): TextareaRenderable {
  const input = renderer.root.findDescendantById("prompt-input")
  if (!(input instanceof TextareaRenderable)) throw new Error("Prompt textarea not found")
  return input
}

function transcriptStatus(renderer: Setup["renderer"]): BoxRenderable {
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
