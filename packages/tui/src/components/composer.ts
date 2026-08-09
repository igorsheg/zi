import {
  BoxRenderable,
  RGBA,
  TextareaRenderable,
  type Extmark,
  type OptimizedBuffer,
  type PasteEvent,
  type RenderContext
} from "@opentui/core"
import { maxSessionPromptHistoryEntries, type ImageContent } from "@with-zi/coding-agent"

import type { Theme } from "../theme.js"
import { promptTextSlice, promptTextWidth, textWidth } from "./cell-text.js"
import { createComposerHistoryReplacement } from "./composer-history-replacement.js"
import {
  replaceComposerRange,
  type ComposerRangeEdit,
  type ComposerRangeReplacementResult
} from "./composer-range-replacement.js"

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

export interface ComposerHistoryEntry {
  readonly entryId: string
  readonly text: string
}

export interface ComposerHistorySource {
  latest(): ComposerHistoryEntry | undefined
  older(entryId: string): ComposerHistoryEntry | undefined
}

export type ComposerHistoryResult = "native_fallthrough" | "cursor_boundary" | "history_changed" | "history_boundary"

export interface ComposerOptions {
  readonly geometry: ComposerGeometry
  readonly slots: ComposerSlots
  readonly theme: Theme
  readonly historySource?: ComposerHistorySource
  readonly onSubmit: () => void
  readonly onContentChange?: () => void
  readonly onCursorChange?: () => void
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
  historyPrevious(): ComposerHistoryResult
  historyNext(): ComposerHistoryResult
  replaceText(text: string, cursorOffset?: number): void
  replaceRange(edit: ComposerRangeEdit): ComposerRangeReplacementResult
  update(geometry: ComposerGeometry, slots: ComposerSlots): number
  destroy(): void
}

interface RailLayout {
  readonly topRightText: string
  readonly topRightWidth: number
}

type ComposerMarkerData =
  | { readonly type: "paste"; readonly marker: string; readonly text: string }
  | { readonly type: "image"; readonly marker: string; readonly image: ImageContent }

