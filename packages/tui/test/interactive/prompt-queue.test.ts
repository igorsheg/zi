import { expect, test } from "bun:test"

import { TextareaRenderable } from "@opentui/core"
import {
  createModels,
  createTestAgentRuntime as createAgentRuntime,
  fauxAssistantMessage,
  fauxProvider,
  fauxThinking
} from "@with-zi/coding-agent/testing"

import type { ClipboardWriter, ClipboardWriteResult } from "../../src/interactive/clipboard.js"
import { createInteractiveTest } from "./harness.js"

test("real prompt keys admit, present, and restore steering and follow-up queues", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  const providerStarted = deferred<void>()
  const release = deferred<void>()
  faux.setResponses([
    async () => {
      providerStarted.resolve()
      await release.promise
      return fauxAssistantMessage("done")
    }
  ])
  const { session } = await createAgentRuntime({ cwd: "/work", models, persist: false })
  const setup = await createInteractiveTest(session, { width: 48, height: 14, kittyKeyboard: true })

  try {
    await setup.renderOnce()
    const input = setup.renderer.root.findDescendantById("prompt-input")
    if (!(input instanceof TextareaRenderable)) throw new Error("Prompt textarea not found")

    input.setText("start")
    setup.mockInput.pressKey("RETURN", { meta: true })
    await providerStarted.promise
    expect(session.isStreaming).toBe(true)

    input.setText("line")
    setup.mockInput.pressEnter({ shift: true })
    expect(input.plainText).toContain("line")
    expect(input.plainText).toContain("\n")
    expect(session.queuedInputs.steering).toHaveLength(0)

    input.setText("blocked super")
    setup.mockInput.pressEnter({ super: true })
    setup.mockInput.pressEnter({ meta: true, super: true })
    setup.mockInput.pressEnter({ hyper: true })
    expect(input.plainText).toBe("blocked super")
    expect(session.queuedInputs.steering).toHaveLength(0)
    expect(session.queuedInputs.followUp).toHaveLength(0)

    input.setText("steering first line\nsecond line")
    setup.mockInput.pressEnter()
    input.setText("follow-up")
    setup.mockInput.pressKey("RETURN", { meta: true })
    await setup.renderOnce()

    expect(session.queuedInputs.steering.map(entry => entry.text)).toEqual(["steering first line\nsecond line"])
    expect(session.queuedInputs.followUp.map(entry => entry.text)).toEqual(["follow-up"])
    expect(session.latestPromptHistoryEntry()?.text).toBe("start")
    const queuedFrame = setup.captureCharFrame()
    expect(queuedFrame).toContain("Steering: steering first line")
    expect(queuedFrame).not.toContain("second line")
    expect(queuedFrame).toContain("Follow-up: follow-up")
    expect(queuedFrame).toContain("↳ Alt+Up to edit all queued messages")

    input.setText("draft")
    input.gotoBufferEnd()
    setup.mockInput.pressArrow("up")
    setup.mockInput.pressArrow("up", { meta: true, shift: true })
    expect(input.plainText).toBe("draft")
    expect(session.queuedInputs.steering).toHaveLength(1)
    expect(session.queuedInputs.followUp).toHaveLength(1)

    setup.mockInput.pressArrow("up", { meta: true })
    await setup.renderOnce()
    expect(input.plainText).toBe("steering first line\nsecond line\n\nfollow-up\n\ndraft")
    expect(session.queuedInputs.steering).toHaveLength(0)
    expect(setup.captureCharFrame()).toContain("Restored 2 queued messages to editor")

    setup.mockInput.pressArrow("up", { meta: true })
    await setup.renderOnce()
    expect(input.plainText).toBe("steering first line\nsecond line\n\nfollow-up\n\ndraft")
    expect(setup.captureCharFrame()).toContain("No queued messages to restore")

    release.resolve()
    await session.waitForIdle()
  } finally {
    session.dispose()
    setup.destroy()
  }
})

