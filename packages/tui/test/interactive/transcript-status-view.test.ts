import { expect, test } from "bun:test"

import { createTestRenderer } from "@opentui/core/testing"
import type { WorkPlanSnapshot } from "@with-zi/coding-agent"

import { InteractiveKeybindings } from "../../src/interactive/interactive-keybindings.js"
import {
  transcriptStatusRows,
  TranscriptStatusView,
  type TranscriptStatusPresentation
} from "../../src/interactive/transcript/status-view.js"
import {
  projectTranscriptBackgroundStatus,
  type TranscriptAgentActivity,
  type TranscriptShellActivity
} from "../../src/interactive/transcript/view.js"
import { defaultTheme } from "../../src/theme.js"

test("background projection counts only independently running shell tasks and agents", () => {
  const shellTasks: readonly TranscriptShellActivity[] = [
    { type: "starting", placement: "background" },
    { type: "background" },
    { type: "starting", placement: "foreground" },
    { type: "foreground" },
    { type: "settling" }
  ]
  const agents: readonly TranscriptAgentActivity[] = [
    { turn: "starting" },
    { turn: "running" },
    { turn: "interrupting" },
    { turn: "idle" }
  ]

  expect(projectTranscriptBackgroundStatus(shellTasks, agents)).toEqual({
    type: "running",
    shellCommands: 2,
    agents: 3
  })
  expect(projectTranscriptBackgroundStatus([{ type: "foreground" }], [{ turn: "idle" }])).toEqual({ type: "idle" })
})

test("transcript status preserves working and unseen-output behavior without a plan", async () => {
  const setup = await createTestRenderer({ width: 60, height: 2, useThread: false })
  const view = new TranscriptStatusView(setup.renderer, new InteractiveKeybindings(), defaultTheme)
  setup.renderer.root.add(view.root)

  try {
    view.update(presentation({ activity: active("ordinary", "Working…"), unseenOutput: true }), setup.renderer.width)
    await setup.renderOnce()
    expect(view.root.height).toBe(transcriptStatusRows)
    expect(setup.captureCharFrame()).toContain("Working… • New output (Ctrl+End to jump)")
    expect(setup.renderer.liveRequestCount).toBe(1)

    view.update(presentation({ unseenOutput: true }), setup.renderer.width)
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("New output (Ctrl+End to jump)")
    expect(setup.captureCharFrame()).not.toContain("Working…")
    expect(setup.renderer.liveRequestCount).toBe(0)
  } finally {
    view.destroy()
    if (!setup.renderer.isDestroyed) setup.renderer.destroy()
  }
})

test("an active plan composes without replacing the working shimmer", async () => {
  const setup = await createTestRenderer({ width: 100, height: 4, useThread: false })
  const view = new TranscriptStatusView(setup.renderer, new InteractiveKeybindings(), defaultTheme)
  setup.renderer.root.add(view.root)
  const plan = snapshot([
    step("completed", "Inspect"),
    step("in_progress", "Implement status composition"),
    step("pending", "Verify")
  ])

  try {
    view.update(
      presentation({ activity: active("ordinary", "Working…"), workPlan: present(plan, 1), unseenOutput: true }),
      setup.renderer.width
    )
    await setup.renderOnce()
    const frame = setup.captureCharFrame()
    expect(frame).toContain("Working… • New output")
    expect(frame).toContain("Plan (1/3)")
    expect(frame).toContain("Ctrl+P")
    expect(setup.renderer.liveRequestCount).toBe(1)
  } finally {
    view.destroy()
    if (!setup.renderer.isDestroyed) setup.renderer.destroy()
  }
})

test("a pending plan composes its next step with ordinary working activity", async () => {
  const setup = await createTestRenderer({ width: 100, height: 3, useThread: false })
  const view = new TranscriptStatusView(setup.renderer, new InteractiveKeybindings(), defaultTheme)
  setup.renderer.root.add(view.root)
  const plan = snapshot([step("pending", "Inspect status ownership"), step("pending", "Implement")])

  try {
    view.update(
      presentation({ activity: active("ordinary", "Working…"), workPlan: present(plan, 0) }),
      setup.renderer.width
    )
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("Working… • Plan (0/2) — Next: Inspect status ownership (Ctrl+P)")
    expect(setup.renderer.liveRequestCount).toBe(1)
  } finally {
    view.destroy()
    if (!setup.renderer.isDestroyed) setup.renderer.destroy()
  }
})

