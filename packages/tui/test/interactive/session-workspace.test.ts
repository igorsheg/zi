import { expect, test } from "bun:test"

import { BoxRenderable, parseKeypress, ScrollBoxRenderable, TextareaRenderable } from "@opentui/core"
import type { AgentSessionEvent, SubagentSnapshot, SubagentTranscriptSnapshot } from "@with-zi/coding-agent"
import { createModels, createTestAgentRuntime, fauxAssistantMessage, fauxProvider } from "@with-zi/coding-agent/testing"

import { createInteractiveTest, renderSettled } from "./harness.js"

test("/agent opens an identical read-only transcript in a golden-ratio companion pane", async () => {
  const provider = fauxProvider()
  const models = createModels()
  models.setProvider(provider.provider)
  const runtime = await createTestAgentRuntime({ cwd: "/repo", models, session: { type: "new", persist: false } })
  const setup = await createInteractiveTest(runtime.session, { width: 120, height: 30 })
  const snapshot: SubagentSnapshot = {
    name: "review-risk",
    lifecycle: "running",
    workCycle: 1,
    task: "Review the workspace.",
    elapsedMs: 1_000,
    sessionId: "child-session-id"
  }
  const transcript: SubagentTranscriptSnapshot = {
    name: snapshot.name,
    messages: [
      { role: "user", content: [{ type: "text", text: "Review the workspace." }], timestamp: 1 },
      fauxAssistantMessage("No blocking risks found.")
    ],
    activeTools: [],
    omittedMessages: 0,
    omittedBytes: 0
  }
  const retargetedSnapshot: SubagentSnapshot = {
    name: "pathfinder",
    lifecycle: "idle",
    workCycle: 1,
    task: "Inspect the layout.",
    sessionId: "second-child-session"
  }
  const retargetedTranscript: SubagentTranscriptSnapshot = {
    ...transcript,
    name: "pathfinder",
    messages: [{ role: "user", content: [{ type: "text", text: "Inspect the layout." }], timestamp: 2 }]
  }
  const subagents = installSubagents(runtime.session, [
    { snapshot, transcript },
    { snapshot: retargetedSnapshot, transcript: retargetedTranscript }
  ])

  try {
    const main = requiredBox(setup.renderer.root.findDescendantById("main-agent-pane"))
    expect(main.border).toBe(false)
    expect(main.title).toBeUndefined()

    await openAgentPicker(setup)
    let frame = setup.captureCharFrame()
    expect(frame).toContain("Subagents · Running")
    expect(frame).toContain("review-risk")
    expect(frame).not.toContain("pathfinder")
    expect(frame).toContain("Tab show all")

    setup.mockInput.pressTab()
    await renderSettled(setup)
    frame = setup.captureCharFrame()
    expect(frame).toContain("Subagents · All")
    expect(frame).toContain("review-risk")
    expect(frame).toContain("pathfinder")
    expect(frame).toContain("Tab show running")

    setup.mockInput.pressTab()
    setup.mockInput.pressEnter()
    await renderSettled(setup)

    const prompt = requiredPrompt(setup.renderer.root.findDescendantById("prompt-input"))
    const split = requiredBox(setup.renderer.root.findDescendantById("workspace-primary-secondary"))
    const primary = requiredBox(setup.renderer.root.findDescendantById("workspace-primary-secondary-first"))
    const companionHost = requiredBox(setup.renderer.root.findDescendantById("workspace-primary-secondary-second"))
    const companion = requiredBox(setup.renderer.root.findDescendantById("subagent-pane-review-risk"))
    const transcriptScroll = requiredScroll(setup.renderer.root.findDescendantById("transcript-scroll"))
    const transcriptScrollTop = transcriptScroll.scrollTop
    expect(main.parent).toBe(primary)
    expect(companion.parent).toBe(companionHost)
    expect(companion.focused).toBe(true)
    expect(prompt.focused).toBe(false)
    expect(main.border).toBe(true)
    expect(main.borderStyle).toBe("rounded")
    expect(main.title).toBe(" Main agent ")
    expect(companion.border).toBe(true)
    expect(companion.borderStyle).toBe("rounded")
    expect(setup.captureCharFrame()).toContain("Main agent")
    expect(setup.captureCharFrame()).toContain("Subagent review-risk")
    expect(primary.width / (primary.width + companion.width)).toBeGreaterThan(0.6)
    expect(primary.width / (primary.width + companion.width)).toBeLessThan(0.64)
    expect(setup.captureCharFrame()).toContain("No blocking risks found.")

    pressRawKey(setup, "\x17")
    pressRawKey(setup, "h")
    await renderSettled(setup)
    expect(prompt.focused).toBe(true)
    expect(setup.renderer.root.findDescendantById("workspace-primary-secondary")).toBe(split)
    expect(setup.renderer.root.findDescendantById("transcript-scroll")).toBe(transcriptScroll)
    expect(transcriptScroll.scrollTop).toBe(transcriptScrollTop)
    expect(main.parent).toBe(primary)
    expect(companion.parent).toBe(companionHost)

    pressRawKey(setup, "\x17")
    pressRawKey(setup, "l")
    await renderSettled(setup)
    expect(companion.focused).toBe(true)
    expect(setup.renderer.root.findDescendantById("workspace-primary-secondary")).toBe(split)
    expect(main.parent).toBe(primary)
    expect(companion.parent).toBe(companionHost)

    pressRawKey(setup, "\x17")
    pressRawKey(setup, "h")
    await renderSettled(setup)
    expect(prompt.focused).toBe(true)

    const draft = prompt.plainText
    pressRawKey(setup, "\x17")
    pressRawKey(setup, "x")
    expect(prompt.plainText).toBe(draft)

    const staleListeners = subagents.listeners()
    await openAgent(setup, 1, true)
    const retargeted = requiredBox(setup.renderer.root.findDescendantById("subagent-pane-pathfinder"))
    expect(setup.renderer.root.findDescendantById("subagent-pane-review-risk")).toBeUndefined()
    expect(retargeted.focused).toBe(true)
    expect(subagents.listenerCount()).toBe(1)
    for (const listener of staleListeners) listener({ type: "subagent_changed", name: "review-risk" })
    expect(setup.renderer.root.findDescendantById("subagent-pane-pathfinder")).toBe(retargeted)
    subagents.updateTranscript("pathfinder", {
      ...retargetedTranscript,
      messages: [...retargetedTranscript.messages, fauxAssistantMessage("Fresh child output.")]
    })
    await renderSettled(setup)
    expect(setup.captureCharFrame()).toContain("Fresh child output.")

    setup.mockInput.pressKey("q")
    await renderSettled(setup)
    expect(setup.renderer.root.findDescendantById("subagent-pane-pathfinder")).toBeUndefined()
    expect(runtime.session.subagentSnapshot("pathfinder")).toBe(retargetedSnapshot)
    expect(prompt.focused).toBe(true)
    expect(main.border).toBe(false)
    expect(main.title).toBeUndefined()
    expect(subagents.listenerCount()).toBe(0)

    await openAgent(setup, 1, true)
    subagents.remove("pathfinder")
    await renderSettled(setup)
    expect(setup.renderer.root.findDescendantById("subagent-pane-pathfinder")).toBeUndefined()
    expect(prompt.focused).toBe(true)
    expect(subagents.listenerCount()).toBe(0)
  } finally {
    runtime.session.dispose()
    setup.destroy()
  }
})

