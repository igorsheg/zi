import type { AgentToolResult, AgentToolUpdateCallback } from "@earendil-works/pi-agent-core"
import { Type } from "@earendil-works/pi-ai"
import { Compile } from "typebox/compile"

import type { CodeModeJson } from "../code-mode/protocol.js"
import type { CodeModeCapableTool, CodeModeToolInvocation } from "../code-mode/tool-contract.js"
import { maxMcpSearchResults, type McpCallValue, type McpHost, type McpServerSnapshot } from "./host.js"

const identity = Type.String({ minLength: 1, maxLength: 512 })
const searchParameters = Type.Object({
  query: Type.String({ minLength: 1, maxLength: 4096 }),
  server: Type.Optional(identity),
  limit: Type.Optional(Type.Integer({ minimum: 1, maximum: maxMcpSearchResults }))
})
const describeParameters = Type.Object({ server: identity, tool: identity })
const callParameters = Type.Object({
  server: identity,
  tool: identity,
  arguments: Type.Record(Type.String(), Type.Unknown())
})
const statusParameters = Type.Object({ server: Type.Optional(identity) })

const matchSchema = Type.Object({ server: identity, tool: identity, description: Type.String() })
const descriptorSchema = Type.Object({
  server: identity,
  name: identity,
  description: Type.String(),
  inputSchema: Type.Unknown(),
  outputSchema: Type.Optional(Type.Unknown())
})
const snapshotSchema = Type.Object(
  {
    name: identity,
    transport: Type.Optional(Type.Union([Type.Literal("stdio"), Type.Literal("streamable-http")])),
    status: Type.Union([
      Type.Literal("disabled"),
      Type.Literal("starting"),
      Type.Literal("ready"),
      Type.Literal("backoff"),
      Type.Literal("failed"),
      Type.Literal("stopping")
    ]),
    tools: Type.Optional(Type.Integer({ minimum: 0 })),
    attempt: Type.Optional(Type.Integer({ minimum: 1 })),
    retryAt: Type.Optional(Type.Integer({ minimum: 0 })),
    message: Type.Optional(Type.String())
  },
  { additionalProperties: false }
)
const callValueSchema = Type.Object({
  content: Type.Array(
    Type.Union([
      Type.Object({ type: Type.Literal("text"), text: Type.String() }),
      Type.Object({ type: Type.Literal("omitted"), contentType: Type.String(), mimeType: Type.Optional(Type.String()) })
    ])
  ),
  structuredContent: Type.Optional(Type.Unknown())
})

const checkSearch = Compile(searchParameters)
const checkDescribe = Compile(describeParameters)
const checkCall = Compile(callParameters)
const checkStatus = Compile(statusParameters)

export interface McpToolDetails {
  readonly type: "mcp"
  readonly operation: "search" | "describe" | "call" | "status"
  readonly outcome: "progress" | "success"
  readonly server?: string
  readonly tool?: string
}

type McpToolInvocation = CodeModeToolInvocation & { readonly result: AgentToolResult<McpToolDetails> }

export function createMcpTools(host: McpHost): readonly CodeModeCapableTool[] {
  return Object.freeze([createSearchTool(host), createDescribeTool(host), createCallTool(host), createStatusTool(host)])
}

function createSearchTool(host: McpHost): CodeModeCapableTool {
  const invoke = async (input: unknown): Promise<McpToolInvocation> => {
    if (!checkSearch.Check(input)) throw new Error("Invalid mcp_search input")
    const value = host.search(input.query, input.server, input.limit)
    return invocation(
      "search",
      value,
      value.map(match => ({ server: match.server, tool: match.tool, description: match.description }))
    )
  }
  return {
    name: "mcp_search",
    label: "mcp_search",
    description: "Search ready MCP tool catalogs without placing their schemas in model context.",
    parameters: searchParameters,
    executionMode: "parallel",
    async execute(_id, input) {
      return (await invoke(input)).result
    },
    codeMode: {
      outputSchema: Type.Array(matchSchema),
      async execute(_id, input) {
        return invoke(input)
      }
    }
  }
}

function createDescribeTool(host: McpHost): CodeModeCapableTool {
  const invoke = async (input: unknown): Promise<McpToolInvocation> => {
    if (!checkDescribe.Check(input)) throw new Error("Invalid mcp_describe input")
    const value = host.describe(input.server, input.tool)
    return invocation(
      "describe",
      value,
      {
        server: value.server,
        name: value.name,
        description: value.description,
        inputSchema: value.inputSchema,
        ...(value.outputSchema === undefined ? {} : { outputSchema: value.outputSchema })
      },
      input.server,
      input.tool
    )
  }
  return {
    name: "mcp_describe",
    label: "mcp_describe",
    description: "Return the bounded contract for one selected MCP tool.",
    parameters: describeParameters,
    executionMode: "parallel",
    async execute(_id, input) {
      return (await invoke(input)).result
    },
    codeMode: {
      outputSchema: descriptorSchema,
      async execute(_id, input) {
        return invoke(input)
      }
    }
  }
}

