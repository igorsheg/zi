import { expect, test } from "bun:test"

import {
  createAgentSession,
  type AgentSession,
  type ProjectTrustSelection,
  SessionManager
} from "@with-zi/coding-agent"
import {
  createModels,
  createTestAgentRuntime as createAgentRuntime,
  fauxAssistantMessage,
  fauxProvider
} from "@with-zi/coding-agent/testing"

import { createInteractiveStore } from "../../src/interactive/interactive-store.js"
import { fileCompletionInputFromText } from "../../src/interactive/prompt/file-completion.js"
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
      inputEdit: { type: "replace", revision: 0, text: "", cursorOffset: 0 }
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
    prompt.draftChanged("/rev path", fileCompletionInputFromText("/rev path", 4))
    expect(prompt.activatePicker("/rev path", fileCompletionInputFromText("/rev path", 4))).toBe(true)
    expect(prompt.$state.get().inputEdit).toEqual({
      type: "replace",
      revision: 1,
      text: "/review path",
      cursorOffset: 8
    })
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
    session: { type: "new", persist: false },
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
    prompt.draftChanged("glob", fileCompletionInputFromText("glob", 4))
    expect(prompt.activatePicker("glob", fileCompletionInputFromText("glob", 4))).toBe(true)
    prompt.draftChanged("steer", fileCompletionInputFromText("steer", 5))
    expect(prompt.activatePicker("steer", fileCompletionInputFromText("steer", 5))).toBe(true)
    prompt.movePicker("", 1)
    expect(prompt.backPicker()).toBe(true)
    expect(prompt.$state.get().inputEdit).toMatchObject({ type: "replace", text: "steer" })
    expect(prompt.picker.presentation("steer")?.frame.id).toBe("settings")
    expect(prompt.activatePicker("steer", fileCompletionInputFromText("steer", 5))).toBe(true)
    prompt.movePicker("", 1)
    expect(prompt.activatePicker("", fileCompletionInputFromText("", 0))).toBe(true)
    expect(session.steeringMode).toBe("all")
    expect(prompt.$state.get().inputEdit).toMatchObject({ type: "replace", text: "" })
    expect(prompt.picker.presentation("")).toBeUndefined()
  } finally {
    mode.dispose()
    session.dispose()
  }
})

