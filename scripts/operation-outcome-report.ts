import {
  projectSessionOutcomes,
  type ProjectedOperationOutcome,
  type ProjectedShellBackgroundTaskOutcome,
  type ProjectedSubagentWorkCycleOutcome,
  type ShellBackgroundTaskCancellationCode,
  type ShellBackgroundTaskErrorCode,
  type ShellBackgroundTaskOrigin
} from "../packages/coding-agent/src/operation-outcomes.js"
import type { ZiPaths } from "../packages/coding-agent/src/paths.js"
import { maxSessionListResults, SessionManager } from "../packages/coding-agent/src/session-manager.js"

export const defaultOperationOutcomeReportSessionLimit = maxSessionListResults
export const maxOperationOutcomeReportSessionLimit = maxSessionListResults
export const maxOperationOutcomeReportRecentRows = 100
export const maxOperationOutcomeReportTrendDays = 366
export const maxOperationOutcomeReportCapabilities = 50
export const maxSubagentWorkCycleReportFailureGroups = 50
export const maxSubagentWorkCycleReportProfiles = 100
export const maxBackgroundTaskReportFailureGroups = 10
export const maxBackgroundTaskReportCancellationGroups = 5
export const maxBackgroundTaskReportOrigins = 2
export const legacySubagentWorkCycleProfileLabel = "Legacy / unspecified"

export interface OperationOutcomeReportSession {
  readonly id: string
  readonly outcomes: readonly ProjectedOperationOutcome[]
}

export interface BuildOperationOutcomeReportOptions {
  readonly cwd: string
  readonly generatedAt: string
  readonly since?: string
  readonly invalid?: number
  readonly omitted?: number
}

export interface LoadOperationOutcomeReportOptions {
  readonly generatedAt?: string
  readonly since?: string
  readonly sessionLimit?: number
}

export interface OperationOutcomeReportScope {
  readonly cwd: string
  readonly scanned: number
  readonly sessionsWithOutcomes: number
  readonly invalid: number
  readonly omitted: number
}

export interface OperationOutcomeOverview {
  readonly total: number
  readonly succeeded: number
  readonly failed: number
  readonly cancelled: number
  readonly successRate: number | null
  readonly p50DurationMs: number | null
  readonly p95DurationMs: number | null
}

export interface OperationOutcomeCapabilityRow {
  readonly capability: string
  readonly operation: string
  readonly total: number
  readonly succeeded: number
  readonly failed: number
  readonly cancelled: number
  readonly successRate: number
  readonly p50DurationMs: number
  readonly p95DurationMs: number
}

export interface OperationOutcomeDailyTrend {
  readonly date: string
  readonly succeeded: number
  readonly failed: number
  readonly cancelled: number
  readonly p95DurationMs: number
}

export interface SubagentWorkCycleFailureGroup {
  readonly errorCode: string
  readonly count: number
  readonly share: number
  readonly affectedProfileCount: number
}

export interface SubagentWorkCycleProfileRow {
  readonly profile: string
  readonly total: number
  readonly succeeded: number
  readonly failed: number
  readonly cancelled: number
  readonly successRate: number
  readonly p50DurationMs: number
  readonly p95DurationMs: number
  readonly truncated: number
}

export interface SubagentWorkCycleOverview extends OperationOutcomeOverview {
  readonly truncated: number
  readonly truncatedRate: number | null
}

export interface SubagentWorkCycleOutcomeReport {
  readonly overview: SubagentWorkCycleOverview
  readonly failureGroups: readonly SubagentWorkCycleFailureGroup[]
  readonly profiles: readonly SubagentWorkCycleProfileRow[]
}

export interface BackgroundTaskFailureGroup {
  readonly errorCode: ShellBackgroundTaskErrorCode
  readonly count: number
  readonly share: number
}

export interface BackgroundTaskCancellationGroup {
  readonly cancellationCode: ShellBackgroundTaskCancellationCode
  readonly count: number
  readonly share: number
}

export interface BackgroundTaskOriginRow extends OperationOutcomeOverview {
  readonly origin: ShellBackgroundTaskOrigin
}

export interface BackgroundTaskOutputSummary {
  readonly totalBytes: number
  readonly p50Bytes: number | null
  readonly p95Bytes: number | null
}

