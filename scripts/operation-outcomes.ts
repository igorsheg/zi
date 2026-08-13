import { resolve } from "node:path"

import { ZiPaths } from "../packages/coding-agent/src/paths.js"
import {
  defaultOperationOutcomeReportSessionLimit,
  loadOperationOutcomeReport,
  maxOperationOutcomeReportRecentRows,
  maxOperationOutcomeReportSessionLimit,
  type OperationOutcomeOverview,
  type OperationOutcomeReport
} from "./operation-outcome-report.js"

export type OperationOutcomeReportFormat = "json" | "text"

export interface OperationOutcomeScriptOptions {
  readonly cwd: string
  readonly agentDir?: string
  readonly since?: string
  readonly sessionLimit: number
  readonly recentLimit: number
  readonly format: OperationOutcomeReportFormat
  readonly compact: boolean
}

const usage = `Usage: bun run outcomes [options]

Read bounded durable operation outcomes for one project.

Options:
  --cwd <path>            Project to inspect (default: current directory)
  --agent-dir <path>      Zi global agent directory (default: ZI_AGENT_DIR or ~/.zi/agent)
  --since <timestamp>     Include outcomes at or after this UTC ISO 8601 timestamp
  --days <count>          Include outcomes from the last count × 24 hours
  --sessions <count>      Maximum session journals to scan (default: ${defaultOperationOutcomeReportSessionLimit})
  --recent <count>        Recent outcome rows to emit, 0-${maxOperationOutcomeReportRecentRows} (default: ${maxOperationOutcomeReportRecentRows})
  --format <json|text>    Output format (default: json)
  --compact               Emit compact JSON
  -h, --help              Show this help

JSON is the canonical, scriptable report. Diagnostics are written to stderr.`

export function parseOperationOutcomeScriptOptions(
  argv: readonly string[],
  now = new Date(),
  invocationCwd = process.cwd()
): OperationOutcomeScriptOptions | { readonly help: true } {
  let cwd = invocationCwd
  let agentDir: string | undefined
  let since: string | undefined
  let sessionLimit = defaultOperationOutcomeReportSessionLimit
  let recentLimit = maxOperationOutcomeReportRecentRows
  let format: OperationOutcomeReportFormat = "json"
  let compact = false

  for (let index = 0; index < argv.length; index++) {
    const argument = argv[index]!
    if (argument === "-h" || argument === "--help") return { help: true }
    if (argument === "--compact") {
      compact = true
      continue
    }

    const value = argv[++index]
    if (value === undefined) throw new Error(`${argument} requires a value`)
    switch (argument) {
      case "--cwd":
        cwd = value
        break
      case "--agent-dir":
        agentDir = value
        break
      case "--since":
        if (since !== undefined) throw new Error("Use either --since or --days once")
        since = parseSince(value)
        break
      case "--days":
        if (since !== undefined) throw new Error("Use either --since or --days once")
        since = daysSince(value, now)
        break
      case "--sessions":
        sessionLimit = boundedInteger(value, "--sessions", 1, maxOperationOutcomeReportSessionLimit)
        break
      case "--recent":
        recentLimit = boundedInteger(value, "--recent", 0, maxOperationOutcomeReportRecentRows)
        break
      case "--format":
        if (value !== "json" && value !== "text") throw new Error("--format must be json or text")
        format = value
        break
      default:
        throw new Error(`Unknown operation outcome argument: ${argument}`)
    }
  }

  if (compact && format !== "json") throw new Error("--compact requires --format json")
  return Object.freeze({
    cwd: resolve(invocationCwd, cwd),
    ...(agentDir === undefined ? {} : { agentDir: resolve(invocationCwd, agentDir) }),
    ...(since === undefined ? {} : { since }),
    sessionLimit,
    recentLimit,
    format,
    compact
  })
}

export async function createOperationOutcomeScriptReport(
  options: OperationOutcomeScriptOptions,
  generatedAt = new Date().toISOString()
): Promise<OperationOutcomeReport> {
  const paths = new ZiPaths(options.cwd, options.agentDir)
  const report = await loadOperationOutcomeReport(paths, {
    generatedAt,
    ...(options.since === undefined ? {} : { since: options.since }),
    sessionLimit: options.sessionLimit
  })
  if (options.recentLimit === report.recent.length) return report
  return Object.freeze({ ...report, recent: Object.freeze(report.recent.slice(0, options.recentLimit)) })
}

export function renderOperationOutcomeScriptReport(
  report: OperationOutcomeReport,
  format: OperationOutcomeReportFormat,
  compact = false
): string {
  return format === "json" ? JSON.stringify(report, null, compact ? undefined : 2) : renderTextReport(report)
}

