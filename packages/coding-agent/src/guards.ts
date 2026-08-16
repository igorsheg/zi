import { Type } from "typebox"
import { Compile } from "typebox/compile"

import type { AgentTeamToolDetails } from "./agent-team/tool-details.js"
import type { AgentMessage } from "./messages.js"

/**
 * TypeBox-backed guards for the primitive JSON shapes Zi validates at its process and file
 * boundaries. The same checks were previously re-implemented inline in a dozen modules; these
 * compiled checkers are the single owner of that behavior.
 *
 * Number guards compose TypeBox's numeric checks with `Number.isSafeInteger`/`Number.isFinite`
 * because JSON Schema integers accept unsafe integers (for example 2 ** 53).
 */
const record = Compile(Type.Record(Type.String(), Type.Unknown()))
const stringRecord = Compile(Type.Record(Type.String(), Type.String()))
const nonNegativeInteger = Compile(Type.Integer({ minimum: 0 }))
const positiveInteger = Compile(Type.Integer({ minimum: 1 }))
const numberGuard = Compile(Type.Number())
const nonNegativeNumber = Compile(Type.Number({ minimum: 0 }))

const textContent = Type.Object({ type: Type.Literal("text"), text: Type.String() })
const imageContent = Type.Object({ type: Type.Literal("image"), data: Type.String(), mimeType: Type.String() })
const thinkingContent = Type.Object({ type: Type.Literal("thinking"), thinking: Type.String() })
const toolCallContent = Type.Object({
  type: Type.Literal("toolCall"),
  id: Type.String(),
  name: Type.String(),
  arguments: Type.Record(Type.String(), Type.Unknown())
})
const userContent = Type.Union([Type.String(), Type.Array(Type.Union([textContent, imageContent]))])
const assistantContent = Type.Array(Type.Union([textContent, thinkingContent, toolCallContent]))
const toolResultContent = Type.Array(Type.Union([textContent, imageContent]))
const agentTeamPath = Type.String({ minLength: 5, maxLength: 512, pattern: "^/root(?:/[a-z][a-z0-9_-]*)*$" })
const agentTeamToolAgent = Type.Object({
  path: agentTeamPath,
  parentPath: agentTeamPath,
  taskName: Type.String({ minLength: 1, maxLength: 64, pattern: "^[a-z][a-z0-9_-]*$" }),
  agentType: Type.Optional(Type.String({ minLength: 1, maxLength: 64, pattern: "^[a-z][a-z0-9_-]*$" })),
  residency: Type.Union([Type.Literal("unloaded"), Type.Literal("loading"), Type.Literal("resident")]),
  turnState: Type.Union([
    Type.Literal("idle"),
    Type.Literal("starting"),
    Type.Literal("running"),
    Type.Literal("interrupting")
  ]),
  turnNumber: Type.Integer({ minimum: 0 }),
  settledStatus: Type.Union([
    Type.Literal("not_started"),
    Type.Literal("completed"),
    Type.Literal("interrupted"),
    Type.Literal("failed")
  ])
})
const agentTeamToolBase = { type: Type.Literal("agent_team"), outcome: Type.Literal("success") }
const agentTeamToolDetails = Compile(
  Type.Union([
    Type.Object({ ...agentTeamToolBase, operation: Type.Literal("spawn"), agent: agentTeamToolAgent }),
    Type.Object({ ...agentTeamToolBase, operation: Type.Literal("send"), target: agentTeamPath }),
    Type.Object({
      ...agentTeamToolBase,
      operation: Type.Literal("followup"),
      target: agentTeamPath,
      delivery: Type.Union([Type.Literal("started"), Type.Literal("joined")])
    }),
    Type.Object({
      ...agentTeamToolBase,
      operation: Type.Literal("wait"),
      activity: Type.Union([Type.Literal("mailbox"), Type.Literal("steered"), Type.Literal("timed_out")]),
      timedOut: Type.Boolean()
    }),
    Type.Object({
      ...agentTeamToolBase,
      operation: Type.Literal("list"),
      agents: Type.Array(agentTeamToolAgent, { maxItems: 64 })
    }),
    Type.Object({
      ...agentTeamToolBase,
      operation: Type.Literal("interrupt"),
      target: agentTeamPath,
      previousTurn: Type.Union([
        Type.Literal("idle"),
        Type.Literal("starting"),
        Type.Literal("running"),
        Type.Literal("interrupting")
      ]),
      result: Type.Union([Type.Literal("interrupted"), Type.Literal("idle")])
    })
  ])
)

const agentMessage = Compile(
  Type.Union([
    Type.Object({ role: Type.Literal("user"), content: userContent, timestamp: Type.Number() }),
    Type.Object({
      role: Type.Literal("assistant"),
      content: assistantContent,
      api: Type.String(),
      provider: Type.String(),
      model: Type.String(),
      usage: Type.Record(Type.String(), Type.Unknown()),
      stopReason: Type.Union([
        Type.Literal("pending"),
        Type.Literal("stop"),
        Type.Literal("length"),
        Type.Literal("toolUse"),
        Type.Literal("error"),
        Type.Literal("aborted")
      ]),
      timestamp: Type.Number()
    }),
    Type.Object({
      role: Type.Literal("toolResult"),
      toolCallId: Type.String(),
      toolName: Type.String(),
      content: toolResultContent,
      isError: Type.Boolean(),
      timestamp: Type.Number()
    }),
    Type.Object({
      role: Type.Literal("custom"),
      customType: Type.String(),
      content: userContent,
      display: Type.Boolean(),
      timestamp: Type.Number()
    }),
    Type.Object({
      role: Type.Literal("compactionSummary"),
      summary: Type.String(),
      tokensBefore: Type.Number(),
      estimatedTokensAfter: Type.Number(),
      timestamp: Type.Number()
    }),
    Type.Object({
      role: Type.Literal("branchSummary"),
      summary: Type.String(),
      fromId: Type.String(),
      timestamp: Type.Number()
    }),
    Type.Object({
      role: Type.Literal("bashExecution"),
      command: Type.String(),
      output: Type.String(),
      truncated: Type.Boolean(),
      cancelled: Type.Boolean(),
      timestamp: Type.Number()
    })
  ])
)

export function isRecord(value: unknown): value is Record<string, unknown> {
  return record.Check(value)
}

export function isStringRecord(value: unknown): value is Record<string, string> {
  return stringRecord.Check(value)
}

export function isNonNegativeInteger(value: unknown): value is number {
  return Number.isSafeInteger(value) && nonNegativeInteger.Check(value)
}

export function isPositiveInteger(value: unknown): value is number {
  return Number.isSafeInteger(value) && positiveInteger.Check(value)
}

export function isFiniteNumber(value: unknown): value is number {
  return numberGuard.Check(value)
}

export function isNonNegativeFinite(value: unknown): value is number {
  return nonNegativeNumber.Check(value)
}

export function isAgentMessage(value: unknown): value is AgentMessage {
  return agentMessage.Check(value)
}

export function isAgentTeamToolDetailsShape(value: unknown): value is AgentTeamToolDetails {
  if (!agentTeamToolDetails.Check(value)) return false
  switch (value.operation) {
    case "spawn":
      return Number.isSafeInteger(value.agent.turnNumber)
    case "list":
      return value.agents.every(agent => Number.isSafeInteger(agent.turnNumber))
    case "send":
    case "followup":
    case "wait":
    case "interrupt":
      return true
    default:
      return false
  }
}