export interface BackgroundTaskOutcomeReport {
  readonly overview: OperationOutcomeOverview
  readonly failureGroups: readonly BackgroundTaskFailureGroup[]
  readonly cancellationGroups: readonly BackgroundTaskCancellationGroup[]
  readonly origins: readonly BackgroundTaskOriginRow[]
  readonly output: BackgroundTaskOutputSummary
}

interface RecentOperationOutcomeEvidence {
  readonly sessionId: string
  readonly sourceEntryId: string
  readonly timestamp: string
  readonly operationId: string
  readonly durationMs: number
}

export type RecentSubagentWorkCycleOutcome = RecentOperationOutcomeEvidence & {
  readonly capability: "subagent"
  readonly operation: "work_cycle"
  readonly runtimeName: string
  readonly workCycle: number
  readonly profile: string
  readonly truncated: boolean
} & (
    | { readonly result: "succeeded" | "cancelled"; readonly errorCode?: never; readonly errorMessage?: never }
    | { readonly result: "failed"; readonly errorCode: string; readonly errorMessage?: string }
  )

export type RecentShellBackgroundTaskOutcome = RecentOperationOutcomeEvidence & {
  readonly capability: "shell"
  readonly operation: "background_task"
  readonly taskId: string
  readonly origin: ShellBackgroundTaskOrigin
  readonly outputBytes: number
} & (
    | { readonly result: "succeeded"; readonly exitCode: 0 }
    | { readonly result: "cancelled"; readonly cancellationCode: ShellBackgroundTaskCancellationCode }
    | { readonly result: "failed"; readonly errorCode: "exit_nonzero"; readonly exitCode: number }
    | { readonly result: "failed"; readonly errorCode: "signaled"; readonly signal: string }
    | {
        readonly result: "failed"
        readonly errorCode: Exclude<ShellBackgroundTaskErrorCode, "exit_nonzero" | "signaled">
      }
  )

export type RecentOperationOutcome = RecentSubagentWorkCycleOutcome | RecentShellBackgroundTaskOutcome

export interface OperationOutcomeReport {
  readonly generatedAt: string
  readonly since?: string
  readonly scope: OperationOutcomeReportScope
  readonly overview: OperationOutcomeOverview
  readonly capabilities: readonly OperationOutcomeCapabilityRow[]
  readonly dailyTrend: readonly OperationOutcomeDailyTrend[]
  readonly subagentWorkCycles: SubagentWorkCycleOutcomeReport
  readonly backgroundTasks: BackgroundTaskOutcomeReport
  readonly recent: readonly RecentOperationOutcome[]
}

interface OutcomeRecord {
  readonly sessionId: string
  readonly outcome: ProjectedOperationOutcome
  readonly timestampMs: number
}

interface ResultCounts {
  succeeded: number
  failed: number
  cancelled: number
}

interface CapabilityAggregate extends ResultCounts {
  readonly capability: string
  readonly operation: string
  readonly durations: number[]
  total: number
}

interface ProfileAggregate extends ResultCounts {
  readonly profile: string
  readonly durations: number[]
  total: number
  truncated: number
}

interface DailyAggregate extends ResultCounts {
  readonly date: string
  readonly durations: number[]
}

interface FailureAggregate {
  readonly errorCode: string
  readonly profiles: Set<string>
  count: number
}

interface SubagentWorkCycleAggregate {
  readonly counts: ResultCounts
  readonly durations: number[]
  readonly failures: Map<string, FailureAggregate>
  readonly profiles: Map<string, ProfileAggregate>
  truncated: number
}

interface BackgroundTaskOriginAggregate extends ResultCounts {
  readonly origin: ShellBackgroundTaskOrigin
  readonly durations: number[]
  total: number
}

interface BackgroundTaskAggregate {
  readonly counts: ResultCounts
  readonly durations: number[]
  readonly outputBytes: number[]
  readonly failures: Map<ShellBackgroundTaskErrorCode, number>
  readonly cancellations: Map<ShellBackgroundTaskCancellationCode, number>
  readonly origins: Map<ShellBackgroundTaskOrigin, BackgroundTaskOriginAggregate>
}

interface CapabilityAggregates {
  readonly subagentWorkCycles: SubagentWorkCycleAggregate
  readonly backgroundTasks: BackgroundTaskAggregate
}