type ComposerHistoryState =
  | { readonly type: "idle" }
  | {
      readonly type: "browsing"
      readonly olderEntryIds: readonly string[]
      readonly currentEntryId: string
      readonly newerEntryIds: readonly string[]
    }

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
  let historyState: ComposerHistoryState = { type: "idle" }
  let markerTypeId = 0
  let nextPasteId = 0
  let nextImageId = 0
  let markerRevision = 0
  let input!: TextareaRenderable

  const reportContentChange = (detachHistory = true) => {
    if (detachHistory) historyState = { type: "idle" }
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
    cursorStyle: { style: "block", blinking: false },
    backgroundColor: options.theme.surface.composer,
    focusedBackgroundColor: options.theme.surface.composer,
    ...(options.onPaste ? { onPaste: options.onPaste } : {}),
    ...(options.onCursorChange ? { onCursorChange: options.onCursorChange } : {}),
    keyBindings: [
      { name: "return", action: "submit" },
      { name: "return", shift: true, action: "newline" }
    ],
    onSubmit: options.onSubmit
  })
  markerTypeId = input.extmarks.registerType("zi-composer-marker")
  const historyReplacement = createComposerHistoryReplacement(input)
  const detachHistory = () => {
    if (historyState.type === "browsing") historyReplacement.abandonBrowse()
    historyState = { type: "idle" }
  }
  const nativeGetSelectedText = input.getSelectedText.bind(input)
  const nativeInsertChar = input.insertChar.bind(input)
  const nativeInsertText = input.insertText.bind(input)
  const nativeDeleteChar = input.deleteChar.bind(input)
  const nativeDeleteCharBackward = input.deleteCharBackward.bind(input)
  const nativeDeleteLine = input.deleteLine.bind(input)
  const nativeDeleteToLineEnd = input.deleteToLineEnd.bind(input)
  const nativeDeleteToLineStart = input.deleteToLineStart.bind(input)
  const nativeDeleteWordForward = input.deleteWordForward.bind(input)
  const nativeDeleteWordBackward = input.deleteWordBackward.bind(input)
  const nativeNewLine = input.newLine.bind(input)
  const nativeDeleteRange = input.deleteRange.bind(input)
  const nativeDeleteSelection = input.deleteSelection.bind(input)
  const nativeClear = input.clear.bind(input)
  const nativeSetText = input.setText.bind(input)
  const nativeReplaceText = input.replaceText.bind(input)
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
  // Native change events are deferred. Wrapping mutations keeps browse detachment and one coherent report synchronous.
  const applyNativeContentMutation = <Result>(mutation: () => Result, clearsRedo = true): Result => {
    detachHistory()
    const beforeText = input.plainText
    const beforeMarkers = composerMarkers(input, markerTypeId)
    const result = mutation()
    const changed = beforeText !== input.plainText || !sameMarkers(beforeMarkers, composerMarkers(input, markerTypeId))
    if (changed) {
      if (clearsRedo) historyReplacement.releaseCompletedBrowse()
      reportContentChange()
    }
    return result
  }

  input.insertChar = char => applyNativeContentMutation(() => nativeInsertChar(char))
  input.insertText = text => applyNativeContentMutation(() => nativeInsertText(text))
  input.deleteChar = () => applyNativeContentMutation(() => nativeDeleteChar())
  input.deleteCharBackward = () => applyNativeContentMutation(() => nativeDeleteCharBackward())
  input.deleteLine = () => applyNativeContentMutation(() => nativeDeleteLine())
  input.deleteToLineEnd = () => applyNativeContentMutation(() => nativeDeleteToLineEnd())
  input.deleteToLineStart = () => applyNativeContentMutation(() => nativeDeleteToLineStart())
  input.deleteWordForward = () => applyNativeContentMutation(() => nativeDeleteWordForward())
  input.deleteWordBackward = () => applyNativeContentMutation(() => nativeDeleteWordBackward())
  input.newLine = () => applyNativeContentMutation(() => nativeNewLine())
  input.deleteRange = (startLine, startCol, endLine, endCol) =>
    applyNativeContentMutation(() => nativeDeleteRange(startLine, startCol, endLine, endCol))
  input.deleteSelection = () => applyNativeContentMutation(() => nativeDeleteSelection())
  input.clear = () => applyNativeContentMutation(() => nativeClear())
  input.setText = text => {
    applyNativeContentMutation(() => nativeSetText(text))
    historyReplacement.reset()
  }
  input.replaceText = text => applyNativeContentMutation(() => nativeReplaceText(text))
  input.undo = () => {
    historyReplacement.pinCompletedBrowse()
    return applyNativeContentMutation(() => nativeUndo(), false)
  }
  input.redo = () => {
    historyReplacement.pinCompletedBrowse()
    return applyNativeContentMutation(() => nativeRedo(), false)
  }
  root.add(input)

  const applyHistoryEffect = (
    previousState: ComposerHistoryState,
    effect: () => void,
    cursor: "start" | "end" | "restore",
    commit?: () => void
  ) => {
    try {
      effect()
      if (cursor === "start") input.cursorOffset = 0
      else if (cursor === "end") input.cursorOffset = promptTextWidth(input.plainText)
    } catch (cause) {
      historyState = previousState
      throw cause
    }
    commit?.()
    reportContentChange(false)
  }

  const olderHistory = (): ComposerHistoryResult => {
    const state = historyState
    if (state.type === "idle") {
      const latest = options.historySource?.latest()
      if (!latest) return "history_boundary"
      historyState = { type: "browsing", olderEntryIds: [], currentEntryId: latest.entryId, newerEntryIds: [] }
      applyHistoryEffect(state, () => historyReplacement.begin(latest, nativeReplaceText), "start")
      return "history_changed"
    }

    const visited = state.olderEntryIds[0]
    if (visited) {
      historyState = {
        type: "browsing",
        olderEntryIds: state.olderEntryIds.slice(1),
        currentEntryId: visited,
        newerEntryIds: [state.currentEntryId, ...state.newerEntryIds]
      }
      applyHistoryEffect(state, () => nativeRedo(), "start")
      return "history_changed"
    }

    const visitedCount = state.newerEntryIds.length + 1
    if (visitedCount >= maxSessionPromptHistoryEntries) return "history_boundary"
    const older = options.historySource?.older(state.currentEntryId)
    if (!older) return "history_boundary"
    historyState = {
      type: "browsing",
      olderEntryIds: [],
      currentEntryId: older.entryId,
      newerEntryIds: [state.currentEntryId, ...state.newerEntryIds]
    }
    applyHistoryEffect(state, () => historyReplacement.replace(older, nativeReplaceText), "start")
    return "history_changed"
  }

  const newerHistory = (): ComposerHistoryResult => {
    const state = historyState
    if (state.type === "idle") return "history_boundary"

    const visited = state.newerEntryIds[0]
    if (visited) {
      historyState = {
        type: "browsing",
        olderEntryIds: [state.currentEntryId, ...state.olderEntryIds],
        currentEntryId: visited,
        newerEntryIds: state.newerEntryIds.slice(1)
      }
      applyHistoryEffect(state, () => nativeUndo(), "end")
      return "history_changed"
    }

    historyState = { type: "idle" }
    applyHistoryEffect(
      state,
      () => nativeUndo(),
      "restore",
      () => historyReplacement.restoreDraft()
    )
    return "history_changed"
  }

  const insertMarker = (marker: string, data: ComposerMarkerData) => {
    detachHistory()
    const start = input.cursorOffset
    nativeInsertText(marker)
    input.extmarks.create({ start, end: start + promptTextWidth(marker), virtual: true, typeId: markerTypeId, data })
    historyReplacement.releaseCompletedBrowse()
    reportContentChange()
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
        const before = promptTextSlice(input.plainText, 0, input.cursorOffset)
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
    historyPrevious() {
      if (input.hasSelection()) return "native_fallthrough"
      const globalVisualRow = input.scrollY + input.visualCursor.visualRow
      if (historyState.type === "browsing" && globalVisualRow === 0) return olderHistory()
      if (historyState.type === "idle" && input.cursorOffset === 0) return olderHistory()
      if (globalVisualRow !== 0) return "native_fallthrough"
      input.cursorOffset = 0
      return "cursor_boundary"
    },
    historyNext() {
      if (input.hasSelection()) return "native_fallthrough"
      const endOffset = promptTextWidth(input.plainText)
      const globalVisualRow = input.scrollY + input.visualCursor.visualRow
      const finalVisualRow = Math.max(0, input.editorView.getTotalVirtualLineCount() - 1)
      if (historyState.type === "browsing" && globalVisualRow === finalVisualRow) return newerHistory()
      if (historyState.type === "idle" && input.cursorOffset === endOffset) return newerHistory()
      if (globalVisualRow !== finalVisualRow) return "native_fallthrough"
      input.cursorOffset = endOffset
      return "cursor_boundary"
    },
    replaceText(text, cursorOffset = promptTextWidth(text)) {
      historyState = { type: "idle" }
      markerRevision++
      nextPasteId = 0
      nextImageId = 0
      nativeSetText(text)
      historyReplacement.reset()
      input.cursorOffset = cursorOffset
      reportContentChange()
    },
    replaceRange(edit) {
      const result = replaceComposerRange(input, markerTypeId, edit)
      if (result === "unavailable") return result
      detachHistory()
      historyReplacement.releaseCompletedBrowse()
      reportContentChange()
      return result
    },
    update(nextGeometry, nextSlots) {
      const geometryChanged = !sameGeometry(geometry, nextGeometry)
      const slotsChanged = !sameSlots(slots, nextSlots)
      if (!geometryChanged && !slotsChanged) return occupiedRows(input, geometry)
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
      return occupiedRows(input, geometry)
    },
    destroy() {
      historyState = { type: "idle" }
      historyReplacement.destroy()
      root.destroyRecursively()
    }
  }
}