test("a maximum queue preserves the constrained composer and Ctrl+C leaves pending rows intact", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  const providerStarted = deferred<void>()
  const release = deferred<void>()
  faux.setResponses([
    async () => {
      providerStarted.resolve()
      await release.promise
      return fauxAssistantMessage("done")
    }
  ])
  const { session } = await createAgentRuntime({ cwd: "/work", models, persist: false })
  const setup = await createInteractiveTest(session, { width: 42, height: 8, kittyKeyboard: true })

  try {
    await setup.renderOnce()
    const input = setup.renderer.root.findDescendantById("prompt-input")
    if (!(input instanceof TextareaRenderable)) throw new Error("Prompt textarea not found")
    input.setText("start")
    setup.mockInput.pressEnter()
    await providerStarted.promise
    for (let index = 0; index < 32; index++) session.steer(`queued-${index}`)
    input.setText("keep this exact draft")
    setup.mockInput.pressEnter()
    await setup.renderOnce()

    expect(input.plainText).toBe("keep this exact draft")
    expect(session.queuedInputs.steering).toHaveLength(32)
    const overflowFrame = setup.captureCharFrame()
    expect(overflowFrame).toContain("Queue capacity exceeded")
    expect(overflowFrame).toContain("… 32 more queued")
    expect(overflowFrame).toContain("keep this exact draft")
    expect(setup.renderer.currentFocusedRenderable).toBe(input)
    expect(
      session.messages.some(message => message.role === "user" && messageText(message) === "keep this exact draft")
    ).toBe(false)

    setup.mockInput.pressCtrlC()
    expect(input.plainText).toBe("")
    expect(session.queuedInputs.steering).toHaveLength(32)
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("Steering: queued-0")

    session.takeQueuedInputs()
    release.resolve()
    await session.waitForIdle()
  } finally {
    session.dispose()
    setup.destroy()
  }
})

test("Escape restores grouped duplicates immediately and queue rows truncate as dim single lines", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  const providerStarted = deferred<void>()
  const release = deferred<void>()
  faux.setResponses([
    async () => {
      providerStarted.resolve()
      await release.promise
      return fauxAssistantMessage("aborted", { stopReason: "aborted" })
    }
  ])
  const { session } = await createAgentRuntime({ cwd: "/work", models, persist: false })
  const setup = await createInteractiveTest(session, { width: 30, height: 14, kittyKeyboard: true })

  try {
    await setup.renderOnce()
    const input = setup.renderer.root.findDescendantById("prompt-input")
    if (!(input instanceof TextareaRenderable)) throw new Error("Prompt textarea not found")
    input.setText("start")
    setup.mockInput.pressEnter()
    await providerStarted.promise
    session.followUp("duplicate")
    session.steer("界界界界界界界界界界界界\nhidden")
    session.steer("duplicate")
    input.setText("existing draft")
    await setup.renderOnce()

    const queuedFrame = setup.captureCharFrame()
    expect(queuedFrame).toContain("Steering: 界界界界界界界...")
    expect(queuedFrame).not.toContain("hidden")
    const queueSpans = setup.captureSpans().lines.flatMap(line => line.spans)
    expect(queueSpans.find(span => span.text.includes("Steering:"))?.fg.toInts()).toEqual([106, 110, 108, 255])

    setup.mockInput.pressEscape()
    expect(input.plainText).toBe("界界界界界界界界界界界界\nhidden\n\nduplicate\n\nduplicate\n\nexisting draft")
    expect(session.queuedInputs.steering).toHaveLength(0)
    expect(session.isAborting).toBe(true)
    const restored = input.plainText
    setup.mockInput.pressEscape()
    expect(input.plainText).toBe(restored)

    release.resolve()
    await session.waitForIdle()
    expect(session.isStreaming).toBe(false)
  } finally {
    session.dispose()
    setup.destroy()
  }
})

