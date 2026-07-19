import {
  BoxRenderable,
  parseColor,
  RGBA,
  StyledText,
  TextRenderable,
  type CliRenderer,
  type TextChunk
} from "@opentui/core"

import type { Color } from "../theme.js"
import { textWidth } from "./cell-text.js"

// Shimmer is the sole TUI component that synthesizes colors between semantic theme endpoints.
const phaseScale = 256
const maxShimmerGraphemes = 64
const graphemes = new Intl.Segmenter(undefined, { granularity: "grapheme" })

export interface ShimmerMotion {
  readonly leadPadColumns: number
  readonly tailPadColumns: number
  readonly bandHalfWidth: number
  readonly floor: number
  readonly msPerColumn: number
}

export const defaultShimmerMotion: ShimmerMotion = Object.freeze({
  leadPadColumns: 6,
  tailPadColumns: 10,
  bandHalfWidth: 3,
  floor: 0,
  msPerColumn: 32
})

interface ShimmerGrapheme {
  readonly text: string
  readonly visualColumn: number
}

interface ShimmerLine {
  readonly text: string
  readonly width: number
  readonly graphemes: readonly ShimmerGrapheme[]
}

export class ShimmerTextView {
  readonly root: BoxRenderable

  readonly #renderer: CliRenderer
  readonly #text: TextRenderable
  #line: ShimmerLine | undefined
  readonly #palette: readonly RGBA[]
  #strengths: Uint8Array
  readonly #now: () => number
  #hasFrame = false
  #active = false
  #destroyed = false

  constructor(renderer: CliRenderer, text: string, baseColor: Color, peakColor: Color, now = () => performance.now()) {
    this.#renderer = renderer
    this.#line = segmentLine(text)
    this.#palette = colorPalette(baseColor, peakColor)
    this.#strengths = new Uint8Array(this.#line?.graphemes.length ?? 0)
    this.#now = now

    this.root = new BoxRenderable(renderer, {
      id: "working-status",
      height: 1,
      flexDirection: "row",
      flexShrink: 0,
      visible: false
    })
    this.#text = new TextRenderable(renderer, {
      id: "working-status-text",
      selectable: false,
      wrapMode: "none",
      fg: baseColor,
      content: baseText(this.#line?.text ?? firstLine(text), this.#palette[0]!)
    })
    this.root.add(this.#text)
    this.root.onLifecyclePass = this.#renderFrame
  }

