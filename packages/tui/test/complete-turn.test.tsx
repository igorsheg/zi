import { expect, test } from "bun:test"
import { mkdtemp, readFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { TextareaRenderable } from "@opentui/core"
import { testRender } from "@opentui/react/test-utils"
import { createAgentRuntime } from "@openzi/coding-agent"
import {
  createModels,
  fauxAssistantMessage,
  fauxProvider,
  fauxText,
  fauxThinking,
  fauxToolCall
} from "@openzi/coding-agent/testing"
import { act } from "react"

import { App } from "../src/app.js"

test("the OpenTUI prompt drives a complete tool turn", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "openzi-tui-turn-"))
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
  const setup = await testRender(<App session={session} onExit={() => {}} />, { width: 80, height: 24 })

  try {
    await setup.renderOnce()
    const input = setup.renderer.root.findDescendantById("prompt-input")
    if (!(input instanceof TextareaRenderable)) throw new Error("Prompt textarea not found")
    await act(async () => {
      input.setText("Write 42 to answer.txt\nUse the write tool.")
      input.submit()
      await new Promise(resolve => setTimeout(resolve, 1))
      await setup.renderOnce()
    })
    expect(session.isStreaming).toBe(true)
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("Working…")
    await act(async () => session.waitForIdle())
    await setup.renderOnce()

    expect(await readFile(join(cwd, "answer.txt"), "utf8")).toBe("42\n")
    const frame = setup.captureCharFrame()
    expect(frame).toContain("Write 42 to answer.txt")
    expect(frame).toContain("Use the write tool.")
    expect(frame).toContain("╭───")
    expect(frame).toContain("╰───")
    expect(frame).toContain("Checking the result.")
    expect(frame).toContain("Done")
    expect(frame).toContain("Wrote answer.txt with 42.")
    expect(frame).not.toContain("## Done")
    const spans = setup.captureSpans().lines.flatMap(line => line.spans)
    expect(spans.find(span => span.text === "42")?.fg.toInts()).toEqual([122, 168, 159, 255])
    expect(session.sessionManager.file).toBeDefined()

    act(() => {
      input.setText("next question")
      setup.resize(40, 3)
    })
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("next question")
  } finally {
    session.dispose()
    act(() => setup.renderer.destroy())
  }
})
