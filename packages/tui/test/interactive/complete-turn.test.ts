import { expect, test } from "bun:test"
import { mkdtemp, readFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { TextareaRenderable } from "@opentui/core"
import {
  createModels,
  createTestAgentRuntime as createAgentRuntime,
  fauxAssistantMessage,
  fauxProvider,
  fauxText,
  fauxThinking,
  fauxToolCall
} from "@zi/coding-agent/testing"

import { createInteractiveTest, renderMarkdownSettled } from "./harness.js"

test("the OpenTUI prompt drives a complete tool turn", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-tui-turn-"))
  const models = createModels()
  const faux = fauxProvider({ tokensPerSecond: 50 })
  models.setProvider(faux.provider)
  faux.setResponses([
    fauxAssistantMessage(fauxToolCall("write", { path: "answer.txt", content: "42\n" }, { id: "write-1" }), {
      stopReason: "toolUse"
    }),
    fauxAssistantMessage([fauxThinking("Checking the result."), fauxText("## Done\n\nWrote **answer.txt** with `42`.")])
  ])
  const { session } = await createAgentRuntime({ cwd, model: "faux/faux-1", models, sessionDir: join(cwd, "sessions") })
  const setup = await createInteractiveTest(session, { width: 80, height: 24 })

  try {
    await setup.renderOnce()
    const input = setup.renderer.root.findDescendantById("prompt-input")
    if (!(input instanceof TextareaRenderable)) throw new Error("Prompt textarea not found")
    input.setText("Write 42 to answer.txt\nUse the write tool.")
    input.submit()
    await new Promise(resolve => setTimeout(resolve, 1))
    await setup.renderOnce()
    expect(session.isStreaming).toBe(true)
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("Working…")
    expect(setup.renderer.liveRequestCount).toBeGreaterThan(0)
    await session.waitForIdle()
    await renderMarkdownSettled(setup)
    expect(setup.renderer.liveRequestCount).toBe(0)

    expect(await readFile(join(cwd, "answer.txt"), "utf8")).toBe("42\n")
    const frame = setup.captureCharFrame()
    expect(frame).toContain("Write 42 to answer.txt")
    expect(frame).toContain("Use the write tool.")
    expect(frame).toContain("◆ Write answer.txt · 1 line · 3 bytes")
    expect(frame).not.toContain("│ 1 │ 42")
    expect(frame).not.toContain("╭───")
    expect(frame).toContain("Checking the result.")
    expect(frame).toContain("Done")
    expect(frame).toContain("Wrote answer.txt with 42.")
    expect(frame).not.toContain("## Done")
    const spans = setup.captureSpans().lines.flatMap(line => line.spans)
    expect(spans.filter(span => span.text === "42").map(span => span.fg.toInts())).toContainEqual([122, 168, 159, 255])
    expect(session.sessionManager.file).toBeDefined()

    input.setText("next question")
    setup.resize(40, 3)
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("next question")
  } finally {
    session.dispose()
    setup.destroy()
  }
})

test("Ctrl+G demotes the session-owned foreground shell task", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-tui-background-"))
  const models = createModels()
  const faux = fauxProvider({ tokensPerSecond: 10_000 })
  models.setProvider(faux.provider)
  faux.setResponses([
    fauxAssistantMessage(
      fauxToolCall(
        "bash",
        { command: `node -e "console.log('started'); setTimeout(() => console.log('done'), 1000)"` },
        { id: "bash-background" }
      ),
      { stopReason: "toolUse" }
    ),
    fauxAssistantMessage("The task is running in the background.")
  ])
  const { session } = await createAgentRuntime({ cwd, model: "faux/faux-1", models, persist: false })
  const setup = await createInteractiveTest(session, { width: 80, height: 24 })

  try {
    await setup.renderOnce()
    const input = setup.renderer.root.findDescendantById("prompt-input")
    if (!(input instanceof TextareaRenderable)) throw new Error("Prompt textarea not found")
    input.setText("Start the command.")
    input.submit()
    await waitUntil(() => session.shellTasks.some(task => task.type === "foreground"))
    await setup.renderOnce()
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("Ctrl+G background")

    setup.mockInput.pressKey("g", { ctrl: true })
    await waitUntil(() => session.shellTasks.some(task => task.type === "background"))
    await session.waitForIdle()
    await waitUntil(() => session.shellTasks.some(task => task.type === "completed"))

    expect(session.shellTasks).toHaveLength(1)
    expect(session.shellTasks[0]).toMatchObject({ type: "completed", outcome: { type: "exited", exitCode: 0 } })
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("background · task")
  } finally {
    session.dispose()
    setup.destroy()
  }
})

async function waitUntil(condition: () => boolean): Promise<void> {
  for (let attempt = 0; attempt < 200; attempt++) {
    if (condition()) return
    // Polling delays are sequential by definition.
    // oxlint-disable-next-line no-await-in-loop
    await Bun.sleep(10)
  }
  throw new Error("Condition was not reached")
}
