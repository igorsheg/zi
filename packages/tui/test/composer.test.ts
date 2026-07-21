import { expect, test } from "bun:test"

import { createTestRenderer } from "@opentui/core/testing"

import {
  compactPasteCharacterThreshold,
  compactPasteLineThreshold,
  composerGeometry,
  createComposer,
  maxCompactPasteMarkers,
  maxCompactPasteRetainedBytes,
  type ComposerHistoryEntry,
  type ComposerHistorySource
} from "../src/components/composer.js"
import { defaultTheme } from "../src/theme.js"

test("composer history traverses stable entries and restores the native draft", async () => {
  const setup = await createTestRenderer({ width: 40, height: 8, useThread: false })
  const history = fakeHistory(["oldest", "middle", "newest"])
  let changes = 0
  const composer = createComposer(setup.renderer, {
    geometry: composerGeometry(40, 8),
    slots: { topLeft: "/work", topRight: [] },
    theme: defaultTheme,
    historySource: history,
    onSubmit() {},
    onContentChange: () => changes++
  })
  setup.renderer.root.add(composer.root)

  try {
    composer.replaceText("draft", 0)
    changes = 0
    expect(composer.historyPrevious()).toBe("history_changed")
    expect(composer.input.plainText).toBe("newest")
    expect(composer.input.cursorOffset).toBe(0)

    expect(composer.historyPrevious()).toBe("history_changed")
    expect(composer.input.plainText).toBe("middle")
    expect(composer.historyPrevious()).toBe("history_changed")
    expect(composer.input.plainText).toBe("oldest")
    expect(composer.historyPrevious()).toBe("unchanged")
    expect(composer.input.plainText).toBe("oldest")

    composer.input.gotoBufferEnd()
    expect(composer.historyNext()).toBe("history_changed")
    expect(composer.input.plainText).toBe("middle")
    expect(composer.input.cursorOffset).toBe(6)
    composer.input.cursorOffset = 0
    expect(composer.historyPrevious()).toBe("history_changed")
    expect(composer.input.plainText).toBe("oldest")

    composer.input.gotoBufferEnd()
    composer.historyNext()
    composer.input.gotoBufferEnd()
    composer.historyNext()
    composer.input.gotoBufferEnd()
    expect(composer.historyNext()).toBe("history_changed")
    expect(composer.input.plainText).toBe("draft")
    expect(composer.input.cursorOffset).toBe(0)
    expect(composer.historyNext()).toBe("cursor_moved")
    expect(composer.historyNext()).toBe("unchanged")
    await Bun.sleep(0)
    expect(changes).toBe(8)
  } finally {
    composer.destroy()
    if (!setup.renderer.isDestroyed) setup.renderer.destroy()
  }
})

test("composer history traverses immediately from horizontal positions on boundary visual lines", async () => {
  const setup = await createTestRenderer({ width: 40, height: 8, useThread: false })
  const composer = createComposer(setup.renderer, {
    geometry: composerGeometry(40, 8),
    slots: { topLeft: "/work", topRight: [] },
    theme: defaultTheme,
    historySource: fakeHistory(["oldest", "界x"]),
    onSubmit() {}
  })
  setup.renderer.root.add(composer.root)

  try {
    composer.replaceText("draft", 0)
    composer.historyPrevious()
    composer.input.cursorOffset = 3
    expect(composer.historyPrevious()).toBe("history_changed")
    expect(composer.input.plainText).toBe("oldest")

    composer.input.cursorOffset = 2
    expect(composer.historyNext()).toBe("history_changed")
    expect(composer.input.plainText).toBe("界x")
    expect(composer.input.cursorOffset).toBe(3)

    composer.input.cursorOffset = 2
    expect(composer.historyNext()).toBe("history_changed")
    expect(composer.input.plainText).toBe("draft")
    expect(composer.input.cursorOffset).toBe(0)
  } finally {
    composer.destroy()
    if (!setup.renderer.isDestroyed) setup.renderer.destroy()
  }
})

