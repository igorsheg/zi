import { expect, test } from "bun:test"

import { TextareaRenderable } from "@opentui/core"
import { createModels, createTestAgentRuntime, fauxProvider } from "@with-zi/coding-agent/testing"

import type {
  ExternalEditor,
  ExternalEditorRequest,
  ExternalEditorResult
} from "../../src/interactive/external-editor.js"
import { createInteractiveTest } from "./harness.js"

test("Ctrl+G replaces the draft with content saved by the resolved external editor", async () => {
  const models = createModels()
  models.setProvider(fauxProvider().provider)
  const { session } = await createTestAgentRuntime({
    cwd: "/work",
    models,
    session: { type: "new", persist: false },
    settings: { externalEditor: "code --wait" }
  })
  const editor = new FakeExternalEditor({ type: "complete", content: "edited prompt" })
  const setup = await createInteractiveTest(
    session,
    { width: 56, height: 10, kittyKeyboard: true },
    undefined,
    undefined,
    undefined,
    undefined,
    undefined,
    undefined,
    editor
  )

  try {
    const input = setup.renderer.root.findDescendantById("prompt-input")
    if (!(input instanceof TextareaRenderable)) throw new Error("Prompt textarea not found")
    input.setText("draft prompt")

    setup.mockInput.pressKey("g", { ctrl: true })
    await Promise.resolve()

    expect(editor.requests).toEqual([{ command: "code --wait", content: "draft prompt", cwd: "/work" }])
    expect(input.plainText).toBe("edited prompt")
  } finally {
    setup.destroy()
    session.dispose()
  }
  expect(editor.disposed).toBe(true)
})

test("external editor admission is single-flight and stale completion cannot cross session replacement", async () => {
  const models = createModels()
  models.setProvider(fauxProvider().provider)
  const first = await createTestAgentRuntime({ cwd: "/first", models, session: { type: "new", persist: false } })
  const second = await createTestAgentRuntime({ cwd: "/second", models, session: { type: "new", persist: false } })
  const editor = new DeferredExternalEditor()
  const setup = await createInteractiveTest(
    first.session,
    { width: 56, height: 10, kittyKeyboard: true },
    undefined,
    undefined,
    undefined,
    undefined,
    undefined,
    undefined,
    editor
  )

  try {
    const input = setup.renderer.root.findDescendantById("prompt-input")
    if (!(input instanceof TextareaRenderable)) throw new Error("Prompt textarea not found")
    input.setText("first draft")
    setup.mockInput.pressKey("g", { ctrl: true })
    setup.mockInput.pressKey("g", { ctrl: true })
    expect(editor.requests).toHaveLength(1)

    setup.mode.replaceSession(second.session)
    const replacement = setup.renderer.root.findDescendantById("prompt-input")
    if (!(replacement instanceof TextareaRenderable)) throw new Error("Replacement textarea not found")
    editor.complete({ type: "complete", content: "stale edit" })
    await Promise.resolve()

    expect(replacement.plainText).toBe("")
  } finally {
    setup.destroy()
    first.session.dispose()
    second.session.dispose()
  }
})

test("external editor failure preserves the draft and reports feedback", async () => {
  const models = createModels()
  models.setProvider(fauxProvider().provider)
  const { session } = await createTestAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })
  const editor = new FakeExternalEditor({ type: "failed", message: "editor failed" })
  const setup = await createInteractiveTest(
    session,
    { width: 56, height: 10, kittyKeyboard: true },
    undefined,
    undefined,
    undefined,
    undefined,
    undefined,
    undefined,
    editor
  )

  try {
    const input = setup.renderer.root.findDescendantById("prompt-input")
    if (!(input instanceof TextareaRenderable)) throw new Error("Prompt textarea not found")
    input.setText("keep this")

    setup.mockInput.pressKey("g", { ctrl: true })
    await Promise.resolve()
    await setup.renderOnce()

    expect(input.plainText).toBe("keep this")
    expect(setup.captureCharFrame()).toContain("editor failed")
  } finally {
    setup.destroy()
    session.dispose()
  }
})

class DeferredExternalEditor implements ExternalEditor {
  readonly requests: ExternalEditorRequest[] = []
  disposed = false
  #complete: ((result: ExternalEditorResult) => void) | undefined

  edit(request: ExternalEditorRequest): Promise<ExternalEditorResult> {
    this.requests.push(request)
    return new Promise(resolve => {
      this.#complete = resolve
    })
  }

  complete(result: ExternalEditorResult): void {
    this.#complete?.(result)
  }

  dispose(): void {
    this.disposed = true
  }
}

class FakeExternalEditor implements ExternalEditor {
  readonly requests: ExternalEditorRequest[] = []
  readonly #result: ExternalEditorResult
  disposed = false

  constructor(result: ExternalEditorResult) {
    this.#result = result
  }

  async edit(request: ExternalEditorRequest): Promise<ExternalEditorResult> {
    this.requests.push(request)
    return this.#result
  }

  dispose(): void {
    this.disposed = true
  }
}
