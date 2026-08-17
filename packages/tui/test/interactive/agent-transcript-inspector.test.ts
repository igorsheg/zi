import { expect, test } from "bun:test"

import { createTestRenderer } from "@opentui/core/testing"
import {
  parseAgentPath,
  type AgentTranscriptEvent,
  type AgentTranscriptLease,
  type AgentTranscriptSnapshot
} from "@with-zi/coding-agent"

import {
  AgentTranscriptInspector,
  type AgentTranscriptInspectorSession,
  type AgentTranscriptInspectorWorkspace
} from "../../src/interactive/agent-transcript-inspector.js"
import { InteractiveKeybindings } from "../../src/interactive/interactive-keybindings.js"
import { createSyntaxStyle, defaultTheme } from "../../src/theme.js"
import { renderSettled } from "./harness.js"

const path = parseAgentPath("/root/research")
const parentPath = parseAgentPath("/root")

class TranscriptLease implements AgentTranscriptLease {
  readonly path = path
  readonly #listeners = new Set<(event: AgentTranscriptEvent) => void>()
  disposed = false

  snapshot(): AgentTranscriptSnapshot {
    if (this.disposed) throw new Error("disposed")
    return {
      agent: {
        path,
        parentPath,
        sessionId: "research-session",
        taskName: "research",
        agentType: "explorer",
        generation: 1,
        residency: "unloaded",
        turn: "idle",
        turnNumber: 1,
        status: "completed"
      },
      messages: [{ role: "user", content: "durable child text", timestamp: 1 }],
      streamingMessage: undefined,
      isStreaming: false,
      isAborting: false,
      retryStatus: { type: "idle" },
      compactionStatus: { type: "idle" },
      workPlan: { revision: 0, steps: [] },
      shellTasks: []
    }
  }

  subscribe(listener: (event: AgentTranscriptEvent) => void): () => void {
    this.#listeners.add(listener)
    return () => this.#listeners.delete(listener)
  }

  dispose(): void {
    this.disposed = true
    this.#listeners.clear()
  }
}

class Workspace implements AgentTranscriptInspectorWorkspace {
  suspended = 0
  resumed = 0

  suspendPresentation(): void {
    this.suspended++
  }

  resumePresentation(): void {
    this.resumed++
  }
}

test("agent transcript inspector paints loading before I/O and restores the root on Escape", async () => {
  const setup = await createTestRenderer({
    width: 80,
    height: 18,
    useThread: false,
    kittyKeyboard: true,
    exitOnCtrlC: false
  })
  const syntaxStyle = createSyntaxStyle(defaultTheme)
  const workspace = new Workspace()
  const opened = deferred<AgentTranscriptLease>()
  let loads = 0
  const session = fakeSession(() => {
    loads++
    return opened.promise
  })
  const inspector = new AgentTranscriptInspector(
    setup.renderer,
    () => session,
    workspace,
    new InteractiveKeybindings(),
    defaultTheme,
    syntaxStyle
  )
  setup.renderer.root.add(inspector.root)

  try {
    inspector.open(path)
    expect(inspector.state.type).toBe("loading")
    expect(loads).toBe(0)
    expect(workspace.suspended).toBe(1)

    await setup.renderOnce()
    expect(loads).toBe(1)
    expect(setup.captureCharFrame()).toContain("Loading agent transcript…")

    const lease = new TranscriptLease()
    opened.resolve(lease)
    await renderSettled(setup)
    expect(inspector.state.type).toBe("viewing")
    const frame = setup.captureCharFrame()
    expect(frame).toContain("root › research")
    expect(frame).toContain("explorer · completed · turn 1")
    expect(frame).toContain("durable child text")
    expect(frame).toContain("Esc return to root · Read-only agent transcript")
    expect(setup.renderer.root.findDescendantById("agent-inspector-transcript-scroll")).toBeDefined()

    setup.resize(32, 8)
    await renderSettled(setup)
    const narrow = setup.captureCharFrame()
    expect(narrow).toContain("completed · #1")
    expect(narrow).toContain("Esc return to root")

    setup.mockInput.pressEscape()
    await renderSettled(setup)
    expect(inspector.state).toEqual({ type: "root" })
    expect(workspace.resumed).toBe(1)
    expect(lease.disposed).toBe(true)
    expect(inspector.root.visible).toBe(false)
  } finally {
    inspector.dispose()
    syntaxStyle.destroy()
    setup.renderer.destroy()
  }
})

