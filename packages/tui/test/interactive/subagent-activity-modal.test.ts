import { expect, test } from "bun:test"

import { BoxRenderable, type Renderable, RGBA, TextareaRenderable, TextRenderable } from "@opentui/core"
import { createTestRenderer } from "@opentui/core/testing"
import type { AgentSessionEvent, SubagentSessionEvents, SubagentSnapshot } from "@with-zi/coding-agent"
import { createModels, createTestAgentRuntime, fauxProvider } from "@with-zi/coding-agent/testing"

import { InteractiveKeybindings } from "../../src/interactive/interactive-keybindings.js"
import { scrimColor } from "../../src/interactive/modal-layer.js"
import {
  activityStatus,
  panelRows,
  SubagentActivityModalView,
  subagentActivityRows
} from "../../src/interactive/subagent-activity-modal.js"
import { defaultTheme } from "../../src/theme.js"
import { createInteractiveTest, renderSettled } from "./harness.js"

test("activity rows speak the transcript tool vocabulary instead of protocol events", () => {
  const rows = subagentActivityRows(
    runningSnapshot(),
    events([
      { type: "agent_start" },
      {
        type: "tool_execution_start",
        toolCallId: "call-1",
        toolName: "read",
        args: { path: "/repo/packages/tui/src/interactive/modal-layer.ts" }
      },
      {
        type: "tool_execution_start",
        toolCallId: "call-2",
        toolName: "bash",
        args: { command: "bun run --filter @with-zi/tui test" }
      },
      { type: "unknown_internal_packet", secret: "do not render" }
    ]),
    { width: 80, maxRows: 12, cwd: "/repo" }
  )

  expect(rows).toEqual([
    { kind: "action", status: "running", text: "Read modal-layer.ts" },
    { kind: "action", status: "running", text: "Run bun run --filter @with-zi/tui test" }
  ])
})

test("a tool call keeps one row and is settled in place when it ends", () => {
  const rows = subagentActivityRows(
    runningSnapshot(),
    events([
      { type: "tool_execution_start", toolCallId: "call-1", toolName: "read", args: { path: "notes.md" } },
      { type: "tool_execution_end", toolCallId: "call-1", isError: false, result: "ok" },
      { type: "tool_execution_start", toolCallId: "call-2", toolName: "bash", args: { command: "bun test" } },
      { type: "tool_execution_end", toolCallId: "call-2", isError: true, result: "exit 1" },
      { type: "tool_execution_start", toolCallId: "call-3", toolName: "bash", args: { command: "bun run build" } }
    ]),
    { width: 80, maxRows: 12, cwd: "/repo" }
  )

  expect(rows).toEqual([
    { kind: "action", status: "done", text: "Read notes.md" },
    { kind: "action", status: "failed", text: "Run bun test" },
    { kind: "action", status: "running", text: "Run bun run build" }
  ])
})

test("a repeated tool_execution_start for the same call does not duplicate its row", () => {
  const rows = subagentActivityRows(
    runningSnapshot(),
    events([
      { type: "tool_execution_start", toolCallId: "call-1", toolName: "read", args: { path: "notes.md" } },
      { type: "tool_execution_start", toolCallId: "call-1", toolName: "read", args: { path: "notes.md" } }
    ]),
    { width: 80, maxRows: 12 }
  )

  expect(rows).toHaveLength(1)
})

test("streaming assistant text replaces its block and omits the child's own tool parts", () => {
  const rows = subagentActivityRows(
    runningSnapshot(),
    events([
      { type: "message_start", message: { role: "assistant", content: [] } },
      { type: "message_update", message: assistantMessage("Modal ownership") },
      {
        type: "message_update",
        message: {
          role: "assistant",
          content: [
            { type: "thinking", thinking: "never rendered here" },
            { type: "text", text: "Modal ownership is clean." },
            { type: "toolCall", toolCallId: "call-1", toolName: "read", args: { path: "notes.md" } }
          ]
        }
      },
      { type: "tool_execution_start", toolCallId: "call-1", toolName: "read", args: { path: "notes.md" } }
    ]),
    { width: 80, maxRows: 12, cwd: "/repo" }
  )

  expect(rows).toEqual([
    { kind: "prose", text: "Modal ownership is clean." },
    { kind: "action", status: "running", text: "Read notes.md" }
  ])
})

