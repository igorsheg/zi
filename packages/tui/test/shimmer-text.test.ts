import { expect, test } from "bun:test"

import { TextRenderable } from "@opentui/core"
import { createTestRenderer } from "@opentui/core/testing"

import { defaultShimmerMotion, phaseForMs, ShimmerTextView, strengthForColumn } from "../src/components/shimmer-text.js"

const phaseScale = 256

test("shimmer phase advances by visual columns and wraps at its bounded period", () => {
  const periodColumns = 3 + defaultShimmerMotion.leadPadColumns + defaultShimmerMotion.tailPadColumns
  expect(phaseForMs(0, "abc")).toBe(0)
  expect(phaseForMs(defaultShimmerMotion.msPerColumn / 2, "abc")).toBe(phaseScale / 2)
  expect(phaseForMs(defaultShimmerMotion.msPerColumn, "abc")).toBe(phaseScale)
  expect(phaseForMs(periodColumns * defaultShimmerMotion.msPerColumn, "abc")).toBe(0)
})

test("shimmer strength peaks at the band center and fades to zero", () => {
  const center = defaultShimmerMotion.leadPadColumns * phaseScale
  expect(strengthForColumn(center, 0)).toBe(255)
  expect(strengthForColumn(center, 1)).toBeGreaterThan(0)
  expect(strengthForColumn(center, 1)).toBeLessThan(255)
  expect(strengthForColumn(center, 5)).toBe(0)
})

test("shimmer keeps stable renderables and balances its live request", async () => {
  const setup = await createTestRenderer({ width: 20, height: 2, useThread: false })
  let now = 0
  const view = new ShimmerTextView(setup.renderer, "Working…", "#000000", "#FFFFFF", () => now)
  setup.renderer.root.add(view.root)

  try {
    expect(setup.renderer.liveRequestCount).toBe(0)
    view.setActive(true)
    view.setActive(true)
    expect(setup.renderer.liveRequestCount).toBe(1)

    await setup.renderOnce()
    const text = setup.renderer.root.findDescendantById("working-status-text")
    if (!(text instanceof TextRenderable)) throw new Error("Working status text not found")
    const firstFrame = text.content

    now = defaultShimmerMotion.msPerColumn / 2
    await setup.renderOnce()
    expect(text.content).toBe(firstFrame)

    now = defaultShimmerMotion.leadPadColumns * defaultShimmerMotion.msPerColumn
    await setup.renderOnce()
    expect(text.content).not.toBe(firstFrame)
    expect(
      setup
        .captureSpans()
        .lines.flatMap(line => line.spans)
        .find(span => span.text === "W")
        ?.fg.toInts()
    ).toEqual([255, 255, 255, 255])

    view.setActive(false)
    expect(view.root.visible).toBe(false)
    expect(setup.renderer.liveRequestCount).toBe(0)

    view.setActive(true)
    expect(setup.renderer.liveRequestCount).toBe(1)
    view.destroy()
    expect(setup.renderer.liveRequestCount).toBe(0)
  } finally {
    view.destroy()
    if (!setup.renderer.isDestroyed) setup.renderer.destroy()
  }
})

test("shimmer interpolates RGB and advances wide graphemes by terminal cells", async () => {
  const setup = await createTestRenderer({ width: 10, height: 2, useThread: false })
  let now =
    defaultShimmerMotion.leadPadColumns * defaultShimmerMotion.msPerColumn + defaultShimmerMotion.msPerColumn / 2
  const interpolation = new ShimmerTextView(setup.renderer, "ab", "#000000", "#FFFFFF", () => now)
  setup.renderer.root.add(interpolation.root)

  try {
    interpolation.setActive(true)
    await setup.renderOnce()
    const interpolated = setup
      .captureSpans()
      .lines.flatMap(line => line.spans)
      .find(span => span.text.includes("a"))
    expect(interpolated?.fg.toInts()).toEqual([212, 212, 212, 255])

    interpolation.destroy()
    const wide = new ShimmerTextView(setup.renderer, "界a", "#000000", "#FFFFFF", () => now)
    setup.renderer.root.add(wide.root)
    now = (defaultShimmerMotion.leadPadColumns + 2) * defaultShimmerMotion.msPerColumn
    wide.setActive(true)
    await setup.renderOnce()

    const peak = setup
      .captureSpans()
      .lines.flatMap(line => line.spans)
      .find(span => span.text.startsWith("a"))
    expect(peak?.fg.toInts()).toEqual([255, 255, 255, 255])
    wide.destroy()
  } finally {
    interpolation.destroy()
    if (!setup.renderer.isDestroyed) setup.renderer.destroy()
  }
})

test("oversized shimmer copy degrades to one static base chunk", async () => {
  const setup = await createTestRenderer({ width: 80, height: 2, useThread: false })
  const content = "x".repeat(100)
  const view = new ShimmerTextView(setup.renderer, content, "#102030", "#FFFFFF")
  setup.renderer.root.add(view.root)

  try {
    view.setActive(true)
    expect(setup.renderer.liveRequestCount).toBe(0)
    await setup.renderOnce()

    const text = setup.renderer.root.findDescendantById("working-status-text")
    if (!(text instanceof TextRenderable)) throw new Error("Working status text not found")
    expect(text.chunks).toHaveLength(1)
    expect(text.chunks[0]?.text).toBe(content)
    expect(text.chunks[0]?.fg?.toInts()).toEqual([16, 32, 48, 255])
  } finally {
    view.destroy()
    if (!setup.renderer.isDestroyed) setup.renderer.destroy()
  }
})
