import type { AgentTool } from "@earendil-works/pi-agent-core"
import { Type } from "typebox"

import type { ExtensionHost } from "./host.js"

export interface ExtensionToolDetails {
  readonly type: "extension"
  readonly extensionId: string
  readonly toolName: string
  readonly outcome: "success"
}

export function admitExtensionTools(
  builtInTools: readonly AgentTool[],
  host: ExtensionHost | undefined
): readonly AgentTool[] {
  if (!host) return builtInTools
  const admitted: AgentTool[] = [...builtInTools]
  const names = new Set(builtInTools.map(tool => tool.name))

  for (const registration of host.toolCatalog()) {
    if (names.has(registration.name)) {
      host.rejectTool(
        registration,
        `Extension tool ${registration.name} conflicts with an existing session tool and was ignored`
      )
      continue
    }
    names.add(registration.name)
    const parameters = Type.Unsafe(registration.parameters)
    admitted.push({
      name: registration.name,
      label: registration.label,
      description: registration.description,
      parameters,
      executionMode: "parallel",
      async execute(_toolCallId, arguments_, signal) {
        const content = await host.invokeTool(registration.name, arguments_, signal)
        const details: ExtensionToolDetails = {
          type: "extension",
          extensionId: registration.source.id,
          toolName: registration.name,
          outcome: "success"
        }
        return { content: [{ type: "text", text: content }], details }
      }
    })
  }

  return Object.freeze(admitted)
}
