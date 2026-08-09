import { expect, test } from "bun:test"

import { BoxRenderable, TextareaRenderable } from "@opentui/core"
import { createTestRenderer } from "@opentui/core/testing"
import type { QueuedInput } from "@with-zi/coding-agent"
import {
  createModels,
  createTestAgentRuntime as createAgentRuntime,
  fauxAssistantMessage,
  fauxProvider,
  fauxThinking
} from "@with-zi/coding-agent/testing"

import type { ClipboardWriter, ClipboardWriteResult } from "../../src/interactive/clipboard.js"
import { InteractiveKeybindings } from "../../src/interactive/interactive-keybindings.js"
import { QueuedInputsView } from "../../src/interactive/prompt/queue-view.js"
import { defaultTheme } from "../../src/theme.js"
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
  const { session } = await createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })
  const setup = await createInteractiveTest(session, { width: 60, height: 24, kittyKeyboard: true })

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
    expect(queuedFrame).toContain("Steering")
    expect(queuedFrame).toContain("steering first line")
    expect(queuedFrame).toContain("second line")
    expect(queuedFrame).toContain("Follow-up")
    expect(queuedFrame).toContain("follow-up")
    expect(queuedFrame).toContain("Alt+Up to edit all queued messages")
    // Pending and committed user messages share geometry while pending delivery
    // remains visually distinct through its transparent surface and dim label.
    const queueSpans = setup.captureSpans().lines.flatMap(line => line.spans)
    expect(queueSpans.find(span => span.text === "Steering")?.fg.toInts()).toEqual([106, 110, 108, 255])
    expect(queueSpans.find(span => span.text === "steering first line")?.fg.toInts()).toEqual([197, 201, 199, 255])
    expect(queueSpans.find(span => span.text === "Follow-up")?.fg.toInts()).toEqual([106, 110, 108, 255])
    expect(queueSpans.find(span => span.text === "follow-up")?.fg.toInts()).toEqual([197, 201, 199, 255])
    const steeringBlock = setup.renderer.root.findDescendantById(`queued-${session.queuedInputs.steering[0]?.id}`)
    if (!(steeringBlock instanceof BoxRenderable)) throw new Error("Steering block not found")
    const steeringSurface = steeringBlock.getChildren()[0]
    if (!(steeringSurface instanceof BoxRenderable)) throw new Error("Steering surface not found")
    expect(steeringSurface.backgroundColor.toInts()[3]).toBe(0)

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

test("queued message blocks never exceed their assigned rows", async () => {
  const setup = await createTestRenderer({ width: 24, height: 12, useThread: false })
  const view = new QueuedInputsView(setup.renderer, new InteractiveKeybindings(), defaultTheme)
  setup.renderer.root.add(view.root)

  try {
    view.update(
      {
        steering: [queuedInput(1, "steer", Array.from({ length: 40 }, (_, index) => `line-${index}`).join("\n"))],
        followUp: []
      },
      6
    )
    await setup.renderOnce()

    expect(view.root.height).toBe(6)
    expect(setup.captureCharFrame()).toContain("line-0")
    expect(setup.captureCharFrame()).toContain("…")

    view.update({ steering: [queuedInput(2, "steer", "界界界界界界界界界界界界")], followUp: [] }, 6)
    await setup.renderOnce()

    expect(view.root.height).toBeLessThanOrEqual(6)
    const cjkRows = setup
      .captureCharFrame()
      .split("\n")
      .filter(row => row.includes("界"))
    expect(cjkRows).toEqual([expect.stringContaining("界界界界界界界界界界"), expect.stringContaining("界界")])
    expect(setup.renderer.root.findDescendantById("queued-1")).toBeUndefined()

    view.update({ steering: [queuedInput(3, "steer", "first"), queuedInput(4, "steer", "later")], followUp: [] }, 6)
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("… 1 more queued")

    view.update(
      {
        steering: [],
        followUp: [queuedInput(5, "followUp", "", [{ type: "image", mimeType: "image/png", data: "AAAA" }])]
      },
      6
    )
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("[image #1]")
  } finally {
    view.destroy()
    if (!setup.renderer.isDestroyed) setup.renderer.destroy()
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
  const { session } = await createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })
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
    // A constrained composer yields the compact summary rather than blocks.
    expect(overflowFrame).toContain("32 queued")
    expect(overflowFrame).toContain("Alt+Up to edit all")
    expect(overflowFrame).toContain("keep this exact draft")
    const footer = setup.renderer.root.findDescendantById("prompt-footer")
    if (!(footer instanceof BoxRenderable)) throw new Error("Prompt footer not found")
    expect(footer.visible).toBe(true)
    expect(setup.renderer.currentFocusedRenderable).toBe(input)
    expect(
      session.messages.some(message => message.role === "user" && messageText(message) === "keep this exact draft")
    ).toBe(false)

    setup.mockInput.pressCtrlC()
    expect(input.plainText).toBe("")
    expect(session.queuedInputs.steering).toHaveLength(32)
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("32 queued")

    session.takeQueuedInputs()
    release.resolve()
    await session.waitForIdle()
  } finally {
    session.dispose()
    setup.destroy()
  }
})

