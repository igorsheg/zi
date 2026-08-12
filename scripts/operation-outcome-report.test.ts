import { expect, test } from "bun:test"
import { mkdtemp, rm, utimes, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import {
  projectSessionOutcomes,
  shellBackgroundTaskOperationId,
  subagentWorkCycleOperationId,
  type OperationResult
} from "../packages/coding-agent/src/operation-outcomes.js"
import { ZiPaths } from "../packages/coding-agent/src/paths.js"
import { SessionManager, type SessionEntry } from "../packages/coding-agent/src/session-manager.js"
import {
  buildOperationOutcomeReport,
  legacySubagentWorkCycleProfileLabel,
  loadOperationOutcomeReport,
  maxSubagentWorkCycleReportProfiles,
  maxOperationOutcomeReportRecentRows,
  maxOperationOutcomeReportTrendDays
} from "./operation-outcome-report.js"

const generatedAt = "2026-03-10T12:00:00.000Z"

interface OutcomeSpec {
  readonly name: string
  readonly workCycle: number
  readonly timestamp: string
  readonly result: OperationResult
  readonly durationMs: number
  readonly profile?: string
  readonly truncated?: boolean
  readonly errorCode?: "assignment_failed" | "provider_error"
  readonly errorMessage?: string
}

test("report aggregates mixed outcomes with nearest-rank percentiles and UTC days", () => {
  const report = buildOperationOutcomeReport(
    [
      reportSession("session-a", [
        outcome({
          name: "alpha",
          workCycle: 1,
          timestamp: "2026-03-01T08:00:00.000Z",
          result: "succeeded",
          durationMs: 10,
          profile: "profile-a"
        }),
        outcome({
          name: "alpha",
          workCycle: 2,
          timestamp: "2026-03-02T08:00:00.000Z",
          result: "failed",
          durationMs: 30,
          profile: "profile-a",
          errorCode: "assignment_failed"
        }),
        outcome({
          name: "zeta",
          workCycle: 1,
          timestamp: "2026-03-01T23:30:00.000-01:00",
          result: "failed",
          durationMs: 40,
          profile: "profile-z",
          truncated: true,
          errorCode: "provider_error",
          errorMessage: "provider unavailable"
        })
      ]),
      reportSession("session-b", [legacyOutcome("legacy", 1, "2026-03-01T12:00:00.000Z", 20)])
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
      capability: "subagent",
      operation: "work_cycle",
      total: 4,
      succeeded: 1,
      failed: 2,
      cancelled: 1,
      successRate: 0.25,
      p50DurationMs: 20,
      p95DurationMs: 40
    }
  ])
  expect(report.subagentWorkCycles.overview).toEqual({ ...report.overview, truncated: 1, truncatedRate: 0.25 })
  expect(report.dailyTrend).toEqual([
    { date: "2026-03-01", succeeded: 1, failed: 0, cancelled: 1, p95DurationMs: 20 },
    { date: "2026-03-02", succeeded: 0, failed: 2, cancelled: 0, p95DurationMs: 40 }
  ])
  expect(report.subagentWorkCycles.failureGroups).toEqual([
    { errorCode: "assignment_failed", count: 1, share: 0.5, affectedProfileCount: 1 },
    { errorCode: "provider_error", count: 1, share: 0.5, affectedProfileCount: 1 }
  ])
  expect(report.subagentWorkCycles.profiles).toEqual([
    {
      profile: "profile-a",
      total: 2,
      succeeded: 1,
      failed: 1,
      cancelled: 0,
      successRate: 0.5,
      p50DurationMs: 10,
      p95DurationMs: 30,
      truncated: 0
    },
    {
      profile: legacySubagentWorkCycleProfileLabel,
      total: 1,
      succeeded: 0,
      failed: 0,
      cancelled: 1,
      successRate: 0,
      p50DurationMs: 20,
      p95DurationMs: 20,
      truncated: 0
    },
    {
      profile: "profile-z",
      total: 1,
      succeeded: 0,
      failed: 1,
      cancelled: 0,
      successRate: 0,
      p50DurationMs: 40,
      p95DurationMs: 40,
      truncated: 1
    }
  ])
  expect(report.recent.find(row => row.capability === "subagent" && row.runtimeName === "zeta")).toEqual(
    expect.objectContaining({
      sessionId: "session-a",
      profile: "profile-z",
      errorCode: "provider_error",
      errorMessage: "provider unavailable"
    })
  )
  expect(Object.isFrozen(report)).toBe(true)
  expect(Object.isFrozen(report.scope)).toBe(true)
  expect(Object.isFrozen(report.dailyTrend)).toBe(true)
  expect(Object.isFrozen(report.dailyTrend[0])).toBe(true)
  expect(Object.isFrozen(report.capabilities[0])).toBe(true)
  expect(Object.isFrozen(report.subagentWorkCycles)).toBe(true)
  expect(Object.isFrozen(report.subagentWorkCycles.failureGroups[0])).toBe(true)
  expect(Object.isFrozen(report.subagentWorkCycles.profiles[0])).toBe(true)
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
  expect(report.subagentWorkCycles).toEqual({
    overview: { ...report.overview, truncated: 0, truncatedRate: null },
    failureGroups: [],
    profiles: []
  })
  expect(report.backgroundTasks).toEqual({
    overview: report.overview,
    failureGroups: [],
    cancellationGroups: [],
    origins: [],
    output: { totalBytes: 0, p50Bytes: null, p95Bytes: null }
  })
  expect(report.recent).toEqual([])
})

