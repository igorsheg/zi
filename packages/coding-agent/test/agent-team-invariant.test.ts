import { expect, test } from "bun:test"

import { InvariantError, InvariantRegistry } from "@with-zi/invariants"

import { AgentTeamInvariant, type AgentTeamTerminalSnapshot } from "../src/agent-team/invariant.js"
import { agentMailMessage, type AgentMailInput } from "../src/agent-team/mail.js"
import { parseAgentPath } from "../src/agent-team/path.js"
import { SessionManager, type CustomMessageEntry } from "../src/session-manager.js"

const root = parseAgentPath("/root")
const research = parseAgentPath("/root/research")
const terminal: AgentTeamTerminalSnapshot = {
  reservations: 0,
  spawnOperations: 0,
  settlements: 0,
  transientRecords: 0,
  transcriptOpen: false
}

function createInvariant(options?: ConstructorParameters<typeof InvariantRegistry>[0]): AgentTeamInvariant {
  return new AgentTeamInvariant(new InvariantRegistry(options))
}

function mail(deliveryId = "mail-1"): AgentMailInput {
  return { deliveryId, sender: root, target: research, kind: "message", text: "Inspect the journal." }
}

function entry(input: AgentMailInput): CustomMessageEntry {
  return SessionManager.inMemory("/work", crypto.randomUUID()).appendCriticalCustomMessage(agentMailMessage(input))
}

test("accepts matching turn and mail target acknowledgements", () => {
  const invariant = createInvariant()
  const turn = { ...mail("turn-1"), kind: "task" as const }
  const turnEntry = entry(turn)
  const message = mail()
  const messageEntry = entry(message)

  expect(() => invariant.turnStarted(turn, turnEntry, turnEntry.id)).not.toThrow()
  expect(() => invariant.mailDelivered(message, "boundary", messageEntry, "boundary", messageEntry.id)).not.toThrow()
})

test("rejects mismatched target entry, publication, and acknowledgement transactionally", () => {
  const invariant = createInvariant()
  const input = mail()
  const admitted = entry(input)
  const other = entry(mail("mail-2"))

  expect(() => invariant.mailDelivered(input, "append", other, "append", other.id)).toThrow(InvariantError)
  expect(() => invariant.mailDelivered(input, "append", admitted, "boundary", admitted.id)).toThrow(InvariantError)
  expect(() => invariant.mailDelivered(input, "append", admitted, "append", other.id)).toThrow(InvariantError)
  expect(() => invariant.mailDelivered(input, "append", admitted, "append", admitted.id)).not.toThrow()

  expect(() => invariant.turnStarted({ ...input, kind: "task" }, admitted, admitted.id)).toThrow(InvariantError)
  expect(() => invariant.turnStarted(input, admitted, other.id)).toThrow(InvariantError)
})

test("accepts terminal cleanup after the active deadline is released", () => {
  const invariant = createInvariant()
  invariant.deadlineScheduled(research, 1)
  invariant.deadlineReleased(research, 1)

  expect(() => invariant.shutdownSucceeded(terminal)).not.toThrow()
})

test("rejects successful shutdown with retained runtime work", () => {
  const cases: readonly [snapshot: AgentTeamTerminalSnapshot, message: string][] = [
    [{ ...terminal, reservations: 1 }, "spawn reservations"],
    [{ ...terminal, spawnOperations: 1 }, "spawn operations"],
    [{ ...terminal, settlements: 1 }, "turn settlements"],
    [{ ...terminal, transientRecords: 1 }, "transient agent records"],
    [{ ...terminal, transcriptOpen: true }, "transcript lease"]
  ]
  for (const [snapshot, message] of cases) {
    expect(() => createInvariant().shutdownSucceeded(snapshot)).toThrow(message)
  }

  const deadline = createInvariant()
  deadline.deadlineScheduled(research, 1)
  expect(() => deadline.shutdownSucceeded(terminal)).toThrow("turn deadlines")
})

test("disabled or disposed diagnostics do not change AgentTeam behavior", () => {
  const disabled = createInvariant({ enabled: false })
  const input = mail()
  const admitted = entry(input)

  expect(() => {
    disabled.turnStarted(input, admitted, "wrong")
    disabled.mailDelivered(input, "append", admitted, "boundary", "wrong")
    disabled.deadlineScheduled(research, 1)
    disabled.shutdownSucceeded({ ...terminal, reservations: 1 })
  }).not.toThrow()

  const disposed = createInvariant()
  disposed.dispose()
  expect(() => disposed.shutdownSucceeded({ ...terminal, reservations: 1 })).not.toThrow()
})
