import {
  isAgentTeamToolDetails,
  type AgentTeamToolAgentDetails,
  type AgentTeamToolDetails
} from "../../agent-team/tool-details.js"
import { maxExpandedToolRows, type ToolPresentation, type ToolPresentationSource, type ToolSubject } from "./types.js"
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

export function projectAgentTeam(source: ToolPresentationSource): ToolPresentation {
  const operation = operationForName(source.name)
  const args = recordValue(source.args)
  const details = semanticDetails(source, operation)
  const failed = source.status === "failed" || source.status === "aborted"
  const fallbackText = "result" in source ? (resultText(source.result) ?? "") : ""

  if (failed) return failedPresentation(operation, args, fallbackText)

  switch (operation) {
    case "spawn": {
      const agent = details?.operation === "spawn" ? details.agent : undefined
      const message = stringValue(args?.message)
      return actionPresentation({
        label: "Spawn",
        subject: agentSubject(agent, stringValue(args?.task_name)),
        details: agent
          ? [
              "admitted",
              ...(agent.agentType === undefined ? [] : [`role ${agent.agentType}`]),
              turnLabel(agent.turnState),
              agent.residency,
              agent.path
            ]
          : [],
        body: message,
        fallbackText: details ? "" : fallbackText
      })
    }
    case "send":
      return actionPresentation({
        label: "Send",
        subject: targetSubject(details?.operation === "send" ? details.target : stringValue(args?.target)),
        details: details?.operation === "send" ? ["delivered", details.target] : [],
        body: stringValue(args?.message),
        fallbackText: details ? "" : fallbackText
      })
    case "followup": {
      const followup = details?.operation === "followup" ? details : undefined
      return actionPresentation({
        label: "Follow up",
        subject: targetSubject(followup?.target ?? stringValue(args?.target)),
        details: followup
          ? [followup.delivery === "started" ? "started turn" : "joined active turn", followup.target]
          : [],
        body: stringValue(args?.message),
        fallbackText: details ? "" : fallbackText
      })
    }
    case "wait":
      return waitPresentation(details?.operation === "wait" ? details : undefined, fallbackText)
    case "list":
      return listPresentation(details?.operation === "list" ? details : undefined, fallbackText)
    case "interrupt": {
      const interrupt = details?.operation === "interrupt" ? details : undefined
      return actionPresentation({
        label: "Interrupt",
        subject: targetSubject(interrupt?.target ?? stringValue(args?.target)),
        details: interrupt
          ? [
              interrupt.result === "interrupted" ? "interrupted" : "already idle",
              `was ${turnLabel(interrupt.previousTurn)}`,
              interrupt.target
            ]
          : [],
        fallbackText: details ? "" : fallbackText
      })
    }
    default:
      return assertNever(operation)
  }
}

function waitPresentation(
  details: Extract<AgentTeamToolDetails, { operation: "wait" }> | undefined,
  fallbackText: string
): ToolPresentation {
  const subject: ToolSubject = {
    type: "text",
    text:
      details?.activity === "mailbox"
        ? "Agent update"
        : details?.activity === "steered"
          ? "New input"
          : details?.activity === "timed_out"
            ? "No agent updates"
            : "Agent activity"
  }
  const body = details ? "" : fallbackText
  return {
    header: {
      label: "Wait",
      subject,
      details: details?.timedOut ? ["timed out"] : details?.activity === "steered" ? ["interrupted"] : []
    },
    ...(body ? { body: { type: "text" as const, text: boundHead(body), tone: "muted" as const } } : {}),
    notices: [],
    preview: {
      compact: { type: "hidden" },
      detailed: body ? { type: "head", rows: maxExpandedToolRows } : { type: "hidden" }
    },
    timing: "duration"
  }
}

function listPresentation(
  details: Extract<AgentTeamToolDetails, { operation: "list" }> | undefined,
  fallbackText: string
): ToolPresentation {
  const agents = details?.agents ?? []
  const working = agents.filter(agent => agent.turnState !== "idle").length
  const completed = agents.filter(agent => agent.settledStatus === "completed").length
  const body = agents.length > 0 ? agents.map(agentLine).join("\n") : details ? "" : fallbackText
  return {
    header: {
      label: "Agents",
      subject: {
        type: "text",
        text: details ? `${agents.length} ${agents.length === 1 ? "agent" : "agents"}` : "Agents"
      },
      details: [
        ...(working > 0 ? [`${working} working`] : []),
        ...(completed > 0 ? [`${completed} completed`] : []),
        ...(details && agents.length === 0 ? ["none"] : [])
      ]
    },
    ...(body ? { body: { type: "text" as const, text: boundHead(body), tone: "muted" as const } } : {}),
    notices: [],
    preview: {
      compact: body ? { type: "head", rows: Math.min(agents.length, 6) } : { type: "hidden" },
      detailed: body ? { type: "head", rows: maxExpandedToolRows } : { type: "hidden" }
    },
    timing: "duration"
  }
}

