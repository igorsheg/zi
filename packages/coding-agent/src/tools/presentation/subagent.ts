import {
  isSubagentToolDetails,
  type SubagentToolAgentDetails,
  type SubagentToolDetails
} from "../../subagents/tool-details.js"
import { maxExpandedToolRows, type ToolNotice, type ToolPresentation, type ToolPresentationSource } from "./types.js"
import {
  assertNever,
  boundHead,
  boundInline,
  matchesToolOutcome,
  normalizeToolText,
  recordValue,
  resultDetails,
  resultText,
  stringValue
} from "./values.js"

const taskSummaryScalars = 120
const resultSummaryScalars = 240

export function projectSubagent(source: ToolPresentationSource): ToolPresentation {
  const operation = operationForName(source.name)
  const args = recordValue(source.args)
  const details = semanticDetails(source, operation)
  const failed = source.status === "failed" || source.status === "aborted"
  const fallbackText = "result" in source ? (resultText(source.result) ?? "") : ""

  if (failed) return failedPresentation(operation, args, fallbackText)

  switch (operation) {
    case "spawn": {
      const agent = singleAgent(details)
      const prompt = stringValue(args?.prompt)
      return detailOnlyPresentation({
        label: source.status === "done" ? "Started" : source.status === "running" ? "Starting" : "Start",
        subject: agentSubject(agent, stringValue(args?.name)),
        details: prompt ? [summary(prompt, taskSummaryScalars)] : [],
        body: prompt,
        notices: agentNotices(),
        fallbackText: details ? "" : fallbackText,
        timing: "duration"
      })
    }
    case "send": {
      const agent = singleAgent(details)
      return detailOnlyPresentation({
        label: source.status === "done" ? "Messaged" : "Message",
        subject: agentSubject(agent),
        details: [],
        body: stringValue(args?.text),
        notices: agentNotices(),
        fallbackText: details ? "" : fallbackText,
        timing: "duration"
      })
    }
    case "continue": {
      const agent = singleAgent(details)
      return detailOnlyPresentation({
        label: source.status === "done" ? "Continued" : "Continue",
        subject: agentSubject(agent),
        details: agent?.workCycle === undefined ? [] : [`cycle ${agent.workCycle}`],
        body: stringValue(args?.text),
        notices: agentNotices(),
        fallbackText: details ? "" : fallbackText,
        timing: "duration"
      })
    }
    case "wait":
      return waitPresentation(source, details, args, fallbackText)
    case "interrupt": {
      const agent = singleAgent(details)
      const interrupted = details?.operation === "interrupt" && details.result === "interrupted"
      return detailOnlyPresentation({
        label: source.status === "done" && interrupted ? "Interrupted" : "Interrupt",
        subject: agentSubject(agent),
        details: details?.operation === "interrupt" && details.result === "already_idle" ? ["already idle"] : [],
        notices: agentNotices(),
        fallbackText: details ? "" : fallbackText,
        timing: "duration"
      })
    }
    case "close": {
      const agent = singleAgent(details)
      return detailOnlyPresentation({
        label: source.status === "done" ? "Closed" : "Close",
        subject: agentSubject(agent),
        details: details?.operation === "close" ? [`was ${lifecycleLabel(details.previousStatus)}`] : [],
        notices: agentNotices(),
        fallbackText: details ? "" : fallbackText,
        timing: "duration"
      })
    }
    case "list":
      return listPresentation(source, details, fallbackText)
    default:
      return assertNever(operation)
  }
}

function waitPresentation(
  source: ToolPresentationSource,
  details: SubagentToolDetails | undefined,
  args: Record<string, unknown> | undefined,
  fallbackText: string
): ToolPresentation {
  const agents = details?.operation === "wait" ? details.agents : []
  const requestedNames = stringArray(args?.names)
  const count = agents.length || requestedNames.length
  const subject =
    agents.length === 1
      ? agentSubject(agents[0])
      : { type: "text" as const, text: count === 1 ? "Agent" : `${count || "…"} agents` }
  const summaries = agents.map(waitSummaryLine)
  const evidence = agents.flatMap(waitEvidenceSections)
  const body =
    agents.length > 0
      ? [...summaries, ...(evidence.length > 0 ? ["", ...evidence] : [])].join("\n")
      : details
        ? ""
        : fallbackText
  const compactRows = agents.length > 0 ? Math.min(agents.length + (evidence.length > 0 ? 1 : 0), 6) : 6
  return {
    header: {
      label: source.status === "done" ? "Finished waiting" : source.status === "running" ? "Waiting for" : "Wait for",
      subject,
      details: []
    },
    ...(body ? { body: { type: "text" as const, text: boundHead(body), tone: "muted" as const } } : {}),
    notices: [],
    preview: {
      compact: body ? { type: "head", rows: compactRows } : { type: "hidden" },
      detailed: body ? { type: "head", rows: maxExpandedToolRows } : { type: "hidden" }
    },
    timing: "duration"
  }
}