test("project trust choices are explicit, safe by default, and dismissible", async () => {
  const session = await createSession("project-trust-store")
  const mode = createInteractiveStore(session)
  const decisions: ProjectTrustSelection[] = []
  let dismissed = 0
  const actions: PromptSessionActions = {
    listSessions: async () => ({ sessions: [], invalid: 0, omitted: 0 }),
    startNewSession: async () => {},
    resumeSession: async () => {},
    decideProjectTrust: async selection => {
      decisions.push(selection)
    },
    dismissProjectTrust: () => {
      dismissed++
    },
    cancelReplacement: () => ({ type: "none", settled: Promise.resolve() })
  }
  const prompt = createPromptStore(mode, new SlashController(), actions)

  try {
    prompt.requestProjectTrust("/work/project")
    expect(prompt.picker.presentation("")?.selectedId).toBe("untrusted-session")
    expect(prompt.activatePicker("", fileCompletionInputFromText("", 0))).toBe(true)
    await Bun.sleep(0)
    expect(decisions).toEqual([{ type: "untrusted", persistence: "session" }])
    expect(prompt.$state.get().workflow.type).toBe("idle")

    prompt.requestProjectTrust("/work/project")
    prompt.movePicker("", 1)
    prompt.movePicker("", 1)
    expect(prompt.activatePicker("", fileCompletionInputFromText("", 0))).toBe(true)
    await Bun.sleep(0)
    expect(decisions[1]).toEqual({ type: "trusted", persistence: "saved" })

    prompt.requestProjectTrust("/work/project")
    expect(prompt.backPicker()).toBe(true)
    expect(dismissed).toBe(1)
    expect(prompt.$state.get()).toMatchObject({
      feedback: { type: "warning", message: expect.stringContaining("remains disabled") },
      workflow: { type: "idle" }
    })
  } finally {
    prompt.dispose()
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
    expect(prompt.activatePicker("", fileCompletionInputFromText("", 0))).toBe(false)
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
    decideProjectTrust: async () => {},
    dismissProjectTrust: () => {},
    cancelReplacement: () => ({ type: "cancelled", settled: cancellation.promise })
  }
  const prompt = createPromptStore(mode, new SlashController(), actions)

  try {
    expect(prompt.submit("/resume", "steer")).toBe(true)
    await Bun.sleep(0)
    expect(prompt.activatePicker("", fileCompletionInputFromText("", 0))).toBe(true)
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

test("clipboard images are validated, retained, and support image-only submission", async () => {
  const session = await createSession("clipboard-image")
  const mode = createInteractiveStore(session)
  const clipboard = { read: async () => ({ type: "image" as const, bytes: pngBytes(), mimeType: "image/png" }) }
  const prompt = createPromptStore(mode, new SlashController(), undefined, clipboard)

  try {
    expect(await prompt.pasteClipboard()).toBeUndefined()
    expect(prompt.$state.get()).toMatchObject({
      feedback: { type: "status", message: "Attached image 1 (PNG)" },
      images: [{ type: "image", mimeType: "image/png" }]
    })
    expect(prompt.submit("", "steer")).toBe(true)
    await session.waitForIdle()

    const user = session.messages.find(message => message.role === "user")
    expect(user?.content).toEqual([
      { type: "text", text: "" },
      { type: "image", mimeType: "image/png", data: Buffer.from(pngBytes()).toString("base64") }
    ])
    expect(prompt.$state.get().images).toEqual([])
  } finally {
    prompt.dispose()
    mode.dispose()
    session.dispose()
  }
})

test("clipboard images reject unsupported models, invalid bytes, and attachment overflow", async () => {
  const session = await createSession("clipboard-limits", ["text"])
  const mode = createInteractiveStore(session)
  const prompt = createPromptStore(mode, new SlashController())
  const image = { type: "image" as const, bytes: pngBytes(), mimeType: "image/png" }

  try {
    expect(prompt.attachImage(image)).toBe(false)
    expect(prompt.$state.get().feedback).toEqual({
      type: "warning",
      message: "The current model does not accept image input"
    })

    session.model.input.push("image")
    expect(prompt.attachImage({ ...image, bytes: new TextEncoder().encode("not an image") })).toBe(false)
    expect(prompt.$state.get().feedback).toEqual({
      type: "warning",
      message: "Clipboard image must be PNG, JPEG, WebP, or GIF"
    })

    for (let index = 0; index < 8; index++) expect(prompt.attachImage(image)).toBe(true)
    expect(prompt.attachImage(image)).toBe(false)
    expect(prompt.$state.get().feedback).toEqual({
      type: "error",
      message: "A prompt cannot contain more than 8 pasted images"
    })
  } finally {
    prompt.dispose()
    mode.dispose()
    session.dispose()
  }
})

test("a newer clipboard read supersedes stale completion", async () => {
  const session = await createSession("clipboard-supersede")
  const mode = createInteractiveStore(session)
  const first = deferred<{ type: "image"; bytes: Uint8Array; mimeType: string } | undefined>()
  let calls = 0
  const prompt = createPromptStore(mode, new SlashController(), undefined, {
    read: () => {
      calls++
      return calls === 1 ? first.promise : Promise.resolve({ type: "image", bytes: pngBytes(), mimeType: "image/png" })
    }
  })

  try {
    const stale = prompt.pasteClipboard()
    await prompt.pasteClipboard()
    first.resolve({ type: "image", bytes: pngBytes(), mimeType: "image/png" })
    await stale

    expect(prompt.$state.get().images).toHaveLength(1)
  } finally {
    prompt.dispose()
    mode.dispose()
    session.dispose()
  }
})

test("clipboard completion cannot attach to a replacement session", async () => {
  const first = await createSession("clipboard-first")
  const second = await createSession("clipboard-second")
  const mode = createInteractiveStore(first)
  const pending = deferred<{ type: "image"; bytes: Uint8Array; mimeType: string } | undefined>()
  const prompt = createPromptStore(mode, new SlashController(), undefined, { read: () => pending.promise })

  try {
    const paste = prompt.pasteClipboard()
    mode.replaceSession(second)
    pending.resolve({ type: "image", bytes: pngBytes(), mimeType: "image/png" })
    await paste

    expect(prompt.$state.get().images).toEqual([])
    expect(prompt.$state.get().feedback).toEqual({ type: "none" })
  } finally {
    prompt.dispose()
    mode.dispose()
    first.dispose()
    second.dispose()
  }
})

test("clearing a prompt aborts its admitted clipboard read", async () => {
  const session = await createSession("clipboard-cancel")
  const mode = createInteractiveStore(session)
  let signal: AbortSignal | undefined
  const prompt = createPromptStore(mode, new SlashController(), undefined, {
    read: currentSignal => {
      signal = currentSignal
      return new Promise((_resolve, reject) => {
        currentSignal.addEventListener("abort", () => reject(currentSignal.reason), { once: true })
      })
    }
  })

  try {
    const paste = prompt.pasteClipboard()
    prompt.clear()
    await paste
    expect(signal?.aborted).toBe(true)
    expect(prompt.$state.get().images).toEqual([])
  } finally {
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

function pngBytes(): Uint8Array {
  return Uint8Array.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
}

async function createSession(provider: string, input: ("text" | "image")[] = ["text", "image"]): Promise<AgentSession> {
  const models = createModels()
  const faux = fauxProvider({ provider, models: [{ id: "model", input }] })
  models.setProvider(faux.provider)
  return (await createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })).session
}