test("subagent streaming updates retain their native transcript roots", async () => {
  const provider = fauxProvider()
  const models = createModels()
  models.setProvider(provider.provider)
  const runtime = await createTestAgentRuntime({ cwd: "/repo", models, session: { type: "new", persist: false } })
  const setup = await createInteractiveTest(runtime.session, { width: 120, height: 30 })
  const snapshot: SubagentSnapshot = {
    name: "streaming-review",
    lifecycle: "running",
    workCycle: 1,
    task: "Review while streaming.",
    sessionId: "streaming-child"
  }
  const transcript: SubagentTranscriptSnapshot = {
    name: snapshot.name,
    messages: [{ role: "user", content: [{ type: "text", text: "Review while streaming." }], timestamp: 1 }],
    streamingMessage: fauxAssistantMessage("First fragment."),
    activeTools: [],
    omittedMessages: 0,
    omittedBytes: 0
  }
  const subagents = installSubagents(runtime.session, [{ snapshot, transcript }])

  try {
    await openAgent(setup)
    const streamingRoot = setup.renderer.root.findDescendantById("streaming-assistant")
    if (!streamingRoot) throw new Error("Streaming subagent root not found")

    subagents.updateTranscript(snapshot.name, {
      ...transcript,
      streamingMessage: fauxAssistantMessage("First fragment, then the second.")
    })
    await renderSettled(setup)

    expect(setup.renderer.root.findDescendantById("streaming-assistant")).toBe(streamingRoot)
    expect(setup.captureCharFrame()).toContain("First fragment, then the second.")
  } finally {
    runtime.session.dispose()
    setup.destroy()
  }
})

