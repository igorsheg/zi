import { expect, test } from "bun:test"

import { createAgentSession, type AgentSession, SessionManager } from "@openzi/coding-agent"
import {
  createModels,
  createTestAgentRuntime as createAgentRuntime,
  fauxAssistantMessage,
  fauxProvider
} from "@openzi/coding-agent/testing"

import { createInteractiveStore } from "../../src/interactive/interactive-store.js"
import { createPromptStore, type PromptSessionActions } from "../../src/interactive/prompt/store.js"
import { SlashController } from "../../src/interactive/slash-controller.js"

test("prompt store restores queued text, images, and status without a renderer", async () => {
  const session = await createSession("restore")
  const mode = createInteractiveStore(session)
  const prompt = createPromptStore(mode, new SlashController())

  try {
    session.steer("queued text", [{ type: "image", data: "aW1hZ2U=", mimeType: "image/png" }])
    const text = prompt.restoreQueuedInputs("current draft")

    expect(text).toBe("queued text\n\ncurrent draft")
    expect(prompt.$state.get()).toEqual({
      feedback: { type: "status", message: "Restored 1 queued message to editor with 1 image" },
      images: [{ type: "image", data: "aW1hZ2U=", mimeType: "image/png" }],
      workflow: { type: "idle" },
      inputEdit: { revision: 0, text: "", cursorOffset: 0 }
    })
    expect(session.queuedInputs.steering).toHaveLength(0)
  } finally {
    mode.dispose()
    session.dispose()
  }
})

test("resource command selection edits the composer without dispatching TUI domain work", async () => {
  const session = await createSession("resource-command")
  const mode = createInteractiveStore(session)
  const slash = new SlashController(() => ({
    listResourceCommands: () => [{ name: "review", description: "Review code", argumentHint: "<path>" }]
  }))
  const prompt = createPromptStore(mode, slash)

  try {
    prompt.draftChanged("/rev path", 4)
    expect(prompt.activatePicker("/rev path", 4)).toBe(true)
    expect(prompt.$state.get().inputEdit).toEqual({ revision: 1, text: "/review path", cursorOffset: 8 })
    expect(session.messages).toEqual([])
  } finally {
    mode.dispose()
    session.dispose()
  }
})

test("compact command forwards focus without creating a user message", async () => {
  const session = await createSession("compact-store")
  const mode = createInteractiveStore(session)
  const prompt = createPromptStore(mode, new SlashController())
  let instructions: string | undefined
  session.compact = async focus => {
    instructions = focus
    return {
      reason: "manual",
      summary: "summary",
      firstKeptEntryId: "kept",
      tokensBefore: 123_000,
      estimatedTokensAfter: 24_000,
      compactedEntries: 4,
      details: { readFiles: [], modifiedFiles: [], omittedReadFiles: 0, omittedModifiedFiles: 0 }
    }
  }

  try {
    expect(prompt.submit("/compact preserve database decisions", "steer")).toBe(true)
    expect(prompt.$state.get().workflow.type).toBe("compacting")
    await Bun.sleep(0)
    expect(instructions).toBe("preserve database decisions")
    expect(session.messages).toEqual([])
    expect(prompt.$state.get()).toMatchObject({
      feedback: { type: "status", message: "Compacted 123k → ~24k context tokens." },
      workflow: { type: "idle" }
    })
  } finally {
    mode.dispose()
    session.dispose()
  }
})

test("compact cancellation stays blocking until settlement and reports no error", async () => {
  const session = await createSession("compact-cancel")
  const mode = createInteractiveStore(session)
  const prompt = createPromptStore(mode, new SlashController())
  const pending = rejectable<Awaited<ReturnType<AgentSession["compact"]>>>()
  session.compact = () => pending.promise
  session.abort = async () => {
    pending.reject(new Error("Compaction cancelled"))
  }

  try {
    expect(prompt.submit("/compact", "steer")).toBe(true)
    expect(prompt.abortAndRestoreQueuedInputs("draft")).toBe("")
    expect(prompt.$state.get().workflow.type).toBe("compacting")
    expect(prompt.submit("new prompt", "steer")).toBe(false)
    await Bun.sleep(0)
    expect(prompt.$state.get()).toMatchObject({ feedback: { type: "none" }, workflow: { type: "idle" } })
  } finally {
    mode.dispose()
    session.dispose()
  }
})

test("automatic compaction failures surface through prompt feedback", async () => {
  const models = createModels()
  const faux = fauxProvider({ provider: "automatic-failure", models: [{ id: "model", contextWindow: 4_000 }] })
  models.setProvider(faux.provider)
  faux.setResponses([fauxAssistantMessage("   "), fauxAssistantMessage("continued")])
  const bootstrap = await createAgentRuntime({
    cwd: "/work",
    models,
    persist: false,
    settings: { compactionReserveTokens: 100, compactionKeepRecentTokens: 1 }
  })
  const model = bootstrap.session.model
  bootstrap.session.dispose()
  const history = SessionManager.inMemory("/work")
  history.appendMessage({ role: "user", content: "old context", timestamp: 1 })
  const answer = fauxAssistantMessage("old answer")
  history.appendMessage({
    ...answer,
    usage: {
      input: 3_900,
      output: 0,
      cacheRead: 0,
      cacheWrite: 0,
      totalTokens: 3_900,
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 }
    }
  })
  const { session } = await createAgentSession({
    services: bootstrap.services,
    sessionManager: history,
    model,
    tools: []
  })
  const mode = createInteractiveStore(session)
  const prompt = createPromptStore(mode, new SlashController())

  try {
    expect(prompt.submit("continue", "steer")).toBe(true)
    await session.waitForIdle()

    expect(prompt.$state.get().feedback).toEqual({ type: "error", message: "Compaction produced an empty summary" })
    expect(session.sessionManager.latestCompaction()).toBeUndefined()
  } finally {
    prompt.dispose()
    mode.dispose()
    session.dispose()
  }
})

