import { BoxRenderable, TextareaRenderable, type RenderContext } from "@opentui/core"

import type { Theme } from "../theme.js"

export interface ComposerGeometry {
  readonly bordered: boolean
  readonly editorRows: number
  readonly protectedRows: number
}

export interface ComposerOptions {
  readonly geometry: ComposerGeometry
  readonly title: string
  readonly bottomTitle: string
  readonly theme: Theme
  readonly onSubmit: () => void
  readonly onContentChange?: () => void
}

export interface Composer {
  readonly root: BoxRenderable
  readonly input: TextareaRenderable
  update(geometry: ComposerGeometry, title: string, bottomTitle: string): void
  destroy(): void
}

export function composerGeometry(width: number, height: number): ComposerGeometry {
  const bordered = height >= 6 && width >= 4
  const editorRows = Math.max(1, Math.min(5, Math.floor(height * 0.3)))
  return { bordered, editorRows, protectedRows: editorRows + (bordered ? 2 : 0) }
}

export function createComposer(ctx: RenderContext, options: ComposerOptions): Composer {
  const root = new BoxRenderable(ctx, {
    id: "prompt-composer",
    border: options.geometry.bordered,
    borderStyle: "rounded",
    borderColor: options.theme.border.default,
    backgroundColor: options.theme.surface.composer,
    title: options.title,
    titleColor: options.theme.text.muted,
    bottomTitle: options.bottomTitle,
    bottomTitleAlignment: "right",
    flexShrink: 0
  })
  const input = new TextareaRenderable(ctx, {
    id: "prompt-input",
    minHeight: 1,
    maxHeight: options.geometry.editorRows,
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
    update(geometry, title, bottomTitle) {
      root.border = geometry.bordered
      root.title = title
      root.bottomTitle = bottomTitle
      input.maxHeight = geometry.editorRows
    },
    destroy() {
      root.destroyRecursively()
    }
  }
}
