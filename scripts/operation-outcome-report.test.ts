import { expect, test } from "bun:test"
import { mkdtemp, rm, utimes, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type { OperationOutcome, OperationResult } from "../packages/coding-agent/src/operation-outcomes.js"
import { ZiPaths } from "../packages/coding-agent/src/paths.js"
import { SessionManager, type SessionJson } from "../packages/coding-agent/src/session-manager.js"
import {
  buildOperationOutcomeReport,
  loadOperationOutcomeReport,
  maxOperationOutcomeReportCapabilities,
  maxOperationOutcomeReportRecentRows,
  maxOperationOutcomeReportTrendDays
} from "./operation-outcome-report.js"

const generatedAt = "2026-03-10T12:00:00.000Z"

interface OutcomeSpec {
  readonly id: string
  readonly timestamp: string
  readonly capability: string
  readonly operation: string
  readonly result: OperationResult
  readonly durationMs: number
  readonly evidence: SessionJson
}

test("report aggregates generic outcomes with nearest-rank percentiles and UTC days", () => {
  const structuredEvidence = { target: "users", metrics: [3, true] } as const
  const report = buildOperationOutcomeReport(
    [
      reportSession("session-a", [
        outcome({
          id: "database-snapshot-1",
          timestamp: "2026-03-01T08:00:00.000Z",
          capability: "database",
          operation: "snapshot",
          result: "succeeded",
          durationMs: 10,
          evidence: structuredEvidence
        }),
        outcome({
          id: "database-snapshot-2",
          timestamp: "2026-03-02T08:00:00.000Z",
          capability: "database",
          operation: "snapshot",
          result: "failed",
          durationMs: 30,
          evidence: "connection refused"
        }),
        outcome({
          id: "index-refresh-1",
          timestamp: "2026-03-01T23:30:00.000-01:00",
          capability: "search_index",
          operation: "refresh",
          result: "failed",
          durationMs: 40,
          evidence: { shard: 7 }
        })
      ]),
      reportSession("session-b", [
        outcome({
          id: "index-refresh-2",
          timestamp: "2026-03-01T12:00:00.000Z",
          capability: "search_index",
          operation: "refresh",
          result: "cancelled",
          durationMs: 20,
          evidence: "operator request"
        })
      ])
    ],
    { cwd: "/work", generatedAt, invalid: 2, omitted: 3 }
  )

  expect(report.scope).toEqual({ cwd: "/work", scanned: 2, sessionsWithOutcomes: 2, invalid: 2, omitted: 3 })
  expect(report.overview).toEqual({
    total: 4,
    succeeded: 1,
    failed: 2,
    cancelled: 1,
    successRate: 0.25,
    p50DurationMs: 20,
    p95DurationMs: 40
  })
  expect(report.capabilities).toEqual([
    {
      capability: "database",
      operation: "snapshot",
      total: 2,
      succeeded: 1,
      failed: 1,
      cancelled: 0,
      successRate: 0.5,
      p50DurationMs: 10,
      p95DurationMs: 30
    },
    {
      capability: "search_index",
      operation: "refresh",
      total: 2,
      succeeded: 0,
      failed: 1,
      cancelled: 1,
      successRate: 0,
      p50DurationMs: 20,
      p95DurationMs: 40
    }
  ])
  expect(report.dailyTrend).toEqual([
    { date: "2026-03-01", succeeded: 1, failed: 0, cancelled: 1, p95DurationMs: 20 },
    { date: "2026-03-02", succeeded: 0, failed: 2, cancelled: 0, p95DurationMs: 40 }
  ])
  expect(report.recent.find(row => row.id === "database-snapshot-2")).toEqual(
    expect.objectContaining({ sessionId: "session-a", evidence: "connection refused" })
  )
  expect(report.recent.find(row => row.id === "database-snapshot-1")?.evidence).toBe(structuredEvidence)
  expect(Object.isFrozen(report)).toBe(true)
  expect(Object.isFrozen(report.scope)).toBe(true)
  expect(Object.isFrozen(report.dailyTrend)).toBe(true)
  expect(Object.isFrozen(report.dailyTrend[0])).toBe(true)
  expect(Object.isFrozen(report.capabilities[0])).toBe(true)
  expect(Object.isFrozen(report.recent[0])).toBe(true)
})

test("empty reports use null rates and duration percentiles", () => {
  const report = buildOperationOutcomeReport([], { cwd: "/empty", generatedAt })

  expect(report.overview).toEqual({
    total: 0,
    succeeded: 0,
    failed: 0,
    cancelled: 0,
    successRate: null,
    p50DurationMs: null,
    p95DurationMs: null
  })
  expect(report.capabilities).toEqual([])
  expect(report.dailyTrend).toEqual([])
  expect(report.recent).toEqual([])
})

test("report applies since before aggregation and sorts recent ties deterministically", () => {
  const timestamp = "2026-03-02T00:00:00.000Z"
  const report = buildOperationOutcomeReport(
    [
      reportSession("session-z", [
        outcome({
          id: "z-entry",
          timestamp,
          capability: "novel",
          operation: "execute",
          result: "succeeded",
          durationMs: 3,
          evidence: null
        })
      ]),
      reportSession("session-a", [
        outcome({
          id: "a-entry",
          timestamp,
          capability: "novel",
          operation: "execute",
          result: "succeeded",
          durationMs: 2,
          evidence: false
        }),
        outcome({
          id: "old-entry",
          timestamp: "2026-03-01T23:59:59.999Z",
          capability: "novel",
          operation: "execute",
          result: "failed",
          durationMs: 1,
          evidence: "old"
        })
      ])
    ],
    { cwd: "/work", generatedAt, since: timestamp }
  )

  expect(report.since).toBe(timestamp)
  expect(report.scope.sessionsWithOutcomes).toBe(2)
  expect(report.overview.total).toBe(2)
  expect(report.recent.map(row => row.sessionId)).toEqual(["session-a", "session-z"])
})

test("recent outcomes, trend days, and capability rows stay bounded", () => {
  const count = maxOperationOutcomeReportTrendDays + 1
  const entries = Array.from({ length: count }, (_, index) =>
    outcome({
      id: `entry-${index}`,
      timestamp: new Date(Date.UTC(2026, 0, 1) + index * 86_400_000).toISOString(),
      capability: `cap_${String(index % (maxOperationOutcomeReportCapabilities + 1)).padStart(2, "0")}`,
      operation: "execute",
      result: "succeeded",
      durationMs: index,
      evidence: index
    })
  )
  const report = buildOperationOutcomeReport([reportSession("session", entries)], { cwd: "/work", generatedAt })

  expect(report.overview.total).toBe(count)
  expect(report.recent).toHaveLength(maxOperationOutcomeReportRecentRows)
  expect(report.recent[0]?.evidence).toBe(count - 1)
  expect(report.recent.at(-1)?.evidence).toBe(count - maxOperationOutcomeReportRecentRows)
  expect(report.dailyTrend).toHaveLength(maxOperationOutcomeReportTrendDays)
  expect(report.dailyTrend[0]?.date).toBe("2026-01-02")
  expect(report.capabilities).toHaveLength(maxOperationOutcomeReportCapabilities)
})

test("loader reads canonical outcomes and accounts for invalid and omitted journals", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-operation-report-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "agent"))
  try {
    const included = SessionManager.create(paths)
    included.appendMessage({ role: "user", content: "private task", timestamp: 1 })
    included.appendOperationOutcome({
      operationId: "workflow/run/included",
      capability: "workflow",
      operation: "run",
      result: "succeeded",
      durationMs: 10,
      evidence: { label: "included", metrics: [1, true] }
    })

    const omitted = SessionManager.create(paths)
    omitted.appendOperationOutcome({
      operationId: "workflow/run/omitted",
      capability: "workflow",
      operation: "run",
      result: "succeeded",
      durationMs: 1,
      evidence: "omitted evidence"
    })

    const invalidPath = join(paths.sessionDir, "invalid-after-preview.jsonl")
    await writeFile(
      invalidPath,
      [
        JSON.stringify({ type: "session", version: 2, id: "invalid", timestamp: generatedAt, cwd: paths.cwd }),
        JSON.stringify({
          type: "message",
          id: "user",
          parentId: null,
          timestamp: generatedAt,
          message: { role: "user", content: "must not leak", timestamp: 1 }
        }),
        "{}",
        ""
      ].join("\n")
    )

    await utimes(omitted.file!, new Date(1000), new Date(1000))
    await utimes(invalidPath, new Date(2000), new Date(2000))
    await utimes(included.file!, new Date(3000), new Date(3000))

    const report = await loadOperationOutcomeReport(paths, { generatedAt, sessionLimit: 2 })

    expect(report.scope).toEqual({ cwd: paths.cwd, scanned: 1, sessionsWithOutcomes: 1, invalid: 1, omitted: 1 })
    expect(report.overview.total).toBe(1)
    expect(report.recent).toEqual([
      expect.objectContaining({
        sessionId: included.sessionId,
        operationId: "workflow/run/included",
        result: "succeeded",
        durationMs: 10,
        evidence: { label: "included", metrics: [1, true] }
      })
    ])
    const serialized = JSON.stringify(report)
    expect(serialized).not.toContain("private task")
    expect(serialized).not.toContain("must not leak")
    expect(serialized).not.toContain(paths.sessionDir)
    expect(serialized).not.toContain("invalid-after-preview.jsonl")
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

function reportSession(id: string, outcomes: readonly OperationOutcome[]) {
  return { id, outcomes }
}

function outcome(spec: OutcomeSpec): OperationOutcome {
  return {
    type: "operation_outcome",
    id: spec.id,
    parentId: null,
    timestamp: spec.timestamp,
    operationId: `operation/${spec.id}`,
    capability: spec.capability,
    operation: spec.operation,
    result: spec.result,
    durationMs: spec.durationMs,
    evidence: spec.evidence
  }
}
