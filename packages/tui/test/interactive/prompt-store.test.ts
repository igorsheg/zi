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

import type { BuiltInNoticeActions, ReloadNoticeOutcome } from "../../src/interactive/built-in-notifications.js"
import { createInteractiveStore } from "../../src/interactive/interactive-store.js"
import { fileCompletionInputFromText } from "../../src/interactive/prompt/file-completion.js"
import { createPromptStore, type PromptSessionActions } from "../../src/interactive/prompt/store.js"
import { SlashController } from "../../src/interactive/slash-controller.js"

test("prompt store restores queued text, images, and a notice without a renderer", async () => {
  const session = await createSession("restore")
  const mode = createInteractiveStore(session)
  const notices = captureBuiltInNotices()
  const prompt = createPromptStore(mode, new SlashController(), undefined, undefined, notices.actions)

  try {
    session.steer("queued text", [{ type: "image", data: "aW1hZ2U=", mimeType: "image/png" }])
    const text = prompt.restoreQueuedInputs("current draft")

    expect(text).toBe("queued text\n\ncurrent draft")
    expect(prompt.$state.get()).toEqual({
      authCeremony: undefined,
      images: [{ type: "image", data: "aW1hZ2U=", mimeType: "image/png" }],
      workflow: { type: "idle" },
      inputEdit: { type: "replace", revision: 0, text: "", cursorOffset: 0 }
    })
    expect(notices.prompt).toEqual([{ type: "info", message: "Restored 1 queued message to editor with 1 image" }])
    expect(session.queuedInputs.steering).toHaveLength(0)
  } finally {
    mode.dispose()
    session.dispose()
  }
})

test("agents command opens a read-only durable-agent picker", async () => {
  const session = await createSession("agents-picker")
  const mode = createInteractiveStore(session)
  const prompt = createPromptStore(mode, new SlashController())

  try {
    expect(prompt.submit("/agents", "steer")).toBe(true)
    expect(prompt.$state.get().workflow).toMatchObject({ type: "choosing_agent", scope: "running", snapshots: [] })
    expect(prompt.picker.presentation("")?.frame).toMatchObject({
      id: "agents",
      title: "Agents · Running",
      emptyText: "No agents are running",
      footer: "Tab show all · Esc close"
    })
  } finally {
    prompt.dispose()
    mode.dispose()
    session.dispose()
  }
})

