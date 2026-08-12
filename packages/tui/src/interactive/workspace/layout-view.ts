import { BoxRenderable, type CliRenderer, type Renderable } from "@opentui/core"

import type { WorkspaceLayoutNode, WorkspacePaneId } from "./layout.js"

type PaneContent = { readonly type: "pane"; readonly paneId: WorkspacePaneId; readonly root: Renderable }

type SplitContent = {
  readonly type: "split"
  readonly splitId: string
  readonly axis: "horizontal" | "vertical"
  ratio: number
  readonly root: BoxRenderable
  readonly firstHost: BoxRenderable
  readonly divider: BoxRenderable
  readonly secondHost: BoxRenderable
  first: LayoutContent
  second: LayoutContent
}

type LayoutContent = PaneContent | SplitContent

export class WorkspaceLayoutView {
  readonly root: BoxRenderable

  readonly #renderer: CliRenderer
  readonly #paneRoot: (paneId: WorkspacePaneId) => Renderable
  #content: LayoutContent | undefined
  #destroyed = false

  constructor(renderer: CliRenderer, paneRoot: (paneId: WorkspacePaneId) => Renderable) {
    this.#renderer = renderer
    this.#paneRoot = paneRoot
    this.root = new BoxRenderable(renderer, {
      id: "workspace-layout",
      flexDirection: "column",
      flexGrow: 1,
      minWidth: 0,
      minHeight: 0,
      overflow: "hidden"
    })
  }

  render(node: WorkspaceLayoutNode, activeOnly?: WorkspacePaneId): void {
    if (this.#destroyed) return
    this.#content = this.#reconcile(this.root, this.#content, node)
    this.#present(this.#content, activeOnly)
    this.#renderer.requestRender()
  }

  destroy(): void {
    if (this.#destroyed) return
    this.#destroyed = true
    if (this.#content) this.#destroyContent(this.#content)
    this.#content = undefined
    this.root.destroyRecursively()
  }

  #reconcile(parent: BoxRenderable, current: LayoutContent | undefined, node: WorkspaceLayoutNode): LayoutContent {
    if (node.type === "pane") {
      const pane = this.#paneRoot(node.paneId)
      if (current?.type === "pane" && current.paneId === node.paneId && current.root === pane) return current
      if (current) this.#destroyContent(current)
      parent.add(pane)
      return { type: "pane", paneId: node.paneId, root: pane }
    }

    if (current?.type === "split" && current.splitId === node.splitId && current.axis === node.axis) {
      if (current.ratio !== node.ratio) {
        current.ratio = node.ratio
        current.firstHost.flexGrow = node.ratio
        current.secondHost.flexGrow = 1 - node.ratio
      }
      current.first = this.#reconcile(current.firstHost, current.first, node.first)
      current.second = this.#reconcile(current.secondHost, current.second, node.second)
      return current
    }

    if (current) this.#destroyContent(current)
    return this.#build(parent, node)
  }

  #build(parent: BoxRenderable, node: WorkspaceLayoutNode): LayoutContent {
    if (node.type === "pane") {
      const pane = this.#paneRoot(node.paneId)
      parent.add(pane)
      return { type: "pane", paneId: node.paneId, root: pane }
    }

    const split = new BoxRenderable(this.#renderer, {
      id: `workspace-${node.splitId}`,
      flexDirection: node.axis === "horizontal" ? "row" : "column",
      flexGrow: 1,
      minWidth: 0,
      minHeight: 0,
      overflow: "hidden"
    })
    const firstHost = splitHost(this.#renderer, `${node.splitId}-first`, node.ratio)
    const secondHost = splitHost(this.#renderer, `${node.splitId}-second`, 1 - node.ratio)
    const divider = new BoxRenderable(this.#renderer, {
      id: `workspace-${node.splitId}-divider`,
      ...(node.axis === "horizontal" ? { width: 1 } : { height: 1 }),
      flexShrink: 0
    })
    split.add(firstHost)
    split.add(divider)
    split.add(secondHost)
    parent.add(split)
    return {
      type: "split",
      splitId: node.splitId,
      axis: node.axis,
      ratio: node.ratio,
      root: split,
      firstHost,
      divider,
      secondHost,
      first: this.#build(firstHost, node.first),
      second: this.#build(secondHost, node.second)
    }
  }

  #present(content: LayoutContent, activeOnly: WorkspacePaneId | undefined): void {
    if (content.type === "pane") {
      setVisible(content.root, activeOnly === undefined || activeOnly === content.paneId)
      return
    }

    const firstVisible = activeOnly === undefined || includesPane(content.first, activeOnly)
    const secondVisible = activeOnly === undefined || includesPane(content.second, activeOnly)
    setVisible(content.firstHost, firstVisible)
    setVisible(content.secondHost, secondVisible)
    setVisible(content.divider, firstVisible && secondVisible)
    this.#present(content.first, activeOnly)
    this.#present(content.second, activeOnly)
  }

  #destroyContent(content: LayoutContent): void {
    if (content.type === "pane") {
      if (content.root.parent) content.root.parent.remove(content.root)
      if (!content.root.isDestroyed) content.root.visible = true
      return
    }

    this.#destroyContent(content.first)
    this.#destroyContent(content.second)
    if (content.root.parent) content.root.parent.remove(content.root)
    content.root.destroyRecursively()
  }
}

function splitHost(renderer: CliRenderer, id: string, grow: number): BoxRenderable {
  return new BoxRenderable(renderer, {
    id: `workspace-${id}`,
    flexBasis: 0,
    flexGrow: grow,
    flexShrink: 1,
    minWidth: 0,
    minHeight: 0,
    overflow: "hidden"
  })
}

function includesPane(content: LayoutContent, paneId: WorkspacePaneId): boolean {
  if (content.type === "pane") return content.paneId === paneId
  return includesPane(content.first, paneId) || includesPane(content.second, paneId)
}

function setVisible(renderable: Renderable, visible: boolean): void {
  if (renderable.visible !== visible) renderable.visible = visible
}
