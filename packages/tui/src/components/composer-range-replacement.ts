import type { Extmark, TextareaRenderable } from "@opentui/core"
import { maxSessionPromptHistoryEntryBytes } from "@zi/coding-agent"

import { promptTextOffsetIsBoundary, promptTextSlice, promptTextWidth } from "./cell-text.js"

export interface ComposerRangeEdit {
  readonly startOffset: number
  readonly endOffset: number
  readonly replacement: string
  readonly cursorOffset: number
}

export type ComposerRangeReplacementResult = "applied" | "unavailable"

interface ExtmarksSnapshotOwner {
  saveSnapshot(): void
}

/** OpenTUI 0.4.5 adapter for one owned-memory native undo point with aligned extmark history. */
export function replaceComposerRange(
  input: TextareaRenderable,
  markerTypeId: number,
  edit: ComposerRangeEdit
): ComposerRangeReplacementResult {
  if (input.isDestroyed) return "unavailable"
  const text = input.plainText
  if (
    edit.startOffset > edit.endOffset ||
    !promptTextOffsetIsBoundary(text, edit.startOffset) ||
    !promptTextOffsetIsBoundary(text, edit.endOffset)
  ) {
    return "unavailable"
  }

  const markers = input.extmarks.getAll()
  if (markers.some(marker => marker.typeId !== markerTypeId)) throw incompatibleOpenTui()
  if (markers.some(marker => intersects(marker, edit.startOffset, edit.endOffset))) return "unavailable"

  const nextText = promptTextSlice(text, 0, edit.startOffset) + edit.replacement + promptTextSlice(text, edit.endOffset)
  if (
    Buffer.byteLength(nextText) > maxSessionPromptHistoryEntryBytes ||
    !promptTextOffsetIsBoundary(nextText, edit.cursorOffset)
  ) {
    return "unavailable"
  }

  const extmarks = snapshotOwner(input.extmarks)
  if (typeof input.editBuffer.replaceTextOwned !== "function") throw incompatibleOpenTui()
  const delta = promptTextWidth(edit.replacement) - (edit.endOffset - edit.startOffset)
  const shifted = markers.map(marker => {
    const shift = marker.start >= edit.endOffset ? delta : 0
    return { marker, start: marker.start + shift, end: marker.end + shift }
  })

  extmarks.saveSnapshot()
  input.clearSelection()
  input.editBuffer.replaceTextOwned(nextText)
  input.extmarks.clear()
  for (const shiftedMarker of shifted) {
    const { marker } = shiftedMarker
    input.extmarks.create({
      start: shiftedMarker.start,
      end: shiftedMarker.end,
      virtual: marker.virtual,
      typeId: marker.typeId,
      data: marker.data,
      ...(marker.styleId === undefined ? {} : { styleId: marker.styleId }),
      ...(marker.priority === undefined ? {} : { priority: marker.priority })
    })
  }
  input.cursorOffset = edit.cursorOffset
  return "applied"
}

function snapshotOwner(value: unknown): ExtmarksSnapshotOwner {
  if (typeof value !== "object" || value === null) throw incompatibleOpenTui()
  const saveSnapshot = Reflect.get(value, "saveSnapshot")
  const history = Reflect.get(value, "history")
  const originalReplaceText = Reflect.get(value, "originalReplaceText")
  if (typeof saveSnapshot !== "function" || typeof history !== "object" || typeof originalReplaceText !== "function") {
    throw incompatibleOpenTui()
  }
  return { saveSnapshot: () => Reflect.apply(saveSnapshot, value, []) }
}

function intersects(marker: Extmark, start: number, end: number): boolean {
  if (start === end) return marker.start < start && marker.end > start
  return marker.start < end && marker.end > start
}

function incompatibleOpenTui(): Error {
  return new Error("OpenTUI 0.4.5 Composer range-replacement adapter is incompatible with the installed runtime")
}
