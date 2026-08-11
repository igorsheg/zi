import { expect, test } from "bun:test"

import { createTestRenderer } from "@opentui/core/testing"

import { promptTextWidth } from "../src/components/cell-text.js"
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

test("composer cursor does not blink", async () => {
  const setup = await createTestRenderer({ width: 60, height: 8, useThread: false })
  const composer = createComposer(setup.renderer, {
    geometry: composerGeometry(60, 8),
    slots: { topRight: [], bottomRight: "/work" },
    theme: defaultTheme,
    onSubmit() {}
  })

  try {
    expect(composer.input.cursorStyle).toEqual({ style: "block", blinking: false })
  } finally {
    composer.destroy()
    if (!setup.renderer.isDestroyed) setup.renderer.destroy()
  }
})

test("composer clears its draft as one undo point and restores owned markers plus prior history", async () => {
  const setup = await createTestRenderer({ width: 60, height: 8, useThread: false })
  const paste = "x".repeat(compactPasteCharacterThreshold + 1)
  const image = { type: "image" as const, mimeType: "image/png", data: "AAAA" }
  const imageChanges: unknown[][] = []
  const composer = createComposer(setup.renderer, {
    geometry: composerGeometry(60, 8),
    slots: { topRight: [], bottomRight: "/work" },
    theme: defaultTheme,
    onSubmit() {},
    onImageMarkersChange: images => imageChanges.push([...images])
  })
  setup.renderer.root.add(composer.root)

  try {
    composer.input.insertText("a")
    composer.input.insertText("b")
    composer.insertPastedText(paste)
    composer.syncImageMarkers([image])
    const draft = composer.input.plainText
    const markerPayloads = composer.input.extmarks.getAll().map(marker => marker.data)
    composer.input.setSelection(0, 2)

    expect(composer.clearDraft()).toBe(true)
    expect(composer.clearDraft()).toBe(false)
    await Bun.sleep(0)
    expect(composer.input.plainText).toBe("")
    expect(composer.input.getSelection()).toBeNull()
    expect(composer.input.extmarks.getAll()).toEqual([])
    expect(imageChanges.at(-1)).toEqual([])

    composer.input.undo()
    await Bun.sleep(0)
    expect(composer.input.plainText).toBe(draft)
    expect(composer.expandedText()).toBe(`ab${paste}`)
    expect(composer.input.extmarks.getAll()[0]!.data).toBe(markerPayloads[0])
    expect(composer.input.extmarks.getAll()[1]!.data).toBe(markerPayloads[1])
    expect(composer.activeImages()[0]).toBe(image)
    expect(imageChanges.at(-1)).toEqual([image])

    composer.input.redo()
    expect(composer.input.plainText).toBe("")
    composer.input.undo()
    expect(composer.input.plainText).toBe(draft)
    composer.input.undo()
    expect(composer.input.plainText).toBe("ab[paste #1 1001 chars]")
    composer.input.undo()
    expect(composer.input.plainText).toBe("ab")
    composer.input.undo()
    expect(composer.input.plainText).toBe("a")
  } finally {
    composer.destroy()
    if (!setup.renderer.isDestroyed) setup.renderer.destroy()
  }
})

test("composer clears and restores an image-only draft", async () => {
  const setup = await createTestRenderer({ width: 60, height: 8, useThread: false })
  const image = { type: "image" as const, mimeType: "image/png", data: "AAAA" }
  const composer = createComposer(setup.renderer, {
    geometry: composerGeometry(60, 8),
    slots: { topRight: [], bottomRight: "/work" },
    theme: defaultTheme,
    onSubmit() {}
  })
  setup.renderer.root.add(composer.root)

  try {
    composer.syncImageMarkers([image])
    expect(composer.clearDraft()).toBe(true)
    composer.input.undo()
    await Bun.sleep(0)
    expect(composer.input.plainText).toBe("[image #1] ")
    expect(composer.activeImages()).toEqual([image])
  } finally {
    composer.destroy()
    if (!setup.renderer.isDestroyed) setup.renderer.destroy()
  }
})

