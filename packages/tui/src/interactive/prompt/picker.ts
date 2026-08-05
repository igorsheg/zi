import { atom, type ReadableAtom } from "nanostores"

import { maxPickerListRows, type PickerRow } from "../../components/picker-list.js"
import { fuzzyMatch } from "../fuzzy-match.js"
import type { PickerWorkflow } from "./state.js"

export const maxPickerDepth = 8
export const maxPickerRows = 2048
export const maxSuspendedFilterLength = 8192

export interface PickerStackRow extends PickerRow {
  readonly searchText: string
}

export interface PickerFrame {
  readonly id: string
  readonly title: string
  readonly rows: readonly PickerStackRow[]
  readonly filter: "none" | "fuzzy"
  /** Preferred total rows, including title, hint, or footer chrome. */
  readonly height?: number
  /** Retain rows and selection for presentation without admitting interaction. */
  readonly disabled?: boolean
  readonly selectedId?: string
  readonly hint?: string
  /** Hints are informational by default; genuine cautions opt into "warning". */
  readonly hintTone?: "warning"
  readonly emptyText?: string
  readonly footer?: string
}

export interface PickerStackFrameState extends PickerFrame {
  readonly selectedIndex: number
  /** The choosing workflow this frame admits; activation dispatches on it. */
  readonly workflow?: PickerWorkflow
  /** The last query admitted through queryChanged; selection resets when it changes. */
  readonly query: string
  readonly parentFilter?: string
}

type NonEmptyPickerFrames = readonly [PickerStackFrameState, ...PickerStackFrameState[]]

export type PickerStackState =
  | { readonly type: "closed" }
  | { readonly type: "open"; readonly frames: NonEmptyPickerFrames }

export interface PickerPresentation {
  readonly depth: number
  readonly frame: PickerFrame
  readonly rows: readonly PickerStackRow[]
  readonly selectedId?: string
  readonly workflow?: PickerWorkflow
}

export type PickerBack =
  | { readonly type: "closed" }
  | { readonly type: "revealed"; readonly filter: string; readonly workflow?: PickerWorkflow }

export interface PickerStack {
  readonly $state: ReadableAtom<PickerStackState>
  open(frame: PickerFrame, workflow?: PickerWorkflow): void
  push(frame: PickerFrame, parentFilter: string, workflow?: PickerWorkflow): void
  replaceTop(frame: PickerFrame, filter: string, workflow?: PickerWorkflow): void
  queryChanged(filter: string): void
  move(filter: string, direction: -1 | 1): void
  presentation(filter: string): PickerPresentation | undefined
  back(): PickerBack
  close(): void
  dispose(): void
}

export function createPickerStack(): PickerStack {
  const $state = atom<PickerStackState>({ type: "closed" })
  let disposed = false

  const current = (): PickerStackState => {
    if (disposed) throw new Error("PickerStack is disposed")
    return $state.get()
  }

  const updateTop = (update: (frame: PickerStackFrameState) => PickerStackFrameState) => {
    const state = current()
    if (state.type === "closed") return
    const [first, ...rest] = state.frames
    const frames: [PickerStackFrameState, ...PickerStackFrameState[]] = [first, ...rest]
    frames[frames.length - 1] = update(frames.at(-1)!)
    $state.set({ type: "open", frames })
  }

  const presentation = (filter: string): PickerPresentation | undefined => {
    const state = current()
    if (state.type === "closed") return undefined
    const frame = state.frames.at(-1)
    if (!frame) return undefined
    const rows = filteredRows(frame, filter)
    const selected = rows[Math.min(frame.selectedIndex, Math.max(0, rows.length - 1))]
    return {
      depth: state.frames.length,
      frame: pickerFrame(frame),
      rows,
      ...(selected ? { selectedId: selected.id } : {}),
      ...(frame.workflow ? { workflow: frame.workflow } : {})
    }
  }

  const pushFrame = (frame: PickerFrame, parentFilter: string, workflow?: PickerWorkflow): void => {
    const state = current()
    if (state.type === "closed") throw new Error("Cannot push a picker frame onto a closed stack")
    if (state.frames.length === maxPickerDepth) {
      throw new Error(`Picker stack cannot exceed ${maxPickerDepth} frames`)
    }
    if (parentFilter.length > maxSuspendedFilterLength) {
      throw new Error(`Suspended picker filters cannot exceed ${maxSuspendedFilterLength} characters`)
    }
    validateFrame(frame)
    // The suspended parent keeps the query it will be revealed with.
    const [first, ...rest] = state.frames
    const parent = { ...(rest.at(-1) ?? first), query: parentFilter }
    const child = activate(frame, "", parentFilter, workflow)
    const frames: NonEmptyPickerFrames =
      rest.length === 0 ? [parent, child] : [first, ...rest.slice(0, -1), parent, child]
    $state.set({ type: "open", frames })
  }

  const replaceFrame = (frame: PickerFrame, filter: string, workflow?: PickerWorkflow): void => {
    current()
    validateFrame(frame)
    updateTop(currentFrame => activate(frame, filter, currentFrame.parentFilter, workflow))
  }

  const goBack = (): PickerBack => {
    const state = current()
    if (state.type === "closed") return { type: "closed" }
    const top = state.frames.at(-1)!
    if (state.frames.length === 1) {
      $state.set({ type: "closed" })
      return { type: "closed" }
    }
    const remaining = state.frames.slice(0, -1)
    $state.set({ type: "open", frames: [remaining[0]!, ...remaining.slice(1)] })
    const revealed = remaining.at(-1)!
    return {
      type: "revealed",
      filter: top.parentFilter ?? "",
      ...(revealed.workflow ? { workflow: revealed.workflow } : {})
    }
  }

  return {
    $state,
    open(frame, workflow) {
      current()
      validateFrame(frame)
      $state.set({ type: "open", frames: [activate(frame, "", undefined, workflow)] })
    },
    push: pushFrame,
    replaceTop(frame, filter, workflow) {
      const state = current()
      if (state.type === "closed") throw new Error("Cannot replace a picker frame on a closed stack")
      replaceFrame(frame, filter, workflow)
    },
    queryChanged(filter) {
      updateTop(frame => {
        // A changed query re-ranks rows, so the selection returns to the best
        // match; an unchanged one only clamps after row replacement. Frames
        // without filtering never move the selection under the user's cursor.
        const reset = frame.query !== filter && frame.filter !== "none"
        const rows = filteredRows(frame, filter)
        const selectedIndex = reset ? 0 : Math.min(frame.selectedIndex, Math.max(0, rows.length - 1))
        if (!reset && selectedIndex === frame.selectedIndex) return frame
        return { ...frame, query: filter, selectedIndex }
      })
    },
    move(filter, direction) {
      updateTop(frame => {
        if (frame.disabled) return frame
        const rows = filteredRows(frame, filter)
        if (rows.length === 0) return frame
        let selectedIndex = frame.selectedIndex + direction
        if (selectedIndex < 0) selectedIndex = rows.length - 1
        else if (selectedIndex >= rows.length) selectedIndex = 0
        return { ...frame, selectedIndex }
      })
    },
    presentation,
    back: goBack,
    close() {
      current()
      $state.set({ type: "closed" })
    },
    dispose() {
      if (disposed) return
      disposed = true
      $state.set({ type: "closed" })
    }
  }
}