function createCallTool(host: McpHost): CodeModeCapableTool {
  const invoke = async (
    input: unknown,
    signal: AbortSignal | undefined,
    onUpdate?: AgentToolUpdateCallback<McpToolDetails>
  ): Promise<McpToolInvocation> => {
    if (!checkCall.Check(input)) throw new Error("Invalid mcp_call input")
    const value = await host.call(input.server, input.tool, input.arguments, signal, message => {
      onUpdate?.({
        content: [{ type: "text", text: message }],
        details: details("call", "progress", input.server, input.tool)
      })
    })
    return invocation("call", value, callValueJson(value), input.server, input.tool)
  }
  return {
    name: "mcp_call",
    label: "mcp_call",
    description: "Call one described MCP tool through Zi's bounded tool seam.",
    parameters: callParameters,
    executionMode: "parallel",
    async execute(_id, input, signal, onUpdate) {
      return (await invoke(input, signal, onUpdate)).result
    },
    codeMode: {
      outputSchema: callValueSchema,
      async execute(_id, input, signal, onUpdate) {
        return invoke(input, signal, onUpdate)
      }
    }
  }
}

function createStatusTool(host: McpHost): CodeModeCapableTool {
  const invoke = async (input: unknown): Promise<McpToolInvocation> => {
    if (!checkStatus.Check(input)) throw new Error("Invalid mcp_status input")
    const snapshots = host.snapshot()
    const value = input.server === undefined ? snapshots : snapshots.filter(snapshot => snapshot.name === input.server)
    return invocation("status", value, value.map(snapshotJson), input.server)
  }
  return {
    name: "mcp_status",
    label: "mcp_status",
    description: "Inspect bounded MCP server lifecycle status.",
    parameters: statusParameters,
    executionMode: "parallel",
    async execute(_id, input) {
      return (await invoke(input)).result
    },
    codeMode: {
      outputSchema: Type.Array(snapshotSchema),
      async execute(_id, input) {
        return invoke(input)
      }
    }
  }
}

function invocation(
  operation: McpToolDetails["operation"],
  rendered: unknown,
  value: CodeModeJson,
  server?: string,
  tool?: string
): McpToolInvocation {
  return {
    result: {
      content: [{ type: "text", text: JSON.stringify(rendered) }],
      details: details(operation, "success", server, tool)
    },
    value
  }
}

function callValueJson(value: McpCallValue): CodeModeJson {
  return {
    content: value.content.map(block =>
      block.type === "text"
        ? { type: "text", text: block.text }
        : {
            type: "omitted",
            contentType: block.contentType,
            ...(block.mimeType === undefined ? {} : { mimeType: block.mimeType })
          }
    ),
    ...(value.structuredContent === undefined ? {} : { structuredContent: value.structuredContent })
  }
}

function snapshotJson(snapshot: McpServerSnapshot): CodeModeJson {
  switch (snapshot.status) {
    case "disabled":
      return { name: snapshot.name, status: snapshot.status }
    case "starting":
    case "stopping":
      return { name: snapshot.name, transport: snapshot.transport, status: snapshot.status }
    case "ready":
      return {
        name: snapshot.name,
        transport: snapshot.transport,
        status: snapshot.status,
        tools: snapshot.tools,
        ...(snapshot.message === undefined ? {} : { message: snapshot.message })
      }
    case "backoff":
      return {
        name: snapshot.name,
        transport: snapshot.transport,
        status: snapshot.status,
        attempt: snapshot.attempt,
        retryAt: snapshot.retryAt,
        message: snapshot.message
      }
    case "failed":
      return {
        name: snapshot.name,
        ...(snapshot.transport === undefined ? {} : { transport: snapshot.transport }),
        status: snapshot.status,
        message: snapshot.message
      }
    default:
      return assertNever(snapshot)
  }
}

function assertNever(value: never): never {
  throw new Error(`Unknown MCP snapshot: ${String(value)}`)
}

function details(
  operation: McpToolDetails["operation"],
  outcome: McpToolDetails["outcome"],
  server?: string,
  tool?: string
): McpToolDetails {
  return Object.freeze({
    type: "mcp",
    operation,
    outcome,
    ...(server === undefined ? {} : { server }),
    ...(tool === undefined ? {} : { tool })
  })
}