function listPresentation(
  source: ToolPresentationSource,
  details: SubagentToolDetails | undefined,
  fallbackText: string
): ToolPresentation {
  const list = details?.operation === "list" ? details : undefined
  const agents = list?.agents ?? []
  const working = list?.workingNames.length ?? 0
  const ready = list?.readyNames.length ?? 0
  const counts = [
    ...(working > 0 ? [`${working} working`] : []),
    ...(ready > 0 ? [`${ready} ready`] : []),
    ...(agents.length === 0 && source.status === "done" ? ["none"] : [])
  ]
  const readyNames = new Set(list?.readyNames ?? [])
  const body =
    agents.length > 0 ? agents.map(agent => listLine(agent, readyNames)).join("\n") : details ? "" : fallbackText
  return {
    header: { label: source.status === "done" ? "Checked agents" : "Check agents", details: counts },
    ...(body ? { body: { type: "text" as const, text: boundHead(body), tone: "muted" as const } } : {}),
    notices: [],
    preview: {
      compact: { type: "hidden" },
      detailed: body ? { type: "head", rows: maxExpandedToolRows } : { type: "hidden" }
    },
    timing: "duration"
  }
}

function failedPresentation(
  operation: SubagentToolDetails["operation"],
  args: Record<string, unknown> | undefined,
  text: string
): ToolPresentation {
  const subject =
    operation === "spawn"
      ? agentSubject(undefined, stringValue(args?.name))
      : operation === "wait"
        ? { type: "text" as const, text: `${stringArray(args?.names).length || "…"} agents` }
        : operation === "list"
          ? undefined
          : { type: "text" as const, text: "Agent" }
  return {
    header: { label: failedLabel(operation), ...(subject ? { subject } : {}), details: [] },
    ...(text ? { body: { type: "text" as const, text: boundHead(text), tone: "error" as const } } : {}),
    notices: [],
    preview: {
      compact: text ? { type: "head", rows: 8 } : { type: "hidden" },
      detailed: text ? { type: "head", rows: maxExpandedToolRows } : { type: "hidden" }
    },
    timing: "duration"
  }
}

function detailOnlyPresentation(input: {
  readonly label: string
  readonly subject: { readonly type: "text"; readonly text: string }
  readonly details: readonly string[]
  readonly body?: string | undefined
  readonly notices: readonly ToolNotice[]
  readonly fallbackText: string
  readonly timing: "duration"
}): ToolPresentation {
  const body = input.body || input.fallbackText
  return {
    header: { label: input.label, subject: input.subject, details: input.details },
    ...(body ? { body: { type: "text" as const, text: boundHead(body), tone: "muted" as const } } : {}),
    notices: input.notices,
    preview: {
      compact: { type: "hidden" },
      detailed: body ? { type: "head", rows: maxExpandedToolRows } : { type: "hidden" }
    },
    timing: input.timing
  }
}

function semanticDetails(
  source: ToolPresentationSource,
  operation: SubagentToolDetails["operation"]
): SubagentToolDetails | undefined {
  if (!("result" in source) || source.result === undefined) return undefined
  const details = resultDetails(source.result)
  return isSubagentToolDetails(details) &&
    details.operation === operation &&
    matchesToolOutcome(source, details.outcome)
    ? details
    : undefined
}

function singleAgent(details: SubagentToolDetails | undefined): SubagentToolAgentDetails | undefined {
  return details && "agent" in details ? details.agent : undefined
}

function agentSubject(
  agent: SubagentToolAgentDetails | undefined,
  fallbackName?: string
): { readonly type: "text"; readonly text: string } {
  return { type: "text", text: agentNameLabel(agent?.name ?? fallbackName ?? "Agent") }
}

function agentNotices(): readonly ToolNotice[] {
  return []
}

function waitSummaryLine(agent: SubagentToolAgentDetails): string {
  const label = agentNameLabel(agent.name)
  const completion = currentCompletion(agent)
  if (!completion) return `${label} ${lifecycleLabel(agent.lifecycle)}`
  const evidence = completion.error || completion.reason || completion.text
  return `${label} ${completionLabel(completion.status)} · ${formatDuration(completion.durationMs)}${
    evidence ? ` — ${summary(evidence, resultSummaryScalars)}` : ""
  }${completion.truncated || completion.omittedBytes > 0 ? " …" : ""}`
}