test("a new assistant message starts a new prose block", () => {
  const rows = subagentActivityRows(
    runningSnapshot(),
    events([
      { type: "message_start", message: { role: "assistant", content: [] } },
      { type: "message_end", message: assistantMessage("First answer.") },
      { type: "message_start", message: { role: "assistant", content: [] } },
      { type: "message_end", message: assistantMessage("Second answer.") }
    ]),
    { width: 80, maxRows: 12 }
  )

  expect(rows).toEqual([
    { kind: "prose", text: "First answer." },
    { kind: "prose", text: "Second answer." }
  ])
})

test("the visible tail is bounded and marks omission with a single row", () => {
  const rows = subagentActivityRows(
    runningSnapshot(),
    events(
      Array.from({ length: 12 }, (_, index) => ({
        type: "tool_execution_start",
        toolCallId: `call-${index + 1}`,
        toolName: "bash",
        args: { command: `step ${index + 1}` }
      }))
    ),
    { width: 80, maxRows: 5 }
  )

  expect(rows).toHaveLength(5)
  expect(rows[0]).toEqual({ kind: "meta", text: "…" })
  expect(rows.at(-1)).toEqual({ kind: "action", status: "running", text: "Run step 12" })
  expect(rows.some(row => row.text.includes("step 8"))).toBe(false)
})

test("retained-buffer omission marks the tail even when every row fits", () => {
  const snapshot = runningSnapshot()
  const rows = subagentActivityRows(
    snapshot,
    { name: snapshot.name, omittedEvents: 7, omittedBytes: 4096, events: [] },
    { width: 80, maxRows: 12 }
  )

  expect(rows[0]).toEqual({ kind: "meta", text: "…" })
})

test("long prose wraps to the modal width and keeps its tail", () => {
  const rows = subagentActivityRows(
    runningSnapshot(),
    events([{ type: "message_end", message: assistantMessage("word ".repeat(40).trim()) }]),
    { width: 20, maxRows: 3 }
  )

  expect(rows).toHaveLength(3)
  expect(rows[0]).toEqual({ kind: "meta", text: "…" })
  for (const row of rows.slice(1)) expect(row.text.length).toBeLessThanOrEqual(20)
})

test("completion contributes its result text and error without restating the status", () => {
  const rows = subagentActivityRows(
    completedSnapshot({
      status: "failed",
      text: "Stopped after the first failing check.",
      error: "child exited with code 1"
    }),
    events([{ type: "agent_start" }, { type: "agent_settled" }]),
    { width: 80, maxRows: 12 }
  )

  expect(rows).toEqual([
    { kind: "prose", text: "Stopped after the first failing check." },
    { kind: "error", text: "child exited with code 1" }
  ])
})

test("completion replaces retained final assistant prose instead of duplicating it", () => {
  const text = "No blocking regressions found."
  const rows = subagentActivityRows(
    completedSnapshot({ status: "completed", text }),
    events([{ type: "message_end", message: assistantMessage(text) }]),
    { width: 80, maxRows: 12 }
  )

  expect(rows).toEqual([{ kind: "prose", text }])
})

test("an empty completion says so rather than leaving the modal blank", () => {
  const rows = subagentActivityRows(completedSnapshot({ status: "completed", text: "  " }), events([]), {
    width: 80,
    maxRows: 12
  })

  expect(rows).toEqual([{ kind: "meta", text: "no result text" }])
})

test("a child that has not produced output yet reports no activity", () => {
  const rows = subagentActivityRows(runningSnapshot(), undefined, { width: 80, maxRows: 12 })

  expect(rows).toEqual([{ kind: "meta", text: "no activity yet" }])
})

test("an auto retry is visible so a stalled child is explainable", () => {
  const rows = subagentActivityRows(
    runningSnapshot(),
    events([{ type: "auto_retry_start", attempt: 2, maxAttempts: 3, delayMs: 1000, errorMessage: "overloaded" }]),
    { width: 80, maxRows: 12 }
  )

  expect(rows).toEqual([{ kind: "meta", text: "retrying 2/3" }])
})

