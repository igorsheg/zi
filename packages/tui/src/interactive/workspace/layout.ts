export type WorkspacePaneId = string
export type WorkspaceSplitId = string
export type WorkspaceSplitAxis = "horizontal" | "vertical"
export type WorkspaceSplitSide = "first" | "second"
export type WorkspaceFocusDirection = "left" | "right" | "up" | "down"

export type WorkspaceLayoutNode =
  | { readonly type: "pane"; readonly paneId: WorkspacePaneId }
  | {
      readonly type: "split"
      readonly splitId: WorkspaceSplitId
      readonly axis: WorkspaceSplitAxis
      readonly ratio: number
      readonly first: WorkspaceLayoutNode
      readonly second: WorkspaceLayoutNode
    }

export interface WorkspaceLayoutState {
  readonly root: WorkspaceLayoutNode
  readonly activePaneId: WorkspacePaneId
}

export interface WorkspaceSplitOperation {
  readonly targetPaneId: WorkspacePaneId
  readonly paneId: WorkspacePaneId
  readonly splitId: WorkspaceSplitId
  readonly axis: WorkspaceSplitAxis
  readonly side: WorkspaceSplitSide
  readonly ratio: number
}

export interface WorkspacePaneRect {
  readonly x: number
  readonly y: number
  readonly width: number
  readonly height: number
}

export interface WorkspaceMinimumSize {
  readonly width: number
  readonly height: number
}

export const maxWorkspacePanes = 4
export const maxWorkspaceDepth = 4
export const minWorkspaceSplitRatio = 0.1
export const maxWorkspaceSplitRatio = 0.9
export const workspaceDividerCells = 1

export function createWorkspaceLayout(primaryPaneId: WorkspacePaneId): WorkspaceLayoutState {
  requireId(primaryPaneId, "pane")
  return { root: { type: "pane", paneId: primaryPaneId }, activePaneId: primaryPaneId }
}

export function splitWorkspacePane(
  state: WorkspaceLayoutState,
  operation: WorkspaceSplitOperation
): WorkspaceLayoutState | undefined {
  requireId(operation.paneId, "pane")
  requireId(operation.splitId, "split")
  if (!validRatio(operation.ratio)) return undefined
  if (workspacePaneIds(state.root).includes(operation.paneId)) return undefined
  if (workspaceSplitIds(state.root).includes(operation.splitId)) return undefined
  if (workspacePaneCount(state.root) >= maxWorkspacePanes) return undefined

  const targetDepth = paneDepth(state.root, operation.targetPaneId)
  if (targetDepth === undefined || targetDepth >= maxWorkspaceDepth) return undefined

  const pane: WorkspaceLayoutNode = { type: "pane", paneId: operation.paneId }
  const root = replacePane(state.root, operation.targetPaneId, current => ({
    type: "split",
    splitId: operation.splitId,
    axis: operation.axis,
    ratio: operation.ratio,
    first: operation.side === "first" ? pane : current,
    second: operation.side === "second" ? pane : current
  }))
  if (!root) return undefined
  return { root, activePaneId: operation.paneId }
}

export function closeWorkspacePane(
  state: WorkspaceLayoutState,
  paneId: WorkspacePaneId
): WorkspaceLayoutState | undefined {
  if (state.root.type === "pane") return undefined
  const removed = removePane(state.root, paneId)
  if (!removed) return undefined
  const activePaneId = state.activePaneId === paneId ? firstPaneId(removed.sibling) : state.activePaneId
  return { root: removed.root, activePaneId }
}

export function activateWorkspacePane(
  state: WorkspaceLayoutState,
  paneId: WorkspacePaneId
): WorkspaceLayoutState | undefined {
  if (!workspacePaneIds(state.root).includes(paneId)) return undefined
  return state.activePaneId === paneId ? state : { ...state, activePaneId: paneId }
}

export function resizeWorkspaceSplit(
  state: WorkspaceLayoutState,
  splitId: WorkspaceSplitId,
  ratio: number
): WorkspaceLayoutState | undefined {
  if (!validRatio(ratio)) return undefined
  const root = replaceSplit(state.root, splitId, split => ({ ...split, ratio }))
  return root ? { ...state, root } : undefined
}

export function focusWorkspacePane(
  state: WorkspaceLayoutState,
  direction: WorkspaceFocusDirection,
  rects: ReadonlyMap<WorkspacePaneId, WorkspacePaneRect>
): WorkspaceLayoutState | undefined {
  const current = rects.get(state.activePaneId)
  if (!current) return undefined

  const originX = current.x + current.width / 2
  const originY = current.y + current.height / 2
  let target: { readonly paneId: WorkspacePaneId; readonly score: number } | undefined

  for (const paneId of workspacePaneIds(state.root)) {
    if (paneId === state.activePaneId) continue
    const rect = rects.get(paneId)
    if (!rect) continue
    const centerX = rect.x + rect.width / 2
    const centerY = rect.y + rect.height / 2
    const primary = directionalDistance(direction, current, rect, originX, originY, centerX, centerY)
    if (primary === undefined) continue
    const secondary =
      direction === "left" || direction === "right" ? Math.abs(centerY - originY) : Math.abs(centerX - originX)
    const score = primary * 10_000 + secondary
    if (!target || score < target.score) target = { paneId, score }
  }

  return target ? { ...state, activePaneId: target.paneId } : undefined
}

