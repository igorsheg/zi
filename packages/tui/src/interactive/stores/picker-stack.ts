import { atom, type ReadableAtom } from "nanostores"

import type { PickerRow } from "../../components/picker-list.js"

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
  readonly selectedId?: string
  readonly hint?: string
  readonly emptyText?: string
  readonly footer?: string
}

export interface PickerStackFrameState extends PickerFrame {
  readonly selectedIndex: number
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
}

export type PickerBack = { readonly type: "closed" } | { readonly type: "revealed"; readonly filter: string }

export type PickerResolution =
  | { readonly type: "stay" }
  | { readonly type: "close"; readonly text?: string }
  | { readonly type: "back" }
  | { readonly type: "push"; readonly frame: PickerFrame; readonly parentFilter: string; readonly text?: string }
  | { readonly type: "replace"; readonly frame: PickerFrame; readonly filter: string }

export type PickerResolutionEffect =
  | { readonly type: "unchanged" }
  | { readonly type: "replace_input"; readonly text: string }

export interface PickerStack {
  readonly $state: ReadableAtom<PickerStackState>
  open(frame: PickerFrame): void
  push(frame: PickerFrame, parentFilter: string): void
  replaceTop(frame: PickerFrame, filter: string): void
  queryChanged(filter: string): void
  move(filter: string, direction: -1 | 1): void
  selected(filter: string): PickerStackRow | undefined
  presentation(filter: string): PickerPresentation | undefined
  /** Apply the stack/composer effect chosen by a callsite after its domain action succeeds. */
  resolve(resolution: PickerResolution): PickerResolutionEffect
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
      ...(selected ? { selectedId: selected.id } : {})
    }
  }

  const pushFrame = (frame: PickerFrame, parentFilter: string): void => {
    const state = current()
    if (state.type === "closed") throw new Error("Cannot push a picker frame onto a closed stack")
    if (state.frames.length === maxPickerDepth) {
      throw new Error(`Picker stack cannot exceed ${maxPickerDepth} frames`)
    }
    if (parentFilter.length > maxSuspendedFilterLength) {
      throw new Error(`Suspended picker filters cannot exceed ${maxSuspendedFilterLength} characters`)
    }
    validateFrame(frame)
    $state.set({ type: "open", frames: [...state.frames, activate(frame, parentFilter)] })
  }

  const replaceFrame = (frame: PickerFrame, filter: string): void => {
    current()
    validateFrame(frame)
    updateTop(currentFrame => activate(frame, currentFrame.parentFilter, filter))
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
    return { type: "revealed", filter: top.parentFilter ?? "" }
  }

  return {
    $state,
    open(frame) {
      current()
      validateFrame(frame)
      $state.set({ type: "open", frames: [activate(frame)] })
    },
    push: pushFrame,
    replaceTop(frame, filter) {
      const state = current()
      if (state.type === "closed") throw new Error("Cannot replace a picker frame on a closed stack")
      replaceFrame(frame, filter)
    },
    queryChanged(filter) {
      updateTop(frame => {
        const rows = filteredRows(frame, filter)
        const selectedIndex = Math.min(frame.selectedIndex, Math.max(0, rows.length - 1))
        return selectedIndex === frame.selectedIndex ? frame : { ...frame, selectedIndex }
      })
    },
    move(filter, direction) {
      updateTop(frame => {
        const rows = filteredRows(frame, filter)
        if (rows.length === 0) return frame
        let selectedIndex = frame.selectedIndex + direction
        if (selectedIndex < 0) selectedIndex = rows.length - 1
        else if (selectedIndex >= rows.length) selectedIndex = 0
        return { ...frame, selectedIndex }
      })
    },
    selected(filter) {
      const currentPresentation = presentation(filter)
      if (!currentPresentation) return undefined
      return currentPresentation.rows.find(row => row.id === currentPresentation.selectedId)
    },
    presentation,
    resolve(resolution) {
      switch (resolution.type) {
        case "stay":
          current()
          return { type: "unchanged" }
        case "close":
          current()
          $state.set({ type: "closed" })
          return { type: "replace_input", text: resolution.text ?? "" }
        case "back": {
          const result = goBack()
          return { type: "replace_input", text: result.type === "revealed" ? result.filter : "" }
        }
        case "push":
          pushFrame(resolution.frame, resolution.parentFilter)
          return { type: "replace_input", text: resolution.text ?? "" }
        case "replace":
          replaceFrame(resolution.frame, resolution.filter)
          return { type: "replace_input", text: resolution.filter }
        default:
          return assertNever(resolution)
      }
    },
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
    ...(frame.selectedId ? { selectedId: frame.selectedId } : {}),
    ...(frame.hint ? { hint: frame.hint } : {}),
    ...(frame.emptyText ? { emptyText: frame.emptyText } : {}),
    ...(frame.footer ? { footer: frame.footer } : {})
  }
}

function activate(frame: PickerFrame, parentFilter?: string, filter = ""): PickerStackFrameState {
  const rows = filteredRows(frame, filter)
  const selectedIndex = frame.selectedId ? rows.findIndex(row => row.id === frame.selectedId) : 0
  return {
    ...frame,
    selectedIndex: selectedIndex < 0 ? 0 : selectedIndex,
    ...(parentFilter === undefined ? {} : { parentFilter })
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

// Ported from pi-tui fuzzy matching at the repository pin in docs/reference-pins.md.
function assertNever(value: never): never {
  throw new Error(`Unexpected picker resolution: ${String(value)}`)
}

function fuzzyMatch(query: string, text: string): { matches: boolean; score: number } {
  const queryLower = query.toLowerCase()
  const textLower = text.toLowerCase()

  const matchQuery = (normalizedQuery: string): { matches: boolean; score: number } => {
    if (normalizedQuery.length === 0) return { matches: true, score: 0 }
    if (normalizedQuery.length > textLower.length) return { matches: false, score: 0 }

    let queryIndex = 0
    let score = 0
    let lastMatchIndex = -1
    let consecutiveMatches = 0

    for (let index = 0; index < textLower.length && queryIndex < normalizedQuery.length; index++) {
      if (textLower[index] !== normalizedQuery[queryIndex]) continue
      const wordBoundary = index === 0 || /[\s\-_./:]/.test(textLower[index - 1] ?? "")
      if (lastMatchIndex === index - 1) {
        consecutiveMatches++
        score -= consecutiveMatches * 5
      } else {
        consecutiveMatches = 0
        if (lastMatchIndex >= 0) score += (index - lastMatchIndex - 1) * 2
      }
      if (wordBoundary) score -= 10
      score += index * 0.1
      lastMatchIndex = index
      queryIndex++
    }

    if (queryIndex < normalizedQuery.length) return { matches: false, score: 0 }
    if (normalizedQuery === textLower) score -= 100
    return { matches: true, score }
  }

  const direct = matchQuery(queryLower)
  if (direct.matches) return direct

  const alphaNumeric = queryLower.match(/^(?<letters>[a-z]+)(?<digits>[0-9]+)$/)
  const numericAlpha = queryLower.match(/^(?<digits>[0-9]+)(?<letters>[a-z]+)$/)
  const swapped = alphaNumeric
    ? `${alphaNumeric.groups?.digits ?? ""}${alphaNumeric.groups?.letters ?? ""}`
    : numericAlpha
      ? `${numericAlpha.groups?.letters ?? ""}${numericAlpha.groups?.digits ?? ""}`
      : ""
  if (!swapped) return direct

  const match = matchQuery(swapped)
  return match.matches ? { matches: true, score: match.score + 5 } : direct
}