test("the dialog title owns lifecycle and duration wording", () => {
  expect(activityStatus(runningSnapshot())).toEqual({ label: "working", elapsed: "12s" })
  expect(activityStatus({ ...runningSnapshot(), lifecycle: "starting", elapsedMs: 400 })).toEqual({
    label: "starting",
    elapsed: "0s"
  })
  expect(activityStatus({ ...idleSnapshot() })).toEqual({ label: "idle", elapsed: "" })
  expect(activityStatus(completedSnapshot({ status: "cancelled", text: "" }))).toEqual({
    label: "cancelled",
    elapsed: "1m 5s"
  })

  const previous = completedSnapshot({ status: "completed", text: "Previous result." })
  expect(activityStatus({ ...previous, lifecycle: "interrupting", workCycle: 2, elapsedMs: 3_000 })).toEqual({
    label: "interrupting",
    elapsed: "3s"
  })
  expect(activityStatus({ ...previous, lifecycle: "closing", workCycle: 2, elapsedMs: 4_000 })).toEqual({
    label: "closing",
    elapsed: "4s"
  })
})

test("a reused child presents its active cycle instead of an older pending completion", () => {
  const previous = completedSnapshot({ status: "completed", text: "First cycle result." })
  const snapshot: SubagentSnapshot = {
    ...previous,
    lifecycle: "running",
    workCycle: 2,
    task: "Review the updated implementation.",
    elapsedMs: 3_000
  }
  const history: SubagentSessionEvents = {
    name: snapshot.name,
    omittedEvents: 0,
    omittedBytes: 0,
    events: [
      ...events(
        [{ type: "tool_execution_start", toolCallId: "old", toolName: "bash", args: { command: "old check" } }],
        1
      ).events,
      ...events(
        [{ type: "tool_execution_start", toolCallId: "new", toolName: "bash", args: { command: "new check" } }],
        2
      ).events
    ]
  }

  expect(activityStatus(snapshot)).toEqual({ label: "working", elapsed: "3s" })
  expect(subagentActivityRows(snapshot, history, { width: 80, maxRows: 12 })).toEqual([
    { kind: "action", status: "running", text: "Run new check" }
  ])
})

test("an exited reused child keeps the terminal cycle separate from older completion evidence", () => {
  const previous = completedSnapshot({ status: "completed", text: "First cycle result." })
  const snapshot: SubagentSnapshot = { ...previous, lifecycle: "exited", workCycle: 2 }
  const history: SubagentSessionEvents = {
    name: snapshot.name,
    omittedEvents: 0,
    omittedBytes: 0,
    events: [
      ...events([{ type: "message_end", message: assistantMessage("First cycle result.") }], 1).events,
      ...events([{ type: "message_end", message: assistantMessage("Second cycle terminal activity.") }], 2).events
    ]
  }

  expect(activityStatus(snapshot)).toEqual({ label: "exited", elapsed: "" })
  expect(subagentActivityRows(snapshot, history, { width: 80, maxRows: 12 })).toEqual([
    { kind: "prose", text: "Second cycle terminal activity." }
  ])
})

test("the dialog keeps a stable share of the terminal instead of following its content", () => {
  expect(panelRows(80)).toBe(18)
  expect(panelRows(40)).toBe(16)
  expect(panelRows(30)).toBe(12)
  expect(panelRows(20)).toBe(10)
  expect(panelRows(12)).toBe(10)
  expect(panelRows(6)).toBe(6)
  expect(panelRows(3)).toBe(3)
})