test("report keeps background task evidence in its closed capability section", () => {
  const report = buildOperationOutcomeReport(
    [
      reportSession("session", [
        outcome({
          name: "worker",
          workCycle: 1,
          timestamp: "2026-03-02T00:00:00.000Z",
          result: "succeeded",
          durationMs: 10,
          profile: "reviewer"
        }),
        shellOutcome({
          taskId: "11111111-1111-4111-8111-111111111111",
          timestamp: "2026-03-02T01:00:00.000Z",
          origin: "requested",
          result: "failed",
          durationMs: 20,
          outputBytes: 100,
          errorCode: "exit_nonzero",
          exitCode: 7
        }),
        shellOutcome({
          taskId: "22222222-2222-4222-8222-222222222222",
          timestamp: "2026-03-02T02:00:00.000Z",
          origin: "demoted",
          result: "cancelled",
          durationMs: 30,
          outputBytes: 300,
          cancellationCode: "killed"
        })
      ])
    ],
    { cwd: "/work", generatedAt }
  )

  expect(report.overview).toEqual({
    total: 3,
    succeeded: 1,
    failed: 1,
    cancelled: 1,
    successRate: 1 / 3,
    p50DurationMs: 20,
    p95DurationMs: 30
  })
  expect(report.capabilities).toEqual([
    {
      capability: "shell",
      operation: "background_task",
      total: 2,
      succeeded: 0,
      failed: 1,
      cancelled: 1,
      successRate: 0,
      p50DurationMs: 20,
      p95DurationMs: 30
    },
    {
      capability: "subagent",
      operation: "work_cycle",
      total: 1,
      succeeded: 1,
      failed: 0,
      cancelled: 0,
      successRate: 1,
      p50DurationMs: 10,
      p95DurationMs: 10
    }
  ])
  expect(report.backgroundTasks).toEqual({
    overview: { total: 2, succeeded: 0, failed: 1, cancelled: 1, successRate: 0, p50DurationMs: 20, p95DurationMs: 30 },
    failureGroups: [{ errorCode: "exit_nonzero", count: 1, share: 1 }],
    cancellationGroups: [{ cancellationCode: "killed", count: 1, share: 1 }],
    origins: [
      {
        origin: "demoted",
        total: 1,
        succeeded: 0,
        failed: 0,
        cancelled: 1,
        successRate: 0,
        p50DurationMs: 30,
        p95DurationMs: 30
      },
      {
        origin: "requested",
        total: 1,
        succeeded: 0,
        failed: 1,
        cancelled: 0,
        successRate: 0,
        p50DurationMs: 20,
        p95DurationMs: 20
      }
    ],
    output: { totalBytes: 400, p50Bytes: 100, p95Bytes: 300 }
  })
  expect(report.recent[0]).toEqual(
    expect.objectContaining({
      capability: "shell",
      taskId: "22222222-2222-4222-8222-222222222222",
      cancellationCode: "killed"
    })
  )
  const serialized = JSON.stringify(report)
  expect(serialized).not.toContain("command")
  expect(serialized).not.toContain("output text")
})