test("settings workflow restores suspended filters until a value closes the stack", async () => {
  const session = await createSession("settings-store")
  const mode = createInteractiveStore(session)
  const prompt = createPromptStore(mode, new SlashController())

  try {
    expect(prompt.submit("/settings", "steer")).toBe(true)
    prompt.draftChanged("glob", 4)
    expect(prompt.activatePicker("glob", 4)).toBe(true)
    prompt.draftChanged("steer", 5)
    expect(prompt.activatePicker("steer", 5)).toBe(true)
    prompt.movePicker("", 1)
    expect(prompt.backPicker()).toBe(true)
    expect(prompt.$state.get().inputEdit.text).toBe("steer")
    expect(prompt.picker.presentation("steer")?.frame.id).toBe("settings")
    expect(prompt.activatePicker("steer", 5)).toBe(true)
    prompt.movePicker("", 1)
    expect(prompt.activatePicker("", 0)).toBe(true)
    expect(session.steeringMode).toBe("all")
    expect(prompt.$state.get().inputEdit.text).toBe("")
    expect(prompt.picker.presentation("")).toBeUndefined()
  } finally {
    mode.dispose()
    session.dispose()
  }
})

test("settings workflow cannot cross a session replacement", async () => {
  const first = await createSession("settings-first")
  const second = await createSession("settings-second")
  const mode = createInteractiveStore(first)
  const prompt = createPromptStore(mode, new SlashController())

  try {
    expect(prompt.submit("/settings", "steer")).toBe(true)
    mode.replaceSession(second)
    expect(prompt.activatePicker("", 0)).toBe(false)
    expect(first.steeringMode).toBe("one-at-a-time")
    expect(second.steeringMode).toBe("one-at-a-time")
  } finally {
    prompt.dispose()
    mode.dispose()
    first.dispose()
    second.dispose()
  }
})

test("session replacement cancellation remains explicit until runtime settlement", async () => {
  const session = await createSession("session-cancellation")
  const mode = createInteractiveStore(session)
  const resume = rejectable<void>()
  const cancellation = deferred<void>()
  const actions: PromptSessionActions = {
    listSessions: async () => ({
      sessions: [
        {
          path: "/sessions/target.jsonl",
          id: "target",
          cwd: "/work",
          createdAt: "2026-01-01T00:00:00.000Z",
          modifiedAt: "2026-01-01T00:00:00.000Z",
          firstMessage: "target session"
        }
      ],
      invalid: 0,
      omitted: 0
    }),
    startNewSession: async () => {},
    resumeSession: () => resume.promise,
    cancelReplacement: () => ({ type: "cancelled", settled: cancellation.promise })
  }
  const prompt = createPromptStore(mode, new SlashController(), actions)

  try {
    expect(prompt.submit("/resume", "steer")).toBe(true)
    await Bun.sleep(0)
    expect(prompt.activatePicker("", 0)).toBe(true)
    expect(prompt.$state.get().workflow.type).toBe("resuming_session")

    expect(prompt.abortAndRestoreQueuedInputs("")).toBe("")
    expect(prompt.$state.get()).toMatchObject({
      feedback: { type: "status", message: "Cancelling session change…" },
      workflow: { type: "cancelling_session" }
    })

    resume.reject(new Error("Session replacement was cancelled"))
    cancellation.resolve()
    await Bun.sleep(0)
    expect(prompt.$state.get()).toMatchObject({ feedback: { type: "none" }, workflow: { type: "idle" } })
  } finally {
    cancellation.resolve()
    prompt.dispose()
    mode.dispose()
    session.dispose()
  }
})

test("prompt store retains rejected input and exposes the admission error", async () => {
  const session = await createSession("disposed")
  const mode = createInteractiveStore(session)
  const prompt = createPromptStore(mode, new SlashController())

  session.dispose()
  expect(prompt.submit("keep this", "steer")).toBe(false)
  expect(prompt.$state.get().feedback).toEqual({ type: "error", message: "AgentSession is disposed" })

  mode.dispose()
})

function deferred<T>() {
  let resolve!: (value: T | PromiseLike<T>) => void
  const promise = new Promise<T>(resolvePromise => {
    resolve = resolvePromise
  })
  return { promise, resolve }
}

function rejectable<T>() {
  let reject!: (cause: unknown) => void
  const promise = new Promise<T>((_resolve, rejectPromise) => {
    reject = rejectPromise
  })
  return { promise, reject }
}

async function createSession(provider: string): Promise<AgentSession> {
  const models = createModels()
  const faux = fauxProvider({ provider, models: [{ id: "model" }] })
  models.setProvider(faux.provider)
  return (await createAgentRuntime({ cwd: "/work", models, persist: false })).session
}
