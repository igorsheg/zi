import { Type } from "typebox"
import { Compile } from "typebox/compile"

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
