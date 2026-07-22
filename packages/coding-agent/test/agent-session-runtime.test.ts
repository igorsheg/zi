import { expect, test } from "bun:test"
import { existsSync } from "node:fs"
import { mkdtemp } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { AgentSessionRuntime } from "../src/agent-session-runtime.js"
import type { AgentRuntime, CreateAgentRuntimeOptions } from "../src/runtime.js"
import { SessionManager, type SessionListResult } from "../src/session-manager.js"
import {
  createModels,
  createTestAgentRuntime,
  createTestAgentSessionRuntime,
  fauxAssistantMessage,
  fauxProvider
} from "../src/testing.js"

test("session runtime omits a new unprompted session and disposes the replaced session", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-session-runtime-new-"))
  const models = createModels()
  const faux = fauxProvider({ provider: "runtime-new", models: [{ id: "model" }] })
  models.setProvider(faux.provider)
  const runtime = await createTestAgentSessionRuntime({
    cwd: join(root, "project"),
    agentDir: join(root, "global"),
    model: "runtime-new/model",
    models
  })
  const previous = runtime.session
  previous.sessionManager.appendMessage({ role: "user", content: "first task", timestamp: 1 })
  previous.sessionManager.appendMessage(fauxAssistantMessage("first answer"))

  try {
    const firstList = runtime.listSessions()
    expect(runtime.listSessions()).toBe(firstList)
    expect((await firstList).sessions.map(session => session.id)).toContain(previous.sessionManager.sessionId)
    expect((await runtime.switchSession(previous.sessionManager.file!)).session).toBe(previous)

    const next = await runtime.newSession()

    expect(runtime.session).toBe(next.session)
    expect(next.services.paths.cwd).toBe(previous.sessionManager.header.cwd)
    expect(next.session.sessionManager.sessionId).not.toBe(previous.sessionManager.sessionId)
    expect(existsSync(next.session.sessionManager.file!)).toBe(false)
    expect(() => previous.prompt("disposed")).toThrow("AgentSession is disposed")
    expect((await runtime.listSessions()).sessions.map(session => session.id)).toEqual([
      previous.sessionManager.sessionId
    ])
  } finally {
    runtime.dispose()
    await runtime.waitForIdle()
  }
})

test("session catalogs stay globally serialized and restart for a replaced runtime", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-session-runtime-list-generation-"))
  const models = createModels()
  const faux = fauxProvider({ provider: "runtime-list-generation", models: [{ id: "model" }] })
  models.setProvider(faux.provider)
  const runtime = await createTestAgentSessionRuntime({
    cwd: join(root, "project"),
    agentDir: join(root, "global"),
    model: "runtime-list-generation/model",
    models
  })
  // oxlint-disable-next-line typescript/unbound-method
  const originalList = SessionManager.list
  const firstStarted = deferred<void>()
  const releaseFirst = deferred<void>()
  const staleResult: SessionListResult = Object.freeze({ sessions: Object.freeze([]), invalid: 0, omitted: 0 })
  let calls = 0
  SessionManager.list = async (paths, options) => {
    calls++
    if (calls === 1) {
      firstStarted.resolve()
      await releaseFirst.promise
      return staleResult
    }
    return originalList(paths, options)
  }

  try {
    const stale = runtime.listSessions()
    await firstStarted.promise
    const next = await runtime.newSession()
    next.session.sessionManager.appendMessage({ role: "user", content: "next task", timestamp: 1 })
    next.session.sessionManager.appendMessage(fauxAssistantMessage("next answer"))
    const current = runtime.listSessions()
    await Bun.sleep(0)
    expect(calls).toBe(1)

    releaseFirst.resolve()
    expect(await stale).toBe(staleResult)
    expect((await current).sessions.map(session => session.id)).toContain(next.session.sessionManager.sessionId)
    expect(calls).toBe(2)
  } finally {
    releaseFirst.resolve()
    SessionManager.list = originalList
    runtime.dispose()
    await runtime.waitForIdle()
  }
})

test("session catalog browsing remains read-only while a provider run is active", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-session-runtime-list-active-"))
  const models = createModels()
  const releaseRun = deferred<void>()
  const faux = fauxProvider({ provider: "runtime-list-active", models: [{ id: "model" }] })
  faux.setResponses([
    async () => {
      await releaseRun.promise
      return fauxAssistantMessage("done")
    }
  ])
  models.setProvider(faux.provider)
  const runtime = await createTestAgentSessionRuntime({
    cwd: join(root, "project"),
    agentDir: join(root, "global"),
    model: "runtime-list-active/model",
    models
  })
  runtime.session.sessionManager.appendMessage({ role: "user", content: "saved task", timestamp: 1 })
  runtime.session.sessionManager.appendMessage(fauxAssistantMessage("saved answer"))
  const run = runtime.session.prompt("active task")

  try {
    expect(runtime.session.isStreaming).toBe(true)
    expect((await runtime.listSessions()).sessions.map(session => session.id)).toContain(
      runtime.session.sessionManager.sessionId
    )
    expect(runtime.session.isStreaming).toBe(true)
  } finally {
    releaseRun.resolve()
    await run
    runtime.dispose()
    await runtime.waitForIdle()
  }
})

