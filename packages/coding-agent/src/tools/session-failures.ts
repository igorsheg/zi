import type { AgentTool, AgentToolResult } from "@earendil-works/pi-agent-core"
import { Type } from "@earendil-works/pi-ai"
import { Compile } from "typebox/compile"

import type { CodeModeJson } from "../code-mode/protocol.js"
import type { CodeModeToolContract, CodeModeToolInvocation } from "../code-mode/tool-contract.js"
import {
  maxSessionFailureMessageBytes,
  maxSessionFailures,
  projectSessionFailures,
  type SessionFailure
} from "../session-failures.js"
import type { SessionManager } from "../session-manager.js"

export const maxSessionFailurePageSize = 100
const defaultSessionFailurePageSize = 50

const parameters = Type.Object({
  cursor: Type.Optional(
    Type.Integer({ minimum: 0, maximum: maxSessionFailures, description: "Zero-based retained failure offset" })
  ),
  limit: Type.Optional(
    Type.Integer({ minimum: 1, maximum: maxSessionFailurePageSize, description: "Maximum failures to return" })
  )
})

const failureBase = {
  id: Type.String(),
  name: Type.String(),
  status: Type.Literal("failed"),
  timestamp: Type.String(),
  sourceEntryId: Type.String()
}
const message = Type.Optional(Type.String({ maxLength: maxSessionFailureMessageBytes }))
const failureSchema = Type.Union([
  Type.Object(
    { kind: Type.Literal("tool"), ...failureBase, code: Type.Optional(Type.String()), message },
    { additionalProperties: false }
  ),
  Type.Object(
    {
      kind: Type.Literal("code_call"),
      ...failureBase,
      parentId: Type.String(),
      code: Type.Optional(Type.String()),
      message,
      durationMs: Type.Number({ minimum: 0 })
    },
    { additionalProperties: false }
  ),
  Type.Object(
    {
      kind: Type.Literal("background_task"),
      ...failureBase,
      parentId: Type.Optional(Type.String()),
      code: Type.String(),
      message: Type.String({ maxLength: maxSessionFailureMessageBytes }),
      durationMs: Type.Number({ minimum: 0 })
    },
    { additionalProperties: false }
  ),
  Type.Object(
    {
      kind: Type.Literal("agent_turn"),
      ...failureBase,
      code: Type.String(),
      message,
      durationMs: Type.Number({ minimum: 0 })
    },
    { additionalProperties: false }
  ),
  Type.Object(
    {
      kind: Type.Literal("provider"),
      ...failureBase,
      code: Type.Literal("provider_error"),
      message,
      retryAttempt: Type.Optional(Type.Integer({ minimum: 1 }))
    },
    { additionalProperties: false }
  )
])

const checkParameters = Compile(parameters)

const outputSchema = Type.Object({
  cursor: Type.Integer({ minimum: 0, maximum: maxSessionFailures }),
  failures: Type.Array(failureSchema, { maxItems: maxSessionFailurePageSize }),
  nextCursor: Type.Optional(Type.Integer({ minimum: 1, maximum: maxSessionFailures })),
  retained: Type.Integer({ minimum: 0, maximum: maxSessionFailures }),
  omitted: Type.Integer({ minimum: 0 })
})

export interface SessionFailurePage {
  readonly cursor: number
  readonly failures: readonly SessionFailure[]
  readonly nextCursor?: number
  readonly retained: number
  readonly omitted: number
}

export type SessionFailuresTool = AgentTool<typeof parameters, SessionFailurePage> & {
  readonly codeMode: CodeModeToolContract
}

type SessionFailuresInvocation = CodeModeToolInvocation & { readonly result: AgentToolResult<SessionFailurePage> }

export function createSessionFailuresTool(sessionManager: SessionManager): SessionFailuresTool {
  const invoke = async (input: unknown, signal?: AbortSignal): Promise<SessionFailuresInvocation> => {
    if (signal?.aborted) throw new Error("Operation aborted")
    if (!checkParameters.Check(input)) throw new Error("Invalid session_failures input")
    const page = sessionFailurePage(sessionManager, input.cursor ?? 0, input.limit ?? defaultSessionFailurePageSize)
    return { result: directResult(page), value: codeModePage(page) }
  }

  return {
    name: "session_failures",
    label: "session_failures",
    description:
      "List bounded failures already committed to this session journal. Failures from the active code cell appear after it settles.",
    parameters,
    executionMode: "parallel",
    async execute(_toolCallId, input, signal) {
      return (await invoke(input, signal)).result
    },
    codeMode: {
      outputSchema,
      async execute(_toolCallId, input, signal) {
        return invoke(input, signal)
      }
    }
  }
}

function sessionFailurePage(sessionManager: SessionManager, cursor: number, limit: number): SessionFailurePage {
  const projection = projectSessionFailures(sessionManager.entries())
  const failures = Object.freeze(projection.failures.slice(cursor, cursor + limit))
  const nextCursor = cursor + failures.length
  return Object.freeze({
    cursor,
    failures,
    ...(nextCursor < projection.failures.length ? { nextCursor } : {}),
    retained: projection.failures.length,
    omitted: projection.omitted
  })
}

function directResult(page: SessionFailurePage): AgentToolResult<SessionFailurePage> {
  const suffix = page.omitted === 0 ? "" : `; ${page.omitted} additional failures omitted`
  return {
    content: [
      { type: "text", text: `Returned ${page.failures.length} of ${page.retained} retained failures${suffix}.` }
    ],
    details: page
  }
}

function codeModePage(page: SessionFailurePage): CodeModeJson {
  return {
    cursor: page.cursor,
    failures: page.failures.map(failure => ({ ...failure })),
    ...(page.nextCursor === undefined ? {} : { nextCursor: page.nextCursor }),
    retained: page.retained,
    omitted: page.omitted
  }
}