test("/agent can reveal retained subagents when none are running", async () => {
  const provider = fauxProvider()
  const models = createModels()
  models.setProvider(provider.provider)
  const runtime = await createTestAgentRuntime({ cwd: "/repo", models, session: { type: "new", persist: false } })
  const setup = await createInteractiveTest(runtime.session, { width: 80, height: 24 })
  const snapshot: SubagentSnapshot = {
    name: "completed-review",
    lifecycle: "idle",
    workCycle: 1,
    task: "Review the change.",
    sessionId: "completed-child"
  }
  installSubagents(runtime.session, [
    {
      snapshot,
      transcript: {
        name: snapshot.name,
        messages: [fauxAssistantMessage("Review complete.")],
        activeTools: [],
        omittedMessages: 0,
        omittedBytes: 0
      }
    }
  ])

  try {
    await openAgentPicker(setup)
    let frame = setup.captureCharFrame()
    expect(frame).toContain("Subagents · Running")
    expect(frame).toContain("No subagents are running")
    expect(frame).not.toContain("completed-review")
    expect(frame).toContain("Tab show all")

    setup.mockInput.pressTab()
    await renderSettled(setup)
    frame = setup.captureCharFrame()
    expect(frame).toContain("Subagents · All")
    expect(frame).toContain("completed-review")
    expect(frame).toContain("Tab show running")
  } finally {
    runtime.session.dispose()
    setup.destroy()
  }
})

test("/agent retains its query and selection when its scope changes", async () => {
  const provider = fauxProvider()
  const models = createModels()
  models.setProvider(provider.provider)
  const runtime = await createTestAgentRuntime({ cwd: "/repo", models, session: { type: "new", persist: false } })
  const setup = await createInteractiveTest(runtime.session, { width: 80, height: 24 })
  const entries = [
    { name: "alpha-review", lifecycle: "running" as const },
    { name: "bravo-review", lifecycle: "interrupting" as const },
    { name: "builder", lifecycle: "running" as const },
    { name: "archived", lifecycle: "idle" as const }
  ].map(({ name, lifecycle }) => ({
    snapshot: {
      name,
      lifecycle,
      workCycle: 1,
      task: `Task for ${name}.`,
      sessionId: `${name}-session`
    } satisfies SubagentSnapshot,
    transcript: {
      name,
      messages: [fauxAssistantMessage(`Transcript for ${name}.`)],
      activeTools: [],
      omittedMessages: 0,
      omittedBytes: 0
    } satisfies SubagentTranscriptSnapshot
  }))
  installSubagents(runtime.session, entries)

  try {
    await openAgentPicker(setup)
    await setup.mockInput.typeText("review")
    await renderSettled(setup)
    setup.mockInput.pressArrow("down")
    setup.mockInput.pressTab()
    await renderSettled(setup)
    const prompt = requiredPrompt(setup.renderer.root.findDescendantById("prompt-input"))
    expect(prompt.plainText).toBe("review")
    expect(setup.captureCharFrame()).toContain("Subagents · All")
    expect(setup.captureCharFrame()).not.toContain("archived")

    setup.mockInput.pressTab()
    await renderSettled(setup)
    expect(prompt.plainText).toBe("review")
    expect(setup.captureCharFrame()).not.toContain("builder")
    setup.mockInput.pressEnter()
    await renderSettled(setup)
    expect(setup.renderer.root.findDescendantById("subagent-pane-bravo-review")).toBeDefined()
  } finally {
    runtime.session.dispose()
    setup.destroy()
  }
})

