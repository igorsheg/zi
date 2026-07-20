import { expect, test } from "bun:test"

import { createTestRenderer } from "@opentui/core/testing"

import {
  compactPasteCharacterThreshold,
  compactPasteLineThreshold,
  composerGeometry,
  createComposer,
  maxCompactPasteMarkers,
  maxCompactPasteRetainedBytes
} from "../src/components/composer.js"
import { defaultTheme } from "../src/theme.js"

test("composer collapses only Pi-sized pastes and expands exact content for submission", async () => {
  const setup = await createTestRenderer({ width: 60, height: 8, useThread: false })
  const composer = createComposer(setup.renderer, {
    geometry: composerGeometry(60, 8),
    slots: { topLeft: "/work", topRight: [] },
    theme: defaultTheme,
    onSubmit() {}
  })
  setup.renderer.root.add(composer.root)

  try {
    const tenLines = Array.from({ length: compactPasteLineThreshold }, () => "line").join("\n")
    composer.insertPastedText(tenLines)
    expect(composer.input.plainText).toBe(tenLines)

    composer.replaceText("")
    const elevenLines = Array.from({ length: compactPasteLineThreshold + 1 }, (_, index) => `line-${index}`).join("\n")
    composer.insertPastedText(elevenLines)
    expect(composer.input.plainText).toBe("[paste #1 +11 lines]")
    expect(composer.expandedText()).toBe(elevenLines)
    composer.input.setSelection(0, composer.input.cursorOffset)
    expect(composer.input.getSelectedText()).toBe(elevenLines)
    composer.input.clearSelection()

    composer.replaceText("")
    const thresholdPaste = "x".repeat(compactPasteCharacterThreshold)
    composer.insertPastedText(thresholdPaste)
    expect(composer.input.plainText).toBe(thresholdPaste)

    composer.replaceText("")
    const longPaste = "x".repeat(compactPasteCharacterThreshold + 1)
    composer.insertPastedText(longPaste)
    expect(composer.input.plainText).toBe("[paste #1 1001 chars]")
    expect(composer.expandedText()).toBe(longPaste)

    const literalMarker = "[paste #1 1001 chars] "
    composer.replaceText(literalMarker)
    composer.insertPastedText(longPaste)
    composer.input.setSelection(0, composer.input.cursorOffset)
    expect(composer.input.getSelectedText()).toBe(literalMarker + longPaste)
    composer.input.clearSelection()

    composer.replaceText("界tail", 2)
    composer.insertPastedText(longPaste)
    expect(composer.input.plainText).toBe("界[paste #1 1001 chars]tail")
    expect(composer.expandedText()).toBe(`界${longPaste}tail`)
  } finally {
    composer.destroy()
    if (!setup.renderer.isDestroyed) setup.renderer.destroy()
  }
})

test("composer bounds retained compact paste markers and falls back to full text", async () => {
  const setup = await createTestRenderer({ width: 60, height: 8, useThread: false })
  const composer = createComposer(setup.renderer, {
    geometry: composerGeometry(60, 8),
    slots: { topLeft: "/work", topRight: [] },
    theme: defaultTheme,
    onSubmit() {}
  })
  setup.renderer.root.add(composer.root)
  const large = "x".repeat(compactPasteCharacterThreshold + 1)

  try {
    for (let index = 0; index < maxCompactPasteMarkers; index++) composer.insertPastedText(large)
    expect(composer.input.plainText.match(/\[paste #/g)).toHaveLength(maxCompactPasteMarkers)

    composer.insertPastedText(large)
    expect(composer.input.plainText.endsWith(large)).toBe(true)
    expect(composer.input.plainText.match(/\[paste #/g)).toHaveLength(maxCompactPasteMarkers)

    composer.replaceText("")
    const retainedChunk = "界".repeat(Math.ceil(maxCompactPasteRetainedBytes / 15))
    for (let index = 0; index < 4; index++) composer.insertPastedText(retainedChunk)
    expect(composer.input.plainText.match(/\[paste #/g)).toHaveLength(4)
    composer.insertPastedText(retainedChunk)
    expect(composer.input.plainText.endsWith(retainedChunk)).toBe(true)
    expect(composer.input.plainText.match(/\[paste #/g)).toHaveLength(4)
  } finally {
    composer.destroy()
    if (!setup.renderer.isDestroyed) setup.renderer.destroy()
  }
})

test("composer image markers and pasted payloads follow native deletion and undo", async () => {
  const setup = await createTestRenderer({ width: 60, height: 8, useThread: false, kittyKeyboard: true })
  const changes: unknown[][] = []
  const composer = createComposer(setup.renderer, {
    geometry: composerGeometry(60, 8),
    slots: { topLeft: "/work", topRight: [] },
    theme: defaultTheme,
    onSubmit() {},
    onImageMarkersChange: images => changes.push([...images])
  })
  setup.renderer.root.add(composer.root)
  const image = { type: "image" as const, mimeType: "image/png", data: "AAAA" }

  try {
    composer.input.focus()
    composer.syncImageMarkers([image])
    await Bun.sleep(0)
    expect(composer.input.plainText).toBe("[image #1] ")
    expect(composer.expandedText()).toBe("")
    expect(changes.at(-1)).toEqual([image])

    setup.mockInput.pressBackspace()
    await Bun.sleep(0)
    expect(composer.input.plainText).toBe("")
    expect(changes.at(-1)).toEqual([])

    setup.mockInput.pressKey("-", { ctrl: true })
    await Bun.sleep(0)
    expect(composer.input.plainText).toBe("[image #1] ")
    expect(changes.at(-1)).toEqual([image])
  } finally {
    composer.destroy()
    if (!setup.renderer.isDestroyed) setup.renderer.destroy()
  }
})

test("reapplying the same composer presentation does not schedule another frame", async () => {
  const setup = await createTestRenderer({ width: 40, height: 8, useThread: false })
  const geometry = composerGeometry(40, 8)
  const slots = { topLeft: "/workspace/openzi", topRight: ["model (high)", "(ctx 15%/247k)"] }
  const composer = createComposer(setup.renderer, { geometry, slots, theme: defaultTheme, onSubmit() {} })
  setup.renderer.root.add(composer.root)

  try {
    await setup.waitForVisualIdle()
    expect(setup.renderer.getSchedulerState().hasScheduledRender).toBe(false)

    composer.update(composerGeometry(40, 8), {
      topLeft: "/workspace/openzi",
      topRight: ["model (high)", "(ctx 15%/247k)"]
    })

    expect(setup.renderer.getSchedulerState().hasScheduledRender).toBe(false)
  } finally {
    composer.destroy()
    if (!setup.renderer.isDestroyed) setup.renderer.destroy()
  }
})
