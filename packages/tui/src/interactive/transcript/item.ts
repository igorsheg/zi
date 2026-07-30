import type { Renderable } from "@opentui/core"

export interface TranscriptItemView {
  readonly root: Renderable
  setExpanded?(expanded: boolean): boolean
  destroy(): void
}