function validateFrame(frame: PickerFrame): void {
  if (
    frame.height !== undefined &&
    (!Number.isInteger(frame.height) || frame.height < 1 || frame.height > maxPickerListRows)
  ) {
    throw new Error(`Picker frame height must be between 1 and ${maxPickerListRows}`)
  }
  if (frame.rows.length > maxPickerRows) {
    throw new Error(`Picker frames cannot exceed ${maxPickerRows} rows`)
  }
  const ids = new Set<string>()
  for (const row of frame.rows) {
    if (ids.has(row.id)) throw new Error(`Picker row IDs must be unique: ${row.id}`)
    ids.add(row.id)
  }
  if (frame.selectedId && !ids.has(frame.selectedId)) {
    throw new Error(`Picker selection is not present in frame: ${frame.selectedId}`)
  }
}

function pickerFrame(frame: PickerStackFrameState): PickerFrame {
  return {
    id: frame.id,
    title: frame.title,
    rows: frame.rows,
    filter: frame.filter,
    ...(frame.height === undefined ? {} : { height: frame.height }),
    ...(frame.disabled ? { disabled: true } : {}),
    ...(frame.selectedId ? { selectedId: frame.selectedId } : {}),
    ...(frame.hint ? { hint: frame.hint } : {}),
    ...(frame.hintTone ? { hintTone: frame.hintTone } : {}),
    ...(frame.emptyText ? { emptyText: frame.emptyText } : {}),
    ...(frame.footer ? { footer: frame.footer } : {})
  }
}

function activate(
  frame: PickerFrame,
  filter: string,
  parentFilter?: string,
  workflow?: PickerWorkflow
): PickerStackFrameState {
  const rows = filteredRows(frame, filter)
  const selectedIndex = frame.selectedId ? rows.findIndex(row => row.id === frame.selectedId) : 0
  return {
    ...frame,
    query: filter,
    selectedIndex: selectedIndex < 0 ? 0 : selectedIndex,
    ...(parentFilter === undefined ? {} : { parentFilter }),
    ...(workflow ? { workflow } : {})
  }
}

function filteredRows(frame: PickerFrame, query: string): readonly PickerStackRow[] {
  if (frame.filter === "none" || !query.trim()) return frame.rows
  const tokens = query
    .trim()
    .split(/[\s/]+/)
    .filter(token => token.length > 0)
  return frame.rows
    .map((row, index) => {
      let score = 0
      for (const token of tokens) {
        const match = fuzzyMatch(token, row.searchText)
        if (!match.matches) return undefined
        score += match.score
      }
      return { row, index, score }
    })
    .filter(result => result !== undefined)
    .toSorted((left, right) => left.score - right.score || left.index - right.index)
    .map(result => result.row)
}