export function workspaceMinimumSize(
  node: WorkspaceLayoutNode,
  paneMinimums: ReadonlyMap<WorkspacePaneId, WorkspaceMinimumSize>,
  dividerCells = workspaceDividerCells
): WorkspaceMinimumSize {
  if (node.type === "pane") return paneMinimums.get(node.paneId) ?? { width: 1, height: 1 }
  const first = workspaceMinimumSize(node.first, paneMinimums, dividerCells)
  const second = workspaceMinimumSize(node.second, paneMinimums, dividerCells)
  return node.axis === "horizontal"
    ? { width: first.width + dividerCells + second.width, height: Math.max(first.height, second.height) }
    : { width: Math.max(first.width, second.width), height: first.height + dividerCells + second.height }
}

export function workspacePaneIds(node: WorkspaceLayoutNode): readonly WorkspacePaneId[] {
  if (node.type === "pane") return [node.paneId]
  return [...workspacePaneIds(node.first), ...workspacePaneIds(node.second)]
}

export function workspaceSplitIds(node: WorkspaceLayoutNode): readonly WorkspaceSplitId[] {
  if (node.type === "pane") return []
  return [node.splitId, ...workspaceSplitIds(node.first), ...workspaceSplitIds(node.second)]
}

export function workspacePaneCount(node: WorkspaceLayoutNode): number {
  return node.type === "pane" ? 1 : workspacePaneCount(node.first) + workspacePaneCount(node.second)
}

function replacePane(
  node: WorkspaceLayoutNode,
  paneId: WorkspacePaneId,
  replace: (pane: Extract<WorkspaceLayoutNode, { readonly type: "pane" }>) => WorkspaceLayoutNode
): WorkspaceLayoutNode | undefined {
  if (node.type === "pane") return node.paneId === paneId ? replace(node) : undefined
  const first = replacePane(node.first, paneId, replace)
  if (first) return { ...node, first }
  const second = replacePane(node.second, paneId, replace)
  return second ? { ...node, second } : undefined
}

function replaceSplit(
  node: WorkspaceLayoutNode,
  splitId: WorkspaceSplitId,
  replace: (split: Extract<WorkspaceLayoutNode, { readonly type: "split" }>) => WorkspaceLayoutNode
): WorkspaceLayoutNode | undefined {
  if (node.type === "pane") return undefined
  if (node.splitId === splitId) return replace(node)
  const first = replaceSplit(node.first, splitId, replace)
  if (first) return { ...node, first }
  const second = replaceSplit(node.second, splitId, replace)
  return second ? { ...node, second } : undefined
}

function removePane(
  node: WorkspaceLayoutNode,
  paneId: WorkspacePaneId
): { readonly root: WorkspaceLayoutNode; readonly sibling: WorkspaceLayoutNode } | undefined {
  if (node.type === "pane") return undefined
  if (node.first.type === "pane" && node.first.paneId === paneId) return { root: node.second, sibling: node.second }
  if (node.second.type === "pane" && node.second.paneId === paneId) return { root: node.first, sibling: node.first }

  const first = removePane(node.first, paneId)
  if (first) return { root: { ...node, first: first.root }, sibling: first.sibling }
  const second = removePane(node.second, paneId)
  return second ? { root: { ...node, second: second.root }, sibling: second.sibling } : undefined
}

function paneDepth(node: WorkspaceLayoutNode, paneId: WorkspacePaneId, depth = 1): number | undefined {
  if (node.type === "pane") return node.paneId === paneId ? depth : undefined
  return paneDepth(node.first, paneId, depth + 1) ?? paneDepth(node.second, paneId, depth + 1)
}

function firstPaneId(node: WorkspaceLayoutNode): WorkspacePaneId {
  return node.type === "pane" ? node.paneId : firstPaneId(node.first)
}

function directionalDistance(
  direction: WorkspaceFocusDirection,
  current: WorkspacePaneRect,
  candidate: WorkspacePaneRect,
  originX: number,
  originY: number,
  centerX: number,
  centerY: number
): number | undefined {
  switch (direction) {
    case "left":
      return candidate.x + candidate.width <= current.x ? originX - centerX : undefined
    case "right":
      return candidate.x >= current.x + current.width ? centerX - originX : undefined
    case "up":
      return candidate.y + candidate.height <= current.y ? originY - centerY : undefined
    case "down":
      return candidate.y >= current.y + current.height ? centerY - originY : undefined
    default:
      return assertNever(direction)
  }
}

function validRatio(ratio: number): boolean {
  return Number.isFinite(ratio) && ratio >= minWorkspaceSplitRatio && ratio <= maxWorkspaceSplitRatio
}

function requireId(id: string, kind: "pane" | "split"): void {
  if (!id) throw new Error(`Workspace ${kind} ID cannot be empty`)
}

function assertNever(value: never): never {
  throw new Error(`Unexpected workspace value: ${String(value)}`)
}
