import { expect, test } from "bun:test"

import {
  activateWorkspacePane,
  closeWorkspacePane,
  createWorkspaceLayout,
  focusWorkspacePane,
  maxWorkspacePanes,
  resizeWorkspaceSplit,
  splitWorkspacePane,
  workspaceMinimumSize,
  workspacePaneIds
} from "../../src/interactive/workspace/layout.js"

test("split inserts a stable binary node and activates the new pane", () => {
  const initial = createWorkspaceLayout("main")
  const split = splitWorkspacePane(initial, {
    targetPaneId: "main",
    paneId: "agent-1",
    splitId: "split-1",
    axis: "horizontal",
    side: "second",
    ratio: 0.618
  })

  expect(split).toEqual({
    activePaneId: "agent-1",
    root: {
      type: "split",
      splitId: "split-1",
      axis: "horizontal",
      ratio: 0.618,
      first: { type: "pane", paneId: "main" },
      second: { type: "pane", paneId: "agent-1" }
    }
  })
})

test("close collapses the parent and chooses the sibling when the active pane closes", () => {
  const split = splitWorkspacePane(createWorkspaceLayout("main"), {
    targetPaneId: "main",
    paneId: "agent-1",
    splitId: "split-1",
    axis: "horizontal",
    side: "second",
    ratio: 0.618
  })!

  expect(closeWorkspacePane(split, "agent-1")).toEqual(createWorkspaceLayout("main"))
  expect(closeWorkspacePane(createWorkspaceLayout("main"), "main")).toBeUndefined()
})

test("closing an inactive nested pane preserves the active pane", () => {
  const first = splitWorkspacePane(createWorkspaceLayout("main"), {
    targetPaneId: "main",
    paneId: "agent-1",
    splitId: "split-1",
    axis: "horizontal",
    side: "second",
    ratio: 0.618
  })!
  const second = splitWorkspacePane(first, {
    targetPaneId: "agent-1",
    paneId: "agent-2",
    splitId: "split-2",
    axis: "vertical",
    side: "second",
    ratio: 0.5
  })!
  const active = activateWorkspacePane(second, "main")!
  const closed = closeWorkspacePane(active, "agent-2")!

  expect(closed.activePaneId).toBe("main")
  expect(workspacePaneIds(closed.root)).toEqual(["main", "agent-1"])
})

test("split rejects duplicate identities, stale targets, invalid ratios, and excess panes", () => {
  const operation = {
    targetPaneId: "main",
    paneId: "agent-1",
    splitId: "split-1",
    axis: "horizontal" as const,
    side: "second" as const,
    ratio: 0.618
  }
  const first = splitWorkspacePane(createWorkspaceLayout("main"), operation)!

  expect(splitWorkspacePane(first, operation)).toBeUndefined()
  expect(splitWorkspacePane(first, { ...operation, paneId: "agent-2", targetPaneId: "missing" })).toBeUndefined()
  expect(splitWorkspacePane(first, { ...operation, paneId: "agent-2", splitId: "split-2", ratio: 1 })).toBeUndefined()

  let state = first
  for (let index = 2; index < maxWorkspacePanes; index++) {
    state = splitWorkspacePane(state, {
      targetPaneId: `agent-${index - 1}`,
      paneId: `agent-${index}`,
      splitId: `split-${index}`,
      axis: "vertical",
      side: "second",
      ratio: 0.5
    })!
  }
  expect(
    splitWorkspacePane(state, {
      targetPaneId: `agent-${maxWorkspacePanes - 1}`,
      paneId: "too-many",
      splitId: "too-many-split",
      axis: "vertical",
      side: "second",
      ratio: 0.5
    })
  ).toBeUndefined()
})

test("resize changes only the addressed split", () => {
  const state = splitWorkspacePane(createWorkspaceLayout("main"), {
    targetPaneId: "main",
    paneId: "agent-1",
    splitId: "split-1",
    axis: "horizontal",
    side: "second",
    ratio: 0.618
  })!

  expect(resizeWorkspaceSplit(state, "split-1", 0.7)?.root).toMatchObject({ ratio: 0.7 })
  expect(resizeWorkspaceSplit(state, "missing", 0.7)).toBeUndefined()
  expect(resizeWorkspaceSplit(state, "split-1", Number.NaN)).toBeUndefined()
})

test("directional focus uses settled pane rectangles", () => {
  const first = splitWorkspacePane(createWorkspaceLayout("main"), {
    targetPaneId: "main",
    paneId: "right-top",
    splitId: "split-1",
    axis: "horizontal",
    side: "second",
    ratio: 0.618
  })!
  const state = splitWorkspacePane(first, {
    targetPaneId: "right-top",
    paneId: "right-bottom",
    splitId: "split-2",
    axis: "vertical",
    side: "second",
    ratio: 0.5
  })!
  const rects = new Map([
    ["main", { x: 0, y: 0, width: 60, height: 40 }],
    ["right-top", { x: 61, y: 0, width: 39, height: 19 }],
    ["right-bottom", { x: 61, y: 20, width: 39, height: 20 }]
  ])

  const left = focusWorkspacePane(state, "left", rects)!
  expect(left.activePaneId).toBe("main")
  expect(focusWorkspacePane(left, "right", rects)?.activePaneId).toBe("right-bottom")
  expect(focusWorkspacePane(activateWorkspacePane(state, "right-top")!, "down", rects)?.activePaneId).toBe(
    "right-bottom"
  )
  expect(focusWorkspacePane(left, "up", rects)).toBeUndefined()
})

test("minimum size composes recursively with divider cells", () => {
  const first = splitWorkspacePane(createWorkspaceLayout("main"), {
    targetPaneId: "main",
    paneId: "agent-1",
    splitId: "split-1",
    axis: "horizontal",
    side: "second",
    ratio: 0.618
  })!
  const state = splitWorkspacePane(first, {
    targetPaneId: "agent-1",
    paneId: "agent-2",
    splitId: "split-2",
    axis: "vertical",
    side: "second",
    ratio: 0.5
  })!

  expect(
    workspaceMinimumSize(
      state.root,
      new Map([
        ["main", { width: 50, height: 12 }],
        ["agent-1", { width: 30, height: 8 }],
        ["agent-2", { width: 30, height: 8 }]
      ])
    )
  ).toEqual({ width: 81, height: 17 })
})
