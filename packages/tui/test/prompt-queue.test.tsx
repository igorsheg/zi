import { expect, test } from "bun:test"

import { TextareaRenderable } from "@opentui/core"
import { testRender } from "@opentui/react/test-utils"
import { createAgentRuntime } from "@openzi/coding-agent"
import { createModels, fauxAssistantMessage, fauxProvider } from "@openzi/coding-agent/testing"
import { act } from "react"

import { App } from "../src/app.js"

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
  const setup = await testRender(<App session={session} onExit={() => {}} />, {
    width: 48,
    height: 14,
    kittyKeyboard: true
  })

  try {
    await setup.renderOnce()
    const input = setup.renderer.root.findDescendantById("prompt-input")
    if (!(input instanceof TextareaRenderable)) throw new Error("Prompt textarea not found")

    await act(async () => {
      input.setText("start")
      setup.mockInput.pressKey("RETURN", { meta: true })
      await providerStarted.promise
    })
    expect(session.isStreaming).toBe(true)

    act(() => {
      input.setText("line")
      setup.mockInput.pressEnter({ shift: true })
    })
    expect(input.plainText).toContain("line")
    expect(input.plainText).toContain("\n")
    expect(session.queuedInputs.steering).toHaveLength(0)

    act(() => {
      input.setText("blocked super")
      setup.mockInput.pressEnter({ super: true })
      setup.mockInput.pressEnter({ meta: true, super: true })
      setup.mockInput.pressEnter({ hyper: true })
    })
    expect(input.plainText).toBe("blocked super")
    expect(session.queuedInputs.steering).toHaveLength(0)
    expect(session.queuedInputs.followUp).toHaveLength(0)

    act(() => {
      input.setText("steering first line\nsecond line")
      setup.mockInput.pressEnter()
    })
    act(() => {
      input.setText("follow-up")
      setup.mockInput.pressKey("RETURN", { meta: true })
    })
    await setup.renderOnce()

    expect(session.queuedInputs.steering.map(entry => entry.text)).toEqual(["steering first line\nsecond line"])
    expect(session.queuedInputs.followUp.map(entry => entry.text)).toEqual(["follow-up"])
    const queuedFrame = setup.captureCharFrame()
    expect(queuedFrame).toContain("Steering: steering first line")
    expect(queuedFrame).not.toContain("second line")
    expect(queuedFrame).toContain("Follow-up: follow-up")
    expect(queuedFrame).toContain("↳ Alt+Up to edit all queued messages")

    act(() => {
      input.setText("draft")
      setup.mockInput.pressArrow("up")
      setup.mockInput.pressArrow("up", { meta: true, shift: true })
    })
    expect(input.plainText).toBe("draft")
    expect(session.queuedInputs.steering).toHaveLength(1)
    expect(session.queuedInputs.followUp).toHaveLength(1)

    act(() => {
      setup.mockInput.pressArrow("up", { meta: true })
    })
    await setup.renderOnce()
    expect(input.plainText).toBe("steering first line\nsecond line\n\nfollow-up\n\ndraft")
    expect(session.queuedInputs.steering).toHaveLength(0)
    expect(setup.captureCharFrame()).toContain("Restored 2 queued messages to editor")

    act(() => {
      setup.mockInput.pressArrow("up", { meta: true })
    })
    await setup.renderOnce()
    expect(input.plainText).toBe("steering first line\nsecond line\n\nfollow-up\n\ndraft")
    expect(setup.captureCharFrame()).toContain("No queued messages to restore")

    await act(async () => {
      release.resolve()
      await session.waitForIdle()
    })
  } finally {
    session.dispose()
    act(() => setup.renderer.destroy())
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
  const setup = await testRender(<App session={session} onExit={() => {}} />, {
    width: 42,
    height: 8,
    kittyKeyboard: true
  })

  try {
    await setup.renderOnce()
    const input = setup.renderer.root.findDescendantById("prompt-input")
    if (!(input instanceof TextareaRenderable)) throw new Error("Prompt textarea not found")
    await act(async () => {
      input.setText("start")
      setup.mockInput.pressEnter()
      await providerStarted.promise
    })
    act(() => {
      for (let index = 0; index < 32; index++) session.steer(`queued-${index}`)
      input.setText("keep this exact draft")
      setup.mockInput.pressEnter()
    })
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

    act(() => setup.mockInput.pressCtrlC())
    expect(input.plainText).toBe("")
    expect(session.queuedInputs.steering).toHaveLength(32)
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("Steering: queued-0")

    act(() => {
      session.takeQueuedInputs()
    })
    await act(async () => {
      release.resolve()
      await session.waitForIdle()
    })
  } finally {
    session.dispose()
    act(() => setup.renderer.destroy())
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
  const setup = await testRender(<App session={session} onExit={() => {}} />, {
    width: 30,
    height: 14,
    kittyKeyboard: true
  })

  try {
    await setup.renderOnce()
    const input = setup.renderer.root.findDescendantById("prompt-input")
    if (!(input instanceof TextareaRenderable)) throw new Error("Prompt textarea not found")
    await act(async () => {
      input.setText("start")
      setup.mockInput.pressEnter()
      await providerStarted.promise
    })
    act(() => {
      session.followUp("duplicate")
      session.steer("界界界界界界界界界界界界\nhidden")
      session.steer("duplicate")
      input.setText("existing draft")
    })
    await setup.renderOnce()

    const queuedFrame = setup.captureCharFrame()
    expect(queuedFrame).toContain("Steering: 界界界界界界界...")
    expect(queuedFrame).not.toContain("hidden")
    const queueSpans = setup.captureSpans().lines.flatMap(line => line.spans)
    expect(queueSpans.find(span => span.text.includes("Steering:"))?.fg.toInts()).toEqual([106, 110, 108, 255])

    act(() => setup.mockInput.pressEscape())
    expect(input.plainText).toBe("界界界界界界界界界界界界\nhidden\n\nduplicate\n\nduplicate\n\nexisting draft")
    expect(session.queuedInputs.steering).toHaveLength(0)
    expect(session.isAborting).toBe(true)
    const restored = input.plainText
    act(() => setup.mockInput.pressEscape())
    expect(input.plainText).toBe(restored)

    await act(async () => {
      release.resolve()
      await session.waitForIdle()
    })
    expect(session.isStreaming).toBe(false)
  } finally {
    session.dispose()
    act(() => setup.renderer.destroy())
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
  const setup = await testRender(<App session={session} onExit={() => {}} />, {
    width: 48,
    height: 14,
    kittyKeyboard: true
  })
  const image = { type: "image" as const, mimeType: "image/png", data: "AAAA" }

  try {
    await setup.renderOnce()
    const input = setup.renderer.root.findDescendantById("prompt-input")
    if (!(input instanceof TextareaRenderable)) throw new Error("Prompt textarea not found")
    await act(async () => {
      input.setText("start")
      setup.mockInput.pressEnter()
      await providerStarted.promise
    })
    act(() => {
      session.followUp("with image", [image])
      setup.mockInput.pressArrow("up", { meta: true })
    })
    await setup.renderOnce()

    expect(input.plainText).toBe("with image")
    expect(setup.captureCharFrame()).toContain("Restored 1 queued message")
    act(() => setup.mockInput.pressEnter({ meta: true }))

    expect(session.queuedInputs.followUp[0]?.text).toBe("with image")
    expect(session.queuedInputs.followUp[0]?.images).toEqual([image])
    act(() => {
      session.takeQueuedInputs()
    })
    await act(async () => {
      release.resolve()
      await session.waitForIdle()
    })
  } finally {
    session.dispose()
    act(() => setup.renderer.destroy())
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
