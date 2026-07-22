import { BoxRenderable, fg, StyledText, TextRenderable, type RenderContext } from "@opentui/core"

import { glyphs } from "../glyphs.js"
import type { Theme } from "../theme.js"

export const maxPickerListRows = 10

export interface PickerRow {
  readonly id: string
  readonly label: string
  readonly detail?: string
  readonly metadata?: string
}

export interface PickerListOptions {
  readonly scope: string
  readonly rows: readonly PickerRow[]
  readonly selectedId?: string
  readonly disabled?: boolean
  readonly height: number
  readonly emptyText?: string
  readonly theme: Theme
}

export interface PickerList {
  readonly root: BoxRenderable
  update(options: PickerListOptions): void
  destroy(): void
}

interface PickerRowView {
  readonly root: BoxRenderable
  readonly text: TextRenderable
  row: PickerRow | undefined
  selected: boolean
  disabled: boolean
  theme: Theme
}

export function createPickerList(ctx: RenderContext, options: PickerListOptions): PickerList {
  const root = new BoxRenderable(ctx, {
    id: "picker-list",
    flexDirection: "column",
    alignItems: "stretch",
    alignSelf: "stretch",
    flexShrink: 0,
    height: Math.min(maxPickerListRows, Math.max(0, options.height)),
    overflow: "hidden",
    backgroundColor: options.theme.surface.composer
  })
  const rowsById = new Map<string, PickerRowView>()
  let emptyView: PickerRowView | undefined
  let scope = options.scope
  let height = -1
  let visible = true

  const createRow = (theme: Theme): PickerRowView => {
    const row = new BoxRenderable(ctx, {
      alignSelf: "stretch",
      height: 1,
      flexShrink: 0,
      backgroundColor: theme.surface.composer
    })
    const text = new TextRenderable(ctx, { height: 1, wrapMode: "none", selectable: false })
    row.add(text)
    return { root: row, text, row: undefined, selected: false, disabled: false, theme }
  }

  const updateRow = (view: PickerRowView, row: PickerRow, selected: boolean, disabled: boolean, theme: Theme): void => {
    const changed =
      view.row?.label !== row.label ||
      view.row?.detail !== row.detail ||
      view.row?.metadata !== row.metadata ||
      view.selected !== selected ||
      view.disabled !== disabled ||
      view.theme !== theme
    if (!changed) return
    view.row = row
    view.selected = selected
    view.disabled = disabled
    view.theme = theme
    view.root.backgroundColor = theme.surface.composer
    view.text.content = rowContent(row, selected, disabled, theme)
  }

  const update = (next: PickerListOptions) => {
    if (scope !== next.scope) {
      removeRows(root, rowsById)
      removeEmpty(root, emptyView)
      emptyView = undefined
      scope = next.scope
    }

    const nextHeight = Math.min(maxPickerListRows, Math.max(0, next.height))
    if (height !== nextHeight) {
      height = nextHeight
      root.height = nextHeight
    }
    const nextVisible = nextHeight > 0
    if (visible !== nextVisible) {
      visible = nextVisible
      root.visible = nextVisible
    }
    if (!nextVisible) {
      removeRows(root, rowsById)
      removeEmpty(root, emptyView)
      emptyView = undefined
      return
    }

    const window = pickerWindow(next.rows, next.selectedId, nextHeight)
    const visibleIds = new Set(window.map(row => row.id))
    for (const [id, view] of rowsById) {
      if (visibleIds.has(id)) continue
      root.remove(view.root)
      view.root.destroyRecursively()
      rowsById.delete(id)
    }

    if (window.length > 0) {
      removeEmpty(root, emptyView)
      emptyView = undefined
      for (const row of window) {
        const view = rowsById.get(row.id) ?? createRow(next.theme)
        rowsById.set(row.id, view)
        updateRow(view, row, row.id === next.selectedId, next.disabled ?? false, next.theme)
      }
      orderRows(
        root,
        window.map(row => rowsById.get(row.id)!.root)
      )
      return
    }

    removeRows(root, rowsById)
    if (!next.emptyText) {
      removeEmpty(root, emptyView)
      emptyView = undefined
      return
    }
    emptyView ??= createRow(next.theme)
    updateRow(emptyView, { id: "", label: next.emptyText }, false, next.disabled ?? false, next.theme)
    if (root.getChildren()[0] !== emptyView.root) root.insertBefore(emptyView.root, root.getChildren()[0])
  }

  update(options)
  return {
    root,
    update,
    destroy() {
      rowsById.clear()
      emptyView = undefined
      root.destroyRecursively()
    }
  }
}

function rowContent(row: PickerRow, selected: boolean, disabled: boolean, theme: Theme): StyledText {
  const active = selected && !disabled
  return new StyledText([
    fg(active ? theme.text.accent : theme.text.muted)(active ? glyphs.listSelected : glyphs.listUnselected),
    fg(disabled ? theme.text.muted : theme.text.primary)(row.label),
    ...(row.detail ? [fg(theme.text.muted)(`  ${row.detail}`)] : []),
    ...(row.metadata ? [fg(theme.text.muted)(`  ${row.metadata}`)] : [])
  ])
}

function pickerWindow(
  rows: readonly PickerRow[],
  selectedId: string | undefined,
  height: number
): readonly PickerRow[] {
  const selectedIndex = rows.findIndex(row => row.id === selectedId)
  const offset = Math.max(0, Math.min(selectedIndex - Math.floor(height / 2), rows.length - height))
  return rows.slice(offset, offset + height)
}

function orderRows(root: BoxRenderable, rows: readonly BoxRenderable[]): void {
  for (let index = 0; index < rows.length; index++) {
    const row = rows[index]!
    const current = root.getChildren()[index]
    if (current !== row) root.insertBefore(row, current)
  }
}

function removeRows(root: BoxRenderable, rows: Map<string, PickerRowView>): void {
  for (const view of rows.values()) {
    root.remove(view.root)
    view.root.destroyRecursively()
  }
  rows.clear()
}

function removeEmpty(root: BoxRenderable, view: PickerRowView | undefined): void {
  if (!view || !root.getChildren().includes(view.root)) return
  root.remove(view.root)
  view.root.destroyRecursively()
}
