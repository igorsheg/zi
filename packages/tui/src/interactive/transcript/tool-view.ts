import { BoxRenderable, fg, StyledText, TextRenderable, type RenderContext } from "@opentui/core"

import { glyphs } from "../../glyphs.js"
import type { Theme } from "../../theme.js"
import type { ActiveTool } from "../interactive-store.js"

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

type ActiveToolPresentation = {
  readonly kind: "command" | "read" | "generic"
  readonly title: string
  readonly status: ActiveTool["status"]
  readonly lines: readonly string[]
  readonly titleTone: "default" | "shell"
}

export class ActiveToolView {
  readonly root: BoxRenderable

  readonly #ctx: RenderContext
  readonly #theme: Theme
  readonly #title: TextRenderable
  #tool: ActiveTool
  #presentation: ActiveToolPresentation
  #preview: { top: TextRenderable; lines: TextRenderable[]; bottom: TextRenderable } | undefined

  constructor(ctx: RenderContext, tool: ActiveTool, theme: Theme) {
    this.#ctx = ctx
    this.#theme = theme
    this.#tool = tool
    this.#presentation = activeToolPresentation(tool)
    this.root = new BoxRenderable(ctx, {
      id: `active-tool:${tool.id}`,
      paddingLeft: 1,
      paddingRight: 1,
      flexDirection: "column",
      flexShrink: 0,
      marginBottom: 1
    })
    this.#title = new TextRenderable(ctx, {
      fg: titleColor(this.#presentation.titleTone, theme),
      content: toolTitle(this.#presentation)
    })
    this.root.add(this.#title)
    this.#rebuildPreview(this.#presentation)
  }

  update(tool: ActiveTool): boolean {
    if (tool === this.#tool) return false
    this.#tool = tool
    const next = activeToolPresentation(tool)
    const current = this.#presentation
    if (sameActiveToolPresentation(current, next)) return false

    if (toolTitle(current) !== toolTitle(next)) this.#title.content = toolTitle(next)
    if (current.titleTone !== next.titleTone) this.#title.fg = titleColor(next.titleTone, this.#theme)

    if (current.lines.length !== next.lines.length || current.kind !== next.kind) {
      this.#destroyPreview()
      this.#rebuildPreview(next)
    } else if (next.lines.length > 0) {
      const preview = this.#preview
      if (!preview) throw new Error("Active tool preview is missing")
      if (current.status !== next.status) {
        const rail = railColor(next.status, this.#theme)
        preview.top.fg = rail
        preview.bottom.fg = rail
      }
      for (let index = 0; index < next.lines.length; index++) {
        if (current.status === next.status && current.lines[index] === next.lines[index]) continue
        preview.lines[index]!.content = previewLine(next.lines[index]!, next.status, this.#theme)
      }
    }

    this.#presentation = next
    return true
  }

  destroy(): void {
    this.root.destroyRecursively()
  }

  #rebuildPreview(presentation: ActiveToolPresentation): void {
    if (presentation.lines.length === 0) return
    const rail = railColor(presentation.status, this.#theme)
    const top = new TextRenderable(this.#ctx, { fg: rail, content: glyphs.toolTop })
    const lines = presentation.lines.map(
      line => new TextRenderable(this.#ctx, { content: previewLine(line, presentation.status, this.#theme) })
    )
    const bottom = new TextRenderable(this.#ctx, { fg: rail, content: glyphs.toolBottom })
    this.root.add(top)
    for (const line of lines) this.root.add(line)
    this.root.add(bottom)
    this.#preview = { top, lines, bottom }
  }

  #destroyPreview(): void {
    if (!this.#preview) return
    const renderables = [this.#preview.top, ...this.#preview.lines, this.#preview.bottom]
    this.#preview = undefined
    for (const renderable of renderables) {
      this.root.remove(renderable)
      renderable.destroyRecursively()
    }
  }
}

export function createActiveToolView(ctx: RenderContext, tool: ActiveTool, theme: Theme): ActiveToolView {
  return new ActiveToolView(ctx, tool, theme)
}

function createToolFrame(
  ctx: RenderContext,
  options: ToolBlockOptions,
  lines: readonly string[],
  titleTone: "default" | "shell",
  theme: Theme
): BoxRenderable {
  const rail = railColor(options.status, theme)
  const root = new BoxRenderable(ctx, {
    paddingLeft: 1,
    paddingRight: 1,
    flexDirection: "column",
    flexShrink: 0,
    marginBottom: 1
  })
  root.add(
    new TextRenderable(ctx, {
      fg: titleColor(titleTone, theme),
      content: `${options.title}${toolSuffix[options.status]}`
    })
  )

  if (lines.length > 0) {
    root.add(new TextRenderable(ctx, { fg: rail, content: glyphs.toolTop }))
    for (const line of lines) {
      root.add(new TextRenderable(ctx, { content: previewLine(line, options.status, theme) }))
    }
    root.add(new TextRenderable(ctx, { fg: rail, content: glyphs.toolBottom }))
  }
  return root
}

function activeToolPresentation(tool: ActiveTool): ActiveToolPresentation {
  const output = resultText(tool.result)
  if (tool.name === "bash") {
    return {
      kind: "command",
      title: formatToolTitle(tool.name, tool.args),
      status: tool.status,
      lines: tailPreview(output, 5),
      titleTone: "shell"
    }
  }
  if (tool.name === "read") {
    return {
      kind: "read",
      title: formatToolTitle(tool.name, tool.args),
      status: tool.status,
      lines: tool.status === "done" ? [] : headPreview(output, 10),
      titleTone: "default"
    }
  }
  return {
    kind: "generic",
    title: formatToolTitle(tool.name, tool.args),
    status: tool.status,
    lines: headPreview(output, 10),
    titleTone: "default"
  }
}

function sameActiveToolPresentation(left: ActiveToolPresentation, right: ActiveToolPresentation): boolean {
  if (
    left.kind !== right.kind ||
    left.title !== right.title ||
    left.status !== right.status ||
    left.titleTone !== right.titleTone ||
    left.lines.length !== right.lines.length
  ) {
    return false
  }
  return left.lines.every((line, index) => line === right.lines[index])
}

function toolTitle(presentation: ActiveToolPresentation): string {
  return `${presentation.title}${toolSuffix[presentation.status]}`
}

function titleColor(tone: ActiveToolPresentation["titleTone"], theme: Theme): string {
  return tone === "shell" ? theme.text.shell : theme.text.primary
}

function railColor(status: ToolStatus, theme: Theme): string {
  return theme.text[toolRailTone[status]]
}

function previewLine(line: string, status: ToolStatus, theme: Theme): StyledText {
  return new StyledText([fg(railColor(status, theme))(glyphs.toolBody), fg(theme.text.toolOutput)(line)])
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
