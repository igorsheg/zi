import { expect, test } from "bun:test"
import { mkdtemp, utimes, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { TextareaRenderable } from "@opentui/core"
import {
  createModels,
  createTestAgentRuntime,
  createTestAgentSessionRuntime,
  fauxAssistantMessage,
  fauxProvider
} from "@with-zi/coding-agent/testing"

import { createInteractiveRuntimeTest, renderSettled, type InteractiveTestSetup } from "./harness.js"

test("/resume loads a bounded current-project catalog and replaces the whole session runtime", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-resume-picker-"))
  const cwd = join(root, "project")
  const agentDir = join(root, "global")
  const savedModels = createModels()
  const saved = fauxProvider({ provider: "removed", models: [{ id: "old-model" }] })
  savedModels.setProvider(saved.provider)
  const models = createModels()
  const faux = fauxProvider({ provider: "resume-picker", models: [{ id: "model" }] })
  models.setProvider(faux.provider)

  const target = await createTestAgentRuntime({ cwd, agentDir, model: "removed/old-model", models: savedModels })
  target.session.sessionManager.appendMessage({ role: "user", content: "older task", timestamp: 1 })
  target.session.sessionManager.appendMessage({
    ...fauxAssistantMessage("older answer"),
    provider: "removed",
    model: "old-model"
  })
  const targetFile = target.session.sessionManager.file!
  const targetId = target.session.sessionManager.sessionId
  target.session.dispose()
  await target.session.waitForIdle()
  await utimes(targetFile, new Date(1_000), new Date(1_000))

  const runtime = await createTestAgentSessionRuntime({ cwd, agentDir, models })
  const previous = runtime.session
  previous.sessionManager.appendMessage({ role: "user", content: "current task", timestamp: 2 })
  previous.sessionManager.appendMessage(fauxAssistantMessage("current answer"))
  const invalid = join(runtime.services.paths.sessionDir, "invalid.jsonl")
  await writeFile(invalid, "invalid\n")
  await utimes(invalid, new Date(500), new Date(500))
  const setup = await createInteractiveRuntimeTest(runtime, { width: 72, height: 18, kittyKeyboard: true })

  try {
    const prompt = promptInput(setup)
    prompt.setText("/resume")
    prompt.gotoBufferEnd()
    setup.mockInput.pressEnter()
    const picker = await waitForFrame(setup, "older task")
    expect(picker).toContain("Resume session")
    expect(picker).toContain("current task")
    expect(picker).toContain("older task")
    expect(picker).toContain("1 invalid")
    expect(prompt.focused).toBe(true)

    setup.mockInput.pressArrow("down")
    setup.mockInput.pressEnter()
    await waitUntil(() => runtime.session.sessionManager.sessionId === targetId)
    await renderSettled(setup)

    expect(runtime.session.sessionManager.file).toBe(targetFile)
    expect(runtime.bootstrapDiagnostic).toEqual({
      type: "model_fallback",
      savedModel: { provider: "removed", modelId: "old-model" },
      fallbackModel: { provider: "resume-picker", modelId: "model" },
      message: "Could not restore model removed/old-model. Using resume-picker/model."
    })
    expect(setup.mode.store.getSession()).toBe(runtime.session)
    expect(setup.captureCharFrame()).toContain("older answer")
    expect(setup.captureCharFrame()).toContain("Could not restore model removed/old-model. Using resume-pick")
    expect(setup.captureCharFrame()).not.toContain("System ❰❰")
    expect(promptInput(setup).focused).toBe(true)
    expect(() => previous.prompt("disposed")).toThrow("AgentSession is disposed")
  } finally {
    setup.destroy()
    runtime.dispose()
    await runtime.waitForIdle()
  }
})

test("/resume keeps the active session selected without rebuilding it", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-resume-current-"))
  const models = createModels()
  const faux = fauxProvider({ provider: "resume-current", models: [{ id: "model" }] })
  models.setProvider(faux.provider)
  const runtime = await createTestAgentSessionRuntime({
    cwd: join(root, "project"),
    agentDir: join(root, "global"),
    model: "resume-current/model",
    models
  })
  const current = runtime.session
  current.sessionManager.appendMessage({ role: "user", content: "keep current transcript", timestamp: 1 })
  current.sessionManager.appendMessage(fauxAssistantMessage("kept answer"))
  const setup = await createInteractiveRuntimeTest(runtime, { width: 64, height: 14, kittyKeyboard: true })

  try {
    const prompt = promptInput(setup)
    prompt.setText("/resume")
    prompt.gotoBufferEnd()
    setup.mockInput.pressEnter()
    await waitForFrame(setup, "keep current transcript")
    setup.mockInput.pressEnter()
    await waitForFrame(setup, "Session already active")

    expect(runtime.session).toBe(current)
    expect(setup.mode.store.getSession()).toBe(current)
    expect(setup.mode.store.$state.get().generation).toBe(0)
    expect(setup.captureCharFrame()).toContain("Session already active")
    expect(prompt.focused).toBe(true)
  } finally {
    setup.destroy()
    runtime.dispose()
    await runtime.waitForIdle()
  }
})