test("/agent explains both empty scopes", async () => {
  const provider = fauxProvider()
  const models = createModels()
  models.setProvider(provider.provider)
  const runtime = await createTestAgentRuntime({ cwd: "/repo", models, session: { type: "new", persist: false } })
  const setup = await createInteractiveTest(runtime.session, { width: 80, height: 24 })

  try {
    await openAgentPicker(setup)
    expect(setup.captureCharFrame()).toContain("No subagents are running")
    setup.mockInput.pressTab()
    await renderSettled(setup)
    expect(setup.captureCharFrame()).toContain("No subagents have been started in this session")
  } finally {
    runtime.session.dispose()
    setup.destroy()
  }
})

test("narrow workspaces retain the tree and show only its active pane", async () => {
  const provider = fauxProvider()
  const models = createModels()
  models.setProvider(provider.provider)
  const runtime = await createTestAgentRuntime({ cwd: "/repo", models, session: { type: "new", persist: false } })
  const setup = await createInteractiveTest(runtime.session, { width: 70, height: 24 })
  const snapshot: SubagentSnapshot = {
    name: "pathfinder",
    lifecycle: "running",
    workCycle: 1,
    task: "Inspect files.",
    elapsedMs: 1_000,
    sessionId: "child-session-id"
  }
  const transcript: SubagentTranscriptSnapshot = {
    name: snapshot.name,
    messages: [{ role: "user", content: [{ type: "text", text: "Inspect files." }], timestamp: 1 }],
    activeTools: [],
    omittedMessages: 0,
    omittedBytes: 0
  }
  installSubagents(runtime.session, [{ snapshot, transcript }])

  try {
    await openAgent(setup)
    const prompt = requiredPrompt(setup.renderer.root.findDescendantById("prompt-input"))
    const split = requiredBox(setup.renderer.root.findDescendantById("workspace-primary-secondary"))
    const mainHost = requiredBox(setup.renderer.root.findDescendantById("workspace-primary-secondary-first"))
    const companionHost = requiredBox(setup.renderer.root.findDescendantById("workspace-primary-secondary-second"))
    const main = requiredBox(setup.renderer.root.findDescendantById("main-agent-pane"))
    const companion = requiredBox(setup.renderer.root.findDescendantById("subagent-pane-pathfinder"))
    expect(main.parent).toBe(mainHost)
    expect(companion.parent).toBe(companionHost)
    expect(main.visible).toBe(false)
    expect(companion.visible).toBe(true)
    expect(prompt.focused).toBe(false)
    expect(main.border).toBe(true)

    setup.resize(120, 24)
    await renderSettled(setup)
    expect(companion.visible).toBe(true)
    expect(prompt.focused).toBe(false)
    expect(setup.renderer.root.findDescendantById("workspace-primary-secondary")).toBe(split)
    setup.resize(70, 24)
    await renderSettled(setup)

    pressRawKey(setup, "\x17")
    pressRawKey(setup, "h")
    await renderSettled(setup)
    expect(prompt.focused).toBe(true)
    expect(main.visible).toBe(true)
    expect(companion.visible).toBe(false)
    expect(setup.renderer.root.findDescendantById("workspace-primary-secondary")).toBe(split)
    expect(main.parent).toBe(mainHost)
    expect(companion.parent).toBe(companionHost)

    setup.resize(120, 24)
    await renderSettled(setup)
    expect(companion.visible).toBe(true)
    expect(prompt.focused).toBe(true)
    setup.resize(70, 24)
    await renderSettled(setup)
    expect(companion.visible).toBe(false)

    pressRawKey(setup, "\x17")
    pressRawKey(setup, "l")
    await renderSettled(setup)
    expect(main.visible).toBe(false)
    expect(companion.visible).toBe(true)
    expect(prompt.focused).toBe(false)
    expect(setup.renderer.root.findDescendantById("workspace-primary-secondary")).toBe(split)
    expect(main.parent).toBe(mainHost)
    expect(companion.parent).toBe(companionHost)
  } finally {
    runtime.session.dispose()
    setup.destroy()
  }
})

