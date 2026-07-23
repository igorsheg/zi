import { expect, test } from "bun:test"

import { type CliRenderer, TextRenderable } from "@opentui/core"
import { createTestRenderer } from "@opentui/core/testing"

import type { ClipboardWriter, ClipboardWriteResult } from "../../src/interactive/clipboard.js"
import { InteractiveKeybindings } from "../../src/interactive/interactive-keybindings.js"
import { SelectionCopyController } from "../../src/interactive/selection-copy.js"

test("selection is copied only on the semantic key and clears after confirmed delivery", async () => {
  const setup = await createTestRenderer({ width: 30, height: 5, useThread: false, kittyKeyboard: true })
  const text = new TextRenderable(setup.renderer, { content: "copy target" })
  setup.renderer.root.add(text)
  await setup.renderOnce()

  const completion = deferred<ClipboardWriteResult>()
  const writes: string[] = []
  const writer: ClipboardWriter = {
    write(value) {
      writes.push(value)
      return completion.promise
    }
  }
  let consumed = 0
  const warnings: string[] = []
  const controller = new SelectionCopyController(
    setup.renderer,
    new InteractiveKeybindings({ "app.selection.copy": ["super+c"] }),
    writer,
    () => consumed++,
    () => {},
    message => warnings.push(message)
  )

  try {
    select(setup.renderer, text, 0, 4)
    expect(setup.renderer.getSelection()?.getSelectedText()).toBe("copy")
    expect(writes).toEqual([])

    setup.mockInput.pressKey("c", { super: true })
    expect(writes).toEqual(["copy"])
    expect(consumed).toBe(1)
    expect(setup.renderer.hasSelection).toBe(true)

    completion.resolve({ type: "copied", route: "osc52" })
    await Promise.resolve()
    expect(setup.renderer.hasSelection).toBe(false)
    expect(warnings).toEqual([])
  } finally {
    controller.dispose()
    setup.renderer.destroy()
  }
})

test("disposing selection copy aborts its write and rejects late completion", async () => {
  const setup = await createTestRenderer({ width: 30, height: 5, useThread: false, kittyKeyboard: true })
  const text = new TextRenderable(setup.renderer, { content: "keep selected" })
  setup.renderer.root.add(text)
  await setup.renderOnce()

  const completion = deferred<ClipboardWriteResult>()
  let signal: AbortSignal | undefined
  const writer: ClipboardWriter = {
    write(_value, currentSignal) {
      signal = currentSignal
      return completion.promise
    }
  }
  const warnings: string[] = []
  const controller = new SelectionCopyController(
    setup.renderer,
    new InteractiveKeybindings(),
    writer,
    () => {},
    () => {},
    message => warnings.push(message)
  )

  try {
    select(setup.renderer, text, 0, 4)
    setup.mockInput.pressCtrlC()
    controller.dispose()
    expect(signal?.aborted).toBe(true)

    completion.resolve({ type: "copied", route: "native" })
    await Promise.resolve()
    expect(setup.renderer.getSelection()?.getSelectedText()).toBe("keep")
    expect(warnings).toEqual([])
  } finally {
    controller.dispose()
    setup.renderer.destroy()
  }
})

test("a stale clipboard completion cannot clear a newer selection", async () => {
  const setup = await createTestRenderer({ width: 30, height: 5, useThread: false, kittyKeyboard: true })
  const text = new TextRenderable(setup.renderer, { content: "first second" })
  setup.renderer.root.add(text)
  await setup.renderOnce()

  const completions = [deferred<ClipboardWriteResult>(), deferred<ClipboardWriteResult>()]
  const signals: AbortSignal[] = []
  const writer: ClipboardWriter = {
    write(_value, signal) {
      signals.push(signal)
      return completions[signals.length - 1]!.promise
    }
  }
  const controller = new SelectionCopyController(
    setup.renderer,
    new InteractiveKeybindings(),
    writer,
    () => {},
    () => {},
    () => {}
  )

  try {
    select(setup.renderer, text, 0, 5)
    setup.mockInput.pressCtrlC()
    select(setup.renderer, text, 6, 12)
    setup.mockInput.pressCtrlC()

    expect(signals).toHaveLength(2)
    expect(signals[0]?.aborted).toBe(true)
    expect(setup.renderer.getSelection()?.getSelectedText()).toBe("second")

    completions[0]!.resolve({ type: "copied", route: "native" })
    await Promise.resolve()
    expect(setup.renderer.getSelection()?.getSelectedText()).toBe("second")

    completions[1]!.resolve({ type: "copied", route: "native" })
    await Promise.resolve()
    expect(setup.renderer.hasSelection).toBe(false)
  } finally {
    controller.dispose()
    setup.renderer.destroy()
  }
})

function select(renderer: CliRenderer, text: TextRenderable, start: number, end: number): void {
  renderer.startSelection(text, text.x + start, text.y)
  renderer.updateSelection(text, text.x + end, text.y, { finishDragging: true })
}

function deferred<T>(): { readonly promise: Promise<T>; resolve(value: T): void } {
  let resolve!: (value: T) => void
  const promise = new Promise<T>(finish => {
    resolve = finish
  })
  return { promise, resolve }
}