test("session runtime rebuilds every cwd-bound service from the resumed header", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-session-runtime-switch-"))
  const agentDir = join(root, "global")
  const models = createModels()
  const faux = fauxProvider({ provider: "runtime-switch", models: [{ id: "model" }] })
  models.setProvider(faux.provider)
  const target = await createTestAgentRuntime({
    cwd: join(root, "target"),
    agentDir,
    model: "runtime-switch/model",
    models
  })
  target.session.sessionManager.appendMessage({ role: "user", content: "resumed task", timestamp: 1 })
  target.session.sessionManager.appendMessage(fauxAssistantMessage("resumed answer"))
  const targetFile = target.session.sessionManager.file!
  target.session.dispose()
  await target.session.waitForIdle()

  const runtime = await createTestAgentSessionRuntime({
    cwd: join(root, "source"),
    agentDir,
    model: "runtime-switch/model",
    models
  })
  const previous = runtime.session
  try {
    await runtime.switchSession(targetFile)

    expect(runtime.services.paths.cwd).toBe(target.services.paths.cwd)
    expect(runtime.services.paths.projectDir).toBe(join(target.services.paths.cwd, ".zi"))
    expect(runtime.session.sessionManager.file).toBe(targetFile)
    expect(runtime.session.messages).toContainEqual({ role: "user", content: "resumed task", timestamp: 1 })
    expect(() => previous.prompt("disposed")).toThrow("AgentSession is disposed")
  } finally {
    runtime.dispose()
    await runtime.waitForIdle()
  }
})

test("replacement construction failure leaves the current session usable", async () => {
  const models = createModels()
  const faux = fauxProvider({ provider: "runtime-failure", models: [{ id: "model" }] })
  faux.setResponses([fauxAssistantMessage("still usable")])
  models.setProvider(faux.provider)
  const options: CreateAgentRuntimeOptions = {
    cwd: "/work",
    model: "runtime-failure/model",
    persist: false,
    modelFactory: () => models
  }
  const initial = await createTestAgentRuntime({ cwd: "/work", model: "runtime-failure/model", persist: false, models })
  const runtime = new AgentSessionRuntime(initial, options, async () => {
    throw new Error("replacement failed")
  })

  try {
    await expectRejection(runtime.newSession(), "replacement failed")
    expect(runtime.session).toBe(initial.session)
    await runtime.session.prompt("continue")
    expect(runtime.session.messages.at(-1)).toMatchObject({
      role: "assistant",
      content: [{ type: "text", text: "still usable" }]
    })
  } finally {
    runtime.dispose()
    await runtime.waitForIdle()
  }
})

test("replacement rechecks the old session before commit and disposes a stale candidate", async () => {
  const models = createModels()
  const faux = fauxProvider({ provider: "runtime-race", models: [{ id: "model" }] })
  const releaseRun = deferred<void>()
  faux.setResponses([
    async () => {
      await releaseRun.promise
      return fauxAssistantMessage("done")
    }
  ])
  models.setProvider(faux.provider)
  const options: CreateAgentRuntimeOptions = {
    cwd: "/work",
    model: "runtime-race/model",
    persist: false,
    modelFactory: () => models
  }
  const initial = await createTestAgentRuntime({ cwd: "/work", model: "runtime-race/model", persist: false, models })
  const candidateReady = deferred<AgentRuntime>()
  const runtime = new AgentSessionRuntime(initial, options, () => candidateReady.promise)
  const replacement = runtime.newSession()
  const candidate = await createTestAgentRuntime({ cwd: "/work", model: "runtime-race/model", persist: false, models })
  const run = initial.session.prompt("start")
  candidateReady.resolve(candidate)

  try {
    await expectRejection(replacement, "Cannot replace the session while the agent is running")
    expect(runtime.session).toBe(initial.session)
    expect(() => candidate.session.prompt("disposed")).toThrow("AgentSession is disposed")
  } finally {
    releaseRun.resolve()
    await run
    runtime.dispose()
    await runtime.waitForIdle()
  }
})

test("cancelling an in-flight replacement keeps the current session and removes its new journal", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-session-runtime-cancel-"))
  const cwd = join(root, "project")
  const agentDir = join(root, "global")
  const models = createModels()
  const faux = fauxProvider({ provider: "runtime-cancel", models: [{ id: "model" }] })
  models.setProvider(faux.provider)
  const options: CreateAgentRuntimeOptions = {
    cwd,
    agentDir,
    model: "runtime-cancel/model",
    modelFactory: () => models
  }
  const initial = await createTestAgentRuntime({ cwd, agentDir, model: "runtime-cancel/model", models })
  const candidateReady = deferred<AgentRuntime>()
  const runtime = new AgentSessionRuntime(initial, options, () => candidateReady.promise)
  const replacement = runtime.newSession()
  const cancellation = runtime.cancelReplacement()
  expect(cancellation.type).toBe("cancelled")
  const candidate = await createTestAgentRuntime({ cwd, agentDir, model: "runtime-cancel/model", models })
  const candidateFile = candidate.session.sessionManager.file!
  candidateReady.resolve(candidate)

  try {
    await expectRejection(replacement, "Session replacement was cancelled")
    await cancellation.settled
    expect(runtime.session).toBe(initial.session)
    expect(() => candidate.session.prompt("disposed")).toThrow("AgentSession is disposed")
    expect(existsSync(candidateFile)).toBe(false)
  } finally {
    runtime.dispose()
    await runtime.waitForIdle()
  }
})

async function expectRejection(operation: Promise<unknown>, message: string): Promise<void> {
  try {
    await operation
    throw new Error("Expected operation to reject")
  } catch (cause) {
    if (!(cause instanceof Error)) throw cause
    expect(cause.message).toContain(message)
  }
}

function deferred<T>() {
  let resolve!: (value: T | PromiseLike<T>) => void
  const promise = new Promise<T>(resolvePromise => {
    resolve = resolvePromise
  })
  return { promise, resolve }
}
