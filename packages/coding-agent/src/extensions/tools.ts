import type { AgentTool } from "@earendil-works/pi-agent-core"
import { Type } from "typebox"

import type { CodeModeCapableTool, CodeModeToolInvocation } from "../code-mode/tool-contract.js"
import type { ExtensionHost } from "./host.js"
import type { ExtensionToolRegistration, JsonValue } from "./protocol.js"

export interface ExtensionToolDetails {
  readonly type: "extension"
  readonly extensionId: string
  readonly toolName: string
  readonly outcome: "success"
}

export function admitExtensionTools(
  builtInTools: readonly AgentTool[],
  host: ExtensionHost | undefined,
  activeTools: ReadonlySet<ExtensionToolRegistration>
): readonly AgentTool[] {
  if (builtInTools.some(tool => tool.name === "code" || tool.name === "then")) {
    throw new Error("The tool names code and then are reserved for native code mode")
  }
  if (!host) return builtInTools
  const admitted: AgentTool[] = [...builtInTools]
  const names = new Set([...builtInTools.map(tool => tool.name), "code", "then"])

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
      signal?: AbortSignal
    ): Promise<CodeModeToolInvocation> => {
      const value = await host.invokeTool(registration.name, arguments_, signal)
      return { value, result: extensionToolResult(registration, value) }
    }
    const tool: CodeModeCapableTool = {
      name: registration.name,
      label: registration.label,
      description: registration.description,
      parameters,
      executionMode: "parallel",
      async execute(toolCallId, arguments_, signal) {
        return (await invoke(toolCallId, arguments_, signal)).result
      },
      codeMode: { outputSchema: registration.outputSchema, execute: invoke }
    }
    admitted.push(tool)
  }

  return Object.freeze(admitted)
}

function extensionToolResult(registration: ExtensionToolRegistration, value: JsonValue) {
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
