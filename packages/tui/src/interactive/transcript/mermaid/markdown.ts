import {
  parseColor,
  RenderableEvents,
  TextRenderable,
  type ColorInput,
  type MouseEvent,
  type RenderContext,
  type RGBA,
  type StyledText
} from "@opentui/core"

import { DiagramCanvasSizeError } from "./core/canvas.js"
import { detectMermaidDiagram } from "./detect.js"
import { MermaidSyntaxError } from "./diagnostics.js"
import { drawFlowchartDiagramGrid } from "./flowchart/drawing.js"
import { parseMermaidFlowchartDiagram } from "./flowchart/parser.js"
import { renderGridStyledText, resolveFlowchartStyleColors } from "./flowchart/style.js"
import { drawSequenceDiagramGrid } from "./sequence/drawing.js"
import { parseMermaidSequenceDiagram } from "./sequence/parser.js"
import { renderSequenceGridStyledText } from "./sequence/render-grid.js"
import { resolveSequenceStyleColors } from "./sequence/style.js"
import { drawStateDiagramGrid } from "./state/drawing.js"
import { parseMermaidStateDiagram } from "./state/parser.js"
import { renderStateGridStyledText } from "./state/render-grid.js"
import { resolveStateStyleColors } from "./state/style.js"

// Ported from OpenCode Merman at c581b59b7f0c235555226900158feab43bf64ded.
// See UPSTREAM.md and LICENSE.opencode in this directory.

type DiagramKind = NonNullable<ReturnType<typeof detectMermaidDiagram>>

interface PreparedDiagram {
  readonly kind: DiagramKind
  readonly text: StyledText
  readonly width: number
  readonly height: number
}

export interface MermaidRendererOptions {
  compact?: boolean
  colors?: {
    text?: ColorInput
    primary?: ColorInput
    secondary?: ColorInput
    muted?: ColorInput
    warning?: ColorInput
    background?: ColorInput
    request?: ColorInput
    response?: ColorInput
    note?: ColorInput
    noteBackground?: ColorInput
  }
}

const maxSourceBytes = 16 * 1024
const maxSourceLines = 256
const maxNodes = 128
const maxEdges = 256
const maxSequenceParticipants = 32
const maxDiagramColumns = 2_000
const maxDiagramRows = 200
const maxDiagramsPerMarkdown = 16

class MermaidLimitError extends Error {}

function color(value: ColorInput | undefined): RGBA | undefined {
  return value === undefined ? undefined : parseColor(value)
}

function definedColors<T extends Record<string, RGBA | undefined>>(colors: T): Partial<Record<keyof T, RGBA>> {
  return Object.fromEntries(
    Object.entries(colors).filter((entry): entry is [string, RGBA] => entry[1] !== undefined)
  ) as Partial<Record<keyof T, RGBA>>
}

class StaticDiagramRenderable extends TextRenderable {
  constructor(ctx: RenderContext, prepared: PreparedDiagram) {
    super(ctx, {
      content: prepared.text,
      width: "100%",
      height: prepared.height,
      wrapMode: "none",
      selectable: false,
      marginTop: 1
    })
    let dragX: number | undefined
    this.onMouseDown = (event: MouseEvent) => {
      if (event.button !== 0) return
      ctx.clearSelection()
      dragX = event.x
      event.preventDefault()
      event.stopPropagation()
    }
    this.onMouseDrag = (event: MouseEvent) => {
      event.preventDefault()
      event.stopPropagation()
      if (dragX === undefined) return
      const dx = event.x - dragX
      dragX = event.x
      if (dx) this.scrollX -= dx
    }
    this.onMouseDragEnd = (event: MouseEvent) => {
      dragX = undefined
      event.preventDefault()
      event.stopPropagation()
    }
    this.onMouseUp = (event: MouseEvent) => {
      if (event.button !== 0) return
      dragX = undefined
      event.preventDefault()
      event.stopPropagation()
    }
    this.onMouseScroll = (event: MouseEvent) => {
      const scroll = event.scroll
      if (!scroll || (scroll.direction !== "left" && scroll.direction !== "right")) return
      event.preventDefault()
      event.stopPropagation()
    }
  }
}