function failedPresentation(
  operation: AgentTeamToolDetails["operation"],
  args: Record<string, unknown> | undefined,
  text: string
): ToolPresentation {
  const subject =
    operation === "spawn"
      ? agentSubject(undefined, stringValue(args?.task_name))
      : operation === "wait"
        ? { type: "text" as const, text: "Agent changes" }
        : operation === "list"
          ? { type: "text" as const, text: "Agents" }
          : targetSubject(stringValue(args?.target))
  return {
    header: { label: operationLabel(operation), subject, details: [] },
    ...(text ? { body: { type: "text" as const, text: boundHead(text), tone: "error" as const } } : {}),
    notices: [],
    preview: {
      compact: text ? { type: "head", rows: 8 } : { type: "hidden" },
      detailed: text ? { type: "head", rows: maxExpandedToolRows } : { type: "hidden" }
    },
    timing: "duration"
  }
}

function actionPresentation(input: {
  readonly label: string
  readonly subject: ToolSubject
  readonly details: readonly string[]
  readonly body?: string | undefined
  readonly fallbackText: string
}): ToolPresentation {
  const body = normalizeToolText(input.body ?? input.fallbackText)
  return {
    header: { label: input.label, subject: input.subject, details: input.details },
    ...(body ? { body: { type: "text" as const, text: boundHead(body), tone: "muted" as const } } : {}),
    notices: [],
    preview: {
      compact: { type: "hidden" },
      detailed: body ? { type: "head", rows: maxExpandedToolRows } : { type: "hidden" }
    },
    timing: "duration"
  }
}

function semanticDetails(
  source: ToolPresentationSource,
  operation: AgentTeamToolDetails["operation"]
): AgentTeamToolDetails | undefined {
  if (!("result" in source) || source.result === undefined) return undefined
  const details = resultDetails(source.result)
  return isAgentTeamToolDetails(details) &&
    details.operation === operation &&
    matchesToolOutcome(source, details.outcome)
    ? details
    : undefined
}

function agentLine(agent: AgentTeamToolAgentDetails): string {
  const state =
    agent.turnState === "idle" && agent.settledStatus !== "not_started"
      ? settledLabel(agent.settledStatus)
      : turnLabel(agent.turnState)
  const role = agent.agentType === undefined ? "" : `role ${agent.agentType} · `
  return `${agentNameLabel(agent.taskName)} — ${role}${state} · ${agent.residency} · turn ${agent.turnNumber} — ${agent.path}`
}

function agentSubject(agent: AgentTeamToolAgentDetails | undefined, fallbackTaskName?: string): ToolSubject {
  const taskName = agent?.taskName ?? fallbackTaskName
  return { type: "text", text: taskName ? agentNameLabel(taskName) : "Agent" }
}

function targetSubject(path: string | undefined): ToolSubject {
  return path ? { type: "text", text: pathLabel(path) } : { type: "text", text: "Agent" }
}

function pathLabel(path: string): string {
  const taskName = path.split("/").at(-1)
  return taskName ? agentNameLabel(taskName) : boundInline(path)
}

function agentNameLabel(value: string): string {
  const words = boundInline(value, 64).replace(/[-_]+/g, " ").trim()
  if (!words) return "Agent"
  return `${words[0]!.toUpperCase()}${words.slice(1)}`
}

function turnLabel(turn: AgentTeamToolAgentDetails["turnState"]): string {
  switch (turn) {
    case "idle":
      return "idle"
    case "starting":
      return "starting"
    case "running":
      return "working"
    case "interrupting":
      return "interrupting"
    default:
      return assertNever(turn)
  }
}

function settledLabel(status: AgentTeamToolAgentDetails["settledStatus"]): string {
  switch (status) {
    case "not_started":
      return "idle"
    case "completed":
      return "completed"
    case "interrupted":
      return "interrupted"
    case "failed":
      return "failed"
    default:
      return assertNever(status)
  }
}

function operationLabel(operation: AgentTeamToolDetails["operation"]): string {
  switch (operation) {
    case "spawn":
      return "Spawn"
    case "send":
      return "Send"
    case "followup":
      return "Follow up"
    case "wait":
      return "Wait"
    case "list":
      return "Agents"
    case "interrupt":
      return "Interrupt"
    default:
      return assertNever(operation)
  }
}

function operationForName(name: string): AgentTeamToolDetails["operation"] {
  switch (name) {
    case "spawn_agent":
      return "spawn"
    case "send_message":
      return "send"
    case "followup_task":
      return "followup"
    case "wait_agent":
      return "wait"
    case "list_agents":
      return "list"
    case "interrupt_agent":
      return "interrupt"
    default:
      throw new Error(`Unexpected AgentTeam tool: ${name}`)
  }
}