  setText(text: string): void {
    const line = segmentLine(text)
    if (line?.text === this.#line?.text) return
    this.#line = line
    this.#strengths = new Uint8Array(line?.graphemes.length ?? 0)
    this.#hasFrame = false
    this.#text.content = baseText(line?.text ?? firstLine(text), this.#palette[0]!)
  }

  setActive(active: boolean): void {
    if (active === this.#active) return
    this.#active = active
    this.root.visible = active
    if (!this.#line || this.#line.graphemes.length === 0) return
    if (active) this.#renderer.requestLive()
    else this.#renderer.dropLive()
  }

  destroy(): void {
    if (this.#destroyed) return
    this.#destroyed = true
    if (this.#active && this.#line && this.#line.graphemes.length > 0) this.#renderer.dropLive()
    this.#active = false
    this.root.onLifecyclePass = null
    this.root.destroyRecursively()
  }

  #renderFrame = (): void => {
    const line = this.#line
    if (!this.#active || !line) return

    const phase = phaseForWidth(this.#now(), line.width, defaultShimmerMotion)
    let changed = !this.#hasFrame
    for (let index = 0; index < line.graphemes.length; index++) {
      const strength = flooredStrength(
        strengthForColumn(phase, line.graphemes[index]!.visualColumn, defaultShimmerMotion),
        defaultShimmerMotion.floor
      )
      if (strength !== this.#strengths[index]) changed = true
      this.#strengths[index] = strength
    }
    if (!changed) return

    this.#hasFrame = true
    this.#text.content = styledLine(line.graphemes, this.#strengths, this.#palette)
  }
}

export function phaseForMs(nowMs: number, text: string, motion: ShimmerMotion = defaultShimmerMotion): number {
  return phaseForWidth(nowMs, textWidth(text), motion)
}

export function strengthForColumn(
  phase: number,
  visualColumn: number,
  motion: ShimmerMotion = defaultShimmerMotion
): number {
  const textPosition = (motion.leadPadColumns + visualColumn) * phaseScale
  const distance = Math.abs(textPosition - phase)
  const radius = motion.bandHalfWidth * phaseScale
  if (radius <= 0) return distance === 0 ? 255 : 0
  if (distance > radius) return 0
  return Math.min(Math.trunc(((radius - distance) * 255) / radius), 255)
}

function phaseForWidth(nowMs: number, width: number, motion: ShimmerMotion): number {
  const periodColumns = width + motion.leadPadColumns + motion.tailPadColumns
  if (periodColumns <= 0 || motion.msPerColumn <= 0) return 0
  const elapsedMs = Math.floor(nowMs)
  const periodMs = periodColumns * motion.msPerColumn
  const cycleMs = elapsedMs % periodMs
  return Math.floor((cycleMs * phaseScale) / motion.msPerColumn)
}

function segmentLine(text: string): ShimmerLine | undefined {
  const line = firstLine(text)
  const segments: ShimmerGrapheme[] = []
  let width = 0
  for (const { segment } of graphemes.segment(line)) {
    if (segments.length === maxShimmerGraphemes) return undefined
    segments.push({ text: segment, visualColumn: width })
    width += textWidth(segment)
  }
  return { text: line, width, graphemes: segments }
}

function firstLine(text: string): string {
  const newline = text.indexOf("\n")
  return newline === -1 ? text : text.slice(0, newline)
}

function flooredStrength(rawStrength: number, floor: number): number {
  if (rawStrength <= floor) return 0
  return Math.trunc(((rawStrength - floor) * 255) / (255 - floor))
}

function colorPalette(baseColor: Color, peakColor: Color): readonly RGBA[] {
  const base = parseColor(baseColor)
  const peak = parseColor(peakColor)
  const baseChannels = base.toInts()
  const peakChannels = peak.toInts()
  return Array.from({ length: 256 }, (_, strength) => {
    if (strength === 0) return base
    if (strength === 255) return peak
    return RGBA.fromInts(
      lerpChannel(baseChannels[0], peakChannels[0], strength),
      lerpChannel(baseChannels[1], peakChannels[1], strength),
      lerpChannel(baseChannels[2], peakChannels[2], strength),
      lerpChannel(baseChannels[3], peakChannels[3], strength)
    )
  })
}

function lerpChannel(from: number, to: number, strength: number): number {
  return Math.max(0, Math.min(from + Math.trunc(((to - from) * strength) / 255), 255))
}

function styledLine(segments: readonly ShimmerGrapheme[], strengths: Uint8Array, palette: readonly RGBA[]): StyledText {
  if (segments.length === 0) return new StyledText([])

  const chunks: TextChunk[] = []
  let text = segments[0]!.text
  let strength = strengths[0]!
  for (let index = 1; index < segments.length; index++) {
    const nextStrength = strengths[index]!
    if (nextStrength === strength) {
      text += segments[index]!.text
      continue
    }
    chunks.push(textChunk(text, palette[strength]!))
    text = segments[index]!.text
    strength = nextStrength
  }
  chunks.push(textChunk(text, palette[strength]!))
  return new StyledText(chunks)
}

function baseText(text: string, color: RGBA): StyledText {
  return new StyledText(text.length === 0 ? [] : [textChunk(text, color)])
}

function textChunk(text: string, color: RGBA): TextChunk {
  return { __isChunk: true, text, fg: color }
}