export async function runOperationOutcomeScript(
  argv: readonly string[],
  stdout: Pick<typeof process.stdout, "write"> = process.stdout,
  stderr: Pick<typeof process.stderr, "write"> = process.stderr
): Promise<number> {
  try {
    const options = parseOperationOutcomeScriptOptions(argv)
    if ("help" in options) {
      stdout.write(`${usage}\n`)
      return 0
    }
    const report = await createOperationOutcomeScriptReport(options)
    if (report.scope.invalid > 0 || report.scope.omitted > 0) {
      stderr.write(
        `Operation outcome scan: ${report.scope.invalid} invalid journal${report.scope.invalid === 1 ? "" : "s"}, ${report.scope.omitted} past the session bound.\n`
      )
    }
    stdout.write(`${renderOperationOutcomeScriptReport(report, options.format, options.compact)}\n`)
    return 0
  } catch (cause) {
    stderr.write(`Unable to report operation outcomes: ${cause instanceof Error ? cause.message : String(cause)}\n`)
    return 1
  }
}

function renderTextReport(report: OperationOutcomeReport): string {
  const lines = [
    "Operation outcomes",
    `Scope: ${report.scope.cwd}`,
    `Generated: ${report.generatedAt}`,
    ...(report.since === undefined ? [] : [`Since: ${report.since}`]),
    `Sessions: ${report.scope.sessionsWithOutcomes} with outcomes / ${report.scope.scanned} scanned / ${report.scope.invalid} invalid / ${report.scope.omitted} omitted`,
    overviewLine("All operations", report.overview),
    "",
    "Capabilities"
  ]

  if (report.capabilities.length === 0) lines.push("  None")
  for (const row of report.capabilities) lines.push(`  ${row.capability}/${row.operation}: ${overviewValues(row)}`)

  lines.push("", "Daily trend")
  if (report.dailyTrend.length === 0) lines.push("  None")
  for (const day of report.dailyTrend) {
    lines.push(
      `  ${day.date}: succeeded=${day.succeeded}, failed=${day.failed}, cancelled=${day.cancelled}, p95=${duration(day.p95DurationMs)}`
    )
  }

  lines.push("", `Recent outcomes (${report.recent.length})`)
  if (report.recent.length === 0) lines.push("  None")
  for (const outcome of report.recent) {
    lines.push(
      `  ${outcome.timestamp} ${outcome.capability}/${outcome.operation} ${outcome.result} ${duration(outcome.durationMs)} operation=${outcome.operationId} entry=${outcome.id} session=${outcome.sessionId} evidence=${JSON.stringify(outcome.evidence)}`
    )
  }

  return lines.join("\n")
}

function overviewLine(label: string, overview: OperationOutcomeOverview): string {
  return `${label}: ${overviewValues(overview)}`
}

function overviewValues(overview: OperationOutcomeOverview): string {
  return `total=${overview.total}, succeeded=${overview.succeeded}, failed=${overview.failed}, cancelled=${overview.cancelled}, success=${percentage(overview.successRate)}, p50=${duration(overview.p50DurationMs)}, p95=${duration(overview.p95DurationMs)}`
}

function percentage(value: number | null): string {
  return value === null ? "n/a" : `${(value * 100).toFixed(1)}%`
}

function duration(value: number | null): string {
  return value === null ? "n/a" : `${value}ms`
}

function parseSince(value: string): string {
  const match = value.match(/^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,3}))?Z$/)
  if (!match) throw new Error("--since must be a UTC ISO 8601 timestamp")
  const timestamp = Date.parse(value)
  const normalized = new Date(timestamp).toISOString()
  const milliseconds = (match[7] ?? "").padEnd(3, "0")
  const canonical = `${match[1]}-${match[2]}-${match[3]}T${match[4]}:${match[5]}:${match[6]}.${milliseconds}Z`
  if (!Number.isFinite(timestamp) || normalized !== canonical) {
    throw new Error("--since must be a UTC ISO 8601 timestamp")
  }
  return normalized
}

function daysSince(value: string, now: Date): string {
  const days = boundedInteger(value, "--days", 1, 3650)
  return new Date(now.getTime() - days * 86_400_000).toISOString()
}

function boundedInteger(value: string, option: string, minimum: number, maximum: number): number {
  if (!/^\d+$/.test(value)) throw new Error(`${option} must be an integer from ${minimum} to ${maximum}`)
  const parsed = Number(value)
  if (!Number.isSafeInteger(parsed) || parsed < minimum || parsed > maximum) {
    throw new Error(`${option} must be an integer from ${minimum} to ${maximum}`)
  }
  return parsed
}

if (import.meta.main) process.exitCode = await runOperationOutcomeScript(process.argv.slice(2))