export function buildOperationOutcomeReport(
  sessions: readonly OperationOutcomeReportSession[],
  options: BuildOperationOutcomeReportOptions
): OperationOutcomeReport {
  validateReportOptions(options)
  const sinceMs = options.since === undefined ? undefined : Date.parse(options.since)
  const records: OutcomeRecord[] = []
  let sessionsWithOutcomes = 0

  for (const session of sessions) {
    const outcomes = session.outcomes.filter(
      outcome => sinceMs === undefined || Date.parse(outcome.timestamp) >= sinceMs
    )
    if (outcomes.length > 0) sessionsWithOutcomes++
    for (const outcome of outcomes) {
      records.push({ sessionId: session.id, outcome, timestampMs: Date.parse(outcome.timestamp) })
    }
  }

  const counts: ResultCounts = { succeeded: 0, failed: 0, cancelled: 0 }
  const durations: number[] = []
  const capabilities = new Map<string, CapabilityAggregate>()
  const daily = new Map<string, DailyAggregate>()
  const aggregates: CapabilityAggregates = {
    subagentWorkCycles: {
      counts: { succeeded: 0, failed: 0, cancelled: 0 },
      durations: [],
      failures: new Map(),
      profiles: new Map(),
      truncated: 0
    },
    backgroundTasks: {
      counts: { succeeded: 0, failed: 0, cancelled: 0 },
      durations: [],
      outputBytes: [],
      failures: new Map(),
      cancellations: new Map(),
      origins: new Map()
    }
  }

  for (const record of records) {
    const { outcome } = record
    counts[outcome.result]++
    durations.push(outcome.durationMs)

    const capabilityKey = `${outcome.capability}\0${outcome.operation}`
    const capability = capabilities.get(capabilityKey) ?? {
      capability: outcome.capability,
      operation: outcome.operation,
      total: 0,
      succeeded: 0,
      failed: 0,
      cancelled: 0,
      durations: []
    }
    capability.total++
    capability[outcome.result]++
    capability.durations.push(outcome.durationMs)
    capabilities.set(capabilityKey, capability)

    const date = new Date(record.timestampMs).toISOString().slice(0, 10)
    const day = daily.get(date) ?? { date, succeeded: 0, failed: 0, cancelled: 0, durations: [] }
    day[outcome.result]++
    day.durations.push(outcome.durationMs)
    daily.set(date, day)

    aggregateCapabilityEvidence(outcome, aggregates)
  }

  const [p50DurationMs, p95DurationMs] = durationPercentiles(durations)
  const total = records.length
  const overview: OperationOutcomeOverview = Object.freeze({
    total,
    ...counts,
    successRate: total === 0 ? null : counts.succeeded / total,
    p50DurationMs,
    p95DurationMs
  })
  const subagent = aggregates.subagentWorkCycles
  const [subagentP50DurationMs, subagentP95DurationMs] = durationPercentiles(subagent.durations)
  const subagentTotal = subagent.durations.length
  const subagentOverview = Object.freeze({
    total: subagentTotal,
    ...subagent.counts,
    successRate: subagentTotal === 0 ? null : subagent.counts.succeeded / subagentTotal,
    p50DurationMs: subagentP50DurationMs,
    p95DurationMs: subagentP95DurationMs,
    truncated: subagent.truncated,
    truncatedRate: subagentTotal === 0 ? null : subagent.truncated / subagentTotal
  })

  const capabilityRows = Object.freeze(
    [...capabilities.values()]
      .toSorted(
        (left, right) =>
          right.total - left.total ||
          compareText(left.capability, right.capability) ||
          compareText(left.operation, right.operation)
      )
      .slice(0, maxOperationOutcomeReportCapabilities)
      .map(capability => {
        const sortedDurations = capability.durations.toSorted((left, right) => left - right)
        return Object.freeze({
          capability: capability.capability,
          operation: capability.operation,
          total: capability.total,
          succeeded: capability.succeeded,
          failed: capability.failed,
          cancelled: capability.cancelled,
          successRate: capability.succeeded / capability.total,
          p50DurationMs: nearestRank(sortedDurations, 0.5),
          p95DurationMs: nearestRank(sortedDurations, 0.95)
        })
      })
  )

  const dailyTrend = Object.freeze(
    [...daily.values()]
      .toSorted((left, right) => compareText(left.date, right.date))
      .slice(-maxOperationOutcomeReportTrendDays)
      .map(day =>
        Object.freeze({
          date: day.date,
          succeeded: day.succeeded,
          failed: day.failed,
          cancelled: day.cancelled,
          p95DurationMs: nearestRank(
            day.durations.toSorted((left, right) => left - right),
            0.95
          )
        })
      )
  )

  const subagentFailureGroups = Object.freeze(
    [...subagent.failures.values()]
      .toSorted((left, right) => right.count - left.count || compareText(left.errorCode, right.errorCode))
      .slice(0, maxSubagentWorkCycleReportFailureGroups)
      .map(failure =>
        Object.freeze({
          errorCode: failure.errorCode,
          count: failure.count,
          share: failure.count / subagent.counts.failed,
          affectedProfileCount: failure.profiles.size
        })
      )
  )

  const subagentProfileRows = Object.freeze(
    [...subagent.profiles.values()]
      .toSorted((left, right) => right.total - left.total || compareText(left.profile, right.profile))
      .slice(0, maxSubagentWorkCycleReportProfiles)
      .map(profile => {
        const sortedDurations = profile.durations.toSorted((left, right) => left - right)
        return Object.freeze({
          profile: profile.profile,
          total: profile.total,
          succeeded: profile.succeeded,
          failed: profile.failed,
          cancelled: profile.cancelled,
          successRate: profile.succeeded / profile.total,
          p50DurationMs: nearestRank(sortedDurations, 0.5),
          p95DurationMs: nearestRank(sortedDurations, 0.95),
          truncated: profile.truncated
        })
      })
  )

  const background = aggregates.backgroundTasks
  const [backgroundP50DurationMs, backgroundP95DurationMs] = durationPercentiles(background.durations)
  const backgroundTotal = background.durations.length
  const backgroundOverview: OperationOutcomeOverview = Object.freeze({
    total: backgroundTotal,
    ...background.counts,
    successRate: backgroundTotal === 0 ? null : background.counts.succeeded / backgroundTotal,
    p50DurationMs: backgroundP50DurationMs,
    p95DurationMs: backgroundP95DurationMs
  })
  const backgroundFailureGroups = Object.freeze(
    [...background.failures]
      .toSorted(
        ([leftCode, leftCount], [rightCode, rightCount]) => rightCount - leftCount || compareText(leftCode, rightCode)
      )
      .slice(0, maxBackgroundTaskReportFailureGroups)
      .map(([errorCode, count]) => Object.freeze({ errorCode, count, share: count / background.counts.failed }))
  )
  const backgroundCancellationGroups = Object.freeze(
    [...background.cancellations]
      .toSorted(
        ([leftCode, leftCount], [rightCode, rightCount]) => rightCount - leftCount || compareText(leftCode, rightCode)
      )
      .slice(0, maxBackgroundTaskReportCancellationGroups)
      .map(([cancellationCode, count]) =>
        Object.freeze({ cancellationCode, count, share: count / background.counts.cancelled })
      )
  )
  const backgroundOrigins = Object.freeze(
    [...background.origins.values()]
      .toSorted((left, right) => right.total - left.total || compareText(left.origin, right.origin))
      .slice(0, maxBackgroundTaskReportOrigins)
      .map(origin => {
        const [originP50DurationMs, originP95DurationMs] = durationPercentiles(origin.durations)
        return Object.freeze({
          origin: origin.origin,
          total: origin.total,
          succeeded: origin.succeeded,
          failed: origin.failed,
          cancelled: origin.cancelled,
          successRate: origin.succeeded / origin.total,
          p50DurationMs: originP50DurationMs,
          p95DurationMs: originP95DurationMs
        })
      })
  )
  const [p50OutputBytes, p95OutputBytes] = durationPercentiles(background.outputBytes)
  const backgroundOutput: BackgroundTaskOutputSummary = Object.freeze({
    totalBytes: background.outputBytes.reduce((sum, bytes) => sum + bytes, 0),
    p50Bytes: p50OutputBytes,
    p95Bytes: p95OutputBytes
  })

  const recent = Object.freeze(
    records
      .toSorted(
        (left, right) =>
          right.timestampMs - left.timestampMs ||
          compareText(left.sessionId, right.sessionId) ||
          compareText(left.outcome.sourceEntryId, right.outcome.sourceEntryId) ||
          compareText(left.outcome.operationId, right.outcome.operationId)
      )
      .slice(0, maxOperationOutcomeReportRecentRows)
      .map(recentOutcome)
  )

  return Object.freeze({
    generatedAt: options.generatedAt,
    ...(options.since === undefined ? {} : { since: options.since }),
    scope: Object.freeze({
      cwd: options.cwd,
      scanned: sessions.length,
      sessionsWithOutcomes,
      invalid: options.invalid ?? 0,
      omitted: options.omitted ?? 0
    }),
    overview,
    capabilities: capabilityRows,
    dailyTrend,
    subagentWorkCycles: Object.freeze({
      overview: subagentOverview,
      failureGroups: subagentFailureGroups,
      profiles: subagentProfileRows
    }),
    backgroundTasks: Object.freeze({
      overview: backgroundOverview,
      failureGroups: backgroundFailureGroups,
      cancellationGroups: backgroundCancellationGroups,
      origins: backgroundOrigins,
      output: backgroundOutput
    }),
    recent
  })
}

