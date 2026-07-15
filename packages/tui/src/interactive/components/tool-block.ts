import { BoxRenderable, fg, StyledText, TextRenderable, type RenderContext } from "@opentui/core"

import { glyphs } from "../../glyphs.js"
import type { Theme } from "../../theme.js"
import type { ActiveTool } from "../stores/interactive.js"

export type ToolStatus = "pending" | "running" | "done" | "failed" | "aborted"

const toolRailTone = {
  pending: "muted",
  running: "accent",
  done: "success",
  failed: "error",
  aborted: "error"
} as const satisfies Record<ToolStatus, keyof Theme["text"]>

const toolSuffix = {
  pending: "",
  running: "",
  done: "",
  failed: " (error)",
  aborted: " (aborted)"
} as const satisfies Record<ToolStatus, string>

export interface ToolBlockOptions {
  readonly title: string
  readonly output?: string
  readonly status: ToolStatus
}

export function createToolBlock(ctx: RenderContext, options: ToolBlockOptions, theme: Theme): BoxRenderable {
  return createToolFrame(ctx, options, headPreview(options.output, 10), "default", theme)
}

export function createCommandToolBlock(ctx: RenderContext, options: ToolBlockOptions, theme: Theme): BoxRenderable {
  return createToolFrame(ctx, options, tailPreview(options.output, 5), "shell", theme)
}

export function createReadToolBlock(ctx: RenderContext, options: ToolBlockOptions, theme: Theme): BoxRenderable {
  const lines = options.status === "done" ? [] : headPreview(options.output, 10)
  return createToolFrame(ctx, options, lines, "default", theme)
}

export function createActiveToolView(ctx: RenderContext, tool: ActiveTool, theme: Theme): BoxRenderable {
  const options = {
    title: formatToolTitle(tool.name, tool.args),
    output: resultText(tool.result),
    status: tool.status
  } as const

  if (tool.name === "bash") return createCommandToolBlock(ctx, options, theme)
  if (tool.name === "read") return createReadToolBlock(ctx, options, theme)
  return createToolBlock(ctx, options, theme)
}

function createToolFrame(
  ctx: RenderContext,
  options: ToolBlockOptions,
  lines: readonly string[],
  titleTone: "default" | "shell",
  theme: Theme
): BoxRenderable {
  const rail = theme.text[toolRailTone[options.status]]
  const root = new BoxRenderable(ctx, {
    paddingLeft: 1,
    paddingRight: 1,
    flexDirection: "column",
    flexShrink: 0,
    marginBottom: 1
  })
  root.add(
    new TextRenderable(ctx, {
      fg: titleTone === "shell" ? theme.text.shell : theme.text.primary,
      content: `${options.title}${toolSuffix[options.status]}`
    })
  )

  if (lines.length > 0) {
    root.add(new TextRenderable(ctx, { fg: rail, content: glyphs.toolTop }))
    for (const line of lines) {
      root.add(
        new TextRenderable(ctx, {
          content: new StyledText([fg(rail)(glyphs.toolBody), fg(theme.text.toolOutput)(line)])
        })
      )
    }
    root.add(new TextRenderable(ctx, { fg: rail, content: glyphs.toolBottom }))
  }
  return root
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

export function formatToolTitle(name: string, args: unknown): string {
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
