import { expect, test } from "bun:test"

import { createUpdatePlanTool, isUpdatePlanToolDetails } from "../src/tools/work-plan.js"
import {
  maxWorkPlanExplanationBytes,
  maxWorkPlanStepBytes,
  maxWorkPlanSteps,
  WorkPlan,
  type WorkPlanJournal,
  type WorkPlanReplacement,
  type WorkPlanSnapshot
} from "../src/work-plan.js"

interface JournalInput extends WorkPlanReplacement {
  readonly revision: number
}

function pending(text: string) {
  return { text, status: "pending" as const }
}

function journal(initial?: WorkPlanSnapshot, append?: (input: JournalInput) => WorkPlanSnapshot) {
  const appended: JournalInput[] = []
  const value: WorkPlanJournal = {
    latestWorkPlan: () => initial,
    appendWorkPlan(input) {
      appended.push(input)
      return append?.(input) ?? input
    }
  }
  return { value, appended }
}

test("work plan restores an immutable snapshot and isolates committed notifications", () => {
  const restored: WorkPlanSnapshot = {
    revision: 4,
    explanation: "Original plan",
    steps: [{ text: "Inspect", status: "completed" }]
  }
  const state = journal(restored)
  const plan = new WorkPlan(state.value)
  const notifications: WorkPlanSnapshot[] = []
  const observerOrder: string[] = []
  const unsubscribe = plan.subscribe(snapshot => notifications.push(snapshot))
  plan.subscribe(() => {
    observerOrder.push("throwing")
    throw new Error("observer failed")
  })
  plan.subscribe(() => observerOrder.push("later"))

  expect(plan.snapshot).toEqual(restored)
  expect(plan.snapshot).not.toBe(restored)
  expect(Object.isFrozen(plan.snapshot)).toBe(true)
  expect(Object.isFrozen(plan.snapshot.steps)).toBe(true)
  expect(Object.isFrozen(plan.snapshot.steps[0])).toBe(true)

  const replacement = {
    explanation: "  Refined after inspection  ",
    steps: [
      { text: "  Implement  ", status: "in_progress" as const },
      { text: "Verify", status: "pending" as const }
    ]
  }
  const snapshot = plan.replace(replacement)

  expect(state.appended).toEqual([
    {
      revision: 5,
      explanation: "Refined after inspection",
      steps: [
        { text: "Implement", status: "in_progress" },
        { text: "Verify", status: "pending" }
      ]
    }
  ])
  expect(snapshot).toEqual(state.appended[0]!)
  expect(plan.snapshot).toBe(snapshot)
  expect(notifications).toEqual([snapshot])
  expect(observerOrder).toEqual(["throwing", "later"])
  expect(Object.isFrozen(snapshot)).toBe(true)
  expect(Object.isFrozen(snapshot.steps)).toBe(true)
  expect(Object.isFrozen(snapshot.steps[0])).toBe(true)

  replacement.steps[0]!.text = "Changed later"
  expect(plan.snapshot.steps[0]?.text).toBe("Implement")
  unsubscribe()
  plan.replace({ steps: [] })
  expect(notifications).toHaveLength(1)
})

test("work plan leaves its snapshot unchanged when persistence fails", () => {
  const original: WorkPlanSnapshot = { revision: 2, steps: [{ text: "Keep", status: "pending" }] }
  const state = journal(original, () => {
    throw new Error("journal full")
  })
  const plan = new WorkPlan(state.value)
  let notifications = 0
  plan.subscribe(() => notifications++)

  expect(() => plan.replace({ steps: [{ text: "Lose", status: "completed" }] })).toThrow("journal full")
  expect(plan.snapshot).toEqual(original)
  expect(notifications).toBe(0)
})

