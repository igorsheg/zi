import { expect, test } from "bun:test"

import { InvariantError, InvariantRegistry } from "@with-zi/invariants"

import { SessionShellInvariant } from "../src/session-shell-invariant.js"
import type { BackgroundTaskOrigin, BackgroundTaskResultInput } from "../src/shell-result.js"

function createInvariant(): SessionShellInvariant {
  return new SessionShellInvariant(new InvariantRegistry())
}

function result(origin: BackgroundTaskOrigin = "requested"): BackgroundTaskResultInput {
  return { taskId: "task-1", origin, result: "succeeded", exitCode: 0, durationMs: 40, outputBytes: 12 }
}

function introduceBackground(invariant: SessionShellInvariant): void {
  invariant.taskIntroduced("task-1")
  invariant.backgroundOwned("task-1", "requested", 10)
}

function settleBackground(invariant: SessionShellInvariant): void {
  invariant.taskSettled("task-1", { type: "exited", exitCode: 0 }, 50, 12)
}

test("rejects duplicate task identity and background ownership without changing the active ownership", () => {
  const invariant = createInvariant()
  introduceBackground(invariant)

  expect(() => invariant.taskIntroduced("task-1")).toThrow(InvariantError)
  expect(() => invariant.backgroundOwned("task-1", "demoted", 20)).toThrow(InvariantError)
  settleBackground(invariant)
  expect(() => invariant.backgroundResult(result())).not.toThrow()
})

test("rejects a background result before terminal settlement transactionally", () => {
  const invariant = createInvariant()
  introduceBackground(invariant)

  expect(() => invariant.backgroundResult(result())).toThrow(InvariantError)
  settleBackground(invariant)
  expect(() => invariant.backgroundResult(result())).not.toThrow()
})

test("rejects duplicate terminal settlements and durable results", () => {
  const terminal = createInvariant()
  introduceBackground(terminal)
  settleBackground(terminal)
  expect(() => settleBackground(terminal)).toThrow(InvariantError)
  terminal.backgroundResult(result())

  const durable = createInvariant()
  introduceBackground(durable)
  settleBackground(durable)
  durable.backgroundResult(result())
  expect(() => durable.backgroundResult(result())).toThrow(InvariantError)
})

test("rejects mismatched result facts without consuming the correspondence", () => {
  const invariant = createInvariant()
  introduceBackground(invariant)
  settleBackground(invariant)

  expect(() =>
    invariant.backgroundResult({
      taskId: "task-2",
      origin: "requested",
      result: "succeeded",
      exitCode: 0,
      durationMs: 40,
      outputBytes: 12
    })
  ).toThrow(InvariantError)
  expect(() => invariant.backgroundResult(result("demoted"))).toThrow(InvariantError)
  expect(() =>
    invariant.backgroundResult({
      taskId: "task-1",
      origin: "requested",
      result: "cancelled",
      cancellationCode: "killed",
      durationMs: 40,
      outputBytes: 12
    })
  ).toThrow(InvariantError)
  expect(() => invariant.backgroundResult({ ...result(), durationMs: 41 })).toThrow(InvariantError)
  expect(() => invariant.backgroundResult({ ...result(), outputBytes: 13 })).toThrow(InvariantError)
  expect(() => invariant.backgroundResult(result())).not.toThrow()
})

test("rejects foreground results and final disposal with outstanding background work", () => {
  const foreground = createInvariant()
  foreground.taskIntroduced("task-1")
  foreground.taskSettled("task-1", { type: "exited", exitCode: 0 }, 50, 12)
  expect(() => foreground.backgroundResult(result())).toThrow(InvariantError)

  const active = createInvariant()
  introduceBackground(active)
  expect(() => active.disposed()).toThrow("active background tasks")

  const awaiting = createInvariant()
  introduceBackground(awaiting)
  settleBackground(awaiting)
  expect(() => awaiting.disposed()).toThrow("unpersisted background results")
  awaiting.backgroundResult(result())
  expect(() => awaiting.disposed()).not.toThrow()
})

test("disabled diagnostics do not change SessionShell protocol behavior", () => {
  const invariant = new SessionShellInvariant(new InvariantRegistry({ enabled: false }))

  expect(() => {
    invariant.backgroundOwned("missing", "requested", 0)
    invariant.backgroundResult(result())
    invariant.disposed()
  }).not.toThrow()
})