test("restored queued images remain attached when the draft is resubmitted", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  const providerStarted = deferred<void>()
  const release = deferred<void>()
  faux.setResponses([
    async () => {
      providerStarted.resolve()
      await release.promise
      return fauxAssistantMessage("done")
    }
  ])
  const { session } = await createAgentRuntime({ cwd: "/work", models, persist: false })
  const setup = await createInteractiveTest(session, { width: 48, height: 14, kittyKeyboard: true })
  const image = { type: "image" as const, mimeType: "image/png", data: "AAAA" }

  try {
    await setup.renderOnce()
    const input = setup.renderer.root.findDescendantById("prompt-input")
    if (!(input instanceof TextareaRenderable)) throw new Error("Prompt textarea not found")
    input.setText("start")
    setup.mockInput.pressEnter()
    await providerStarted.promise
    session.followUp("with image", [image])
    setup.mockInput.pressArrow("up", { meta: true })
    await setup.renderOnce()

    expect(input.plainText).toBe("with image [image #1] ")
    expect(setup.captureCharFrame()).toContain("Restored 1 queued message")
    setup.mockInput.pressEnter({ meta: true })

    expect(session.queuedInputs.followUp[0]?.text).toBe("with image")
    expect(session.queuedInputs.followUp[0]?.images).toEqual([image])
    session.takeQueuedInputs()
    release.resolve()
    await session.waitForIdle()
  } finally {
    session.dispose()
    setup.destroy()
  }
})

test("explicit selection copy precedes prompt clearing and supports a delivered Cmd+C", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  faux.setResponses([fauxAssistantMessage(fauxThinking("assistant response"))])
  const { session } = await createAgentRuntime({ cwd: "/work", models, persist: false })
  await session.prompt("copy target")
  let delivery: ClipboardWriteResult = { type: "unavailable" }
  const writes: string[] = []
  const writer: ClipboardWriter = {
    write: async text => {
      writes.push(text)
      return delivery
    }
  }
  const setup = await createInteractiveTest(
    session,
    { width: 48, height: 16, kittyKeyboard: true },
    () => {},
    { "app.selection.copy": ["super+c", "ctrl+c"] },
    undefined,
    undefined,
    undefined,
    writer
  )

  try {
    await setup.renderOnce()
    const input = setup.renderer.root.findDescendantById("prompt-input")
    if (!(input instanceof TextareaRenderable)) throw new Error("Prompt textarea not found")
    const row = setup
      .captureCharFrame()
      .split("\n")
      .findIndex(line => line.includes("copy target"))
    expect(row).toBeGreaterThanOrEqual(0)

    await setup.mockMouse.drag(1, row, 12, row)
    const selected = setup.renderer.getSelection()?.getSelectedText()
    if (!selected) throw new Error("Transcript selection not found")
    expect(selected).toBe("copy target")
    expect(writes).toEqual([])

    const failedSelection = setup.renderer.getSelection()
    input.setText("preserve on unsupported copy")
    setup.mockInput.pressCtrlC()
    await Promise.resolve()

    expect(writes).toEqual([selected])
    expect(input.plainText).toBe("preserve on unsupported copy")
    expect(setup.renderer.getSelection()).toBe(failedSelection)
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("Copy failed; the selection was preserved")

    delivery = { type: "copied", route: "native" }
    input.setText("keep this exact draft")
    setup.mockInput.pressKey("c", { super: true })
    await Promise.resolve()

    expect(writes).toEqual([selected, selected])
    expect(input.plainText).toBe("keep this exact draft")
    expect(setup.renderer.getSelection()).toBeNull()
    await setup.renderOnce()
    expect(setup.captureCharFrame()).not.toContain("Copy failed")
  } finally {
    session.dispose()
    setup.destroy()
  }
})

function messageText(message: { role: string; content?: unknown }): string {
  if (message.role !== "user") return ""
  if (typeof message.content === "string") return message.content
  if (!Array.isArray(message.content)) return ""
  return message.content
    .flatMap(part => {
      if (typeof part !== "object" || part === null) return []
      if (!("type" in part) || part.type !== "text" || !("text" in part) || typeof part.text !== "string") return []
      return part.text
    })
    .join("\n")
}

function deferred<T>() {
  let resolve!: (value: T | PromiseLike<T>) => void
  const promise = new Promise<T>(resolvePromise => {
    resolve = resolvePromise
  })
  return { promise, resolve }
}
