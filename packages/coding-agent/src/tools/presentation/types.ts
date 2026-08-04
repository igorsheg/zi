export type ToolPresentationSource =
  | { readonly status: "preparing"; readonly name: string; readonly args: unknown }
  | { readonly status: "ready"; readonly name: string; readonly args: unknown }
  | { readonly status: "running"; readonly name: string; readonly args: unknown; readonly result?: unknown }
  | { readonly status: "done"; readonly name: string; readonly args: unknown; readonly result: unknown }
  | { readonly status: "failed"; readonly name: string; readonly args: unknown; readonly result: unknown }
  | { readonly status: "aborted"; readonly name: string; readonly args: unknown; readonly result: unknown }

export interface ToolPresentation {
  readonly header: ToolHeader
  readonly body?: ToolBody
  readonly notices: readonly ToolNotice[]
  readonly preview: ToolPreviewPolicy
  readonly timing: ToolTimingPolicy
}

/**
 * Header slots form a single grammar, rendered left to right:
 * `bullet Label subject · details +added/-removed · status · timing`.
 * Each slot has exactly one job; projectors must not leak one channel into
 * another:
 * - label: stable operation verb ("Run", "Edit", "Spawn"). Never shifts tense
 *   with lifecycle; the bullet, rail color, and view-owned lifecycle words
 *   carry that.
 * - subject: the target acted on. At most one per tool.
 * - details: auxiliary facts (timeouts, task ids, ranges, counts). Pure
 *   decoration; the view drops them first under width pressure.
 * - status: a single outcome phrase ("exit 1", "timed out", "match not
 *   found"). Never lifecycle ("failed"/"aborted" — the view adds those) and
 *   never evidence qualifiers explained by notices ("truncated").
 */
export interface ToolHeader {
  readonly label: string
  readonly subject?: ToolSubject
  readonly secondary?: ToolSubject
  readonly details: readonly string[]
  readonly delta?: { readonly added: number; readonly removed: number }
  readonly status?: string
}

export type ToolSubject =
  | { readonly type: "command"; readonly text: string; readonly prompt: boolean }
  | { readonly type: "path"; readonly path: string }
  | { readonly type: "task"; readonly id: string }
  | { readonly type: "text"; readonly text: string }

export type ToolBody =
  | { readonly type: "terminal"; readonly text: string }
  | { readonly type: "source"; readonly text: string; readonly path: string; readonly startLine?: number }
  | { readonly type: "diff"; readonly text: string; readonly path?: string }
  | { readonly type: "text"; readonly text: string; readonly tone: "normal" | "muted" | "error" }

interface ToolNoticeBase {
  readonly tone: "muted" | "warning" | "error"
  readonly visibility: "always" | "detailed"
}

export type ToolNotice =
  | (ToolNoticeBase & { readonly type: "message"; readonly text: string })
  | (Omit<ToolNoticeBase, "tone"> & {
      readonly type: "path"
      readonly tone: "muted" | "warning"
      readonly label: string
      readonly path: string
    })

export interface ToolPreviewPolicy {
  readonly compact: ToolPreviewWindow
  readonly detailed: ToolPreviewWindow
}

export type ToolPreviewWindow =
  | { readonly type: "hidden" }
  | { readonly type: "head"; readonly rows: number }
  | { readonly type: "tail"; readonly rows: number }
  | { readonly type: "edges"; readonly head: number; readonly tail: number }

export type ToolTimingPolicy = "duration" | "started" | "hidden"

export const maxToolInlineScalars = 4_096
export const maxToolNotices = 8
export const maxToolPreviewRows = 12
export const maxExpandedToolRows = 200

/**
 * Expanded evidence that keeps both ends splits the expanded row budget
 * between head and tail; the cap carries the elision count, so no row is
 * reserved for an in-body marker.
 */
export function splitWindow(head: number): ToolPreviewWindow {
  return { type: "edges", head, tail: Math.max(0, maxExpandedToolRows - head) }
}