test("resource command selection edits the composer without dispatching TUI domain work", async () => {
  const session = await createSession("resource-command")
  const mode = createInteractiveStore(session)
  const slash = new SlashController(() => ({
    extensionCommandRevision: 0,
    listExtensionCommands: () => [],
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

test("extension command dispatch is typed, local, and creates no user message", async () => {
  const session = await createSession("extension-command-store")
  const mode = createInteractiveStore(session)
  const slash = new SlashController(() => ({
    extensionCommandRevision: 1,
    listExtensionCommands: () => [
      { name: "counter", description: "Manage counter", argumentHint: "[show|increment]", extensionId: "counter" }
    ],
    listResourceCommands: () => []
  }))
  const notices = captureBuiltInNotices()
  const prompt = createPromptStore(mode, slash, undefined, undefined, notices.actions)
  let invocation: { name: string; arguments: string } | undefined
  session.invokeExtensionCommand = async (name, arguments_) => {
    invocation = { name, arguments: arguments_ }
    return "Counter: 1"
  }

  try {
    expect(prompt.submit("/counter increment", "steer")).toBe(true)
    expect(prompt.$state.get().workflow).toMatchObject({ type: "running_extension_command", name: "counter" })
    await Bun.sleep(0)
    expect(invocation).toEqual({ name: "counter", arguments: "increment" })
    expect(prompt.$state.get().workflow).toEqual({ type: "idle" })
    expect(notices.prompt).toEqual([
      { type: "progress", message: "Running /counter…" },
      { type: "info", message: "Counter: 1" }
    ])
    expect(session.messages).toEqual([])
  } finally {
    mode.dispose()
    session.dispose()
  }
})

test("compact command forwards focus without creating a user message", async () => {
  const session = await createSession("compact-store")
  const mode = createInteractiveStore(session)
  const notices = captureBuiltInNotices()
  const prompt = createPromptStore(mode, new SlashController(), undefined, undefined, notices.actions)
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
    expect(prompt.$state.get().workflow).toEqual({ type: "idle" })
    expect(notices.prompt).toEqual([
      { type: "clear" },
      { type: "info", message: "Compacted 123k → ~24k context tokens." }
    ])
  } finally {
    mode.dispose()
    session.dispose()
  }
})

test("copy command delegates the active session without creating a user message", async () => {
  const session = await createSession("copy-store")
  const mode = createInteractiveStore(session)
  const copied: Array<Pick<AgentSession, "getLastAssistantText">> = []
  const prompt = createPromptStore(mode, new SlashController(), undefined, undefined, undefined, {
    copyLastAssistant: current => copied.push(current)
  })

  try {
    expect(prompt.submit("/copy", "steer")).toBe(true)
    expect(copied).toEqual([session])
    expect(session.messages).toEqual([])
    expect(prompt.$state.get().inputEdit).toMatchObject({ type: "replace", text: "" })
    expect(prompt.$state.get().workflow).toEqual({ type: "idle" })
  } finally {
    prompt.dispose()
    mode.dispose()
    session.dispose()
  }
})

test("reload command awaits session reload, invalidates slash catalog, and reports outcome", async () => {
  const session = await createSession("reload-store")
  const mode = createInteractiveStore(session)
  let generation = 0
  let reads = 0
  let resources = [{ name: "review", description: "Review code" }]
  const slash = new SlashController(
    () => ({
      extensionCommandRevision: 0,
      listExtensionCommands: () => [],
      listResourceCommands() {
        reads++
        return resources
      }
    }),
    () => generation
  )
  const notices = captureBuiltInNotices()
  const prompt = createPromptStore(mode, slash, undefined, undefined, notices.actions)
  let reloaded = false
  session.reload = async () => {
    reloaded = true
    resources = [{ name: "deploy", description: "Deploy current project" }]
    return {
      resources: session.resources,
      extensions: {
        outcome: "replaced",
        snapshot: session.extensionHostSnapshot ?? {
          status: "disabled",
          lifecycle: "started",
          extensions: [],
          commands: [],
          tools: [],
          diagnostics: [],
          omittedDiagnostics: 0,
          staleFrames: 0,
          stdout: { text: "", retainedBytes: 0, omittedBytes: 0 },
          stderr: { text: "", retainedBytes: 0, omittedBytes: 0 }
        },
        diagnostics: [],
        omittedDiagnostics: 0
      },
      settingsErrors: []
    }
  }

  try {
    expect(slash.suggestions("/rev", 4)[0]?.name).toBe("review")
    expect(reads).toBe(1)
    expect(prompt.submit("/reload", "steer")).toBe(true)
    expect(prompt.$state.get().workflow.type).toBe("reloading")
    await Bun.sleep(0)
    expect(reloaded).toBe(true)
    expect(prompt.$state.get()).toMatchObject({ workflow: { type: "idle" } })
    expect(notices.reloads).toEqual([{ outcome: "success", message: "Reloaded settings, resources, and extensions" }])
    expect(session.messages).toEqual([])
    expect(slash.suggestions("/dep", 4)[0]?.name).toBe("deploy")
    expect(reads).toBe(2)
  } finally {
    mode.dispose()
    session.dispose()
  }
})

test("reload notice surfaces the first source-attributed diagnostic", async () => {
  const session = await createSession("reload-diagnostics")
  const mode = createInteractiveStore(session)
  const notices = captureBuiltInNotices()
  const prompt = createPromptStore(mode, new SlashController(), undefined, undefined, notices.actions)
  session.reload = async () => ({
    resources: {
      ...session.resources,
      diagnostics: [
        { type: "warning", resource: "skill", path: "/tmp/skills/broken/SKILL.md", message: "missing frontmatter" }
      ]
    },
    extensions: {
      outcome: "replaced",
      snapshot: {
        status: "ready",
        lifecycle: "started",
        extensions: [],
        commands: [],
        tools: [],
        diagnostics: [],
        omittedDiagnostics: 0,
        staleFrames: 0,
        stdout: { text: "", retainedBytes: 0, omittedBytes: 0 },
        stderr: { text: "", retainedBytes: 0, omittedBytes: 0 }
      },
      diagnostics: [
        { path: "/tmp/extensions/bad.ts", phase: "import", severity: "error", message: "Cannot find module" }
      ],
      omittedDiagnostics: 2
    },
    settingsErrors: []
  })

  try {
    expect(prompt.submit("/reload", "steer")).toBe(true)
    await Bun.sleep(0)
    expect(prompt.$state.get()).toMatchObject({ workflow: { type: "idle" } })
    expect(notices.reloads).toEqual([
      {
        outcome: "warning",
        message: "Reloaded settings, resources, and extensions: /tmp/extensions/bad.ts: Cannot find module (+3 more)"
      }
    ])
  } finally {
    mode.dispose()
    session.dispose()
  }
})

test("reload remaining count includes omitted extension diagnostics behind settings errors", async () => {
  const session = await createSession("reload-omitted-remaining")
  const mode = createInteractiveStore(session)
  const notices = captureBuiltInNotices()
  const prompt = createPromptStore(mode, new SlashController(), undefined, undefined, notices.actions)
  session.reload = async () => ({
    resources: session.resources,
    extensions: {
      outcome: "replaced",
      snapshot: {
        status: "ready",
        lifecycle: "started",
        extensions: [],
        commands: [],
        tools: [],
        diagnostics: [],
        omittedDiagnostics: 0,
        staleFrames: 0,
        stdout: { text: "", retainedBytes: 0, omittedBytes: 0 },
        stderr: { text: "", retainedBytes: 0, omittedBytes: 0 }
      },
      diagnostics: [],
      omittedDiagnostics: 2
    },
    settingsErrors: [{ scope: "global", path: "/tmp/settings.json", error: new Error("invalid json") }]
  })

  try {
    expect(prompt.submit("/reload", "steer")).toBe(true)
    await Bun.sleep(0)
    expect(prompt.$state.get()).toMatchObject({ workflow: { type: "idle" } })
    expect(notices.reloads).toEqual([
      {
        outcome: "warning",
        message: "Reloaded settings, resources, and extensions: /tmp/settings.json: invalid json (+2 more)"
      }
    ])
  } finally {
    mode.dispose()
    session.dispose()
  }
})

test("reload failures replace prompt progress with the built-in reload outcome", async () => {
  const session = await createSession("reload-failure")
  const mode = createInteractiveStore(session)
  const notices = captureBuiltInNotices()
  const prompt = createPromptStore(mode, new SlashController(), undefined, undefined, notices.actions)
  session.reload = async () => {
    throw new Error("reload exploded")
  }

  try {
    expect(prompt.submit("/reload", "steer")).toBe(true)
    expect(notices.prompt).toEqual([{ type: "progress", message: "Reloading…" }])
    await Bun.sleep(0)
    expect(prompt.$state.get()).toMatchObject({ workflow: { type: "idle" } })
    expect(notices.reloads).toEqual([{ outcome: "error", message: "reload exploded" }])
    expect(session.messages).toEqual([])
  } finally {
    mode.dispose()
    session.dispose()
  }
})

test("reload refuses while the session is streaming", async () => {
  const session = await createSession("reload-busy")
  const mode = createInteractiveStore(session)
  const notices = captureBuiltInNotices()
  const prompt = createPromptStore(mode, new SlashController(), undefined, undefined, notices.actions)
  Object.defineProperty(session, "isStreaming", { configurable: true, get: () => true })
  let reloaded = false
  session.reload = async () => {
    reloaded = true
    return { resources: session.resources, extensions: undefined, settingsErrors: [] }
  }

  try {
    expect(prompt.submit("/reload", "steer")).toBe(true)
    expect(reloaded).toBe(false)
    expect(prompt.$state.get().workflow).toEqual({ type: "idle" })
    expect(notices.prompt).toEqual([{ type: "warning", message: "Wait for the current response before reloading" }])
  } finally {
    mode.dispose()
    session.dispose()
  }
})

test("compact cancellation stays blocking until settlement and reports no error", async () => {
  const session = await createSession("compact-cancel")
  const mode = createInteractiveStore(session)
  const notices = captureBuiltInNotices()
  const prompt = createPromptStore(mode, new SlashController(), undefined, undefined, notices.actions)
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
    expect(prompt.$state.get()).toMatchObject({ workflow: { type: "idle" } })
    expect(notices.prompt).toEqual([{ type: "clear" }, { type: "clear" }])
  } finally {
    mode.dispose()
    session.dispose()
  }
})

test("automatic compaction failures do not publish prompt notices", async () => {
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
  const notices = captureBuiltInNotices()
  const prompt = createPromptStore(mode, new SlashController(), undefined, undefined, notices.actions)

  try {
    expect(prompt.submit("continue", "steer")).toBe(true)
    await session.waitForIdle()

    expect(notices.prompt).toEqual([{ type: "clear" }])
    expect(session.sessionManager.latestCompaction()).toBeUndefined()
  } finally {
    prompt.dispose()
    mode.dispose()
    session.dispose()
  }
})

test("Codex settings use two picker frames and persist Fast Mode through AgentSession", async () => {
  const session = await createSession("codex-settings-store")
  const mode = createInteractiveStore(session)
  const notices = captureBuiltInNotices()
  const prompt = createPromptStore(mode, new SlashController(), undefined, undefined, notices.actions)

  try {
    expect(prompt.submit("/codex-settings", "steer")).toBe(true)
    expect(prompt.picker.presentation("")).toMatchObject({
      depth: 1,
      frame: { id: "codex-settings" },
      selectedId: "fast-mode"
    })
    expect(prompt.activatePicker("", fileCompletionInputFromText("", 0))).toBe(true)
    expect(prompt.picker.presentation("")).toMatchObject({
      depth: 2,
      frame: { id: "codex-setting-values" },
      selectedId: "false"
    })

    expect(prompt.backPicker()).toBe(true)
    expect(prompt.$state.get().inputEdit).toMatchObject({ type: "replace", text: "" })
    expect(prompt.picker.presentation("")?.frame.id).toBe("codex-settings")
    expect(prompt.activatePicker("", fileCompletionInputFromText("", 0))).toBe(true)
    prompt.movePicker("", 1)
    expect(prompt.activatePicker("", fileCompletionInputFromText("", 0))).toBe(true)

    expect(session.settingsManager.getGlobal().codexFastMode).toBe(true)
    expect(session.settingsManager.get().codexFastMode).toBe(true)
    expect(prompt.$state.get().workflow).toMatchObject({ type: "choosing_codex_setting" })
    expect(prompt.$state.get().inputEdit).toMatchObject({ type: "replace", text: "" })
    expect(notices.prompt.at(-1)).toEqual({ type: "info", message: "Codex Fast mode: On" })
    expect(prompt.picker.presentation("")).toMatchObject({
      frame: { id: "codex-settings" },
      rows: [{ id: "fast-mode", detail: "[On]" }]
    })
  } finally {
    prompt.dispose()
    mode.dispose()
    session.dispose()
  }
})

test("settings workflow restores suspended filters after a value commits", async () => {
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
    expect(prompt.$state.get().workflow).toMatchObject({ type: "choosing_setting", scope: "global" })
    expect(prompt.$state.get().inputEdit).toMatchObject({ type: "replace", text: "steer" })
    expect(prompt.picker.presentation("steer")).toMatchObject({
      frame: { id: "settings" },
      rows: [{ id: "steeringMode", detail: "[all]", metadata: "Effective: all" }],
      selectedId: "steeringMode"
    })
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
    expect(prompt.$state.get()).toMatchObject({ workflow: { type: "idle" } })
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
  const notices = captureBuiltInNotices()
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
  const prompt = createPromptStore(mode, new SlashController(), actions, undefined, notices.actions)

  try {
    expect(prompt.submit("/resume", "steer")).toBe(true)
    await Bun.sleep(0)
    expect(prompt.activatePicker("", fileCompletionInputFromText("", 0))).toBe(true)
    expect(prompt.$state.get().workflow.type).toBe("resuming_session")

    expect(prompt.abortAndRestoreQueuedInputs("")).toBe("")
    expect(prompt.$state.get().workflow).toMatchObject({ type: "cancelling_session" })
    expect(notices.prompt.at(-1)).toEqual({ type: "progress", message: "Cancelling session change…" })

    resume.reject(new Error("Session replacement was cancelled"))
    cancellation.resolve()
    await Bun.sleep(0)
    expect(prompt.$state.get()).toMatchObject({ workflow: { type: "idle" } })
    expect(notices.prompt.at(-1)).toEqual({ type: "clear" })
  } finally {
    cancellation.resolve()
    prompt.dispose()
    mode.dispose()
    session.dispose()
  }
})

test("disposing a session replacement cannot republish stale prompt progress", async () => {
  const session = await createSession("session-disposal")
  const mode = createInteractiveStore(session)
  const replacement = deferred<void>()
  const cancellation = deferred<void>()
  const notices = captureBuiltInNotices()
  const actions: PromptSessionActions = {
    listSessions: async () => ({ sessions: [], invalid: 0, omitted: 0 }),
    startNewSession: () => replacement.promise,
    resumeSession: async () => {},
    decideProjectTrust: async () => {},
    dismissProjectTrust: () => {},
    cancelReplacement: () => ({ type: "cancelled", settled: cancellation.promise })
  }
  const prompt = createPromptStore(mode, new SlashController(), actions, undefined, notices.actions)

  try {
    expect(prompt.submit("/new", "steer")).toBe(true)
    expect(notices.prompt).toEqual([{ type: "progress", message: "Starting new session…" }])

    notices.prompt.length = 0
    prompt.dispose()
    expect(notices.prompt).toEqual([])

    replacement.resolve()
    cancellation.resolve()
    await Bun.sleep(0)
    expect(notices.prompt).toEqual([])
  } finally {
    replacement.resolve()
    cancellation.resolve()
    mode.dispose()
    session.dispose()
  }
})

test("clipboard images are validated, retained, and support image-only submission", async () => {
  const session = await createSession("clipboard-image")
  const mode = createInteractiveStore(session)
  const clipboard = { read: async () => ({ type: "image" as const, bytes: pngBytes(), mimeType: "image/png" }) }
  const notices = captureBuiltInNotices()
  const prompt = createPromptStore(mode, new SlashController(), undefined, clipboard, notices.actions)

  try {
    expect(await prompt.pasteClipboard()).toBeUndefined()
    expect(prompt.$state.get()).toMatchObject({ images: [{ type: "image", mimeType: "image/png" }] })
    expect(notices.prompt.at(-1)).toEqual({ type: "info", message: "Attached image 1 (PNG)" })
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
  const notices = captureBuiltInNotices()
  const prompt = createPromptStore(mode, new SlashController(), undefined, undefined, notices.actions)
  const image = { type: "image" as const, bytes: pngBytes(), mimeType: "image/png" }

  try {
    expect(prompt.attachImage(image)).toBe(false)
    expect(notices.prompt.at(-1)).toEqual({ type: "warning", message: "The current model does not accept image input" })

    session.model.input.push("image")
    expect(prompt.attachImage({ ...image, bytes: new TextEncoder().encode("not an image") })).toBe(false)
    expect(notices.prompt.at(-1)).toEqual({
      type: "warning",
      message: "Clipboard image must be PNG, JPEG, WebP, or GIF"
    })

    for (let index = 0; index < 8; index++) expect(prompt.attachImage(image)).toBe(true)
    expect(prompt.attachImage(image)).toBe(false)
    expect(notices.prompt.at(-1)).toEqual({
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

test("prompt store retains rejected input and publishes the admission error", async () => {
  const session = await createSession("disposed")
  const mode = createInteractiveStore(session)
  const notices = captureBuiltInNotices()
  const prompt = createPromptStore(mode, new SlashController(), undefined, undefined, notices.actions)

  session.dispose()
  expect(prompt.submit("keep this", "steer")).toBe(false)
  expect(notices.prompt).toEqual([{ type: "error", message: "AgentSession is disposed" }])

  mode.dispose()
})

type PromptNotice =
  | { readonly type: "progress" | "info" | "warning" | "error"; readonly message: string }
  | { readonly type: "clear" }

function captureBuiltInNotices(): {
  readonly actions: BuiltInNoticeActions
  readonly prompt: PromptNotice[]
  readonly reloads: { readonly outcome: ReloadNoticeOutcome; readonly message: string }[]
} {
  const prompt: PromptNotice[] = []
  const reloads: { outcome: ReloadNoticeOutcome; message: string }[] = []
  return {
    actions: {
      promptProgress: message => prompt.push({ type: "progress", message }),
      promptInfo: message => prompt.push({ type: "info", message }),
      promptWarning: message => prompt.push({ type: "warning", message }),
      promptError: message => prompt.push({ type: "error", message }),
      clearPrompt: () => prompt.push({ type: "clear" }),
      backgroundTaskCapacityExceeded() {},
      reloadCompleted: (outcome, message) => reloads.push({ outcome, message }),
      reloadFailed: message => reloads.push({ outcome: "error", message })
    },
    prompt,
    reloads
  }
}

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
