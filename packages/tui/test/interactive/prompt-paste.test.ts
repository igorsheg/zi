import { expect, test } from "bun:test"

import { TextareaRenderable } from "@opentui/core"
import {
  createModels,
  createTestAgentRuntime as createAgentRuntime,
  fauxAssistantMessage,
  fauxProvider
} from "@with-zi/coding-agent/testing"

import { maxPastedTextBytes, type ClipboardReader } from "../../src/interactive/clipboard.js"
import { createInteractiveTest } from "./harness.js"

const browser = { open: async () => {}, dispose() {} }

test("bracketed paste normalizes lines, strips ANSI, inserts at the cursor, and remains one undo edit", async () => {
  const { session } = await sessionWithResponses("bracketed-paste")
  const setup = await createInteractiveTest(session, { width: 56, height: 12, kittyKeyboard: true })

  try {
    await setup.renderOnce()
    const input = promptInput(setup)
    input.setText("leftright")
    input.cursorOffset = 4

    await setup.mockInput.pasteBracketedText("one\r\n\x1b[31mtwo\x1b[0m")
    expect(input.plainText).toBe("leftone\ntworight")

    setup.mockInput.pressKey("-", { ctrl: true })
    expect(input.plainText).toBe("leftright")
  } finally {
    session.dispose()
    setup.destroy()
  }
})

test("large bracketed paste uses an atomic marker and submits its exact payload", async () => {
  const { session } = await sessionWithResponses("compact-paste")
  const setup = await createInteractiveTest(session, { width: 56, height: 12, kittyKeyboard: true })
  const pasted = Array.from({ length: 11 }, (_, index) => `line-${index}`).join("\n")

  try {
    await setup.renderOnce()
    const input = promptInput(setup)
    await setup.mockInput.pasteBracketedText(pasted)
    expect(input.plainText).toBe("[paste #1 +11 lines]")

    setup.mockInput.pressEnter()
    await session.waitForIdle()
    expect(userText(session.messages.find(message => message.role === "user")?.content)).toBe(pasted)
  } finally {
    session.dispose()
    setup.destroy()
  }
})

test("oversized bracketed text is rejected without changing the draft", async () => {
  const { session } = await sessionWithResponses("bounded-paste")
  const setup = await createInteractiveTest(session, { width: 56, height: 12, kittyKeyboard: true })

  try {
    await setup.renderOnce()
    const input = promptInput(setup)
    input.setText("keep")
    await setup.mockInput.pasteBracketedText("x".repeat(maxPastedTextBytes + 1))
    await setup.renderOnce()

    expect(input.plainText).toBe("keep")
    expect(setup.captureCharFrame()).toContain("Pasted text exceeds the 1 MiB limit")
  } finally {
    session.dispose()
    setup.destroy()
  }
})

test("semantic and empty bracketed paste read local clipboard text with native normalization", async () => {
  const { session } = await sessionWithResponses("clipboard-text")
  const clipboard: ClipboardReader = { read: async () => ({ type: "text", text: "first\rsecond\x1b[31m!\x1b[0m" }) }
  const setup = await createInteractiveTest(
    session,
    { width: 56, height: 12, kittyKeyboard: true },
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

    expect(input.plainText).toBe("first\nsecond!")

    input.setText("")
    await setup.mockInput.pasteBracketedText("")
    await Bun.sleep(0)
    expect(input.plainText).toBe("first\nsecond!")
  } finally {
    session.dispose()
    setup.destroy()
  }
})

test("clipboard images stay outside textarea state, prevent empty exit, and submit directly", async () => {
  const { session } = await sessionWithResponses("clipboard-image")
  let exited = false
  const bytes = Uint8Array.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
  const clipboard: ClipboardReader = { read: async () => ({ type: "image", bytes, mimeType: "image/png" }) }
  const setup = await createInteractiveTest(
    session,
    { width: 56, height: 12, kittyKeyboard: true },
    () => {
      exited = true
    },
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

    setup.mockInput.pressCtrlC()
    await setup.renderOnce()
    expect(input.plainText).toBe("")
    expect(setup.captureCharFrame()).toContain("Input cleared · Ctrl+Z to undo")
    expect(session.queuedInputs).toEqual({ steering: [], followUp: [] })

    setup.mockInput.pressKey("z", { ctrl: true })
    await Bun.sleep(0)
    await setup.renderOnce()
    expect(input.plainText).toBe("[image #1] ")
    expect(setup.captureCharFrame()).toContain("1 image")
    expect(session.queuedInputs).toEqual({ steering: [], followUp: [] })

    setup.mockInput.pressBackspace()
    setup.mockInput.pressEnter()
    await Bun.sleep(0)
    await setup.renderOnce()
    expect(session.messages.some(message => message.role === "user")).toBe(false)
    expect(setup.captureCharFrame()).toContain("Removed 1 attached image")

    setup.mockInput.pressKey("-", { ctrl: true })
    await Bun.sleep(0)
    await setup.renderOnce()
    expect(input.plainText).toBe("[image #1] ")
    expect(setup.captureCharFrame()).toContain("Restored 1 attached image")

    setup.mockInput.pressKey("d", { ctrl: true })
    expect(exited).toBe(false)

    setup.mockInput.pressEnter()
    await session.waitForIdle()
    const user = session.messages.find(message => message.role === "user")
    expect(user?.content).toEqual([
      { type: "text", text: "" },
      { type: "image", data: Buffer.from(bytes).toString("base64"), mimeType: "image/png" }
    ])
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("[image #1]")
  } finally {
    session.dispose()
    setup.destroy()
  }
})

test("picker updates cannot restore a natively deleted image marker", async () => {
  const { session } = await sessionWithResponses("clipboard-image-picker-race")
  const bytes = Uint8Array.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
  const clipboard: ClipboardReader = { read: async () => ({ type: "image", bytes, mimeType: "image/png" }) }
  const setup = await createInteractiveTest(
    session,
    { width: 56, height: 12, kittyKeyboard: true },
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

    input.cursorOffset = 0
    input.insertText("/")
    input.cursorOffset = input.plainText.length
    setup.mockInput.pressBackspace()
    await Bun.sleep(0)
    await setup.renderOnce()

    expect(input.plainText).toBe("/")
    expect(setup.captureCharFrame()).toContain("Removed 1 attached image")
  } finally {
    session.dispose()
    setup.destroy()
  }
})

function userText(content: unknown): string {
  if (!Array.isArray(content)) return ""
  return content.flatMap(part => (part?.type === "text" && typeof part.text === "string" ? [part.text] : [])).join("")
}

function promptInput(setup: Awaited<ReturnType<typeof createInteractiveTest>>): TextareaRenderable {
  const input = setup.renderer.root.findDescendantById("prompt-input")
  if (!(input instanceof TextareaRenderable)) throw new Error("Prompt textarea not found")
  return input
}

async function sessionWithResponses(provider: string) {
  const models = createModels()
  const faux = fauxProvider({ provider })
  faux.setResponses([fauxAssistantMessage("done")])
  models.setProvider(faux.provider)
  return createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })
}