test("a multiline draft and pending block share one terminal row budget", async () => {
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
  const { session } = await createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })
  const setup = await createInteractiveTest(session, { width: 30, height: 14, kittyKeyboard: true })

  try {
    await setup.renderOnce()
    const input = setup.renderer.root.findDescendantById("prompt-input")
    if (!(input instanceof TextareaRenderable)) throw new Error("Prompt textarea not found")
    input.setText("start")
    setup.mockInput.pressEnter()
    await providerStarted.promise

    session.steer("queued first\nqueued second")
    input.setText("draft one\ndraft two\ndraft three\ndraft four")
    await setup.renderOnce()

    const block = setup.renderer.root.findDescendantById(`queued-${session.queuedInputs.steering[0]?.id}`)
    const composer = setup.renderer.root.findDescendantById("prompt-composer")
    if (!(block instanceof BoxRenderable) || !(composer instanceof BoxRenderable)) {
      throw new Error("Prompt layout not found")
    }
    expect(block.screenY + block.height).toBeLessThanOrEqual(composer.screenY)
    expect(composer.height).toBe(6)
    expect(composer.screenY + composer.height).toBeLessThanOrEqual(setup.renderer.height)
    expect(setup.captureCharFrame()).toContain("queued second")
    expect(setup.captureCharFrame()).toContain("draft four")

    const footer = setup.renderer.root.findDescendantById("prompt-footer")
    const oldEntryId = session.queuedInputs.steering[0]?.id
    if (!(footer instanceof BoxRenderable) || oldEntryId === undefined) throw new Error("Prompt footer not found")
    input.setText("")
    await setup.mockInput.typeText("/m", 0)
    await setup.renderOnce()
    expect(setup.captureCharFrame()).not.toContain("queued second")
    expect(footer.visible).toBe(false)

    session.takeQueuedInputs()
    session.steer("replacement queue message")
    const replacementId = session.queuedInputs.steering[0]?.id
    input.setText("")
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("replacement queue message")
    expect(setup.captureCharFrame()).not.toContain("queued second")
    expect(setup.renderer.root.findDescendantById(`queued-${oldEntryId}`)).toBeUndefined()
    expect(setup.renderer.root.findDescendantById(`queued-${replacementId}`)).toBeInstanceOf(BoxRenderable)
    expect(footer.visible).toBe(true)

    session.takeQueuedInputs()
    release.resolve()
    await session.waitForIdle()
  } finally {
    session.dispose()
    setup.destroy()
  }
})

test("Escape restores grouped duplicates after presenting multiline queue bodies", async () => {
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
  const { session } = await createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })
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
    expect(queuedFrame).toContain("Steering")
    expect(queuedFrame).toContain("界界界界界界界界界界界界")
    expect(queuedFrame).toContain("hidden")
    const queueSpans = setup.captureSpans().lines.flatMap(line => line.spans)
    // The pending body carries the user-message primary text; the label stays dim.
    expect(queueSpans.find(span => span.text === "Steering")?.fg.toInts()).toEqual([106, 110, 108, 255])
    expect(queueSpans.find(span => span.text === "hidden")?.fg.toInts()).toEqual([197, 201, 199, 255])

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
  const { session } = await createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })
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
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("with image [image #1]")

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

test("background-shell capacity refusal is passive and preserves the draft", async () => {
  const models = createModels()
  models.setProvider(fauxProvider().provider)
  const { session } = await createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })
  const setup = await createInteractiveTest(session, { width: 80, height: 24 })

  try {
    await setup.renderOnce()
    const input = setup.renderer.root.findDescendantById("prompt-input")
    if (!(input instanceof TextareaRenderable)) throw new Error("Prompt textarea not found")
    input.setText("keep this draft")
    Object.defineProperty(session, "shellTasks", { configurable: true, get: () => [{ type: "foreground" }] })
    setup.mode.store.backgroundForegroundShellTask = () => ({ type: "capacity_exceeded" })

    setup.mockInput.pressKey("g", { ctrl: true })
    await setup.renderOnce()

    expect(setup.captureCharFrame()).toContain("Background task capacity exceeded")
    expect(input.plainText).toBe("keep this draft")
    expect(session.messages).toEqual([])
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
  const { session } = await createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })
  await session.prompt("copy target")
  const messageCount = session.messages.length
  const providerCalls = faux.state.callCount
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
    expect(setup.captureCharFrame()).toContain("Copy failed; the selection was")

    delivery = { type: "copied", route: "native" }
    input.setText("keep this exact draft")
    setup.mockInput.pressKey("c", { super: true })
    await Promise.resolve()

    expect(writes).toEqual([selected, selected])
    expect(input.plainText).toBe("keep this exact draft")
    expect(setup.renderer.getSelection()).toBeNull()
    await setup.renderOnce()
    expect(setup.captureCharFrame()).not.toContain("Copy failed")
    expect(session.messages).toHaveLength(messageCount)
    expect(faux.state.callCount).toBe(providerCalls)
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

function queuedInput(
  id: number,
  delivery: QueuedInput["delivery"],
  text: string,
  images: QueuedInput["images"] = []
): QueuedInput {
  return { id, delivery, text, images, bytes: Buffer.byteLength(text) }
}

function deferred<T>() {
  let resolve!: (value: T | PromiseLike<T>) => void
  const promise = new Promise<T>(resolvePromise => {
    resolve = resolvePromise
  })
  return { promise, resolve }
}
