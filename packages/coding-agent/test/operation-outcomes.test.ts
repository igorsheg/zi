import { expect, test } from "bun:test"
import { appendFile, mkdtemp, readFile, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { maxOperationOutcomeEvidenceBytes, type OperationOutcomeInput } from "../src/operation-outcomes.js"
import { ZiPaths } from "../src/paths.js"
import { SessionManager } from "../src/session-manager.js"

const succeeded = (operationId = "subagent/reviewer/work_cycle/1"): OperationOutcomeInput => ({
  capability: "subagent",
  operation: "work_cycle",
  operationId,
  result: "succeeded",
  durationMs: 12,
  evidence: { name: "reviewer", workCycle: 1, profile: "provenance-scout", preview: "done" }
})

test("operation outcomes persist one generic envelope and remain model invisible", () => {
  const session = SessionManager.inMemory("/work")
  const entry = session.appendOperationOutcome(succeeded())

  expect(entry.id).not.toBe(entry.operationId)
  expect(entry.operationId).toBe("subagent/reviewer/work_cycle/1")
  expect(session.operationOutcomes()).toEqual([entry])
  expect(session.messages()).toEqual([])
  expect(session.presentationMessages()).toEqual([])
  expect(() => session.appendOperationOutcome(succeeded())).toThrow(
    "Operation outcome already exists: subagent/reviewer/work_cycle/1"
  )
})

test("operation outcome identities are indexed without materializing the journal", () => {
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
  expect(() => session.appendOperationOutcome(succeeded("other-operation"))).not.toThrow()
})

test("operation outcome identities remain unique when a journal is restored", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-operation-outcome-identity-"))
  try {
    const session = SessionManager.create(new ZiPaths(join(root, "project"), join(root, "agent")))
    const first = session.appendOperationOutcome(succeeded())
    const lines = (await readFile(session.file!, "utf8")).trim().split("\n")
    const duplicate = { ...JSON.parse(lines.at(-1)!), id: crypto.randomUUID(), parentId: first.id }
    await appendFile(session.file!, `${JSON.stringify(duplicate)}\n`)

    expect(() => SessionManager.open(session.file!)).toThrow("Duplicate operation outcome")
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test("operation outcomes accept string and snapshot callsite-owned structured evidence", () => {
  const session = SessionManager.inMemory("/work")
  const text = session.appendOperationOutcome({
    capability: "extensions",
    operation: "reload",
    operationId: "extensions/reload/1",
    result: "failed",
    durationMs: 7,
    evidence: "Worker failed to become ready"
  })
  const evidence = { taskId: "task-1", cancellationCode: "killed", output: { bytes: 128 } }
  const structured = session.appendOperationOutcome({
    capability: "shell",
    operation: "background_task",
    operationId: "shell/background_task/task-1",
    result: "cancelled",
    durationMs: 42,
    evidence
  })
  evidence.output.bytes = 256

  expect(session.operationOutcomes()).toEqual([text, structured])
  expect(structured.evidence).toEqual({ taskId: "task-1", cancellationCode: "killed", output: { bytes: 128 } })
  expect(Object.isFrozen(structured)).toBe(true)
  expect(Object.isFrozen(structured.evidence)).toBe(true)
  expect(Object.isFrozen(structured.evidence.output)).toBe(true)
})

test("operation outcomes validate only the shared envelope and JSON bounds", () => {
  const session = SessionManager.inMemory("/work")
  const append: unknown = Reflect.get(session, "appendOperationOutcome")
  if (typeof append !== "function") throw new Error("Expected appendOperationOutcome")

  expect(() => Reflect.apply(append, session, [{ ...succeeded(), capability: "Subagent" }])).toThrow(
    "Invalid session entry"
  )
  expect(() => Reflect.apply(append, session, [{ ...succeeded(), operationId: "" }])).toThrow("Invalid session entry")
  expect(() => Reflect.apply(append, session, [{ ...succeeded(), result: "unknown" }])).toThrow("Invalid session entry")
  expect(() => Reflect.apply(append, session, [{ ...succeeded(), durationMs: -1 }])).toThrow("Invalid session entry")
  expect(() =>
    Reflect.apply(append, session, [{ ...succeeded(), evidence: "x".repeat(maxOperationOutcomeEvidenceBytes + 1) }])
  ).toThrow("Invalid session entry")
  expect(() => Reflect.apply(append, session, [{ ...succeeded(), evidence: undefined }])).toThrow(
    "Invalid session entry"
  )
  expect(() => Reflect.apply(append, session, [{ ...succeeded(), evidence: { invalid: BigInt(1) } }])).toThrow(
    "Invalid session entry"
  )
})