const railItemSeparator = " • "

function occupiedRows(input: TextareaRenderable, geometry: ComposerGeometry): number {
  const borderRows = geometry.bordered ? 2 : 0
  const editorColumns = Math.max(1, geometry.columns - (geometry.bordered ? 2 : 0))
  const measured = input.editorView.measureForDimensions(editorColumns, geometry.editorRows)
  const editorRows = Math.max(1, Math.min(geometry.editorRows, measured?.lineCount ?? input.lineCount))
  return editorRows + borderRows
}

function layoutRail(geometry: ComposerGeometry, slots: ComposerSlots): RailLayout {
  if (!geometry.bordered || slots.topRight.length === 0) return { topRightText: "", topRightWidth: 0 }
  const available = geometry.columns - 4 - textWidth(slots.topLeft) - (slots.topLeft ? 1 : 0)
  const separatorWidth = textWidth(railItemSeparator)
  const visibleItems: string[] = []
  let topRightWidth = 0
  for (const item of slots.topRight) {
    const nextWidth = topRightWidth + (visibleItems.length === 0 ? 0 : separatorWidth) + textWidth(item)
    if (nextWidth > available) break
    visibleItems.push(item)
    topRightWidth = nextWidth
  }
  return { topRightText: visibleItems.join(railItemSeparator), topRightWidth }
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

function sameMarkers(
  left: readonly (Extmark & { data: ComposerMarkerData })[],
  right: readonly (Extmark & { data: ComposerMarkerData })[]
): boolean {
  return (
    left.length === right.length &&
    left.every((marker, index) => {
      const other = right[index]
      return (
        other !== undefined &&
        marker.id === other.id &&
        marker.start === other.start &&
        marker.end === other.end &&
        marker.data === other.data
      )
    })
  )
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
        promptTextSlice(expanded, 0, marker.start) +
        (marker.data.type === "paste" ? marker.data.text : "") +
        promptTextSlice(expanded, marker.end),
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
