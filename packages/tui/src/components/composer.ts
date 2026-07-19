import { BoxRenderable, RGBA, TextareaRenderable, type OptimizedBuffer, type RenderContext } from "@opentui/core"
import stringWidth from "string-width"

import type { Theme } from "../theme.js"

export interface ComposerGeometry {
  readonly columns: number
  readonly bordered: boolean
  readonly editorRows: number
  readonly protectedRows: number
}

export interface ComposerSlots {
  readonly topLeft: string
  /** Ordered most important first. Only the largest fitting prefix is rendered. */
  readonly topRight: readonly string[]
}

export interface ComposerOptions {
  readonly geometry: ComposerGeometry
  readonly slots: ComposerSlots
  readonly theme: Theme
  readonly onSubmit: () => void
  readonly onContentChange?: () => void
}

export interface Composer {
  readonly root: BoxRenderable
  readonly input: TextareaRenderable
  update(geometry: ComposerGeometry, slots: ComposerSlots): void
  destroy(): void
}

interface RailLayout {
  readonly topRightText: string
  readonly topRightWidth: number
}

export function composerGeometry(width: number, height: number): ComposerGeometry {
  const bordered = height >= 6 && width >= 4
  const editorRows = Math.max(1, Math.min(5, Math.floor(height * 0.3)))
  return { columns: width, bordered, editorRows, protectedRows: editorRows + (bordered ? 2 : 0) }
}

export function createComposer(ctx: RenderContext, options: ComposerOptions): Composer {
  let geometry = options.geometry
  let slots = retainSlots(options.slots)
  let rail = layoutRail(geometry, slots)
  const railColor = RGBA.fromHex(options.theme.text.muted)
  const railBackground = RGBA.fromHex(options.theme.surface.composer)
  const root = new BoxRenderable(ctx, {
    id: "prompt-composer",
    border: geometry.bordered,
    borderStyle: "rounded",
    borderColor: options.theme.border.default,
    backgroundColor: options.theme.surface.composer,
    ...(geometry.bordered ? { title: slots.topLeft } : {}),
    titleColor: options.theme.text.muted,
    flexShrink: 0,
    renderAfter(buffer) {
      drawTopRightSlot(buffer, this, geometry.bordered, rail, railColor, railBackground)
    }
  })
  const input = new TextareaRenderable(ctx, {
    id: "prompt-input",
    minHeight: 1,
    maxHeight: geometry.editorRows,
    wrapMode: "word",
    textColor: options.theme.text.primary,
    focusedTextColor: options.theme.text.primary,
    cursorColor: options.theme.text.primary,
    backgroundColor: options.theme.surface.composer,
    focusedBackgroundColor: options.theme.surface.composer,
    ...(options.onContentChange ? { onContentChange: options.onContentChange } : {}),
    keyBindings: [
      { name: "return", action: "submit" },
      { name: "return", shift: true, action: "newline" }
    ],
    onSubmit: options.onSubmit
  })
  root.add(input)

  return {
    root,
    input,
    update(nextGeometry, nextSlots) {
      const geometryChanged = !sameGeometry(geometry, nextGeometry)
      const slotsChanged = !sameSlots(slots, nextSlots)
      if (!geometryChanged && !slotsChanged) return
      const retainedSlots = slotsChanged ? retainSlots(nextSlots) : slots

      const borderChanged = geometry.bordered !== nextGeometry.bordered
      const editorRowsChanged = geometry.editorRows !== nextGeometry.editorRows
      const topLeftChanged = slots.topLeft !== retainedSlots.topLeft
      const nextRail =
        geometry.columns !== nextGeometry.columns || borderChanged || slotsChanged
          ? layoutRail(nextGeometry, retainedSlots)
          : rail
      const railChanged = rail.topRightText !== nextRail.topRightText

      geometry = nextGeometry
      slots = retainedSlots
      rail = nextRail

      if (borderChanged) root.border = geometry.bordered
      if (geometry.bordered && (borderChanged || topLeftChanged)) root.title = slots.topLeft
      if (editorRowsChanged) input.maxHeight = geometry.editorRows
      if (railChanged) root.requestRender()
    },
    destroy() {
      root.destroyRecursively()
    }
  }
}

function layoutRail(geometry: ComposerGeometry, slots: ComposerSlots): RailLayout {
  if (!geometry.bordered || slots.topRight.length === 0) return { topRightText: "", topRightWidth: 0 }
  const available = geometry.columns - 4 - stringWidth(slots.topLeft) - (slots.topLeft ? 1 : 0)
  let topRightText = ""
  let topRightWidth = 0
  for (const item of slots.topRight) {
    const itemWidth = stringWidth(item)
    const nextWidth = topRightWidth + (topRightText ? 1 : 0) + itemWidth
    if (nextWidth > available) break
    topRightText += `${topRightText ? " " : ""}${item}`
    topRightWidth = nextWidth
  }
  return { topRightText, topRightWidth }
}

function drawTopRightSlot(
  buffer: OptimizedBuffer,
  root: BoxRenderable,
  bordered: boolean,
  rail: RailLayout,
  color: RGBA,
  background: RGBA
): void {
  if (!bordered || !rail.topRightText) return
  buffer.drawText(
    rail.topRightText,
    root.screenX + root.width - rail.topRightWidth - 2,
    root.screenY,
    color,
    background
  )
}

function retainSlots(slots: ComposerSlots): ComposerSlots {
  return { topLeft: slots.topLeft, topRight: [...slots.topRight] }
}

function sameGeometry(left: ComposerGeometry, right: ComposerGeometry): boolean {
  return (
    left.columns === right.columns &&
    left.bordered === right.bordered &&
    left.editorRows === right.editorRows &&
    left.protectedRows === right.protectedRows
  )
}

function sameSlots(left: ComposerSlots, right: ComposerSlots): boolean {
  return (
    left.topLeft === right.topLeft &&
    left.topRight.length === right.topRight.length &&
    left.topRight.every((item, index) => item === right.topRight[index])
  )
}
