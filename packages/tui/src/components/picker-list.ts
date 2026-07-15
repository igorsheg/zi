import { BoxRenderable, fg, StyledText, TextRenderable, type RenderContext } from "@opentui/core"

import { glyphs } from "../glyphs.js"
import type { Theme } from "../theme.js"

export interface PickerRow {
  readonly id: string
  readonly label: string
  readonly detail?: string
  readonly metadata?: string
}

export interface PickerListOptions {
  readonly rows: readonly PickerRow[]
  readonly selectedId?: string
  readonly height: number
  readonly emptyText?: string
  readonly theme: Theme
}

export interface PickerList {
  readonly root: BoxRenderable
  update(options: PickerListOptions): void
  destroy(): void
}

export function createPickerList(ctx: RenderContext, options: PickerListOptions): PickerList {
  const root = new BoxRenderable(ctx, {
    id: "picker-list",
    flexDirection: "column",
    alignItems: "stretch",
    alignSelf: "stretch",
    flexShrink: 0,
    height: options.height,
    overflow: "hidden",
    backgroundColor: options.theme.surface.composer
  })

  const update = (next: PickerListOptions) => {
    clear(root)
    root.height = next.height
    root.visible = next.height > 0
    if (next.height <= 0) return

    const visibleRows = pickerWindow(next.rows, next.selectedId, next.height)
    for (let index = 0; index < next.height; index++) {
      const row = visibleRows[index]
      const line = new BoxRenderable(ctx, {
        alignSelf: "stretch",
        height: 1,
        flexShrink: 0,
        backgroundColor: next.theme.surface.composer
      })
      line.add(
        new TextRenderable(ctx, {
          height: 1,
          wrapMode: "none",
          selectable: false,
          content: row
            ? rowContent(row, next.selectedId, next.theme)
            : next.rows.length === 0 && next.emptyText && index === 0
              ? new StyledText([fg(next.theme.text.muted)(`${glyphs.listUnselected}${next.emptyText}`)])
              : ""
        })
      )
      root.add(line)
    }
  }

  update(options)
  return {
    root,
    update,
    destroy() {
      root.destroyRecursively()
    }
  }
}

function rowContent(row: PickerRow, selectedId: string | undefined, theme: Theme): StyledText {
  const selected = row.id === selectedId
  return new StyledText([
    fg(selected ? theme.text.accent : theme.text.muted)(selected ? glyphs.listSelected : glyphs.listUnselected),
    fg(theme.text.primary)(row.label),
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

function clear(root: BoxRenderable): void {
  for (const child of root.getChildren()) {
    root.remove(child)
    child.destroyRecursively()
  }
}