test("composer range replacement is one undo point and preserves prior native history", async () => {
  const setup = await createTestRenderer({ width: 60, height: 8, useThread: false })
  const composer = createComposer(setup.renderer, {
    geometry: composerGeometry(60, 8),
    slots: { topRight: [], bottomRight: "/work" },
    theme: defaultTheme,
    onSubmit() {}
  })
  setup.renderer.root.add(composer.root)

  try {
    composer.input.insertText("prefix @sr suffix")
    const start = promptTextWidth("prefix ")
    const end = promptTextWidth("prefix @sr")
    expect(
      composer.replaceRange({
        startOffset: start,
        endOffset: end,
        replacement: "@src/index.ts",
        cursorOffset: promptTextWidth("prefix @src/index.ts")
      })
    ).toBe("applied")
    expect(composer.input.plainText).toBe("prefix @src/index.ts suffix")
    expect(composer.input.cursorOffset).toBe(promptTextWidth("prefix @src/index.ts"))

    composer.input.undo()
    expect(composer.input.plainText).toBe("prefix @sr suffix")
    composer.input.redo()
    expect(composer.input.plainText).toBe("prefix @src/index.ts suffix")
    composer.input.undo()
    composer.input.undo()
    expect(composer.input.plainText).toBe("")
  } finally {
    composer.destroy()
    if (!setup.renderer.isDestroyed) setup.renderer.destroy()
  }
})

test("composer range replacement shifts owned markers and preserves payload identity through undo and redo", async () => {
  const setup = await createTestRenderer({ width: 80, height: 8, useThread: false })
  const paste = "x".repeat(compactPasteCharacterThreshold + 1)
  const image = { type: "image" as const, mimeType: "image/png", data: "AAAA" }
  const composer = createComposer(setup.renderer, {
    geometry: composerGeometry(80, 8),
    slots: { topRight: [], bottomRight: "/work" },
    theme: defaultTheme,
    onSubmit() {}
  })
  setup.renderer.root.add(composer.root)

  try {
    composer.insertPastedText(paste)
    composer.input.insertText(" @sr ")
    composer.syncImageMarkers([image])
    const before = composer.input.extmarks.getAll()
    const payloads = before.map(marker => marker.data)
    const imageStart = before[1]!.start
    const tokenStart = promptTextWidth("[paste #1 1001 chars] ")
    const tokenEnd = tokenStart + promptTextWidth("@sr")

    expect(
      composer.replaceRange({
        startOffset: tokenStart,
        endOffset: tokenEnd,
        replacement: "@src/index.ts",
        cursorOffset: tokenStart + promptTextWidth("@src/index.ts")
      })
    ).toBe("applied")
    const completed = composer.input.extmarks.getAll()
    expect(completed.map(marker => marker.data)).toEqual(payloads)
    expect(completed[0]!.data).toBe(payloads[0])
    expect(completed[1]!.data).toBe(payloads[1])
    expect(completed.find(marker => marker.data === payloads[1])!.start).toBe(
      imageStart + promptTextWidth("@src/index.ts") - promptTextWidth("@sr")
    )
    expect(composer.expandedText()).toBe(`${paste} @src/index.ts `)
    expect(composer.activeImages()[0]).toBe(image)

    composer.input.undo()
    expect(composer.input.plainText).toContain("@sr")
    expect(composer.input.extmarks.getAll()[0]!.data).toBe(payloads[0])
    expect(composer.activeImages()[0]).toBe(image)
    composer.input.redo()
    expect(composer.input.plainText).toContain("@src/index.ts")
    expect(composer.input.extmarks.getAll()[1]!.data).toBe(payloads[1])
  } finally {
    composer.destroy()
    if (!setup.renderer.isDestroyed) setup.renderer.destroy()
  }
})