test("the dialog frame carries identity and the close affordance without spending content rows", async () => {
  const setup = await createTestRenderer({ width: 46, height: 25, useThread: false })
  const view = new SubagentActivityModalView(setup.renderer, new InteractiveKeybindings(), defaultTheme)
  setup.renderer.root.add(view.root)

  try {
    view.update(
      runningSnapshot(),
      events([
        { type: "tool_execution_start", toolCallId: "call-1", toolName: "read", args: { path: "notes.md" } },
        { type: "message_end", message: assistantMessage("Ownership is clean.") }
      ]),
      "/repo"
    )
    await setup.renderOnce()

    // Fixed height: identity on the top rule, the task under it, the activity
    // tail filling downward, and the close affordance on the bottom rule.
    expect(frameRows(setup.captureCharFrame(), panelRows(25))).toEqual([
      "╭─ review-risk · working · 12s ──────────────╮",
      "│ Review the subagent activity modal for ... │",
      "│ ◈ Read notes.md                            │",
      "│ Ownership is clean.                        │",
      "│                                            │",
      "│                                            │",
      "│                                            │",
      "│                                            │",
      "│                                            │",
      "╰──────────────────────────────── esc close ─╯"
    ])
  } finally {
    view.destroy()
    setup.renderer.destroy()
  }
})

test("resizing reprojects the unchanged task at the new width", async () => {
  const setup = await createTestRenderer({ width: 60, height: 25, useThread: false })
  const view = new SubagentActivityModalView(setup.renderer, new InteractiveKeybindings(), defaultTheme)
  setup.renderer.root.add(view.root)

  try {
    view.update(runningSnapshot(), undefined, "/repo")
    await setup.renderOnce()
    const wideTask = frameRows(setup.captureCharFrame(), panelRows(25))[1]!

    setup.resize(30, 25)
    view.update(runningSnapshot(), undefined, "/repo")
    await setup.renderOnce()
    const narrowTask = frameRows(setup.captureCharFrame(), panelRows(25))[1]!

    expect(wideTask).toContain("production reg")
    expect(narrowTask).not.toContain("production reg")
    expect(narrowTask).toEndWith("... │")
    expect(narrowTask.length).toBeLessThan(wideTask.length)
  } finally {
    view.destroy()
    setup.renderer.destroy()
  }
})

test("the dialog height follows the terminal, not the child's output", async () => {
  const setup = await createTestRenderer({ width: 46, height: 25, useThread: false })
  const view = new SubagentActivityModalView(setup.renderer, new InteractiveKeybindings(), defaultTheme)
  setup.renderer.root.add(view.root)

  try {
    view.update(runningSnapshot(), undefined, "/repo")
    await setup.renderOnce()
    const empty = view.root.height

    view.update(
      runningSnapshot(),
      events(
        Array.from({ length: 40 }, (_, index) => ({
          type: "tool_execution_start",
          toolCallId: `call-${index}`,
          toolName: "bash",
          args: { command: `step ${index}` }
        }))
      ),
      "/repo"
    )
    await setup.renderOnce()

    expect(view.root.height).toBe(empty)
    expect(empty).toBe(panelRows(25))
  } finally {
    view.destroy()
    setup.renderer.destroy()
  }
})

test("the modal keeps stable rows and only reassigns the rows whose presentation changed", async () => {
  const setup = await createTestRenderer({ width: 46, height: 25, useThread: false })
  const view = new SubagentActivityModalView(setup.renderer, new InteractiveKeybindings(), defaultTheme)
  setup.renderer.root.add(view.root)

  try {
    const first = events([
      { type: "tool_execution_start", toolCallId: "call-1", toolName: "read", args: { path: "notes.md" } },
      { type: "message_end", message: assistantMessage("Reading.") }
    ])
    view.update(runningSnapshot(), first, "/repo")
    await setup.renderOnce()

    const body = view.root.getChildren()[1]!
    const rows = body.getChildren()
    const rowCount = body.getChildrenCount()
    const actionRow = textRow(rows[0])
    const proseRow = textRow(rows[1])
    const actionContent = actionRow.content

    view.update(
      runningSnapshot(),
      events([
        { type: "tool_execution_start", toolCallId: "call-1", toolName: "read", args: { path: "notes.md" } },
        { type: "message_end", message: assistantMessage("Reading. Ownership is clean.") }
      ]),
      "/repo"
    )
    await setup.renderOnce()

    expect(body.getChildrenCount()).toBe(rowCount)
    expect(body.getChildren()[0]).toBe(actionRow)
    expect(body.getChildren()[1]).toBe(proseRow)
    expect(actionRow.content).toBe(actionContent)
    expect(frameRows(setup.captureCharFrame(), panelRows(25))[3]).toContain("Reading. Ownership is clean.")
  } finally {
    view.destroy()
    setup.renderer.destroy()
  }
})

