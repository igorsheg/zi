import { expect, test } from "bun:test"
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join, resolve } from "node:path"

import { TextareaRenderable } from "@opentui/core"
import {
  createModels,
  createTestAgentRuntime,
  fauxAssistantMessage,
  fauxProvider,
  fauxText,
  fauxToolCall
} from "@with-zi/coding-agent/testing"

import { createInteractiveTest, renderSettled } from "./harness.js"

test("interactive mode presents extension tools through the generic tool frame", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-interactive-extension-tool-"))
  const cwd = join(root, "project")
  const agentDir = join(root, "agent")
  const extensionDir = join(agentDir, "extensions", "generic-tool")
  await mkdir(cwd, { recursive: true })
  await mkdir(extensionDir, { recursive: true })
  await writeFile(
    join(extensionDir, "index.ts"),
    `import { Schema, type ExtensionAPI } from "@with-zi/extension-api"
export default function (zi: ExtensionAPI): void {
  zi.registerTool({
    name: "repository_echo",
    description: "Echo a repository value",
    parameters: Schema.object({ value: Schema.string() }),
    execute: ({ value }) => "generic:" + value
  })
}
`
  )
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  faux.setResponses([
    fauxAssistantMessage(fauxToolCall("repository_echo", { value: "visible" }, { id: "generic-tool-1" }), {
      stopReason: "toolUse"
    }),
    fauxAssistantMessage(fauxText("Finished."))
  ])
  const cli = resolve(import.meta.dirname, "../../../cli/src/main.ts")
  const runtime = await createTestAgentRuntime({
    cwd,
    agentDir,
    model: "faux/faux-1",
    models,
    extensionWorkerCommand: [process.execPath, cli]
  })
  const setup = await createInteractiveTest(runtime.session, { width: 72, height: 18, kittyKeyboard: true })

  try {
    const input = setup.renderer.root.findDescendantById("prompt-input")
    if (!(input instanceof TextareaRenderable)) throw new Error("Prompt textarea not found")
    input.setText("Use the extension tool")
    input.gotoBufferEnd()
    setup.mockInput.pressEnter()
    await runtime.session.waitForIdle()
    await renderSettled(setup)

    const frame = setup.captureCharFrame()
    expect(frame).toContain("Tool repository_echo")
    expect(frame).toContain('"value": "visible"')
    expect(frame).toContain("generic:visible")
    expect(frame).toContain("Finished.")
  } finally {
    setup.destroy()
    runtime.session.dispose()
    await runtime.session.waitForIdle()
    await rm(root, { recursive: true, force: true })
  }
}, 10_000)

test("interactive mode presents source-attributed extension failures", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-interactive-extension-failure-"))
  const cwd = join(root, "project")
  const agentDir = join(root, "agent")
  const extensionDir = join(agentDir, "extensions")
  await mkdir(cwd, { recursive: true })
  await mkdir(extensionDir, { recursive: true })
  await writeFile(
    join(extensionDir, "failed.ts"),
    `export default function (): never { throw new Error("factory failed") }\n`
  )
  const cli = resolve(import.meta.dirname, "../../../cli/src/main.ts")
  const runtime = await createTestAgentRuntime({
    cwd,
    agentDir,
    models: createModels(),
    extensionWorkerCommand: [process.execPath, cli]
  })
  const setup = await createInteractiveTest(runtime.session, { width: 72, height: 12, kittyKeyboard: true })

  try {
    await renderSettled(setup)
    const frame = setup.captureCharFrame()
    expect(frame).toContain("Extension")
    expect(frame).toContain("failed.ts: factory failed")
    expect(frame).toContain("System ❰❰")
  } finally {
    setup.destroy()
    runtime.session.dispose()
    await runtime.session.waitForIdle()
    await rm(root, { recursive: true, force: true })
  }
}, 10_000)
