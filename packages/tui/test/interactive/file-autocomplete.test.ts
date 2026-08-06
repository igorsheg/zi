import { expect, test } from "bun:test"
import { mkdir, mkdtemp, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { BoxRenderable, TextareaRenderable } from "@opentui/core"
import { createModels, createTestAgentRuntime as createAgentRuntime, fauxProvider } from "@with-zi/coding-agent/testing"

import { promptTextWidth } from "../../src/components/cell-text.js"
import {
  captureFileCompletionInput,
  maxFileCompletionContextCells,
  parseFileCompletionContext
} from "../../src/interactive/prompt/file-completion.js"
import { promptCompletionPickerHeight } from "../../src/interactive/prompt/frames.js"
import { transcriptStatusRows } from "../../src/interactive/transcript/status-view.js"
import { createInteractiveTest, renderSettled, type InteractiveTestSetup } from "./harness.js"

test("interactive @ completion uses the below-composer picker and distinguishes directory continuation from files", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-interactive-files-"))
  const cwd = join(root, "project")
  await mkdir(join(cwd, "src"), { recursive: true })
  await writeFile(join(cwd, "src", "index.ts"), "export {}")
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  const { session } = await createAgentRuntime({ cwd, models, session: { type: "new", persist: false } })
  const setup = await createInteractiveTest(session, { width: 60, height: 12 })

  try {
    const input = setup.renderer.root.findDescendantById("prompt-input")
    if (!(input instanceof TextareaRenderable)) throw new Error("Prompt textarea not found")

    await setup.mockInput.typeText("@s")
    await waitForFrame(setup, "@src/")
    const pickerStack = setup.renderer.root.findDescendantById("picker-stack")
    const pickerList = setup.renderer.root.findDescendantById("picker-list")
    if (!(pickerStack instanceof BoxRenderable) || !(pickerList instanceof BoxRenderable)) {
      throw new Error("File picker not found")
    }
    expect(pickerStack.visible).toBe(true)
    expect(pickerList.height).toBe(promptCompletionPickerHeight - transcriptStatusRows)
    expect(input.focused).toBe(true)

    await setup.mockInput.typeText("r")
    await renderSettled(setup)
    expect(pickerStack.visible).toBe(true)
    expect(pickerList.height).toBe(promptCompletionPickerHeight - transcriptStatusRows)
    await waitForFrame(setup, "@src/")

    setup.mockInput.pressEnter()
    expect(input.plainText).toBe("@src/")
    await renderSettled(setup)
    expect(pickerStack.visible).toBe(true)
    await waitForFrame(setup, "@src/index.ts")
    setup.mockInput.pressTab()
    expect(input.plainText).toBe("@src/index.ts ")
    expect(session.messages).toEqual([])

    input.setText("@src/index.t")
    input.cursorOffset = promptTextWidth("@src/index.t")
    await waitForFrame(setup, "@src/index.ts")
    await setup.mockInput.typeText("s")
    await waitForPickerHidden(setup, pickerStack)

    input.setText("@sr")
    input.cursorOffset = 3
    await waitForFrame(setup, "@src/")
    setup.mockInput.pressEscape()
    await Bun.sleep(30)
    await renderSettled(setup)
    expect(input.plainText).toBe("@sr")
    expect(input.cursorOffset).toBe(3)
    expect(input.focused).toBe(true)
    expect(pickerStack.visible).toBe(false)

    await setup.mockInput.typeText("c")
    await Bun.sleep(30)
    await renderSettled(setup)
    expect(input.plainText).toBe("@src")
    expect(pickerStack.visible).toBe(false)
    await setup.mockInput.typeText(" ")
    await renderSettled(setup)
    expect(pickerStack.visible).toBe(false)
    await setup.mockInput.typeText("@i")
    await waitForFrame(setup, "@src/index.ts")

    const largeDraft = "x".repeat(1024 * 1024)
    input.setText(largeDraft)
    input.cursorOffset = 0
    const captured = captureFileCompletionInput(input)
    expect(captured.beforeCursor).toBe("")
    expect(captured.afterCursor.length).toBeLessThanOrEqual(maxFileCompletionContextCells)
    expect(parseFileCompletionContext(captured)).toBeUndefined()
  } finally {
    session.dispose()
    setup.destroy()
  }
})

async function waitForPickerHidden(setup: InteractiveTestSetup, picker: BoxRenderable): Promise<void> {
  for (let attempt = 0; attempt < 40; attempt++) {
    // Renderer and debounce settlement are intentionally observed in sequence.
    // oxlint-disable-next-line no-await-in-loop
    await Bun.sleep(10)
    // oxlint-disable-next-line no-await-in-loop
    await renderSettled(setup)
    if (!picker.visible) return
  }
  throw new Error("File picker never closed")
}

async function waitForFrame(setup: InteractiveTestSetup, text: string): Promise<void> {
  for (let attempt = 0; attempt < 40; attempt++) {
    // Renderer and debounce settlement are intentionally observed in sequence.
    // oxlint-disable-next-line no-await-in-loop
    await Bun.sleep(10)
    // oxlint-disable-next-line no-await-in-loop
    await renderSettled(setup)
    if (setup.captureCharFrame().includes(text)) return
  }
  throw new Error(`Picker never rendered ${text}`)
}
