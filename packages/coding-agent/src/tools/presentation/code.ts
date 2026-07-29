import { isCodeModeDetails, type CodeModeCall } from "../../code-mode/trace.js"
import { maxExpandedToolRows, type ToolPresentation, type ToolPresentationSource } from "./types.js"
import { boundHead, boundInline, matchesToolOutcome, recordValue, resultDetails, resultText } from "./values.js"

export function projectCodeTool(source: ToolPresentationSource): ToolPresentation {
  const args = recordValue(source.args)
  const code = typeof args?.code === "string" ? args.code : ""
  const detailValue = "result" in source ? resultDetails(source.result) : undefined
  const trace =
    isCodeModeDetails(detailValue) && matchesToolOutcome(source, detailValue.outcome) ? detailValue : undefined
  const running = trace?.calls.findLast(call => call.state === "running")
  const completed = trace?.calls.filter(call => call.state !== "running").length ?? 0
  const total = trace?.calls.length ?? 0
  const summary = running
    ? `${running.name} · ${completed}/${total}`
    : total > 0
      ? `${total} ${total === 1 ? "call" : "calls"}`
      : undefined
  const terminal =
    trace?.outcome === "error"
      ? `× ${boundInline(trace.error, 160)}`
      : trace?.outcome === "success" && "result" in source
        ? `→ ${boundInline(resultText(source.result) ?? "completed", 160)}`
        : undefined
  const body = trace ? formatTrace(trace.calls, trace.logs, terminal) : code ? boundHead(code) : undefined
  return {
    header: {
      label: "Code",
      ...(running ? { subject: { type: "text", text: boundInline(running.name) } as const } : {}),
      details: summary ? [summary] : []
    },
    ...(body
      ? {
          body: {
            type: "text" as const,
            text: body,
            tone: source.status === "failed" || trace?.outcome === "error" ? ("error" as const) : ("normal" as const)
          }
        }
      : {}),
    notices: [],
    preview: { compact: { type: "tail", rows: 5 }, detailed: { type: "head", rows: maxExpandedToolRows } },
    timing: "duration"
  }
}

function formatTrace(
  calls: readonly CodeModeCall[],
  logs: readonly string[],
  terminal: string | undefined
): string | undefined {
  const lines = calls.map(call => {
    const detail = callDetail(call)
    switch (call.state) {
      case "running":
        return `… ${call.name}${detail ? ` ${detail}` : ""}${call.preview ? ` — ${boundInline(call.preview, 160)}` : ""}`
      case "succeeded":
        return `✓ ${call.name}${detail ? ` ${detail}` : ""} — ${boundInline(call.result, 160)}`
      case "failed":
        return `× ${call.name}${detail ? ` ${detail}` : ""} — ${boundInline(call.error, 160)}`
      case "aborted":
        return `■ ${call.name}${detail ? ` ${detail}` : ""} — aborted`
      default:
        return assertNever(call)
    }
  })
  for (const log of logs) lines.push(`│ ${boundInline(log, 160)}`)
  if (terminal) lines.push(terminal)
  return lines.length > 0 ? lines.join("\n") : undefined
}

function callDetail(call: CodeModeCall): string | undefined {
  const input = call.arguments
  if (!isRecord(input)) return undefined
  if (typeof input.path === "string") return boundInline(input.path)
  if (typeof input.command === "string") return boundInline(input.command)
  if (typeof input.operation === "string") return boundInline(input.operation)
  return undefined
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}

function assertNever(value: never): never {
  throw new Error(`Unknown code-mode call state: ${String(value)}`)
}