function prepareDiagram(kind: DiagramKind, source: string, options: MermaidRendererOptions): PreparedDiagram {
  const colors = options.colors ?? {}
  switch (kind) {
    case "flowchart": {
      const diagram = parseMermaidFlowchartDiagram(source)
      enforceComplexity(diagram.nodes.length, diagram.edges.length)
      const grid = drawFlowchartDiagramGrid(diagram, options.compact === undefined ? {} : { compact: options.compact })
      const size = grid.getTextSize({ trimTop: true, trimBottom: true })
      enforceSize(size)
      return {
        kind,
        text: renderGridStyledText(
          grid,
          resolveFlowchartStyleColors({
            node: color(colors.primary),
            database: color(colors.primary),
            edge: color(colors.secondary),
            label: color(colors.text),
            group: color(colors.muted)
          })
        ),
        ...size
      }
    }
    case "sequence": {
      const diagram = parseMermaidSequenceDiagram(source)
      if (diagram.participants.length > maxSequenceParticipants) throw new MermaidLimitError()
      enforceComplexity(diagram.participants.length, diagram.steps.length)
      const grid = drawSequenceDiagramGrid(diagram, options.compact === undefined ? {} : { compact: options.compact })
      const size = grid.getTextSize()
      enforceSize(size)
      return {
        kind,
        text: renderSequenceGridStyledText(
          grid,
          resolveSequenceStyleColors(
            definedColors({
              participant: color(colors.primary),
              lifeline: color(colors.muted),
              group: color(colors.secondary),
              request: color(colors.request ?? colors.primary),
              response: color(colors.response ?? colors.primary),
              fragment: color(colors.secondary),
              fragmentLabelBg: color(colors.background),
              note: color(colors.note ?? colors.warning),
              noteBg: color(colors.noteBackground ?? colors.background)
            })
          )
        ),
        ...size
      }
    }
    case "state": {
      const diagram = parseMermaidStateDiagram(source)
      enforceComplexity(diagram.states.length + diagram.composites.length, diagram.transitions.length)
      const grid = drawStateDiagramGrid(diagram)
      const size = grid.getTextSize({ trimBottom: true })
      enforceSize(size)
      return {
        kind,
        text: renderStateGridStyledText(
          grid,
          resolveStateStyleColors({
            state: color(colors.primary),
            composite: color(colors.muted),
            transition: color(colors.secondary),
            label: color(colors.text),
            noteBorder: color(colors.warning),
            noteText: color(colors.warning),
            noteConnector: color(colors.muted),
            start: color(colors.muted),
            end: color(colors.muted),
            choice: color(colors.secondary)
          })
        ),
        ...size
      }
    }
  }
}

function sourceWithinBounds(source: string): boolean {
  if (Buffer.byteLength(source) > maxSourceBytes) return false
  let lines = 1
  for (const char of source) {
    if (char === "\n" && ++lines > maxSourceLines) return false
  }
  return true
}

function enforceComplexity(nodes: number, edges: number): void {
  if (nodes > maxNodes || edges > maxEdges) throw new MermaidLimitError()
}

function enforceSize(size: { readonly width: number; readonly height: number }): void {
  if (size.width > maxDiagramColumns || size.height > maxDiagramRows) throw new MermaidLimitError()
}

export interface MermaidRenderer {
  render(key: string, source: string): TextRenderable | undefined
  release(key: string): void
}

export function createMermaidRenderer(
  ctx: RenderContext,
  input: MermaidRendererOptions | (() => MermaidRendererOptions) = {}
): MermaidRenderer {
  const lastGood = new Map<string, PreparedDiagram>()
  return {
    render(key, source) {
      if (!sourceWithinBounds(source)) return undefined
      const kind = detectMermaidDiagram(source)
      if (!kind || (!lastGood.has(key) && lastGood.size >= maxDiagramsPerMarkdown)) return undefined
      const options = typeof input === "function" ? input() : input

      try {
        const prepared = prepareDiagram(kind, source, options)
        const diagram = new StaticDiagramRenderable(ctx, prepared)
        claimLastGood(key, prepared, diagram, lastGood)
        return diagram
      } catch (error) {
        if (error instanceof MermaidSyntaxError) {
          const previous = lastGood.get(key)
          if (!previous || previous.kind !== kind) return undefined
          const diagram = new StaticDiagramRenderable(ctx, previous)
          claimLastGood(key, previous, diagram, lastGood)
          return diagram
        }
        if (error instanceof DiagramCanvasSizeError || error instanceof MermaidLimitError) return undefined
        throw error
      }
    },
    release(key) {
      lastGood.delete(key)
    }
  }
}

function claimLastGood(
  key: string,
  value: PreparedDiagram,
  owner: StaticDiagramRenderable,
  cache: Map<string, PreparedDiagram>
): void {
  const claim = { ...value }
  cache.set(key, claim)
  owner.once(RenderableEvents.DESTROYED, () => {
    // Replacement destroys the prior block before the new block can claim the same key.
    queueMicrotask(() => {
      if (cache.get(key) === claim) cache.delete(key)
    })
  })
}