test("report applies since before aggregation and sorts recent ties deterministically", () => {
  const timestamp = "2026-03-02T00:00:00.000Z"
  const report = buildOperationOutcomeReport(
    [
      reportSession("session-z", [
        outcome({ name: "worker-z", workCycle: 1, timestamp, result: "succeeded", durationMs: 3, profile: "same" })
      ]),
      reportSession("session-a", [
        outcome({ name: "worker-a", workCycle: 1, timestamp, result: "succeeded", durationMs: 2, profile: "same" }),
        outcome({
          name: "worker-a",
          workCycle: 2,
          timestamp: "2026-03-01T23:59:59.999Z",
          result: "failed",
          durationMs: 1,
          profile: "same",
          errorCode: "provider_error"
        })
      ])
    ],
    { cwd: "/work", generatedAt, since: timestamp }
  )

  expect(report.since).toBe(timestamp)
  expect(report.scope.sessionsWithOutcomes).toBe(2)
  expect(report.overview.total).toBe(2)
  expect(report.subagentWorkCycles.failureGroups).toEqual([])
  expect(report.recent.map(row => row.sessionId)).toEqual(["session-a", "session-z"])
})

test("recent outcomes are newest-first and UTC trend days stay bounded", () => {
  const count = maxOperationOutcomeReportTrendDays + 1
  const entries = Array.from({ length: count }, (_, index) =>
    outcome({
      name: "worker",
      workCycle: index + 1,
      timestamp: new Date(Date.UTC(2026, 0, 1) + index * 86_400_000).toISOString(),
      result: "succeeded",
      durationMs: index,
      profile: `profile-${index.toString().padStart(3, "0")}`
    })
  )
  const report = buildOperationOutcomeReport([reportSession("session", entries)], { cwd: "/work", generatedAt })

  expect(report.overview.total).toBe(count)
  expect(report.recent).toHaveLength(maxOperationOutcomeReportRecentRows)
  expect(report.recent[0]?.capability === "subagent" ? report.recent[0].workCycle : undefined).toBe(count)
  const oldestRecent = report.recent.at(-1)
  expect(oldestRecent?.capability === "subagent" ? oldestRecent.workCycle : undefined).toBe(
    count - maxOperationOutcomeReportRecentRows + 1
  )
  expect(report.dailyTrend).toHaveLength(maxOperationOutcomeReportTrendDays)
  expect(report.dailyTrend[0]?.date).toBe("2026-01-02")
  expect(report.subagentWorkCycles.profiles).toHaveLength(maxSubagentWorkCycleReportProfiles)
  expect(report.subagentWorkCycles.profiles[0]?.profile).toBe("profile-000")
  expect(report.subagentWorkCycles.profiles.at(-1)?.profile).toBe("profile-099")
})