test("composer history replacement remains bounded across repeated complete traversals", async () => {
  const setup = await createTestRenderer({ width: 40, height: 8, useThread: false })
  const history = fakeHistory(Array.from({ length: 100 }, (_, index) => `entry-${index}`))
  const composer = createComposer(setup.renderer, {
    geometry: composerGeometry(40, 8),
    slots: { topLeft: "/work", topRight: [] },
    theme: defaultTheme,
    historySource: history,
    onSubmit() {}
  })
  setup.renderer.root.add(composer.root)

  try {
    composer.replaceText("draft", 0)
    for (let traversal = 0; traversal < 4; traversal++) {
      for (let entry = 0; entry < 100; entry++) {
        expect(composer.historyPrevious()).toBe("history_changed")
      }
      expect(composer.historyPrevious()).toBe("unchanged")
      for (let entry = 0; entry < 100; entry++) {
        expect(composer.historyNext()).toBe("history_changed")
      }
      expect(composer.input.plainText).toBe("draft")
    }

    history.append("catalog turnover")
    expect(composer.historyPrevious()).toBe("history_changed")
    expect(composer.input.plainText).toBe("catalog turnover")
    expect(composer.historyNext()).toBe("history_changed")
    expect(composer.input.plainText).toBe("draft")

    for (let generation = 0; generation < 300; generation++) {
      history.append(`generation-${generation}`)
      composer.replaceText("draft", 0)
      expect(composer.historyPrevious()).toBe("history_changed")
      expect(composer.input.plainText).toBe(`generation-${generation}`)
      expect(composer.historyNext()).toBe("history_changed")
    }
    const retainedBuffers: unknown = Reflect.get(composer.input.editBuffer, "_textBytes")
    expect(Array.isArray(retainedBuffers) ? retainedBuffers.length : -1).toBe(101)
  } finally {
    composer.destroy()
    if (!setup.renderer.isDestroyed) setup.renderer.destroy()
  }
})

test("composer history reuses pinned stable IDs across repeated abandoned browses", async () => {
  const setup = await createTestRenderer({ width: 40, height: 8, useThread: false })
  const history = fakeHistory(Array.from({ length: 100 }, (_, index) => `entry-${index}`))
  const composer = createComposer(setup.renderer, {
    geometry: composerGeometry(40, 8),
    slots: { topLeft: "/work", topRight: [] },
    theme: defaultTheme,
    historySource: history,
    onSubmit() {}
  })
  setup.renderer.root.add(composer.root)

  try {
    composer.replaceText("draft", 0)
    for (let traversal = 0; traversal < 4; traversal++) {
      for (let entry = 0; entry < 100; entry++) {
        expect(composer.historyPrevious()).toBe("history_changed")
      }
      composer.input.insertText("!")
      expect(composer.input.plainText).toBe("!entry-0")
      composer.input.cursorOffset = 0
    }
    const retainedBuffers: unknown = Reflect.get(composer.input.editBuffer, "_textBytes")
    expect(Array.isArray(retainedBuffers) ? retainedBuffers.length : -1).toBe(100)
  } finally {
    composer.destroy()
    if (!setup.renderer.isDestroyed) setup.renderer.destroy()
  }
})

test("composer history does not recycle replacements retained by ordinary native redo", async () => {
  const setup = await createTestRenderer({ width: 40, height: 8, useThread: false })
  const history = fakeHistory(["historical"])
  const composer = createComposer(setup.renderer, {
    geometry: composerGeometry(40, 8),
    slots: { topLeft: "/work", topRight: [] },
    theme: defaultTheme,
    historySource: history,
    onSubmit() {}
  })
  setup.renderer.root.add(composer.root)

  try {
    composer.replaceText("draft", 0)
    composer.historyPrevious()
    composer.historyNext()
    composer.input.redo()
    composer.input.gotoBufferEnd()
    composer.input.insertText("!")
    expect(composer.input.plainText).toBe("historical!")

    history.append("newest")
    composer.input.cursorOffset = 0
    expect(composer.historyPrevious()).toBe("history_changed")
    expect(composer.input.plainText).toBe("newest")
    expect(composer.historyNext()).toBe("history_changed")
    expect(composer.input.plainText).toBe("historical!")
  } finally {
    composer.destroy()
    if (!setup.renderer.isDestroyed) setup.renderer.destroy()
  }
})

