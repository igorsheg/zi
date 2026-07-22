import { expect, test } from "bun:test"
import { mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { TextareaRenderable } from "@opentui/core"
import type { AgentSession } from "@zi/coding-agent"
import { createModels, createTestAgentRuntime, fauxProvider } from "@zi/coding-agent/testing"

import { createInteractiveTest, renderSettled, type InteractiveTestSetup } from "./harness.js"

test("/settings keeps the composer focused through scoped nested selection", async () => {
  const { session, setup } = await createSettingsFixture()

  try {
    const prompt = promptInput(setup)
    await setup.mockInput.typeText("/s", 0)
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("/settings")

    setup.mockInput.pressTab()
    expect(prompt.plainText).toBe("/settings ")
    setup.mockInput.pressEnter()
    await renderSettled(setup)
    expect(prompt.focused).toBe(true)
    expect(setup.captureCharFrame()).toContain("Settings scope")

    await setup.mockInput.typeText("glob", 0)
    setup.mockInput.pressEnter()
    await renderSettled(setup)
    expect(setup.captureCharFrame()).toContain("Settings · Global")
    expect(setup.captureCharFrame()).toContain("Thinking level")
    expect(setup.captureCharFrame()).toContain("[inherited]")

    await setup.mockInput.typeText("steer", 0)
    setup.mockInput.pressEnter()
    await renderSettled(setup)
    expect(setup.captureCharFrame()).toContain("Steering mode · Global")
    expect(setup.captureCharFrame()).toContain("one-at-a-time")
    expect(setup.captureCharFrame()).toContain("all")

    setup.mockInput.pressEscape()
    await renderSettled(setup)
    expect(prompt.plainText).toBe("steer")
    expect(setup.captureCharFrame()).toContain("Settings · Global")
    setup.mockInput.pressEscape()
    await renderSettled(setup)
    expect(prompt.plainText).toBe("glob")
    expect(setup.captureCharFrame()).toContain("Settings scope")

    setup.mockInput.pressEnter()
    await renderSettled(setup)
    await setup.mockInput.typeText("steer", 0)
    setup.mockInput.pressEnter()
    await renderSettled(setup)
    setup.mockInput.pressArrow("down")
    setup.mockInput.pressEnter()
    await renderSettled(setup)
    expect(session.steeringMode).toBe("all")
    expect(session.settingsManager.getGlobal().steeringMode).toBe("all")
    expect(prompt.plainText).toBe("")
    expect(setup.captureCharFrame()).toContain("Steering mode: all (global)")
    expect(setup.captureCharFrame()).not.toContain("Settings · Global")
  } finally {
    session.dispose()
    setup.destroy()
  }
})

test("automatic compaction is an explicit scoped On or Off setting", async () => {
  const { session, setup } = await createSettingsFixture()

  try {
    const prompt = promptInput(setup)
    prompt.setText("/settings")
    prompt.gotoBufferEnd()
    setup.mockInput.pressEnter()
    await renderSettled(setup)
    setup.mockInput.pressEnter()
    await renderSettled(setup)
    await setup.mockInput.typeText("auto", 0)
    setup.mockInput.pressEnter()
    await renderSettled(setup)

    expect(setup.captureCharFrame()).toContain("Automatic compaction · Global")
    expect(setup.captureCharFrame()).toContain("On")
    expect(setup.captureCharFrame()).toContain("Off")
    setup.mockInput.pressArrow("down")
    setup.mockInput.pressEnter()
    await renderSettled(setup)

    expect(session.settingsManager.getGlobal().compactionEnabled).toBe(false)
    expect(session.settingsManager.get().compactionEnabled).toBe(false)
    expect(setup.captureCharFrame()).toContain("Automatic compaction: Off (global)")
  } finally {
    session.dispose()
    setup.destroy()
  }
})

test("automatic retry is an explicit scoped On or Off setting", async () => {
  const { session, setup } = await createSettingsFixture()

  try {
    const prompt = promptInput(setup)
    prompt.setText("/settings")
    prompt.gotoBufferEnd()
    setup.mockInput.pressEnter()
    await renderSettled(setup)
    setup.mockInput.pressEnter()
    await renderSettled(setup)
    await setup.mockInput.typeText("retry", 0)
    setup.mockInput.pressEnter()
    await renderSettled(setup)

    expect(setup.captureCharFrame()).toContain("Automatic retry · Global")
    expect(setup.captureCharFrame()).toContain("On")
    expect(setup.captureCharFrame()).toContain("Off")
    setup.mockInput.pressArrow("down")
    setup.mockInput.pressEnter()
    await renderSettled(setup)

    expect(session.settingsManager.getGlobal().retryEnabled).toBe(false)
    expect(session.settingsManager.get().retryEnabled).toBe(false)
    expect(setup.captureCharFrame()).toContain("Automatic retry: Off (global)")
  } finally {
    session.dispose()
    setup.destroy()
  }
})

test("thinking values come from the model and persist through AgentSession", async () => {
  const { session, setup } = await createSettingsFixture()

  try {
    const prompt = promptInput(setup)
    prompt.setText("/settings")
    prompt.gotoBufferEnd()
    setup.mockInput.pressEnter()
    await renderSettled(setup)
    setup.mockInput.pressArrow("down")
    setup.mockInput.pressEnter()
    await renderSettled(setup)
    setup.mockInput.pressEnter()
    await renderSettled(setup)

    const frame = setup.captureCharFrame()
    expect(frame).toContain("Thinking level · Project")
    expect(frame).not.toContain("xhigh")
    expect(frame).not.toContain("max")
    setup.mockInput.pressArrow("up")
    setup.mockInput.pressEnter()
    await renderSettled(setup)

    expect(session.thinkingLevel).toBe("low")
    expect(session.settingsManager.getProject().defaultThinkingLevel).toBe("low")
    expect(prompt.plainText).toBe("")
    expect(setup.captureCharFrame()).toContain("Thinking level: low (project)")
    expect(setup.captureCharFrame()).not.toContain("Settings · Project")
  } finally {
    session.dispose()
    setup.destroy()
  }
})

test("global settings explain an effective project override", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-settings-picker-shadow-"))
  const cwd = join(root, "project")
  const agentDir = join(root, "global")
  await mkdir(join(cwd, ".zi"), { recursive: true })
  await mkdir(agentDir, { recursive: true })
  await writeFile(join(agentDir, "settings.json"), JSON.stringify({ steeringMode: "one-at-a-time" }))
  await writeFile(join(cwd, ".zi", "settings.json"), JSON.stringify({ steeringMode: "all" }))
  const { session, setup } = await createSettingsFixture({ cwd, agentDir })

  try {
    const prompt = promptInput(setup)
    prompt.setText("/settings")
    prompt.gotoBufferEnd()
    setup.mockInput.pressEnter()
    await renderSettled(setup)
    setup.mockInput.pressEnter()
    await renderSettled(setup)

    expect(setup.captureCharFrame()).toContain("Effective: all (project override)")
    await setup.mockInput.typeText("steer", 0)
    setup.mockInput.pressEnter()
    await renderSettled(setup)
    setup.mockInput.pressEnter()
    await renderSettled(setup)

    expect(session.steeringMode).toBe("all")
    expect(prompt.plainText).toBe("")
    expect(setup.captureCharFrame()).toContain("project override keeps all effective")
    expect(setup.captureCharFrame()).not.toContain("Settings · Global")
    expect(JSON.parse(await readFile(join(agentDir, "settings.json"), "utf8"))).toEqual({
      steeringMode: "one-at-a-time"
    })
  } finally {
    session.dispose()
    setup.destroy()
  }
})