async function openAgent(
  setup: Awaited<ReturnType<typeof createInteractiveTest>>,
  selectionOffset = 0,
  showAll = false
): Promise<void> {
  await openAgentPicker(setup)
  if (showAll) setup.mockInput.pressTab()
  for (let index = 0; index < selectionOffset; index++) setup.mockInput.pressArrow("down")
  setup.mockInput.pressEnter()
  await renderSettled(setup)
}

async function openAgentPicker(setup: Awaited<ReturnType<typeof createInteractiveTest>>): Promise<void> {
  await setup.mockInput.typeText("/agent")
  setup.mockInput.pressEnter()
  await renderSettled(setup)
}

function installSubagents(
  session: Parameters<typeof createInteractiveTest>[0],
  initialEntries: readonly { readonly snapshot: SubagentSnapshot; readonly transcript: SubagentTranscriptSnapshot }[]
): {
  updateTranscript(name: string, transcript: SubagentTranscriptSnapshot): void
  remove(name: string): void
  listeners(): readonly ((event: AgentSessionEvent) => void)[]
  listenerCount(): number
} {
  let entries = [...initialEntries]
  const listeners = new Set<(event: AgentSessionEvent) => void>()
  const emit = (name: string) => {
    for (const listener of listeners) listener({ type: "subagent_changed", name })
  }
  Object.defineProperties(session, {
    subagentSnapshots: { value: () => entries.map(entry => entry.snapshot) },
    subagentSnapshot: { value: (name: string) => entries.find(entry => entry.snapshot.name === name)?.snapshot },
    subagentTranscript: { value: (name: string) => entries.find(entry => entry.snapshot.name === name)?.transcript },
    subscribe: {
      value: (listener: (event: AgentSessionEvent) => void) => {
        listeners.add(listener)
        return () => listeners.delete(listener)
      }
    }
  })
  return {
    updateTranscript(name, transcript) {
      entries = entries.map(entry => (entry.snapshot.name === name ? { ...entry, transcript } : entry))
      emit(name)
    },
    remove(name) {
      entries = entries.filter(entry => entry.snapshot.name !== name)
      emit(name)
    },
    listeners: () => [...listeners],
    listenerCount: () => listeners.size
  }
}

function pressRawKey(setup: Awaited<ReturnType<typeof createInteractiveTest>>, raw: string): void {
  const parsed = parseKeypress(raw)
  if (!parsed) throw new Error(`Could not parse key: ${JSON.stringify(raw)}`)
  setup.renderer.keyInput.processParsedKey(parsed)
}

function requiredPrompt(value: unknown): TextareaRenderable {
  if (!(value instanceof TextareaRenderable)) throw new Error("Prompt input not found")
  return value
}

function requiredScroll(value: unknown): ScrollBoxRenderable {
  if (!(value instanceof ScrollBoxRenderable)) throw new Error("Transcript scroll not found")
  return value
}

function requiredBox(value: unknown): BoxRenderable {
  if (!(value instanceof BoxRenderable)) throw new Error("Workspace box not found")
  return value
}