test("narrow status rows preserve activity and unseen output before the plan", async () => {
  const setup = await createTestRenderer({ width: 20, height: 3, useThread: false })
  const view = new TranscriptStatusView(setup.renderer, new InteractiveKeybindings(), defaultTheme)
  setup.renderer.root.add(view.root)
  const plan = snapshot([step("in_progress", "Implement status composition"), step("pending", "Verify")])

  try {
    view.update(
      presentation({ activity: active("ordinary", "Working…"), workPlan: present(plan, 0), unseenOutput: true }),
      setup.renderer.width
    )
    await setup.renderOnce()
    const frame = setup.captureCharFrame()
    expect(frame).toContain("Working… • New")
    expect(frame).not.toContain("Plan")
  } finally {
    view.destroy()
    if (!setup.renderer.isDestroyed) setup.renderer.destroy()
  }
})

test("background work composes counts without displacing activity, attention, or plan priority", async () => {
  const setup = await createTestRenderer({ width: 140, height: 4, useThread: false })
  const view = new TranscriptStatusView(setup.renderer, new InteractiveKeybindings(), defaultTheme)
  setup.renderer.root.add(view.root)
  const plan = snapshot([step("in_progress", "Implement status composition"), step("pending", "Verify")])

  try {
    view.update(
      presentation({
        activity: active("special", "Compacting…"),
        background: background(2, 1),
        workPlan: present(plan, 0),
        unseenOutput: true
      }),
      setup.renderer.width
    )
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain(
      "Working… (Compacting…) • New output • ◎ 2 commands · 1 agent still running • Plan (0/2)"
    )

    view.update(presentation({ background: background(1, 2) }), setup.renderer.width)
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("◎ 1 command · 2 agents still running")
    expect(setup.captureCharFrame()).not.toContain("Working…")
  } finally {
    view.destroy()
    if (!setup.renderer.isDestroyed) setup.renderer.destroy()
  }
})

test("status availability owns shimmer admission", async () => {
  const setup = await createTestRenderer({ width: 60, height: 2, useThread: false })
  const view = new TranscriptStatusView(setup.renderer, new InteractiveKeybindings(), defaultTheme)
  setup.renderer.root.add(view.root)

  try {
    view.update(presentation({ activity: active("ordinary", "Working…") }), setup.renderer.width)
    expect(setup.renderer.liveRequestCount).toBe(1)
    view.setAvailable(false)
    expect(view.root.visible).toBe(false)
    expect(setup.renderer.liveRequestCount).toBe(0)
    view.setAvailable(true)
    expect(view.root.visible).toBe(true)
    expect(setup.renderer.liveRequestCount).toBe(1)
  } finally {
    view.destroy()
    if (!setup.renderer.isDestroyed) setup.renderer.destroy()
  }
})

function presentation(value: Partial<TranscriptStatusPresentation> = {}): TranscriptStatusPresentation {
  return {
    activity: { type: "idle" },
    background: { type: "idle" },
    workPlan: { type: "absent" },
    unseenOutput: false,
    ...value
  }
}

function background(shellCommands: number, agents: number): TranscriptStatusPresentation["background"] {
  return { type: "running", shellCommands, agents }
}

function active(kind: "ordinary" | "special", text: string): TranscriptStatusPresentation["activity"] {
  return kind === "ordinary" ? { type: "working" } : { type: "working_with_lifecycle", text }
}

function present(plan: WorkPlanSnapshot, currentIndex: number): TranscriptStatusPresentation["workPlan"] {
  const completed = plan.steps.filter(candidate => candidate.status === "completed").length
  const total = plan.steps.filter(candidate => candidate.status !== "cancelled").length
  const currentStatus = plan.steps[currentIndex]?.status
  if (currentStatus !== "pending" && currentStatus !== "in_progress") throw new Error("Expected current work")
  return { type: "present", plan, completed, total, currentIndex, currentStatus }
}

type FixtureStep = WorkPlanSnapshot["steps"][number]

function step(status: FixtureStep["status"], text: string): FixtureStep {
  return { status, text }
}

let nextRevision = 0

function snapshot(steps: readonly FixtureStep[]): WorkPlanSnapshot {
  return { revision: ++nextRevision, steps }
}