test("loader deduplicates legacy and native outcomes and accounts for invalid and omitted journals", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-operation-report-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "agent"))
  try {
    const deduplicated = SessionManager.create(paths)
    deduplicated.appendMessage({ role: "user", content: "private task", timestamp: 1 })
    deduplicated.appendSubagent({
      event: "work_cycle_finished",
      name: "worker",
      workCycle: 1,
      status: "failed",
      preview: "legacy",
      originalBytes: 6,
      omittedBytes: 0,
      truncated: false,
      durationMs: 5,
      reason: "provider_error"
    })
    deduplicated.appendOperationOutcome({
      capability: "subagent",
      operation: "work_cycle",
      operationId: subagentWorkCycleOperationId("worker", 1),
      name: "worker",
      workCycle: 1,
      profile: "native-profile",
      result: "succeeded",
      preview: "native",
      originalBytes: 6,
      omittedBytes: 0,
      truncated: false,
      durationMs: 10
    })

    const omitted = SessionManager.create(paths)
    omitted.appendOperationOutcome({
      capability: "subagent",
      operation: "work_cycle",
      operationId: subagentWorkCycleOperationId("omitted", 1),
      name: "omitted",
      workCycle: 1,
      profile: "omitted-profile",
      result: "succeeded",
      preview: "omitted",
      originalBytes: 7,
      omittedBytes: 0,
      truncated: false,
      durationMs: 1
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
    await utimes(deduplicated.file!, new Date(3000), new Date(3000))

    const report = await loadOperationOutcomeReport(paths, { generatedAt, sessionLimit: 2 })

    expect(report.scope).toEqual({ cwd: paths.cwd, scanned: 1, sessionsWithOutcomes: 1, invalid: 1, omitted: 1 })
    expect(report.overview.total).toBe(1)
    expect(report.recent).toEqual([
      expect.objectContaining({
        sessionId: deduplicated.sessionId,
        result: "succeeded",
        profile: "native-profile",
        durationMs: 10
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

function reportSession(id: string, entries: readonly SessionEntry[]) {
  return { id, outcomes: projectSessionOutcomes(entries) }
}

function outcome(spec: OutcomeSpec): SessionEntry {
  const operationId = subagentWorkCycleOperationId(spec.name, spec.workCycle)
  const evidence = {
    type: "operation_outcome" as const,
    id: operationId,
    parentId: null,
    timestamp: spec.timestamp,
    capability: "subagent" as const,
    operation: "work_cycle" as const,
    operationId,
    name: spec.name,
    workCycle: spec.workCycle,
    ...(spec.profile === undefined ? {} : { profile: spec.profile }),
    preview: "",
    originalBytes: 0,
    omittedBytes: 0,
    truncated: spec.truncated ?? false,
    durationMs: spec.durationMs
  }
  if (spec.result === "failed") {
    return {
      ...evidence,
      result: spec.result,
      errorCode: spec.errorCode ?? "provider_error",
      ...(spec.errorMessage === undefined ? {} : { errorMessage: spec.errorMessage })
    }
  }
  return { ...evidence, result: spec.result }
}

type ShellOutcomeSpec = {
  readonly taskId: string
  readonly timestamp: string
  readonly origin: "requested" | "demoted"
  readonly durationMs: number
  readonly outputBytes: number
} & (
  | { readonly result: "succeeded" }
  | { readonly result: "cancelled"; readonly cancellationCode: "killed" | "disposed" }
  | { readonly result: "failed"; readonly errorCode: "exit_nonzero"; readonly exitCode: number }
)

function shellOutcome(spec: ShellOutcomeSpec): SessionEntry {
  const operationId = shellBackgroundTaskOperationId(spec.taskId)
  const evidence = {
    type: "operation_outcome" as const,
    id: operationId,
    parentId: null,
    timestamp: spec.timestamp,
    capability: "shell" as const,
    operation: "background_task" as const,
    operationId,
    taskId: spec.taskId,
    origin: spec.origin,
    durationMs: spec.durationMs,
    outputBytes: spec.outputBytes
  }
  if (spec.result === "succeeded") return { ...evidence, result: spec.result, exitCode: 0 }
  if (spec.result === "cancelled") {
    return { ...evidence, result: spec.result, cancellationCode: spec.cancellationCode }
  }
  return { ...evidence, result: spec.result, errorCode: spec.errorCode, exitCode: spec.exitCode }
}

function legacyOutcome(name: string, workCycle: number, timestamp: string, durationMs: number): SessionEntry {
  return {
    type: "subagent",
    event: "work_cycle_finished",
    id: `legacy-${name}-${workCycle}`,
    parentId: null,
    timestamp,
    name,
    workCycle,
    status: "cancelled",
    preview: "",
    originalBytes: 0,
    omittedBytes: 0,
    truncated: false,
    durationMs
  }
}