test("composer history restores its previous transition when native replacement fails", async () => {
  const setup = await createTestRenderer({ width: 40, height: 8, useThread: false })
  const composer = createComposer(setup.renderer, {
    geometry: composerGeometry(40, 8),
    slots: { topLeft: "/work", topRight: [] },
    theme: defaultTheme,
    historySource: fakeHistory(["older", "newest"]),
    onSubmit() {}
  })
  setup.renderer.root.add(composer.root)
  const replaceText = composer.input.editBuffer.replaceText.bind(composer.input.editBuffer)

  try {
    composer.replaceText("draft", 0)
    composer.input.editBuffer.replaceText = () => {
      throw new Error("replacement failed")
    }
    expect(() => composer.historyPrevious()).toThrow("replacement failed")

    composer.input.editBuffer.replaceText = replaceText
    expect(composer.historyPrevious()).toBe("history_changed")
    expect(composer.input.plainText).toBe("newest")
  } finally {
    composer.input.editBuffer.replaceText = replaceText
    composer.destroy()
    if (!setup.renderer.isDestroyed) setup.renderer.destroy()
  }
})

test("composer history detaches on editing or external replacement and ignores later appends until a new browse", async () => {
  const setup = await createTestRenderer({ width: 40, height: 8, useThread: false })
  const history = fakeHistory(["older", "newest"])
  const composer = createComposer(setup.renderer, {
    geometry: composerGeometry(40, 8),
    slots: { topLeft: "/work", topRight: [] },
    theme: defaultTheme,
    historySource: history,
    onSubmit() {}
  })
  setup.renderer.root.add(composer.root)

  try {
    composer.replaceText("draft", 0)
    composer.historyPrevious()
    composer.input.insertText("edited ")
    expect(composer.input.plainText).toBe("edited newest")
    composer.input.cursorOffset = 0
    composer.historyPrevious()
    expect(composer.input.plainText).toBe("newest")
    composer.input.gotoBufferEnd()
    composer.historyNext()
    expect(composer.input.plainText).toBe("edited newest")

    composer.replaceText("replacement", 0)
    composer.historyPrevious()
    history.append("appended")
    composer.historyPrevious()
    expect(composer.input.plainText).toBe("older")
    composer.input.gotoBufferEnd()
    composer.historyNext()
    composer.input.gotoBufferEnd()
    composer.historyNext()
    expect(composer.input.plainText).toBe("replacement")

    composer.input.cursorOffset = 0
    composer.historyPrevious()
    expect(composer.input.plainText).toBe("appended")
  } finally {
    composer.destroy()
    if (!setup.renderer.isDestroyed) setup.renderer.destroy()
  }
})

test("composer history preserves compact paste and image extmarks plus prior undo", async () => {
  const setup = await createTestRenderer({ width: 60, height: 8, useThread: false })
  const image = { type: "image" as const, mimeType: "image/png", data: "AAAA" }
  const paste = "x".repeat(compactPasteCharacterThreshold + 1)
  const composer = createComposer(setup.renderer, {
    geometry: composerGeometry(60, 8),
    slots: { topLeft: "/work", topRight: [] },
    theme: defaultTheme,
    historySource: fakeHistory(["historical"]),
    onSubmit() {}
  })
  setup.renderer.root.add(composer.root)

  try {
    composer.input.insertText("a")
    composer.input.insertText("b")
    composer.insertPastedText(paste)
    composer.syncImageMarkers([image])
    const draft = composer.input.plainText
    expect(draft).toBe("ab[paste #1 1001 chars] [image #1] ")
    composer.input.cursorOffset = 0

    composer.historyPrevious()
    await Bun.sleep(0)
    expect(composer.input.plainText).toBe("historical")
    expect(composer.activeImages()).toEqual([])
    composer.input.gotoBufferEnd()
    composer.historyNext()

    expect(composer.input.plainText).toBe(draft)
    expect(composer.expandedText()).toBe(`ab${paste}`)
    expect(composer.activeImages()).toEqual([image])
    expect(composer.activeImages()[0]).toBe(image)
    expect(composer.input.cursorOffset).toBe(0)

    composer.input.undo()
    expect(composer.input.plainText).toBe("ab[paste #1 1001 chars]")
    composer.input.undo()
    expect(composer.input.plainText).toBe("ab")
  } finally {
    composer.destroy()
    if (!setup.renderer.isDestroyed) setup.renderer.destroy()
  }
})