test("agent transcript inspector rejects a stale completion after loading is cancelled", async () => {
  const setup = await createTestRenderer({
    width: 42,
    height: 10,
    useThread: false,
    kittyKeyboard: true,
    exitOnCtrlC: false
  })
  const syntaxStyle = createSyntaxStyle(defaultTheme)
  const workspace = new Workspace()
  const opened = deferred<AgentTranscriptLease>()
  const session = fakeSession(() => opened.promise)
  const inspector = new AgentTranscriptInspector(
    setup.renderer,
    () => session,
    workspace,
    new InteractiveKeybindings(),
    defaultTheme,
    syntaxStyle
  )
  setup.renderer.root.add(inspector.root)

  try {
    inspector.open(path)
    await setup.renderOnce()
    setup.mockInput.pressEscape()
    await renderSettled(setup)
    const lease = new TranscriptLease()
    opened.resolve(lease)
    await Promise.resolve()
    expect(inspector.state).toEqual({ type: "root" })
    expect(lease.disposed).toBe(true)
    expect(workspace.resumed).toBe(1)
  } finally {
    inspector.dispose()
    syntaxStyle.destroy()
    setup.renderer.destroy()
  }
})

test("agent transcript inspector keeps load failures focused and bounded at narrow widths", async () => {
  const setup = await createTestRenderer({
    width: 32,
    height: 8,
    useThread: false,
    kittyKeyboard: true,
    exitOnCtrlC: false
  })
  const syntaxStyle = createSyntaxStyle(defaultTheme)
  const workspace = new Workspace()
  const session = fakeSession(() =>
    Promise.reject(new Error(`The durable child journal is unavailable. ${"x".repeat(3_000)}`))
  )
  const inspector = new AgentTranscriptInspector(
    setup.renderer,
    () => session,
    workspace,
    new InteractiveKeybindings(),
    defaultTheme,
    syntaxStyle
  )
  setup.renderer.root.add(inspector.root)

  try {
    inspector.open(path)
    await renderSettled(setup)
    expect(inspector.state).toMatchObject({ type: "failed", path })
    const frame = setup.captureCharFrame()
    expect(frame).toContain("Agent transcript unavailable.")
    expect(frame).toContain("Esc return to root")
    expect(inspector.root.focused).toBe(true)

    setup.resize(32, 4)
    await renderSettled(setup)
    const compact = setup.captureCharFrame()
    expect(compact).toContain("The durable child journal is")
    expect(compact).toContain("unavailable.")
    expect(compact).toContain("Esc return to root")
    expect(compact).not.toContain("journalrunavailable")

    setup.mockInput.pressEscape()
    await renderSettled(setup)
    expect(workspace.resumed).toBe(1)
  } finally {
    inspector.dispose()
    syntaxStyle.destroy()
    setup.renderer.destroy()
  }
})

function fakeSession(open: AgentTranscriptInspectorSession["openAgentTranscript"]): AgentTranscriptInspectorSession {
  const snapshot = new TranscriptLease().snapshot().agent
  return { sessionManager: { header: { cwd: "/work" } }, agentSnapshots: () => [snapshot], openAgentTranscript: open }
}

function deferred<Value>() {
  let resolve!: (value: Value | PromiseLike<Value>) => void
  const promise = new Promise<Value>(resolvePromise => {
    resolve = resolvePromise
  })
  return { promise, resolve }
}
