import { expect, test } from "bun:test"

import { TextareaRenderable } from "@opentui/core"
import { createModels, createTestAgentRuntime as createAgentRuntime, fauxProvider } from "@with-zi/coding-agent/testing"

import type { ClipboardReader } from "../../src/interactive/clipboard.js"
import { createInteractiveTest, renderSettled } from "./harness.js"

const browser = { open: async () => {}, dispose() {} }

test("default Up and Down recall the full compacted session journal and restore the draft", async () => {
  const { session } = await createSession("history-default")
  const old = session.sessionManager.appendMessage({ role: "user", content: "old prompt", timestamp: 1 })
  const kept = session.sessionManager.appendMessage({ role: "user", content: "kept prompt", timestamp: 2 })
  session.sessionManager.appendCompaction({
    reason: "manual",
    summary: "summary",
    firstKeptEntryId: kept.id,
    tokensBefore: 100,
    estimatedTokensAfter: 10,
    details: { readFiles: [], modifiedFiles: [], omittedReadFiles: 0, omittedModifiedFiles: 0 }
  })
  expect(session.sessionManager.activeEntries().some(entry => entry.id === old.id)).toBe(false)
  const setup = await createInteractiveTest(session, { width: 48, height: 12, kittyKeyboard: true })

  try {
    await setup.renderOnce()
    const input = promptInput(setup)
    input.setText("draft")
    input.cursorOffset = 0

    setup.mockInput.pressArrow("up")
    expect(input.plainText).toBe("kept prompt")
    expect(input.cursorOffset).toBe(0)
    setup.mockInput.pressArrow("up")
    expect(input.plainText).toBe("old prompt")
    setup.mockInput.pressArrow("up")
    expect(input.plainText).toBe("old prompt")

    input.gotoBufferEnd()
    setup.mockInput.pressArrow("down")
    expect(input.plainText).toBe("kept prompt")
    expect(input.cursorOffset).toBe("kept prompt".length)
    setup.mockInput.pressArrow("down")
    expect(input.plainText).toBe("draft")
    expect(input.cursorOffset).toBe(0)
  } finally {
    session.dispose()
    setup.destroy()
  }
})

test("default Up and Down fall through to native multiline movement", async () => {
  const { session } = await createSession("history-native-movement")
  session.sessionManager.appendMessage({ role: "user", content: "remembered", timestamp: 1 })
  const setup = await createInteractiveTest(session, { width: 48, height: 12, kittyKeyboard: true })

  try {
    await setup.renderOnce()
    const input = promptInput(setup)
    const handleKeyPress = input.handleKeyPress.bind(input)
    const nativeVerticalKeys: string[] = []
    input.handleKeyPress = key => {
      if (key.name === "up" || key.name === "down") nativeVerticalKeys.push(key.name)
      return handleKeyPress(key)
    }
    input.setText("abcdef\nx\nabcdef")
    input.cursorOffset = 5

    setup.mockInput.pressArrow("down")
    expect(input.cursorOffset).toBe(8)
    setup.mockInput.pressArrow("down")
    expect(input.cursorOffset).toBe(14)
    setup.mockInput.pressArrow("up")
    expect(input.cursorOffset).toBe(8)
    setup.mockInput.pressArrow("up")
    expect(input.cursorOffset).toBe(5)
    expect(nativeVerticalKeys).toEqual(["down", "down", "up", "up"])
    expect(input.plainText).toBe("abcdef\nx\nabcdef")

    const verticalKeyCount = nativeVerticalKeys.length
    input.setSelection(0, 5)
    setup.mockInput.pressArrow("down")
    expect(nativeVerticalKeys).toHaveLength(verticalKeyCount + 1)
    expect(nativeVerticalKeys.at(-1)).toBe("down")
    expect(input.plainText).toBe("abcdef\nx\nabcdef")

    input.setText("x".repeat(100))
    input.gotoBufferEnd()
    const wrappedRow = input.scrollY + input.visualCursor.visualRow
    expect(wrappedRow).toBeGreaterThan(0)
    setup.mockInput.pressArrow("up")
    expect(input.scrollY + input.visualCursor.visualRow).toBe(wrappedRow - 1)
    setup.mockInput.pressArrow("down")
    expect(input.scrollY + input.visualCursor.visualRow).toBe(wrappedRow)
    expect(nativeVerticalKeys.slice(-2)).toEqual(["up", "down"])
  } finally {
    session.dispose()
    setup.destroy()
  }
})

