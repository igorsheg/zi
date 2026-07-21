import { expect, test } from "bun:test"
import { mkdir, mkdtemp, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { TextareaRenderable } from "@opentui/core"
import { createModels, createTestAgentRuntime as createAgentRuntime, fauxProvider } from "@openzi/coding-agent/testing"

import {
  captureFileCompletionInput,
  maxFileCompletionContextCells,
  parseFileCompletionContext
} from "../../src/interactive/prompt/file-completion.js"
import { createInteractiveTest, renderSettled, type InteractiveTestSetup } from "./harness.js"

test("interactive @ completion uses the below-composer picker and distinguishes directory continuation from files", async () => {
  const root = await mkdtemp(join(tmpdir(), "openzi-interactive-files-"))
  const cwd = join(root, "project")
  await mkdir(join(cwd, "src"), { recursive: true })
  await writeFile(join(cwd, "src", "index.ts"), "export {}")
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  const { session } = await createAgentRuntime({ cwd, models, persist: false })
  const setup = await createInteractiveTest(session, { width: 60, height: 12 })

  try {
    const input = setup.renderer.root.findDescendantById("prompt-input")
    if (!(input instanceof TextareaRenderable)) throw new Error("Prompt textarea not found")

    await setup.mockInput.typeText("@s")
    await waitForFrame(setup, "@src/")
    expect(setup.renderer.root.findDescendantById("picker-stack")).toBeDefined()
    expect(input.focused).toBe(true)

    setup.mockInput.pressEnter()
    expect(input.plainText).toBe("@src/")
    await waitForFrame(setup, "@src/index.ts")
    setup.mockInput.pressTab()
    expect(input.plainText).toBe("@src/index.ts ")
    expect(session.messages).toEqual([])

    input.setText("@sr")
    input.cursorOffset = 3
    await waitForFrame(setup, "@src/")
    setup.mockInput.pressEscape()
    expect(input.plainText).toBe("@sr")
    expect(input.cursorOffset).toBe(3)
    expect(input.focused).toBe(true)

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