function aggregateCapabilityEvidence(outcome: ProjectedOperationOutcome, aggregates: CapabilityAggregates): void {
  switch (outcome.capability) {
    case "subagent":
      aggregateSubagentWorkCycle(outcome, aggregates.subagentWorkCycles)
      return
    case "shell":
      aggregateBackgroundTask(outcome, aggregates.backgroundTasks)
      return
    default:
      return assertNever(outcome)
  }
}

function aggregateSubagentWorkCycle(
  outcome: ProjectedSubagentWorkCycleOutcome,
  aggregate: SubagentWorkCycleAggregate
): void {
  const profile = outcome.profile ?? legacySubagentWorkCycleProfileLabel
  aggregate.counts[outcome.result]++
  aggregate.durations.push(outcome.durationMs)
  if (outcome.truncated) aggregate.truncated++

  const profileRow = aggregate.profiles.get(profile) ?? {
    profile,
    total: 0,
    succeeded: 0,
    failed: 0,
    cancelled: 0,
    durations: [],
    truncated: 0
  }
  profileRow.total++
  profileRow[outcome.result]++
  profileRow.durations.push(outcome.durationMs)
  if (outcome.truncated) profileRow.truncated++
  aggregate.profiles.set(profile, profileRow)

  if (outcome.result !== "failed") return
  const failure = aggregate.failures.get(outcome.errorCode) ?? {
    errorCode: outcome.errorCode,
    count: 0,
    profiles: new Set<string>()
  }
  failure.count++
  failure.profiles.add(profile)
  aggregate.failures.set(outcome.errorCode, failure)
}