test("composer range replacement refuses marker overlap without changing selection or text", async () => {
  const setup = await createTestRenderer({ width: 60, height: 8, useThread: false })
  const composer = createComposer(setup.renderer, {
    geometry: composerGeometry(60, 8),
    slots: { topRight: [], bottomRight: "/work" },
    theme: defaultTheme,
    onSubmit() {}
  })
  setup.renderer.root.add(composer.root)

  try {
    composer.insertPastedText("x".repeat(compactPasteCharacterThreshold + 1))
    const text = composer.input.plainText
    composer.input.setSelection(0, 3)
    expect(composer.replaceRange({ startOffset: 1, endOffset: 3, replacement: "x", cursorOffset: 2 })).toBe(
      "unavailable"
    )
    expect(composer.input.plainText).toBe(text)
    expect(composer.input.getSelection()).toEqual({ start: 0, end: 3 })
  } finally {
    composer.destroy()
    if (!setup.renderer.isDestroyed) setup.renderer.destroy()
  }
})

test("composer owned range replacements do not consume OpenTUI replacement registry slots", async () => {
  const setup = await createTestRenderer({ width: 40, height: 8, useThread: false })
  const composer = createComposer(setup.renderer, {
    geometry: composerGeometry(40, 8),
    slots: { topRight: [], bottomRight: "/work" },
    theme: defaultTheme,
    onSubmit() {}
  })
  setup.renderer.root.add(composer.root)

  try {
    composer.replaceText("@x", 2)
    const retainedBefore: unknown = Reflect.get(composer.input.editBuffer, "_textBytes")
    const countBefore = Array.isArray(retainedBefore) ? retainedBefore.length : -1
    for (let index = 0; index < 300; index++) {
      expect(
        composer.replaceRange({
          startOffset: 0,
          endOffset: 2,
          replacement: index % 2 === 0 ? "@y" : "@x",
          cursorOffset: 2
        })
      ).toBe("applied")
    }
    const retainedAfter: unknown = Reflect.get(composer.input.editBuffer, "_textBytes")
    expect(Array.isArray(retainedAfter) ? retainedAfter.length : -1).toBe(countBefore)
  } finally {
    composer.destroy()
    if (!setup.renderer.isDestroyed) setup.renderer.destroy()
  }
})

