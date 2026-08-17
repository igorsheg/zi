import type { AgentTool, AgentToolResult, AgentToolUpdateCallback } from "@earendil-works/pi-agent-core"
import { Type } from "typebox"

import type { CodeModeCapableTool, CodeModeToolInvocation } from "../code-mode/tool-contract.js"
import type { ExtensionHost } from "./host.js"
import type { ExtensionToolRegistration, JsonValue } from "./protocol.js"

export interface ExtensionToolDetails {
  readonly type: "extension"
  readonly extensionId: string
  readonly toolName: string
  readonly outcome: "progress" | "success"
}

type ExtensionToolHost = Pick<ExtensionHost, "toolCatalog" | "rejectTool" | "invokeTool">

export function admitExtensionTools(
  builtInTools: readonly AgentTool[],
  host: ExtensionToolHost | undefined,
  activeTools: ReadonlySet<ExtensionToolRegistration>,
  reservedNames: ReadonlySet<string>
): readonly AgentTool[] {
  if (builtInTools.some(tool => tool.name === "code" || tool.name === "then")) {
    throw new Error("The tool names code and then are reserved for native code mode")
  }
  if (!host) return builtInTools
  const admitted: AgentTool[] = [...builtInTools]
  const names = new Set([...reservedNames, "code", "then"])

  for (const registration of host.toolCatalog()) {
    if (names.has(registration.name)) {
      host.rejectTool(
        registration,
        `Extension tool ${registration.name} conflicts with an existing session tool and was ignored`
      )
      continue
    }
    if (!activeTools.has(registration)) continue
    names.add(registration.name)
    const parameters = Type.Unsafe(registration.parameters)
    const invoke = async (
      _toolCallId: string,
      arguments_: unknown,
      signal?: AbortSignal,
      onUpdate?: AgentToolUpdateCallback<ExtensionToolDetails>
    ): Promise<CodeModeToolInvocation> => {
      const value = await host.invokeTool(registration.name, arguments_, signal, message => {
        onUpdate?.(extensionToolProgress(registration, message))
      })
      return { value, result: extensionToolResult(registration, value) }
    }
    const tool: CodeModeCapableTool = {
      name: registration.name,
      label: registration.label,
      description: registration.description,
      parameters,
      executionMode: "parallel",
      async execute(toolCallId, arguments_, signal, onUpdate) {
        return (await invoke(toolCallId, arguments_, signal, onUpdate)).result
      },
      codeMode: { outputSchema: registration.outputSchema, execute: invoke }
    }
    admitted.push(tool)
  }

  return Object.freeze(admitted)
}

function extensionToolProgress(
  registration: ExtensionToolRegistration,
  message: string
): AgentToolResult<ExtensionToolDetails> {
  const details: ExtensionToolDetails = {
    type: "extension",
    extensionId: registration.source.id,
    toolName: registration.name,
    outcome: "progress"
  }
  return { content: [{ type: "text" as const, text: message }], details }
}

function extensionToolResult(
  registration: ExtensionToolRegistration,
  value: JsonValue
): AgentToolResult<ExtensionToolDetails> {
  const details: ExtensionToolDetails = {
    type: "extension",
    extensionId: registration.source.id,
    toolName: registration.name,
    outcome: "success"
  }
  return {
    content: [{ type: "text" as const, text: typeof value === "string" ? value : JSON.stringify(value) }],
    details
  }
}
