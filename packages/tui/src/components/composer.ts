import {
  BoxRenderable,
  RGBA,
  TextareaRenderable,
  type Extmark,
  type OptimizedBuffer,
  type PasteEvent,
  type RenderContext
} from "@opentui/core"
import type { ImageContent } from "@openzi/coding-agent"

import type { Theme } from "../theme.js"
import { textWidth } from "./cell-text.js"

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
  readonly onImageMarkersChange?: (images: readonly ImageContent[]) => void
  readonly onPaste?: (event: PasteEvent) => void
}

export interface Composer {
  readonly root: BoxRenderable
  readonly input: TextareaRenderable
  insertPastedText(text: string): void
  syncImageMarkers(images: readonly ImageContent[]): void
  activeImages(): readonly ImageContent[]
  expandedText(): string
  replaceText(text: string, cursorOffset?: number): void
  update(geometry: ComposerGeometry, slots: ComposerSlots): void
  destroy(): void
}

interface RailLayout {
  readonly topRightText: string
  readonly topRightWidth: number
}

type ComposerMarkerData =
  | { readonly type: "paste"; readonly marker: string; readonly text: string }
  | { readonly type: "image"; readonly marker: string; readonly image: ImageContent }

export const compactPasteLineThreshold = 10
export const compactPasteCharacterThreshold = 1_000
export const maxCompactPasteMarkers = 32
export const maxCompactPasteRetainedBytes = 4 * 1024 * 1024

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
  let suppressContentChange = false
  let markerTypeId = 0
  let nextPasteId = 0
  let nextImageId = 0
  let markerRevision = 0
  let input!: TextareaRenderable

  const notifyContentChange = () => {
    if (suppressContentChange) return
    options.onContentChange?.()
    const revision = ++markerRevision
    queueMicrotask(() => {
      if (revision !== markerRevision || input.isDestroyed) return
      options.onImageMarkersChange?.(imageMarkers(input, markerTypeId))
    })
  }

  input = new TextareaRenderable(ctx, {
    id: "prompt-input",
    minHeight: 1,
    maxHeight: geometry.editorRows,
    wrapMode: "word",
    textColor: options.theme.text.primary,
    focusedTextColor: options.theme.text.primary,
    cursorColor: options.theme.text.primary,
    backgroundColor: options.theme.surface.composer,
    focusedBackgroundColor: options.theme.surface.composer,
    onContentChange: notifyContentChange,
    ...(options.onPaste ? { onPaste: options.onPaste } : {}),
    keyBindings: [
      { name: "return", action: "submit" },
      { name: "return", shift: true, action: "newline" }
    ],
    onSubmit: options.onSubmit
  })
  markerTypeId = input.extmarks.registerType("openzi-composer-marker")
  const nativeGetSelectedText = input.getSelectedText.bind(input)
  const nativeUndo = input.undo.bind(input)
  const nativeRedo = input.redo.bind(input)
  input.getSelectedText = () => {
    const selectedText = nativeGetSelectedText()
    const selection = input.getSelection()
    if (!selection) return selectedText
    const start = Math.min(selection.start, selection.end)
    const end = Math.max(selection.start, selection.end)
    const markers = composerMarkers(input, markerTypeId).flatMap(marker =>
      marker.data.type === "paste" && marker.start >= start && marker.end <= end
        ? [{ ...marker, start: marker.start - start, end: marker.end - start }]
        : []
    )
    return expandMarkerRanges(selectedText, markers)
  }
  input.undo = () => {
    const result = nativeUndo()
    notifyContentChange()
    return result
  }
  input.redo = () => {
    const result = nativeRedo()
    notifyContentChange()
    return result
  }
  root.add(input)

  const insertMarker = (marker: string, data: ComposerMarkerData) => {
    suppressContentChange = true
    try {
      const start = input.cursorOffset
      input.insertText(marker)
      input.extmarks.create({
        start,
        end: start + promptOffsetWidth(marker),
        virtual: true,
        typeId: markerTypeId,
        data
      })
    } finally {
      suppressContentChange = false
    }
    notifyContentChange()
  }

  return {
    root,
    input,
    insertPastedText(text) {
      const lineCount = text.split("\n").length
      if (lineCount <= compactPasteLineThreshold && text.length <= compactPasteCharacterThreshold) {
        input.insertText(text)
        return
      }
      const retainedPastes = composerMarkers(input, markerTypeId).flatMap(marker =>
        marker.data.type === "paste" ? [marker.data] : []
      )
      if (
        retainedPastes.length >= maxCompactPasteMarkers ||
        retainedPastes.reduce((bytes, marker) => bytes + Buffer.byteLength(marker.text), 0) + Buffer.byteLength(text) >
          maxCompactPasteRetainedBytes
      ) {
        input.insertText(text)
        return
      }
      const marker =
        lineCount > compactPasteLineThreshold
          ? `[paste #${++nextPasteId} +${lineCount} lines]`
          : `[paste #${++nextPasteId} ${text.length} chars]`
      insertMarker(marker, { type: "paste", marker, text })
    },
    syncImageMarkers(images) {
      const unmatched = imageMarkers(input, markerTypeId).slice()
      const missing: ImageContent[] = []
      for (const image of images) {
        const index = unmatched.findIndex(candidate => candidate === image)
        if (index === -1) missing.push(image)
        else unmatched.splice(index, 1)
      }
      for (const image of missing) {
        const before = displaySlice(input.plainText, 0, input.cursorOffset)
        const prefix = before.length > 0 && !/\s$/.test(before) ? " " : ""
        const marker = `${prefix}[image #${++nextImageId}] `
        insertMarker(marker, { type: "image", marker, image })
      }
    },
    activeImages() {
      return imageMarkers(input, markerTypeId)
    },
    expandedText() {
      return expandMarkerRanges(input.plainText, composerMarkers(input, markerTypeId))
    },
    replaceText(text, cursorOffset = promptOffsetWidth(text)) {
      suppressContentChange = true
      markerRevision++
      nextPasteId = 0
      nextImageId = 0
      try {
        input.setText(text)
        input.cursorOffset = cursorOffset
      } finally {
        suppressContentChange = false
      }
      options.onContentChange?.()
    },
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
  const available = geometry.columns - 4 - textWidth(slots.topLeft) - (slots.topLeft ? 1 : 0)
  let topRightText = ""
  let topRightWidth = 0
  for (const item of slots.topRight) {
    const itemWidth = textWidth(item)
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

const graphemes = new Intl.Segmenter(undefined, { granularity: "grapheme" })

function promptOffsetWidth(value: string): number {
  let width = 0
  for (const part of graphemes.segment(value)) width += part.segment === "\n" ? 1 : textWidth(part.segment)
  return width
}

function displayOffsetIndex(value: string, offset: number): number {
  if (offset <= 0) return 0
  let width = 0
  for (const part of graphemes.segment(value)) {
    const next = width + promptOffsetWidth(part.segment)
    if (next > offset) return part.index
    width = next
  }
  return value.length
}

function displaySlice(value: string, start = 0, end = promptOffsetWidth(value)): string {
  return value.slice(displayOffsetIndex(value, start), displayOffsetIndex(value, end))
}

function composerMarkers(
  input: TextareaRenderable,
  markerTypeId: number
): Array<Extmark & { data: ComposerMarkerData }> {
  // OpenTUI 0.4.5 restores extmarks on undo without rebuilding its type index.
  return input.extmarks
    .getAll()
    .filter(extmark => extmark.typeId === markerTypeId)
    .filter((extmark): extmark is Extmark & { data: ComposerMarkerData } => isComposerMarkerData(extmark.data))
    .toSorted((left, right) => left.start - right.start)
}

function imageMarkers(input: TextareaRenderable, markerTypeId: number): ImageContent[] {
  return composerMarkers(input, markerTypeId).flatMap(marker =>
    marker.data.type === "image" ? [marker.data.image] : []
  )
}

function expandMarkerRanges(text: string, markers: readonly (Extmark & { data: ComposerMarkerData })[]): string {
  return markers
    .toSorted((left, right) => right.start - left.start)
    .reduce(
      (expanded, marker) =>
        displaySlice(expanded, 0, marker.start) +
        (marker.data.type === "paste" ? marker.data.text : "") +
        displaySlice(expanded, marker.end),
      text
    )
}

function isComposerMarkerData(value: unknown): value is ComposerMarkerData {
  if (typeof value !== "object" || value === null || !("type" in value) || !("marker" in value)) return false
  if (typeof value.marker !== "string") return false
  if (value.type === "paste") return "text" in value && typeof value.text === "string"
  if (value.type !== "image" || !("image" in value)) return false
  const image = value.image
  return (
    typeof image === "object" &&
    image !== null &&
    "type" in image &&
    image.type === "image" &&
    "data" in image &&
    typeof image.data === "string" &&
    "mimeType" in image &&
    typeof image.mimeType === "string"
  )
}
