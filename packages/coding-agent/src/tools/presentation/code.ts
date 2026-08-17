import { isCodeModeDetails, type CodeModeFailureStage, type CodeModeTraceCall } from "../../code-mode/trace.js"
import { isRecord } from "../../guards.js"
import { maxExpandedToolRows, type ToolPresentation, type ToolPresentationSource } from "./types.js"
import {
  boundHead,
  boundInline,
  matchesToolOutcome,
  normalizeToolText,
  recordValue,
  resultDetails,
  resultText
} from "./values.js"

// Pi Fabric v0.40.3 (08019b61) previews eight source lines. Zi replaces source with activity after the first trace so live updates never reproject unchanged code.
const compactCodeRows = 8

export function projectCodeTool(source: ToolPresentationSource): ToolPresentation {
  const args = recordValue(source.args)
  const code = typeof args?.code === "string" ? args.code : ""
  const description = typeof args?.description === "string" ? boundInline(args.description, 160) : undefined
  const detailValue = "result" in source ? resultDetails(source.result) : undefined
  const trace =
    isCodeModeDetails(detailValue) && matchesToolOutcome(source, detailValue.outcome) ? detailValue : undefined
  const sourcePreview = !trace && code ? formatSource(code) : undefined
  const running = trace?.calls.findLast(call => call.state === "running")
  const subject = description ?? (running ? boundInline(running.name) : undefined)
  const details = trace
    ? traceDetails(trace.calls, trace.outcome)
    : sourcePreview
      ? [lineLabel(sourcePreview.lines)]
      : []
  const terminal =
    trace?.outcome === "error"
      ? `× ${boundInline(trace.error, 160)}`
      : trace?.outcome === "success" && "result" in source
        ? `→ ${boundInline(resultText(source.result) ?? "completed", 160)}`
        : undefined
  const activity = trace
    ? formatTrace(trace.calls, trace.outcome === "progress" ? trace.logs : [], terminal)
    : undefined
  const body = activity ?? sourcePreview?.text

  return {
    header: { label: "Code", ...(subject ? { subject: { type: "text", text: subject } as const } : {}), details },
    ...(body
      ? {
          body: activity
            ? {
                type: "text" as const,
                text: body,
                tone:
                  source.status === "failed" || trace?.outcome === "error" ? ("error" as const) : ("normal" as const)
              }
            : { type: "code" as const, text: body, language: "typescript" as const, startLine: 1 }
        }
      : {}),
    notices: [],
    preview: trace
      ? { compact: { type: "tail", rows: 5 }, detailed: { type: "head", rows: maxExpandedToolRows } }
      : { compact: { type: "head", rows: compactCodeRows }, detailed: { type: "head", rows: maxExpandedToolRows } },
    timing: "duration"
  }
}

function traceDetails(calls: readonly CodeModeTraceCall[], outcome: "progress" | "success" | "error"): string[] {
  const completed = calls.filter(call => call.state !== "running").length
  const failed = calls.filter(call => call.state === "failed").length
  const aborted = calls.filter(call => call.state === "aborted").length
  const details: string[] = []

  if (calls.length > 0) {
    details.push(outcome === "progress" ? `${completed}/${calls.length} calls` : callLabel(calls.length))
  }
  if (failed > 0) details.push(`${failed} failed`)
  if (aborted > 0) details.push(`${aborted} aborted`)
  return details
}

function formatSource(code: string): { text: string; lines: number } {
  const normalized = normalizeToolText(code)
  const bounded = boundHead(normalized)
  const output = bounded ? bounded.split("\n") : []
  if (bounded !== normalized) output.push("// … source truncated")
  return { text: output.join("\n"), lines: normalized.split("\n").length }
}

function formatTrace(
  calls: readonly CodeModeTraceCall[],
  logs: readonly string[],
  terminal: string | undefined
): string | undefined {
  const lines = calls.map(call => {
    const detail = callDetail(call)
    switch (call.state) {
      case "running":
        return `… ${call.name}${detail ? ` ${detail}` : ""}${call.preview ? ` — ${boundInline(call.preview, 160)}` : ""}`
      case "succeeded": {
        const result = "result" in call ? ` — ${boundInline(call.result, 160)}` : ""
        return `✓ ${call.name}${detail ? ` ${detail}` : ""}${result}`
      }
      case "failed": {
        const error = call.error === undefined ? failureStageLabel(call.stage) : boundInline(call.error, 160)
        return `× ${call.name}${detail ? ` ${detail}` : ""} — ${error}`
      }
      case "aborted":
        return `■ ${call.name}${detail ? ` ${detail}` : ""} — aborted`
      default:
        return assertNever(call)
    }
  })
  const progress = logs.findLast(log => log.trim().length > 0)
  if (progress) lines.push(`… ${boundInline(progress, 160)}`)
  if (terminal) lines.push(terminal)
  return lines.length > 0 ? lines.join("\n") : undefined
}

function failureStageLabel(stage: CodeModeFailureStage | undefined): string {
  if (stage === undefined) return "failed"
  switch (stage) {
    case "prepare":
      return "argument preparation failed"
    case "validate":
      return "argument validation failed"
    case "invoke":
      return "invoke failed"
    default:
      return assertNever(stage)
  }
}

function callDetail(call: CodeModeTraceCall): string | undefined {
  const input = call.arguments
  if (!isRecord(input)) return undefined
  if (typeof input.path === "string") return boundInline(input.path)
  if (typeof input.command === "string") return `$ ${boundInline(input.command)}`
  if (typeof input.operation === "string") return boundInline(input.operation)
  return undefined
}

function callLabel(calls: number): string {
  return `${calls} ${calls === 1 ? "call" : "calls"}`
}

function lineLabel(lines: number): string {
  return `${lines} ${lines === 1 ? "line" : "lines"}`
}

function assertNever(value: never): never {
  throw new Error(`Unknown code-mode call state: ${String(value)}`)
}