test("/resume can browse during a run but refuses replacement until the session is idle", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-resume-active-"))
  const cwd = join(root, "project")
  const agentDir = join(root, "global")
  const models = createModels()
  const releaseRun = deferred<void>()
  const faux = fauxProvider({ provider: "resume-active", models: [{ id: "model" }] })
  faux.setResponses([
    async () => {
      await releaseRun.promise
      return fauxAssistantMessage("finished")
    }
  ])
  models.setProvider(faux.provider)

  const target = await createTestAgentRuntime({ cwd, agentDir, model: "resume-active/model", models })
  target.session.sessionManager.appendMessage({ role: "user", content: "older active target", timestamp: 1 })
  target.session.sessionManager.appendMessage(fauxAssistantMessage("older active answer"))
  const targetFile = target.session.sessionManager.file!
  target.session.dispose()
  await target.session.waitForIdle()
  await utimes(targetFile, new Date(1_000), new Date(1_000))

  const runtime = await createTestAgentSessionRuntime({ cwd, agentDir, model: "resume-active/model", models })
  const current = runtime.session
  const setup = await createInteractiveRuntimeTest(runtime, { width: 72, height: 18, kittyKeyboard: true })
  const run = current.prompt("running task")

  try {
    const prompt = promptInput(setup)
    prompt.setText("/resume")
    prompt.gotoBufferEnd()
    setup.mockInput.pressEnter()
    await waitForFrame(setup, "older active target")

    setup.mockInput.pressArrow("down")
    setup.mockInput.pressEnter()
    await renderSettled(setup)

    expect(runtime.session).toBe(current)
    expect(setup.captureCharFrame()).toContain("Cannot replace the session while the agent is running")
    expect(setup.captureCharFrame()).toContain("Resume session")
  } finally {
    releaseRun.resolve()
    await run
    setup.destroy()
    runtime.dispose()
    await runtime.waitForIdle()
  }
})

test("/new replaces the active session, clears its transcript, and preserves composer focus", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-new-session-"))
  const models = createModels()
  const faux = fauxProvider({ provider: "new-session", models: [{ id: "model" }] })
  models.setProvider(faux.provider)
  const runtime = await createTestAgentSessionRuntime({
    cwd: join(root, "project"),
    agentDir: join(root, "global"),
    model: "new-session/model",
    models
  })
  const previous = runtime.session
  previous.sessionManager.appendMessage({ role: "user", content: "old transcript", timestamp: 1 })
  previous.sessionManager.appendMessage(fauxAssistantMessage("old answer"))
  const previousId = previous.sessionManager.sessionId
  const setup = await createInteractiveRuntimeTest(runtime, { width: 64, height: 14, kittyKeyboard: true })

  try {
    const prompt = promptInput(setup)
    prompt.setText("/new")
    prompt.gotoBufferEnd()
    setup.mockInput.pressEnter()
    await waitUntil(() => runtime.session.sessionManager.sessionId !== previousId)
    await renderSettled(setup)

    expect(runtime.session.messages).toEqual([])
    expect(setup.mode.store.getSession()).toBe(runtime.session)
    expect(setup.captureCharFrame()).not.toContain("old transcript")
    expect(promptInput(setup).focused).toBe(true)
    expect(() => previous.prompt("disposed")).toThrow("AgentSession is disposed")
  } finally {
    setup.destroy()
    runtime.dispose()
    await runtime.waitForIdle()
  }
})

function promptInput(setup: InteractiveTestSetup): TextareaRenderable {
  const input = setup.renderer.root.findDescendantById("prompt-input")
  if (!(input instanceof TextareaRenderable)) throw new Error("Prompt textarea not found")
  return input
}

function deferred<T>() {
  let resolve!: (value: T | PromiseLike<T>) => void
  const promise = new Promise<T>(resolvePromise => {
    resolve = resolvePromise
  })
  return { promise, resolve }
}

async function waitUntil(predicate: () => boolean): Promise<void> {
  for (let attempt = 0; attempt < 100; attempt++) {
    if (predicate()) return
    // oxlint-disable-next-line no-await-in-loop
    await Bun.sleep(1)
  }
  throw new Error("Condition was not met")
}

async function waitForFrame(setup: InteractiveTestSetup, expected: string): Promise<string> {
  for (let attempt = 0; attempt < 100; attempt++) {
    // oxlint-disable-next-line no-await-in-loop
    await renderSettled(setup)
    const frame = setup.captureCharFrame()
    if (frame.includes(expected)) return frame
    // oxlint-disable-next-line no-await-in-loop
    await Bun.sleep(1)
  }
  throw new Error(`Frame did not contain ${JSON.stringify(expected)}:\n${setup.captureCharFrame()}`)
}
