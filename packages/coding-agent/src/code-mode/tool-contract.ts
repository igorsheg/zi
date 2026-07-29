import type { AgentTool, AgentToolResult, AgentToolUpdateCallback } from "@earendil-works/pi-agent-core"

import type { CodeModeJson } from "./protocol.js"

export interface CodeModeToolInvocation {
  readonly result: AgentToolResult<unknown>
  readonly value: CodeModeJson
}

export interface CodeModeToolContract {
  readonly outputSchema: unknown
  execute(
    toolCallId: string,
    input: unknown,
    signal: AbortSignal,
    onUpdate?: AgentToolUpdateCallback<unknown>
  ): Promise<CodeModeToolInvocation>
}

export type CodeModeCapableTool = AgentTool & { readonly codeMode: CodeModeToolContract }

export function codeModeToolContract(tool: AgentTool): CodeModeToolContract | undefined {
  return (tool as AgentTool & { readonly codeMode?: CodeModeToolContract }).codeMode
}
