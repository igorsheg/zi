import type { Renderable } from "@opentui/core"

export interface TranscriptItemView {
  readonly root: Renderable
  destroy(): void
}