test("the modal bounds its retained rows regardless of how much the child produces", async () => {
  const setup = await createTestRenderer({ width: 46, height: 40, useThread: false })
  const view = new SubagentActivityModalView(setup.renderer, new InteractiveKeybindings(), defaultTheme)
  setup.renderer.root.add(view.root)

  try {
    view.update(
      runningSnapshot(),
      events(
        Array.from({ length: 400 }, (_, index) => ({
          type: "tool_execution_start",
          toolCallId: `call-${index}`,
          toolName: "bash",
          args: { command: `step ${index}` }
        }))
      ),
      "/repo"
    )
    await setup.renderOnce()

    expect(view.root.getChildrenCount()).toBe(2)
    const body = view.root.getChildren()[1]!
    expect(body.getChildrenCount()).toBe(15)
    const frame = frameRows(setup.captureCharFrame(), panelRows(40))
    expect(frame[0]).toStartWith("╭─ review-risk · working · 12s ─")
    expect(frame[2]).toBe("│ …                                          │")
    expect(frame.at(-2)).toBe("│ ◈ Run step 399                             │")
    expect(frame.at(-1)).toEndWith(" esc close ─╯")
  } finally {
    view.destroy()
    setup.renderer.destroy()
  }
})

test("the backdrop dims the session behind the dialog and leaves the dialog itself opaque", async () => {
  const setup = await createTestRenderer({ width: 46, height: 25, useThread: false })
  const session = new BoxRenderable(setup.renderer, {
    width: "100%",
    height: "100%",
    backgroundColor: defaultTheme.surface.app
  })
  session.add(
    new TextRenderable(setup.renderer, { content: "transcript line", fg: defaultTheme.text.primary, height: 1 })
  )
  setup.renderer.root.add(session)

  const layer = new BoxRenderable(setup.renderer, {
    position: "absolute",
    top: 0,
    left: 0,
    width: "100%",
    height: "100%",
    zIndex: 1000,
    shouldFill: true,
    backgroundColor: scrimColor(defaultTheme.surface.app),
    justifyContent: "flex-end",
    alignItems: "stretch"
  })
  const view = new SubagentActivityModalView(setup.renderer, new InteractiveKeybindings(), defaultTheme)
  layer.add(view.root)
  setup.renderer.root.add(layer)

  try {
    view.update(
      runningSnapshot(),
      events([{ type: "message_end", message: assistantMessage("Ownership is clean.") }]),
      "/repo"
    )
    await setup.renderOnce()

    const lines = setup.captureSpans().lines
    const behind = textRow(session.getChildren()[0])
    const dimmed = lines[0]?.spans.find(span => span.text.includes("transcript"))?.fg.toInts() ?? []
    const opaque = lines
      .flatMap(line => line.spans)
      .find(span => span.text.includes("Ownership"))
      ?.fg.toInts()

    expect(opaque).toEqual(behind.fg.toInts())
    expect(dimmed[0]).toBeLessThan(behind.fg.toInts()[0])

    // The dialog shares the session's plane: only the frame and the dimmed
    // surroundings separate it, so no row inside it reads as a lighter block.
    const surface = RGBA.fromHex(defaultTheme.surface.app).toInts()
    const planes = new Set(lines.flatMap(line => line.spans).map(span => span.bg.toInts().join(",")))
    expect([...planes]).toEqual([surface.join(",")])
  } finally {
    view.destroy()
    layer.destroyRecursively()
    setup.renderer.destroy()
  }
})