test("invalid project settings refuse picker writes without changing live behavior", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-settings-picker-invalid-"))
  const cwd = join(root, "project")
  const agentDir = join(root, "global")
  const projectFile = join(cwd, ".zi", "settings.json")
  const invalid = JSON.stringify({ steeringMode: "grouped" })
  await mkdir(join(cwd, ".zi"), { recursive: true })
  await writeFile(projectFile, invalid)
  const { session, setup } = await createSettingsFixture({ cwd, agentDir })

  try {
    const prompt = promptInput(setup)
    prompt.setText("/settings")
    prompt.gotoBufferEnd()
    setup.mockInput.pressEnter()
    await renderSettled(setup)
    setup.mockInput.pressArrow("down")
    setup.mockInput.pressEnter()
    await renderSettled(setup)
    await setup.mockInput.typeText("steer", 0)
    setup.mockInput.pressEnter()
    await renderSettled(setup)
    setup.mockInput.pressArrow("down")
    setup.mockInput.pressEnter()
    await renderSettled(setup)

    expect(session.steeringMode).toBe("one-at-a-time")
    expect(await readFile(projectFile, "utf8")).toBe(invalid)
    expect(setup.captureCharFrame()).toContain("Cannot update invalid project settings")
  } finally {
    session.dispose()
    setup.destroy()
  }
})

interface SettingsFixtureOptions {
  readonly cwd?: string
  readonly agentDir?: string
}

async function createSettingsFixture(
  options: SettingsFixtureOptions = {}
): Promise<{ session: AgentSession; setup: InteractiveTestSetup }> {
  const root = await mkdtemp(join(tmpdir(), "zi-settings-picker-"))
  const cwd = options.cwd ?? join(root, "project")
  const agentDir = options.agentDir ?? join(root, "global")
  await mkdir(cwd, { recursive: true })
  const models = createModels()
  const faux = fauxProvider({ provider: "settings", models: [{ id: "model", reasoning: true }] })
  models.setProvider(faux.provider)
  const { session } = await createTestAgentRuntime({ cwd, agentDir, model: "settings/model", models, persist: false })
  const setup = await createInteractiveTest(session, { width: 100, height: 18, kittyKeyboard: true })
  return { session, setup }
}

function promptInput(setup: InteractiveTestSetup): TextareaRenderable {
  const input = setup.renderer.root.findDescendantById("prompt-input")
  if (!(input instanceof TextareaRenderable)) throw new Error("Prompt textarea not found")
  return input
}
