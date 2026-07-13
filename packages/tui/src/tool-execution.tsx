import type { ToolExecution } from "./session-context.js"

export function ToolExecutionView({ tool }: { tool: ToolExecution }) {
  const icon = tool.status === "running" ? "│" : tool.status === "done" ? "✓" : "✗"
  const color = tool.status === "failed" ? "#F85149" : tool.status === "done" ? "#3FB950" : "#79C0FF"
  const output = resultText(tool.result)

  return (
    <box paddingLeft={1} flexDirection="column" flexShrink={0}>
      <text fg={color}>
        {icon} {tool.name} {detail(tool.args)}
      </text>
      {output ? <text fg="#7D8590">  {output}</text> : null}
    </box>
  )
}

function resultText(result: unknown): string {
  if (!result || typeof result !== "object" || !("content" in result) || !Array.isArray(result.content)) return ""
  return result.content
    .map((part: unknown) =>
      part && typeof part === "object" && "type" in part && part.type === "text" && "text" in part
        ? String(part.text)
        : "",
    )
    .filter(Boolean)
    .join("\n")
}

function detail(args: unknown): string {
  if (!args || typeof args !== "object") return ""
  const values = args as Record<string, unknown>
  const value = values.path ?? values.command
  return value === undefined ? "" : String(value)
}