test("the modal owner restores focus and closes when its retained subagent is evicted", async () => {
  const models = createModels()
  const provider = fauxProvider()
  models.setProvider(provider.provider)
  const runtime = await createTestAgentRuntime({ cwd: "/repo", models, session: { type: "new", persist: false } })
  const setup = await createInteractiveTest(runtime.session, { width: 46, height: 25 })
  const snapshot: SubagentSnapshot = {
    ...completedSnapshot({ status: "completed", text: "Previous cycle result." }),
    lifecycle: "running",
    workCycle: 2,
    elapsedMs: 12_000
  }
  let available = true
  let modalSubscriber: ((event: AgentSessionEvent) => void) | undefined

  Object.defineProperties(runtime.session, {
    subagentSnapshots: { value: () => (available ? [snapshot] : []) },
    subagentSnapshot: { value: (name: string) => (available && name === snapshot.name ? snapshot : undefined) },
    subagentSessionEvents: { value: () => events([]) },
    subscribe: {
      value: (subscriber: (event: AgentSessionEvent) => void) => {
        modalSubscriber = subscriber
        return () => {
          if (modalSubscriber === subscriber) modalSubscriber = undefined
        }
      }
    }
  })

  try {
    const prompt = setup.renderer.root.findDescendantById("prompt-input")
    if (!(prompt instanceof TextareaRenderable)) throw new Error("Prompt input not found")

    await setup.mockInput.typeText("/agent")
    setup.mockInput.pressEnter()
    await renderSettled(setup)
    setup.mockInput.pressEnter()
    await renderSettled(setup)

    const layer = setup.renderer.root.findDescendantById("modal-layer")
    const modal = setup.renderer.root.findDescendantById("subagent-activity")
    if (!(layer instanceof BoxRenderable) || !(modal instanceof BoxRenderable)) {
      throw new Error("Subagent modal not found")
    }
    expect(layer.visible).toBe(true)
    expect(modal.focused).toBe(true)
    expect(setup.renderer.liveRequestCount).toBe(1)
    expect(prompt.focused).toBe(false)
    expect(prompt.showCursor).toBe(false)

    setup.resize(46, 40)
    await setup.renderOnce()
    expect(modal.height).toBe(panelRows(40))

    available = false
    modalSubscriber?.({ type: "subagent_changed", name: "another-agent" })
    await setup.renderOnce()

    expect(layer.visible).toBe(false)
    expect(setup.renderer.liveRequestCount).toBe(0)
    expect(prompt.focused).toBe(true)
    expect(prompt.showCursor).toBe(true)
  } finally {
    runtime.session.dispose()
    setup.destroy()
  }
})

function textRow(renderable: Renderable | undefined): TextRenderable {
  if (!(renderable instanceof TextRenderable)) throw new Error("Expected an activity text row")
  return renderable
}

function frameRows(frame: string, height: number): string[] {
  return frame
    .split("\n")
    .slice(0, height)
    .map(line => line.trimEnd())
}

function runningSnapshot(): SubagentSnapshot {
  return {
    name: "review-risk",
    lifecycle: "running",
    workCycle: 1,
    task: "Review the subagent activity modal for production regressions.",
    elapsedMs: 12_000,
    sessionId: "child-session-id"
  }
}

function completedSnapshot(completion: {
  status: "completed" | "failed" | "cancelled"
  text: string
  error?: string
}): SubagentSnapshot {
  return {
    ...idleSnapshot(),
    completion: {
      name: "review-risk",
      workCycle: 1,
      status: completion.status,
      text: completion.text,
      originalBytes: Buffer.byteLength(completion.text),
      omittedBytes: 0,
      truncated: false,
      durationMs: 65_000,
      ...(completion.error ? { error: completion.error } : {})
    }
  }
}

function idleSnapshot(): SubagentSnapshot {
  const { elapsedMs, ...snapshot } = runningSnapshot()
  void elapsedMs
  return { ...snapshot, lifecycle: "idle" }
}

function assistantMessage(text: string): Record<string, unknown> {
  return { role: "assistant", content: [{ type: "text", text }] }
}

function events(payloads: readonly Record<string, unknown>[], workCycle = 1): SubagentSessionEvents {
  return {
    name: "review-risk",
    omittedEvents: 0,
    omittedBytes: 0,
    events: payloads.map((payload, index) => ({
      sequence: index + 1,
      rpcSequence: index + 1,
      receivedAt: index + 1,
      workCycle,
      event: Object.freeze({ ...payload, type: String(payload.type) })
    }))
  }
}