function aggregateBackgroundTask(
  outcome: ProjectedShellBackgroundTaskOutcome,
  aggregate: BackgroundTaskAggregate
): void {
  aggregate.counts[outcome.result]++
  aggregate.durations.push(outcome.durationMs)
  aggregate.outputBytes.push(outcome.outputBytes)

  const origin = aggregate.origins.get(outcome.origin) ?? {
    origin: outcome.origin,
    total: 0,
    succeeded: 0,
    failed: 0,
    cancelled: 0,
    durations: []
  }
  origin.total++
  origin[outcome.result]++
  origin.durations.push(outcome.durationMs)
  aggregate.origins.set(outcome.origin, origin)

  if (outcome.result === "failed") {
    aggregate.failures.set(outcome.errorCode, (aggregate.failures.get(outcome.errorCode) ?? 0) + 1)
  } else if (outcome.result === "cancelled") {
    aggregate.cancellations.set(
      outcome.cancellationCode,
      (aggregate.cancellations.get(outcome.cancellationCode) ?? 0) + 1
    )
  }
}

export async function loadOperationOutcomeReport(
  paths: ZiPaths,
  options: LoadOperationOutcomeReportOptions = {}
): Promise<OperationOutcomeReport> {
  const sessionLimit = options.sessionLimit ?? defaultOperationOutcomeReportSessionLimit
  const listed = await SessionManager.list(paths, { limit: sessionLimit })
  const sessions: OperationOutcomeReportSession[] = []
  let invalid = listed.invalid

  for (const info of listed.sessions) {
    try {
      const session = SessionManager.open(info.path)
      sessions.push({ id: session.sessionId, outcomes: projectSessionOutcomes(session.entries()) })
    } catch {
      invalid++
    }
  }

  return buildOperationOutcomeReport(sessions, {
    cwd: paths.cwd,
    generatedAt: options.generatedAt ?? new Date().toISOString(),
    ...(options.since === undefined ? {} : { since: options.since }),
    invalid,
    omitted: listed.omitted
  })
}

