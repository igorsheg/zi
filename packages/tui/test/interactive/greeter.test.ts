import { expect, test } from "bun:test"

import { TextareaRenderable } from "@opentui/core"
import {
  createModels,
  createTestAgentRuntime as createAgentRuntime,
  fauxAssistantMessage,
  fauxProvider
} from "@with-zi/coding-agent/testing"

import { createInteractiveTest, renderMarkdownSettled, renderSettled } from "./harness.js"

test("a fresh session greets the user immediately above the composer", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  const { session } = await createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })
  const setup = await createInteractiveTest(session, { width: 40, height: 12 })

  try {
    await setup.renderOnce()
    const rows = setup
      .captureCharFrame()
      .split("\n")
      .map(row => row.trimEnd())
    const start = rows.indexOf(" ░▀▀█░▀█▀  zi coding agent")
    expect(rows.slice(start, start + 4)).toEqual([
      " ░▀▀█░▀█▀  zi coding agent",
      " ░▄▀░░░█░  you can build with",
      " ░▀▀▀░▀▀▀",
      ""
    ])
    expect(rows[start + 4]?.startsWith("╭─")).toBe(true)
    expect(rows[start + 6]).toContain("/work")

    await setup.mockInput.typeText("draft")
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("░▀▀█░▀█▀  zi coding agent")
  } finally {
    session.dispose()
    setup.destroy()
  }
})

test("resizing reuses the greeter and keeps the composer focused", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  const { session } = await createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })
  const setup = await createInteractiveTest(session, { width: 40, height: 12 })

  try {
    await setup.renderOnce()
    const greeter = setup.renderer.root.findDescendantById("session-greeter")
    const input = setup.renderer.root.findDescendantById("prompt-input")
    if (!greeter) throw new Error("Session greeter not found")
    if (!(input instanceof TextareaRenderable)) throw new Error("Prompt textarea not found")

    setup.resize(20, 12)
    await setup.renderOnce()
    const compactRows = setup
      .captureCharFrame()
      .split("\n")
      .map(row => row.trimEnd())
    expect(compactRows).toContain(" ░▀▀█░▀█▀  zi")
    expect(compactRows).toContain(" ░▄▀░░░█░")
    expect(setup.renderer.root.findDescendantById("session-greeter")).toBe(greeter)

    setup.resize(13, 12)
    await setup.renderOnce()
    expect(setup.captureCharFrame()).not.toContain("░▀▀█░▀█▀")
    expect(setup.renderer.root.findDescendantById("session-greeter")).toBe(greeter)

    setup.resize(40, 10)
    await setup.renderOnce()
    expect(setup.captureCharFrame()).not.toContain("░▀▀█░▀█▀")
    expect(setup.renderer.root.findDescendantById("session-greeter")).toBe(greeter)

    setup.resize(40, 12)
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("░▀▀█░▀█▀  zi coding agent")
    expect(input.focused).toBe(true)
  } finally {
    session.dispose()
    setup.destroy()
  }
})

test("the greeter yields its rows to a prompt picker", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  const { session } = await createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })
  const setup = await createInteractiveTest(session, { width: 40, height: 12, kittyKeyboard: true })

  try {
    await setup.mockInput.typeText("/m")
    await renderSettled(setup)

    const frame = setup.captureCharFrame()
    expect(frame).not.toContain("░▀▀█░▀█▀")
    expect(frame).toContain("Select model")

    setup.mockInput.pressEscape()
    await renderSettled(setup)
    expect(setup.captureCharFrame()).toContain("░▀▀█░▀█▀")
  } finally {
    session.dispose()
    setup.destroy()
  }
})

test("an existing session opens without the greeter", async () => {
  const models = createModels()
  const faux = fauxProvider()
  faux.setResponses([fauxAssistantMessage("earlier response")])
  models.setProvider(faux.provider)
  const { session } = await createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })
  await session.prompt("earlier prompt")
  const setup = await createInteractiveTest(session, { width: 40, height: 12 })

  try {
    await renderMarkdownSettled(setup)
    const frame = setup.captureCharFrame()
    expect(frame).not.toContain("░▀▀█░▀█▀")
    expect(frame).toContain("earlier response")
  } finally {
    session.dispose()
    setup.destroy()
  }
})

test("the greeter leaves when the first prompt becomes part of the session", async () => {
  const models = createModels()
  const faux = fauxProvider()
  faux.setResponses([fauxAssistantMessage("hello")])
  models.setProvider(faux.provider)
  const { session } = await createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })
  const setup = await createInteractiveTest(session, { width: 40, height: 12 })

  try {
    await setup.mockInput.typeText("start")
    setup.mockInput.pressEnter()
    await session.waitForIdle()
    await renderMarkdownSettled(setup)

    const frame = setup.captureCharFrame()
    expect(frame).not.toContain("░▀▀█░▀█▀")
    expect(frame).toContain("hello")
  } finally {
    session.dispose()
    setup.destroy()
  }
})