function waitEvidenceSections(agent: SubagentToolAgentDetails): string[] {
  const completion = currentCompletion(agent)
  if (!completion) return []
  const fields = [
    ...(completion.error ? [{ label: "error", text: completion.error }] : []),
    ...(completion.reason ? [{ label: "reason", text: completion.reason }] : []),
    ...(completion.text ? [{ label: "output", text: completion.text }] : [])
  ]
  if (
    fields.length === 1 &&
    normalizeToolText(fields[0]!.text) === summary(fields[0]!.text, resultSummaryScalars) &&
    !completion.truncated &&
    completion.omittedBytes === 0
  ) {
    return []
  }

  const agentLabel = agentNameLabel(agent.name)
  const sections = fields.map(field => `${agentLabel} ${field.label}:\n${normalizeToolText(field.text)}`)
  if (completion.truncated || completion.omittedBytes > 0) {
    sections.push(
      `${agentLabel} evidence truncated${completion.omittedBytes > 0 ? ` · ${completion.omittedBytes} bytes omitted` : ""}`
    )
  }
  return sections
}

function currentCompletion(
  agent: SubagentToolAgentDetails
): NonNullable<SubagentToolAgentDetails["completion"]> | undefined {
  const completion = agent.completion
  return !completion || (agent.workCycle !== undefined && completion.workCycle !== agent.workCycle)
    ? undefined
    : completion
}

function listLine(agent: SubagentToolAgentDetails, readyNames: ReadonlySet<string>): string {
  const lifecycle = lifecycleLabel(agent.lifecycle)
  const state = readyNames.has(agent.name)
    ? agent.lifecycle === "idle" || agent.lifecycle === "exited"
      ? "result ready"
      : `${lifecycle} · result ready`
    : lifecycle
  return `${agentNameLabel(agent.name)} — ${state}`
}

function lifecycleLabel(lifecycle: SubagentToolAgentDetails["lifecycle"]): string {
  switch (lifecycle) {
    case "starting":
    case "spawn_admitting":
      return "starting"
    case "running":
      return "working"
    case "interrupting":
      return "interrupting"
    case "closing":
      return "closing"
    case "idle":
      return "idle"
    case "exited":
      return "exited"
    default:
      return assertNever(lifecycle)
  }
}

function completionLabel(status: NonNullable<SubagentToolAgentDetails["completion"]>["status"]): string {
  switch (status) {
    case "completed":
      return "completed"
    case "failed":
      return "failed"
    case "cancelled":
      return "cancelled"
    default:
      return assertNever(status)
  }
}

function summary(value: string, limit: number): string {
  return boundInline(value, limit)
}

function agentNameLabel(value: string): string {
  const words = boundInline(value, 64).replace(/[-_]+/g, " ").trim()
  if (!words) return "Agent"
  return `${words[0]!.toUpperCase()}${words.slice(1)}`
}

function formatDuration(durationMs: number): string {
  if (durationMs < 60_000) return `${(durationMs / 1_000).toFixed(1)}s`
  const minutes = Math.floor(durationMs / 60_000)
  const seconds = Math.floor((durationMs % 60_000) / 1_000)
  return `${minutes}m ${seconds}s`
}

function stringArray(value: unknown): string[] {
  return Array.isArray(value) ? value.filter((item): item is string => typeof item === "string").slice(0, 16) : []
}

function failedLabel(operation: SubagentToolDetails["operation"]): string {
  switch (operation) {
    case "spawn":
      return "Start"
    case "send":
      return "Message"
    case "continue":
      return "Continue"
    case "wait":
      return "Wait for"
    case "interrupt":
      return "Interrupt"
    case "close":
      return "Close"
    case "list":
      return "Check agents"
    default:
      return assertNever(operation)
  }
}

function operationForName(name: string): SubagentToolDetails["operation"] {
  switch (name) {
    case "spawn_subagent":
      return "spawn"
    case "send_subagent":
      return "send"
    case "continue_subagent":
      return "continue"
    case "wait_subagents":
      return "wait"
    case "interrupt_subagent":
      return "interrupt"
    case "close_subagent":
      return "close"
    case "list_subagents":
      return "list"
    default:
      throw new Error(`Unexpected subagent tool: ${name}`)
  }
}