function recentOutcome(record: OutcomeRecord): RecentOperationOutcome {
  switch (record.outcome.capability) {
    case "subagent":
      return recentSubagentWorkCycle(record.sessionId, record.outcome)
    case "shell":
      return recentBackgroundTask(record.sessionId, record.outcome)
    default:
      return assertNever(record.outcome)
  }
}

function recentSubagentWorkCycle(
  sessionId: string,
  outcome: ProjectedSubagentWorkCycleOutcome
): RecentSubagentWorkCycleOutcome {
  const evidence = {
    sessionId,
    sourceEntryId: outcome.sourceEntryId,
    timestamp: outcome.timestamp,
    operationId: outcome.operationId,
    capability: outcome.capability,
    operation: outcome.operation,
    runtimeName: outcome.name,
    workCycle: outcome.workCycle,
    profile: outcome.profile ?? legacySubagentWorkCycleProfileLabel,
    durationMs: outcome.durationMs,
    truncated: outcome.truncated
  } as const
  if (outcome.result !== "failed") return Object.freeze({ ...evidence, result: outcome.result })
  return Object.freeze({
    ...evidence,
    result: outcome.result,
    errorCode: outcome.errorCode,
    ...(outcome.errorMessage === undefined ? {} : { errorMessage: outcome.errorMessage })
  })
}

function recentBackgroundTask(
  sessionId: string,
  outcome: ProjectedShellBackgroundTaskOutcome
): RecentShellBackgroundTaskOutcome {
  const evidence = {
    sessionId,
    sourceEntryId: outcome.sourceEntryId,
    timestamp: outcome.timestamp,
    operationId: outcome.operationId,
    capability: outcome.capability,
    operation: outcome.operation,
    taskId: outcome.taskId,
    origin: outcome.origin,
    durationMs: outcome.durationMs,
    outputBytes: outcome.outputBytes
  } as const
  switch (outcome.result) {
    case "succeeded":
      return Object.freeze({ ...evidence, result: outcome.result, exitCode: outcome.exitCode })
    case "cancelled":
      return Object.freeze({ ...evidence, result: outcome.result, cancellationCode: outcome.cancellationCode })
    case "failed":
      if (outcome.errorCode === "exit_nonzero") {
        return Object.freeze({
          ...evidence,
          result: outcome.result,
          errorCode: outcome.errorCode,
          exitCode: outcome.exitCode
        })
      }
      if (outcome.errorCode === "signaled") {
        return Object.freeze({
          ...evidence,
          result: outcome.result,
          errorCode: outcome.errorCode,
          signal: outcome.signal
        })
      }
      return Object.freeze({ ...evidence, result: outcome.result, errorCode: outcome.errorCode })
    default:
      return assertNever(outcome)
  }
}

function durationPercentiles(durations: readonly number[]): readonly [number | null, number | null] {
  if (durations.length === 0) return [null, null]
  const sorted = durations.toSorted((left, right) => left - right)
  return [nearestRank(sorted, 0.5), nearestRank(sorted, 0.95)]
}

function nearestRank(sorted: readonly number[], percentile: number): number {
  return sorted[Math.ceil(percentile * sorted.length) - 1]!
}

function compareText(left: string, right: string): number {
  return left < right ? -1 : left > right ? 1 : 0
}

function assertNever(value: never): never {
  throw new Error(`Unexpected operation outcome: ${String(value)}`)
}

function validateReportOptions(options: BuildOperationOutcomeReportOptions): void {
  if (!Number.isFinite(Date.parse(options.generatedAt))) throw new Error("Invalid report generated timestamp")
  if (options.since !== undefined && !Number.isFinite(Date.parse(options.since))) {
    throw new Error("Invalid report range timestamp")
  }
  if (options.invalid !== undefined && (!Number.isInteger(options.invalid) || options.invalid < 0)) {
    throw new Error("Invalid report invalid-session count")
  }
  if (options.omitted !== undefined && (!Number.isInteger(options.omitted) || options.omitted < 0)) {
    throw new Error("Invalid report omitted-session count")
  }
}
