import { expect, test } from "bun:test"

import type { AgentSession } from "@openzi/coding-agent"
import { createModels, createTestAgentRuntime as createAgentRuntime, fauxProvider } from "@openzi/coding-agent/testing"

import { createInteractiveCommands } from "../../src/interactive/interactive-commands.js"
import { createInteractiveStore } from "../../src/interactive/interactive-store.js"
import { createPromptStore, type PromptSessionActions } from "../../src/interactive/prompt/store.js"

test("prompt store restores queued text, images, and status without a renderer", async () => {
  const session = await createSession("restore")
  const mode = createInteractiveStore(session)
  const prompt = createPromptStore(mode, createInteractiveCommands())

  try {
    session.steer("queued text", [{ type: "image", data: "aW1hZ2U=", mimeType: "image/png" }])
    const text = prompt.restoreQueuedInputs("current draft")

    expect(text).toBe("queued text\n\ncurrent draft")
    expect(prompt.$state.get()).toEqual({
      feedback: { type: "status", message: "Restored 1 queued message to editor with 1 image" },
      images: [{ type: "image", data: "aW1hZ2U=", mimeType: "image/png" }],
      workflow: { type: "idle" },
      inputEdit: { revision: 0, text: "" }
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
  const commands = createInteractiveCommands(() => ({
    listResourceCommands: () => [{ name: "review", description: "Review code", argumentHint: "<path>" }]
  }))
  const prompt = createPromptStore(mode, commands)

  try {
    prompt.draftChanged("/rev", 4)
    expect(prompt.activatePicker("/rev", 4)).toBe(true)
    expect(prompt.$state.get().inputEdit.text).toBe("/review ")
    expect(session.messages).toEqual([])
  } finally {
    mode.dispose()
    session.dispose()
  }
})

test("settings workflow restores suspended filters until a value closes the stack", async () => {
  const session = await createSession("settings-store")
  const mode = createInteractiveStore(session)
  const prompt = createPromptStore(mode, createInteractiveCommands())

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
  const prompt = createPromptStore(mode, createInteractiveCommands())

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
  const prompt = createPromptStore(mode, createInteractiveCommands(), actions)

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
  const prompt = createPromptStore(mode, createInteractiveCommands())

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