test("composer history respects multiline, wrapped, selection, and display-width boundaries", async () => {
  const setup = await createTestRenderer({ width: 16, height: 8, useThread: false })
  const composer = createComposer(setup.renderer, {
    geometry: composerGeometry(16, 8),
    slots: { topLeft: "", topRight: [] },
    theme: defaultTheme,
    historySource: fakeHistory(["界"]),
    onSubmit() {}
  })
  setup.renderer.root.add(composer.root)

  try {
    await setup.renderOnce()
    composer.replaceText("first line that wraps\nlast", 0)
    composer.input.gotoBufferEnd()
    expect(composer.historyPrevious()).toBe("cursor_moved")
    expect(composer.input.plainText).toBe("first line that wraps\nlast")
    while (composer.input.cursorOffset !== 0) {
      expect(composer.historyPrevious()).toBe("cursor_moved")
    }
    expect(composer.historyPrevious()).toBe("history_changed")
    expect(composer.input.plainText).toBe("界")
    expect(composer.input.cursorOffset).toBe(0)
    expect(composer.historyNext()).toBe("history_changed")
    expect(composer.input.plainText).toBe("first line that wraps\nlast")
    expect(composer.input.cursorOffset).toBe(0)

    composer.input.gotoBufferEnd()
    composer.input.cursorOffset--
    expect(composer.historyNext()).toBe("cursor_moved")
    expect(composer.input.cursorOffset).toBe(composer.input.plainText.length)

    composer.input.setSelection(0, 5)
    expect(composer.historyPrevious()).toBe("cursor_moved")
    expect(composer.input.plainText).toBe("first line that wraps\nlast")
  } finally {
    composer.destroy()
    if (!setup.renderer.isDestroyed) setup.renderer.destroy()
  }
})

test("composer history admits at most the coding-agent history bound", async () => {
  const setup = await createTestRenderer({ width: 40, height: 8, useThread: false })
  const history = fakeHistory(Array.from({ length: 101 }, (_, index) => `entry-${index}`))
  const composer = createComposer(setup.renderer, {
    geometry: composerGeometry(40, 8),
    slots: { topLeft: "/work", topRight: [] },
    theme: defaultTheme,
    historySource: history,
    onSubmit() {}
  })
  setup.renderer.root.add(composer.root)

  try {
    composer.replaceText("", 0)
    let recalled = 0
    while (composer.historyPrevious() === "history_changed") recalled++
    expect(recalled).toBe(100)
    expect(composer.input.plainText).toBe("entry-1")
  } finally {
    composer.destroy()
    if (!setup.renderer.isDestroyed) setup.renderer.destroy()
  }
})

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

function fakeHistory(texts: readonly string[]): ComposerHistorySource & { append(text: string): void } {
  const entries: ComposerHistoryEntry[] = texts.map((text, index) => ({ entryId: `entry-${index}`, text }))
  return {
    latest: () => entries.at(-1),
    older(entryId) {
      const index = entries.findIndex(entry => entry.entryId === entryId)
      return index > 0 ? entries[index - 1] : undefined
    },
    append(text) {
      entries.push({ entryId: `entry-${entries.length}`, text })
    }
  }
}

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