test("composer history traverses stable entries and restores the native draft", async () => {
  const setup = await createTestRenderer({ width: 40, height: 8, useThread: false })
  const history = fakeHistory(["oldest", "middle", "newest"])
  let changes = 0
  const composer = createComposer(setup.renderer, {
    geometry: composerGeometry(40, 8),
    slots: { topRight: [], bottomRight: "/work" },
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
    expect(composer.historyPrevious()).toBe("history_boundary")
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
    expect(composer.historyNext()).toBe("cursor_boundary")
    expect(composer.historyNext()).toBe("history_boundary")
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
    slots: { topRight: [], bottomRight: "/work" },
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
    slots: { topRight: [], bottomRight: "/work" },
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
      expect(composer.historyPrevious()).toBe("history_boundary")
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
    slots: { topRight: [], bottomRight: "/work" },
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
    slots: { topRight: [], bottomRight: "/work" },
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
    slots: { topRight: [], bottomRight: "/work" },
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
    slots: { topRight: [], bottomRight: "/work" },
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
    slots: { topRight: [], bottomRight: "/work" },
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
    slots: { topRight: [], bottomRight: "" },
    theme: defaultTheme,
    historySource: fakeHistory(["界"]),
    onSubmit() {}
  })
  setup.renderer.root.add(composer.root)

  try {
    await setup.renderOnce()
    composer.replaceText("first line that wraps\nlast", 0)
    composer.input.gotoBufferEnd()
    const endOffset = composer.input.cursorOffset
    expect(composer.historyPrevious()).toBe("native_fallthrough")
    expect(composer.input.cursorOffset).toBe(endOffset)
    composer.input.cursorOffset = 1
    expect(composer.input.scrollY + composer.input.visualCursor.visualRow).toBe(0)
    expect(composer.historyPrevious()).toBe("cursor_boundary")
    expect(composer.input.cursorOffset).toBe(0)
    expect(composer.historyPrevious()).toBe("history_changed")
    expect(composer.input.plainText).toBe("界")
    expect(composer.input.cursorOffset).toBe(0)
    expect(composer.historyNext()).toBe("history_changed")
    expect(composer.input.plainText).toBe("first line that wraps\nlast")
    expect(composer.input.cursorOffset).toBe(0)

    composer.input.gotoBufferEnd()
    composer.input.cursorOffset--
    expect(composer.historyNext()).toBe("cursor_boundary")
    expect(composer.input.cursorOffset).toBe(composer.input.plainText.length)

    composer.input.setSelection(0, 5)
    const selection = composer.input.getSelection()
    expect(composer.historyPrevious()).toBe("native_fallthrough")
    expect(composer.input.getSelection()).toEqual(selection)
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
    slots: { topRight: [], bottomRight: "/work" },
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
    slots: { topRight: [], bottomRight: "/work" },
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
    slots: { topRight: [], bottomRight: "/work" },
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
    slots: { topRight: [], bottomRight: "/work" },
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

test("composer reports its current visual row occupancy", async () => {
  const setup = await createTestRenderer({ width: 20, height: 20, useThread: false })
  const geometry = composerGeometry(20, 20)
  const slots = { topRight: [], bottomRight: "" }
  const composer = createComposer(setup.renderer, { geometry, slots, theme: defaultTheme, onSubmit() {} })
  setup.renderer.root.add(composer.root)

  try {
    expect(composer.update(geometry, slots)).toBe(3)

    composer.input.setText("one\ntwo\nthree")
    expect(composer.update(geometry, slots)).toBe(5)

    composer.input.setText("x".repeat(100))
    expect(composer.update(geometry, slots)).toBe(7)
  } finally {
    composer.destroy()
    if (!setup.renderer.isDestroyed) setup.renderer.destroy()
  }
})

test("composer rail places padded metadata on the right edges", async () => {
  const setup = await createTestRenderer({ width: 40, height: 8, useThread: false })
  const geometry = composerGeometry(40, 8)
  const slots = { topRight: ["ctx 15%/247k", "model (high)"], bottomRight: "/workspace/zi" }
  const composer = createComposer(setup.renderer, { geometry, slots, theme: defaultTheme, onSubmit() {} })
  setup.renderer.root.add(composer.root)

  try {
    await setup.waitForVisualIdle()
    const rows = setup.captureCharFrame().split("\n")
    expect(rows[0]).toBe("╭───────── ctx 15%/247k • model (high) ╮")
    expect(rows[2]).toBe("╰─────────────────────── /workspace/zi ╯")
  } finally {
    composer.destroy()
    if (!setup.renderer.isDestroyed) setup.renderer.destroy()
  }
})

test("reapplying the same composer presentation does not schedule another frame", async () => {
  const setup = await createTestRenderer({ width: 40, height: 8, useThread: false })
  const geometry = composerGeometry(40, 8)
  const slots = { topRight: ["ctx 15%/247k", "model (high)"], bottomRight: "/workspace/zi" }
  const composer = createComposer(setup.renderer, { geometry, slots, theme: defaultTheme, onSubmit() {} })
  setup.renderer.root.add(composer.root)

  try {
    await setup.waitForVisualIdle()
    expect(setup.renderer.getSchedulerState().hasScheduledRender).toBe(false)

    composer.update(composerGeometry(40, 8), {
      topRight: ["ctx 15%/247k", "model (high)"],
      bottomRight: "/workspace/zi"
    })

    expect(setup.renderer.getSchedulerState().hasScheduledRender).toBe(false)
  } finally {
    composer.destroy()
    if (!setup.renderer.isDestroyed) setup.renderer.destroy()
  }
})
