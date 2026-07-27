import { expect, test } from "bun:test"
import { mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { TextareaRenderable } from "@opentui/core"
import { createModels, createTestAgentSessionRuntime } from "@with-zi/coding-agent/testing"

import { createInteractiveRuntimeTest, renderSettled, type InteractiveTestSetup } from "./harness.js"

test("interactive project trust safely defaults to exclusion and can remember admission", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-interactive-project-trust-"))
  const cwd = join(root, "project")
  const agentDir = join(root, "global")
  await mkdir(join(cwd, ".zi"), { recursive: true })
  await writeFile(join(cwd, ".zi", "settings.json"), JSON.stringify({ steeringMode: "all" }))
  const runtime = await createTestAgentSessionRuntime({ cwd, agentDir, models: createModels() })
  const excluded = runtime.session
  const setup = await createInteractiveRuntimeTest(runtime, { width: 76, height: 18, kittyKeyboard: true })

  try {
    const frame = await waitForFrame(setup, "Project trust")
    expect(frame).toContain("Do not trust (this session)")
    expect(frame).toContain("Trust and remember")
    expect(runtime.projectTrust.type).toBe("unresolved")
    expect(runtime.session.steeringMode).toBe("one-at-a-time")
    expect(promptInput(setup).focused).toBe(true)

    setup.mockInput.pressArrow("down")
    setup.mockInput.pressArrow("down")
    setup.mockInput.pressEnter()
    await waitUntil(() => runtime.projectTrust.type === "trusted")
    await renderSettled(setup)

    expect(runtime.projectTrust).toMatchObject({ type: "trusted", source: "interactive" })
    expect(runtime.session.steeringMode).toBe("all")
    expect(setup.mode.store.getSession()).toBe(runtime.session)
    expect(JSON.parse(await readFile(join(agentDir, "trust.json"), "utf8"))).toEqual({
      [runtime.projectTrust.cwd]: true
    })
    expect(() => excluded.prompt("disposed")).toThrow("AgentSession is disposed")
    expect(promptInput(setup).focused).toBe(true)
  } finally {
    setup.destroy()
    runtime.dispose()
    await runtime.waitForIdle()
  }
})

function promptInput(setup: InteractiveTestSetup): TextareaRenderable {
  const input = setup.renderer.root.findDescendantById("prompt-input")
  if (!(input instanceof TextareaRenderable)) throw new Error("Prompt textarea not found")
  return input
}

async function waitUntil(predicate: () => boolean): Promise<void> {
  for (let attempt = 0; attempt < 100; attempt++) {
    if (predicate()) return
    // oxlint-disable-next-line no-await-in-loop
    await Bun.sleep(1)
  }
  throw new Error("Condition was not met")
}

async function waitForFrame(setup: InteractiveTestSetup, expected: string): Promise<string> {
  for (let attempt = 0; attempt < 100; attempt++) {
    // oxlint-disable-next-line no-await-in-loop
    await renderSettled(setup)
    const frame = setup.captureCharFrame()
    if (frame.includes(expected)) return frame
    // oxlint-disable-next-line no-await-in-loop
    await Bun.sleep(1)
  }
  throw new Error(`Frame did not contain ${JSON.stringify(expected)}:\n${setup.captureCharFrame()}`)
}
