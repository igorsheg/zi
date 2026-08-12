import { expect, test } from "bun:test"

import {
  projectSessionOutcomes,
  shellBackgroundTaskOperationId,
  subagentWorkCycleOperationId,
  type ShellBackgroundTaskOperationOutcomeInput,
  type SubagentWorkCycleOperationOutcomeInput
} from "../src/operation-outcomes.js"
import { SessionManager } from "../src/session-manager.js"

const succeeded = (name = "reviewer", workCycle = 1): SubagentWorkCycleOperationOutcomeInput => ({
  capability: "subagent",
  operation: "work_cycle",
  operationId: subagentWorkCycleOperationId(name, workCycle),
  name,
  workCycle,
  profile: "provenance-scout",
  result: "succeeded",
  preview: "done",
  originalBytes: 4,
  omittedBytes: 0,
  truncated: false,
  durationMs: 12
})

test("operation outcomes use deterministic identities and remain model invisible", () => {
  const session = SessionManager.inMemory("/work")
  const entry = session.appendOperationOutcome(succeeded())

  expect(entry.id).toBe("subagent/reviewer/work_cycle/1")
  expect(entry.operationId).toBe(subagentWorkCycleOperationId("reviewer", 1))
  expect(session.operationOutcomeEntries()).toEqual([entry])
  expect(session.messages()).toEqual([])
  expect(session.presentationMessages()).toEqual([])
  expect(projectSessionOutcomes(session.entries())).toEqual([
    expect.objectContaining({
      sourceEntryId: entry.id,
      timestamp: entry.timestamp,
      profile: "provenance-scout",
      result: "succeeded"
    })
  ])
  expect(() => session.appendOperationOutcome(succeeded())).toThrow(
    "Operation outcome already exists: subagent/reviewer/work_cycle/1"
  )
  expect(session.operationOutcomeEntries()).toEqual([entry])
})

test("operation outcome identity checks do not materialize the journal", () => {
  const session = SessionManager.inMemory("/tmp")
  session.appendOperationOutcome(succeeded())
  Object.defineProperty(session, "entries", {
    value() {
      throw new Error("journal materialized")
    }
  })

  expect(() => session.appendOperationOutcome(succeeded())).toThrow(
    "Operation outcome already exists: subagent/reviewer/work_cycle/1"
  )
  expect(() => session.appendOperationOutcome(succeeded("other"))).not.toThrow()
})

test("shell background-task outcomes are closed, durable, and model invisible", () => {
  const session = SessionManager.inMemory("/work")
  const taskId = "11111111-1111-4111-8111-111111111111"
  const input: ShellBackgroundTaskOperationOutcomeInput = {
    capability: "shell",
    operation: "background_task",
    operationId: shellBackgroundTaskOperationId(taskId),
    taskId,
    origin: "requested",
    result: "failed",
    errorCode: "exit_nonzero",
    exitCode: 7,
    durationMs: 42,
    outputBytes: 128
  }

  const entry = session.appendOperationOutcome(input)

  expect(entry.id).toBe(shellBackgroundTaskOperationId(taskId))
  expect(projectSessionOutcomes(session.entries())).toEqual([
    expect.objectContaining({
      capability: "shell",
      operation: "background_task",
      taskId,
      result: "failed",
      errorCode: "exit_nonzero",
      exitCode: 7,
      outputBytes: 128
    })
  ])
  expect(session.messages()).toEqual([])
  expect(session.presentationMessages()).toEqual([])
  expect(JSON.stringify(entry)).not.toContain("command")
  expect(JSON.stringify(entry)).not.toContain("output text")
})

test("shell background-task outcomes reject mismatched terminal evidence", () => {
  const session = SessionManager.inMemory("/work")
  const append: unknown = Reflect.get(session, "appendOperationOutcome")
  if (typeof append !== "function") throw new Error("Expected appendOperationOutcome")
  const taskId = "22222222-2222-4222-8222-222222222222"
  const common = {
    capability: "shell",
    operation: "background_task",
    operationId: shellBackgroundTaskOperationId(taskId),
    taskId,
    origin: "demoted",
    durationMs: 1,
    outputBytes: 0
  }

  expect(() => Reflect.apply(append, session, [{ ...common, result: "succeeded", exitCode: 1 }])).toThrow(
    "Invalid session entry"
  )
  expect(() =>
    Reflect.apply(append, session, [
      { ...common, result: "cancelled", cancellationCode: "killed", errorCode: "timed_out" }
    ])
  ).toThrow("Invalid session entry")
  expect(() =>
    Reflect.apply(append, session, [{ ...common, result: "failed", errorCode: "signaled", signal: "not-signal" }])
  ).toThrow("Invalid session entry")
  expect(() =>
    Reflect.apply(append, session, [{ ...common, result: "failed", errorCode: "execution_failed", command: "secret" }])
  ).toThrow("Invalid session entry")
})

test("native operation outcomes reject invalid result and failure combinations", () => {
  const session = SessionManager.inMemory("/work")
  const append: unknown = Reflect.get(session, "appendOperationOutcome")
  if (typeof append !== "function") throw new Error("Expected appendOperationOutcome")

  expect(() =>
    Reflect.apply(append, session, [{ ...succeeded(), result: "succeeded", errorCode: "provider_error" }])
  ).toThrow("Invalid session entry")
  expect(() =>
    Reflect.apply(append, session, [{ ...succeeded(), result: "failed", errorCode: "legacy_failure" }])
  ).toThrow("Invalid session entry")
  expect(() => Reflect.apply(append, session, [{ ...succeeded(), operationId: "random-id" }])).toThrow(
    "Invalid session entry"
  )
})

test("legacy subagent completions project to normalized outcomes", () => {
  const session = SessionManager.inMemory("/work")
  const completed = session.appendSubagent({
    event: "work_cycle_finished",
    name: "legacy-worker",
    workCycle: 1,
    status: "completed",
    preview: "legacy done",
    originalBytes: 11,
    omittedBytes: 0,
    truncated: false,
    durationMs: 20
  })
  const failed = session.appendSubagent({
    event: "work_cycle_finished",
    name: "legacy-worker",
    workCycle: 2,
    status: "failed",
    preview: "",
    originalBytes: 0,
    omittedBytes: 0,
    truncated: false,
    durationMs: 21,
    reason: "old_reason",
    error: "old failure"
  })

  expect(projectSessionOutcomes(session.entries())).toEqual([
    expect.objectContaining({
      sourceEntryId: completed.id,
      operationId: subagentWorkCycleOperationId("legacy-worker", 1),
      result: "succeeded"
    }),
    expect.objectContaining({
      sourceEntryId: failed.id,
      operationId: subagentWorkCycleOperationId("legacy-worker", 2),
      result: "failed",
      errorCode: "legacy_failure",
      errorMessage: "old failure"
    })
  ])
})

test("native outcomes supersede legacy completion entries without duplicate projection", () => {
  const session = SessionManager.inMemory("/work")
  session.appendSubagent({
    event: "work_cycle_finished",
    name: "mixed-worker",
    workCycle: 1,
    status: "failed",
    preview: "legacy",
    originalBytes: 6,
    omittedBytes: 0,
    truncated: false,
    durationMs: 5,
    reason: "provider_error"
  })
  const native = session.appendOperationOutcome({ ...succeeded("mixed-worker"), preview: "native", originalBytes: 6 })

  expect(projectSessionOutcomes(session.entries())).toEqual([
    expect.objectContaining({ sourceEntryId: native.id, preview: "native", result: "succeeded" })
  ])
})
