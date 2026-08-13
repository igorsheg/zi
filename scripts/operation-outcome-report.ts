import type { OperationOutcome } from "../packages/coding-agent/src/operation-outcomes.js"
import type { ZiPaths } from "../packages/coding-agent/src/paths.js"
import { maxSessionListResults, SessionManager } from "../packages/coding-agent/src/session-manager.js"

export const defaultOperationOutcomeReportSessionLimit = maxSessionListResults
export const maxOperationOutcomeReportSessionLimit = maxSessionListResults
export const maxOperationOutcomeReportRecentRows = 100
export const maxOperationOutcomeReportTrendDays = 366
export const maxOperationOutcomeReportCapabilities = 50

export interface OperationOutcomeReportSession {
  readonly id: string
  readonly outcomes: readonly OperationOutcome[]
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

export type RecentOperationOutcome = OperationOutcome & { readonly sessionId: string }

export interface OperationOutcomeReport {
  readonly generatedAt: string
  readonly since?: string
  readonly scope: OperationOutcomeReportScope
  readonly overview: OperationOutcomeOverview
  readonly capabilities: readonly OperationOutcomeCapabilityRow[]
  readonly dailyTrend: readonly OperationOutcomeDailyTrend[]
  readonly recent: readonly RecentOperationOutcome[]
}

interface OutcomeRecord {
  readonly sessionId: string
  readonly outcome: OperationOutcome
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

interface DailyAggregate extends ResultCounts {
  readonly date: string
  readonly durations: number[]
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

  const recent = Object.freeze(
    records
      .toSorted(
        (left, right) =>
          right.timestampMs - left.timestampMs ||
          compareText(left.sessionId, right.sessionId) ||
          compareText(left.outcome.id, right.outcome.id) ||
          compareText(left.outcome.operationId, right.outcome.operationId)
      )
      .slice(0, maxOperationOutcomeReportRecentRows)
      .map(record => Object.freeze({ sessionId: record.sessionId, ...record.outcome }))
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
    recent
  })
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
      sessions.push({ id: session.sessionId, outcomes: session.operationOutcomes() })
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
