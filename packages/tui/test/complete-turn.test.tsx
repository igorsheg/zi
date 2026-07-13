import { expect, test } from "bun:test"
import { mkdtemp, readFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { createAgentRuntime } from "@openzi/coding-agent"
import {
  createModels,
  fauxAssistantMessage,
  fauxProvider,
  fauxText,
  fauxToolCall,
} from "@openzi/coding-agent/testing"
import { type TextareaRenderable } from "@opentui/core"
import { testRender } from "@opentui/react/test-utils"
import { act } from "react"
import { App } from "../src/app.js"

test("the OpenTUI prompt drives a complete tool turn", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "openzi-tui-turn-"))
  const models = createModels()
  const faux = fauxProvider({ tokensPerSecond: 10_000 })
  models.setProvider(faux.provider)
  faux.setResponses([
    fauxAssistantMessage(fauxToolCall("write", { path: "answer.txt", content: "42\n" }, { id: "write-1" }), {
      stopReason: "toolUse",
    }),
    fauxAssistantMessage([fauxText("Wrote answer.txt with 42.")]),
  ])
  const { session } = await createAgentRuntime({
    cwd,
    model: "faux/faux-1",
    models,
    sessionDir: join(cwd, "sessions"),
  })
  const setup = await testRender(<App cwd={cwd} session={session} />, { width: 80, height: 24 })

  try {
    await setup.renderOnce()
    const input = setup.renderer.root.findDescendantById("prompt-input") as TextareaRenderable
    await act(async () => {
      input.setText("Write 42 to answer.txt")
      input.submit()
      await session.waitForIdle()
    })
    await setup.renderOnce()

    expect(await readFile(join(cwd, "answer.txt"), "utf8")).toBe("42\n")
    expect(setup.captureCharFrame()).toContain("Wrote answer.txt with 42.")
    expect(session.sessionManager.file).toBeDefined()
  } finally {
    session.dispose()
    act(() => setup.renderer.destroy())
  }
})
