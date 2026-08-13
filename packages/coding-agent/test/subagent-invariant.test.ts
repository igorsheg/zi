import { expect, test } from "bun:test"

import { InvariantError, InvariantRegistry } from "@with-zi/invariants"

import { SubagentInvariant } from "../src/subagents/invariant.js"

function createInvariant(): SubagentInvariant {
  return new SubagentInvariant(new InvariantRegistry())
}

test("subagent lifecycle pairs monotonic work cycles with one durable result", () => {
  const invariant = createInvariant()

  invariant.introduce("worker")
  invariant.startWork("worker", 1)
  invariant.admitInterrupt("worker", 1)
  invariant.settleWork("worker", 1)
  invariant.persistResult("worker", 1)
  invariant.startWork("worker", 2)
  invariant.settleWork("worker", 2)
  invariant.persistResult("worker", 2)
  invariant.exit("worker")

  expect(() => invariant.shutdownSucceeded()).not.toThrow()
})

test("subagent lifecycle rejects wrong cycles, duplicate settlement and result, and work after exit", () => {
  {
    const invariant = createInvariant()
    invariant.introduce("worker")
    expect(() => invariant.startWork("worker", 2)).toThrow("expected 1")
  }
  {
    const invariant = createInvariant()
    invariant.introduce("worker")
    invariant.startWork("worker", 1)
    expect(() => invariant.settleWork("worker", 2)).toThrow("crossed active cycle 1")
  }
  {
    const invariant = createInvariant()
    invariant.introduce("worker")
    invariant.startWork("worker", 1)
    invariant.settleWork("worker", 1)
    expect(() => invariant.settleWork("worker", 1)).toThrow(InvariantError)
  }
  {
    const invariant = createInvariant()
    invariant.introduce("worker")
    invariant.startWork("worker", 1)
    invariant.settleWork("worker", 1)
    invariant.persistResult("worker", 1)
    expect(() => invariant.persistResult("worker", 1)).toThrow("observed twice")
  }
  {
    const invariant = createInvariant()
    invariant.introduce("worker")
    invariant.exit("worker")
    expect(() => invariant.startWork("worker", 1)).toThrow("after child worker exited")
  }
})

test("subagent interrupt and shutdown correspondence reject stale or missing work results", () => {
  {
    const invariant = createInvariant()
    invariant.introduce("worker")
    invariant.startWork("worker", 1)
    expect(() => invariant.admitInterrupt("worker", 2)).toThrow("crossed active cycle 1")
  }
  {
    const invariant = createInvariant()
    invariant.introduce("worker")
    invariant.startWork("worker", 1)
    invariant.settleWork("worker", 1)
    invariant.exit("worker")
    expect(() => invariant.shutdownSucceeded()).toThrow("without durable results")
  }
})