test("effective history overrides intercept only at history boundaries", async () => {
  const { session } = await createSession("history-overrides")
  session.sessionManager.appendMessage({ role: "user", content: "remembered", timestamp: 1 })
  const setup = await createInteractiveTest(session, { width: 48, height: 12, kittyKeyboard: true }, () => {}, {
    "tui.input.historyPrevious": ["ctrl+p"],
    "tui.input.historyNext": ["ctrl+n"]
  })

  try {
    await setup.renderOnce()
    const input = promptInput(setup)
    const handleKeyPress = input.handleKeyPress.bind(input)
    const nativeKeys: string[] = []
    input.handleKeyPress = key => {
      nativeKeys.push(`${key.ctrl ? "ctrl+" : ""}${key.name}`)
      return handleKeyPress(key)
    }
    const draft = "abcdef\nx\nabcdef"
    input.setText(draft)
    input.cursorOffset = 14

    setup.mockInput.pressKey("p", { ctrl: true })
    expect(input.cursorOffset).toBe(14)
    setup.mockInput.pressArrow("up")
    expect(input.cursorOffset).toBe(8)
    setup.mockInput.pressArrow("up")
    expect(input.cursorOffset).toBe(5)
    expect(nativeKeys).toEqual(["ctrl+p", "up", "up"])

    input.cursorOffset = 5
    setup.mockInput.pressKey("p", { ctrl: true })
    expect(input.cursorOffset).toBe(0)
    expect(nativeKeys).toEqual(["ctrl+p", "up", "up"])

    setup.mockInput.pressKey("p", { ctrl: true })
    expect(input.plainText).toBe("remembered")
    setup.mockInput.pressKey("p", { ctrl: true })
    expect(input.plainText).toBe("remembered")
    expect(nativeKeys).toEqual(["ctrl+p", "up", "up"])

    input.gotoBufferEnd()
    setup.mockInput.pressKey("n", { ctrl: true })
    expect(input.plainText).toBe(draft)
    expect(nativeKeys).toEqual(["ctrl+p", "up", "up"])

    input.setText("draft")
    input.cursorOffset = 0
    setup.mockInput.pressKey("n", { ctrl: true })
    expect(input.cursorOffset).toBe(5)
    setup.mockInput.pressKey("n", { ctrl: true })
    expect(input.cursorOffset).toBe(5)
    expect(nativeKeys).toEqual(["ctrl+p", "up", "up"])
  } finally {
    session.dispose()
    setup.destroy()
  }
})

test("picker navigation wins over history and session replacement installs a fresh catalog", async () => {
  const firstRuntime = await createSession("history-first")
  const secondRuntime = await createSession("history-second")
  const first = firstRuntime.session
  const second = secondRuntime.session
  first.sessionManager.appendMessage({ role: "user", content: "first session", timestamp: 1 })
  second.sessionManager.appendMessage({ role: "user", content: "second session", timestamp: 1 })
  const setup = await createInteractiveTest(first, { width: 52, height: 14, kittyKeyboard: true })

  try {
    const input = promptInput(setup)
    await setup.mockInput.typeText("/m", 0)
    await renderSettled(setup)
    expect(setup.captureCharFrame()).toContain("/model  <provider/model>")

    const cursor = input.cursorOffset
    setup.mockInput.pressArrow("up")
    expect(input.plainText).toBe("/m")
    expect(input.cursorOffset).toBe(cursor)

    setup.mockInput.pressEscape()
    input.setText("")
    setup.mockInput.pressArrow("up")
    expect(input.plainText).toBe("first session")

    setup.mode.replaceSession(second)
    expect(input.isDestroyed).toBe(true)
    const replacement = promptInput(setup)
    expect(replacement).not.toBe(input)
    setup.mockInput.pressArrow("up")
    expect(replacement.plainText).toBe("second session")
    expect(setup.renderer.currentFocusedRenderable).toBe(replacement)
  } finally {
    first.dispose()
    second.dispose()
    setup.destroy()
  }
})

test("history clears recalled attachment state and restores the draft image marker", async () => {
  const { session } = await createSession("history-images")
  session.sessionManager.appendMessage({ role: "user", content: "historical", timestamp: 1 })
  const bytes = Uint8Array.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
  const clipboard: ClipboardReader = { read: async () => ({ type: "image", bytes, mimeType: "image/png" }) }
  const setup = await createInteractiveTest(
    session,
    { width: 52, height: 12, kittyKeyboard: true },
    () => {},
    undefined,
    browser,
    undefined,
    clipboard
  )

  try {
    await setup.renderOnce()
    const input = promptInput(setup)
    setup.mockInput.pressKey("v", process.platform === "win32" ? { meta: true } : { ctrl: true })
    await Bun.sleep(0)
    await setup.renderOnce()
    expect(input.plainText).toBe("[image #1] ")
    expect(setup.captureCharFrame()).toContain("1 image")

    input.cursorOffset = 0
    setup.mockInput.pressArrow("up")
    await renderSettled(setup)
    expect(input.plainText).toBe("historical")
    expect(setup.captureCharFrame()).not.toContain("1 image")

    input.gotoBufferEnd()
    setup.mockInput.pressArrow("down")
    await renderSettled(setup)
    expect(input.plainText).toBe("[image #1] ")
    expect(setup.captureCharFrame()).toContain("1 image")
    expect(input.focused).toBe(true)
  } finally {
    session.dispose()
    setup.destroy()
  }
})

function promptInput(setup: Awaited<ReturnType<typeof createInteractiveTest>>): TextareaRenderable {
  const input = setup.renderer.root.findDescendantById("prompt-input")
  if (!(input instanceof TextareaRenderable)) throw new Error("Prompt textarea not found")
  return input
}

async function createSession(provider: string) {
  const models = createModels()
  const faux = fauxProvider({ provider })
  models.setProvider(faux.provider)
  return createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })
}
