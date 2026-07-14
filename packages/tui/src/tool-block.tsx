import { glyphs } from "./glyphs.js"
import type { ActiveTool } from "./session-context.js"
import { useTheme } from "./theme.js"

// Tool output lines are ordered text and have no stable IDs.
/* oxlint-disable react/no-array-index-key */

export type ToolStatus = "pending" | "running" | "done" | "failed" | "aborted"

export interface ToolBlockProps {
  title: string
  output?: string
  status: ToolStatus
}

export function ToolBlock(props: ToolBlockProps) {
  return <ToolFrame {...props} lines={headPreview(props.output, 10)} titleTone="default" />
}

export function CommandToolBlock(props: ToolBlockProps) {
  return <ToolFrame {...props} lines={tailPreview(props.output, 5)} titleTone="shell" />
}

export function ActiveToolView({ tool }: { tool: ActiveTool }) {
  const props = {
    title: toolTitle(tool.name, tool.args),
    output: resultText(tool.result),
    status: tool.status
  } as const

  return tool.name === "bash" ? <CommandToolBlock {...props} /> : <ToolBlock {...props} />
}

function ToolFrame({
  title,
  status,
  lines,
  titleTone
}: ToolBlockProps & { lines: readonly string[]; titleTone: "default" | "shell" }) {
  const theme = useTheme()
  const rail =
    status === "done"
      ? theme.text.success
      : status === "failed" || status === "aborted"
        ? theme.text.error
        : status === "running"
          ? theme.text.accent
          : theme.text.muted
  const suffix = status === "failed" ? " (error)" : status === "aborted" ? " (aborted)" : ""
  const titleColor = titleTone === "shell" ? theme.text.shell : theme.text.primary

  return (
    <box paddingLeft={1} paddingRight={1} flexDirection="column" flexShrink={0} marginBottom={1}>
      <text fg={titleColor}>
        {title}
        {suffix}
      </text>
      {lines.length > 0 ? (
        <>
          <text fg={rail}>{glyphs.toolTop}</text>
          {lines.map((line, index) => (
            <text key={index}>
              <span style={{ fg: rail }}>{glyphs.toolBody}</span>
              <span style={{ fg: theme.text.toolOutput }}>{line}</span>
            </text>
          ))}
          <text fg={rail}>{glyphs.toolBottom}</text>
        </>
      ) : null}
    </box>
  )
}

function headPreview(output: string | undefined, limit: number): string[] {
  const lines = outputLines(output)
  if (lines.length <= limit) return lines
  return [...lines.slice(0, limit), `... (${lines.length - limit} more lines)`]
}

function tailPreview(output: string | undefined, limit: number): string[] {
  const lines = outputLines(output)
  if (lines.length <= limit) return lines
  return [`... (${lines.length - limit} earlier lines)`, ...lines.slice(-limit)]
}

function outputLines(output: string | undefined): string[] {
  return output ? output.replace(/[\r\n]+$/, "").split(/\r?\n/) : []
}

function toolTitle(name: string, args: unknown): string {
  if (!isRecord(args)) return name
  const detail = displayValue(args.path ?? args.command)
  if (name === "bash") return detail ? `$ ${detail}` : "$"
  return detail ? `${name} ${detail}` : name
}

function resultText(result: unknown): string {
  if (!isRecord(result) || !Array.isArray(result.content)) return ""
  return result.content
    .map(part => (isRecord(part) && part.type === "text" && typeof part.text === "string" ? part.text : ""))
    .filter(Boolean)
    .join("\n")
}

function displayValue(value: unknown): string {
  return typeof value === "string" || typeof value === "number" || typeof value === "boolean" ? String(value) : ""
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}