test("work plan enforces text, status, and collection bounds before persistence", () => {
  const state = journal()
  const plan = new WorkPlan(state.value)

  for (const replacement of [
    { steps: Array.from({ length: maxWorkPlanSteps + 1 }, (_, index) => pending(`Step ${index}`)) },
    { steps: [pending(" ")] },
    { steps: [pending("x".repeat(maxWorkPlanStepBytes + 1))] },
    { steps: [pending("界".repeat(Math.floor(maxWorkPlanStepBytes / 3) + 1))] },
    { explanation: " ", steps: [] },
    { explanation: "x".repeat(maxWorkPlanExplanationBytes + 1), steps: [] },
    { steps: [], extra: true },
    { steps: [{ text: "Unexpected", status: "pending", extra: true }] },
    {
      steps: [
        { text: "First", status: "in_progress" as const },
        { text: "Second", status: "in_progress" as const }
      ]
    },
    { steps: [{ text: "Unknown", status: "blocked" }] }
  ]) {
    expect(() => plan.replace(replacement)).toThrow()
  }
  expect(state.appended).toEqual([])

  const atBounds = plan.replace({
    explanation: "e".repeat(maxWorkPlanExplanationBytes),
    steps: Array.from({ length: maxWorkPlanSteps }, (_, index) => pending(`${index}`.padEnd(maxWorkPlanStepBytes, "x")))
  })
  expect(atBounds.steps).toHaveLength(maxWorkPlanSteps)
  expect(state.appended).toHaveLength(1)
})

test("update_plan returns typed direct details and the native snapshot in Code Mode", async () => {
  const state = journal()
  const plan = new WorkPlan(state.value)
  const tool = createUpdatePlanTool(plan)
  const input = {
    explanation: "Starting work",
    steps: [
      { text: "Inspect", status: "completed" as const },
      { text: "Implement", status: "in_progress" as const },
      { text: "Verify", status: "pending" as const },
      { text: "Skip obsolete path", status: "cancelled" as const }
    ]
  }

  expect(tool.name).toBe("update_plan")
  expect(tool.executionMode).toBe("sequential")
  const direct = await tool.execute("direct", input)
  expect(direct.content).toEqual([{ type: "text", text: "Plan updated to revision 1." }])
  expect(isUpdatePlanToolDetails(direct.details)).toBe(true)
  expect(direct.details).toBe(plan.snapshot)

  const code = await tool.codeMode.execute(
    "code",
    { steps: [{ text: "Done", status: "completed" }] },
    new AbortController().signal
  )
  expect(code.result.content).toEqual([{ type: "text", text: "Plan updated to revision 2." }])
  expect(code.result.details).toBe(plan.snapshot)
  expect(code.value).toEqual({ revision: 2, steps: [{ text: "Done", status: "completed" }] })
  expect(code.value).not.toBe(plan.snapshot)
})

test("update_plan details guard checks the complete bounded snapshot", () => {
  expect(isUpdatePlanToolDetails({ revision: 0, steps: [] })).toBe(true)
  expect(isUpdatePlanToolDetails({ revision: -1, steps: [] })).toBe(false)
  expect(isUpdatePlanToolDetails({ revision: 1, explanation: " ", steps: [] })).toBe(false)
  expect(
    isUpdatePlanToolDetails({
      revision: 1,
      steps: [
        { text: "One", status: "in_progress" },
        { text: "Two", status: "in_progress" }
      ]
    })
  ).toBe(false)
  expect(isUpdatePlanToolDetails({ revision: 1, steps: [{ text: " padded ", status: "pending" }] })).toBe(false)
  expect(isUpdatePlanToolDetails({ revision: 1, steps: [], extra: true })).toBe(false)
  expect(isUpdatePlanToolDetails({ revision: 1, steps: [{ text: "Exact", status: "pending", extra: true }] })).toBe(
    false
  )
})

test("update_plan rejects cancellation before replacing the plan", () => {
  const state = journal()
  const tool = createUpdatePlanTool(new WorkPlan(state.value))
  const controller = new AbortController()
  controller.abort()

  expect(Promise.resolve(tool.execute("cancelled", { steps: [] }, controller.signal))).rejects.toThrow(
    "Operation aborted"
  )
  expect(state.appended).toEqual([])
})
