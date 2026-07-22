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
