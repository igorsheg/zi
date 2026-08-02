import { expect, test } from "bun:test"

import { createTestRenderer } from "@opentui/core/testing"
import { projectToolPresentation } from "@with-zi/coding-agent"

import { ToolCallView } from "../../src/interactive/transcript/tool-view.js"
import { defaultTheme } from "../../src/theme.js"

test("wait rows keep completion evidence concise until expanded", async () => {
  const setup = await createTestRenderer({ width: 72, height: 30, useThread: false })
  const name = "shutdown-reviewer"
  const evidence = [
    "Checked interruption ownership.",
    ...Array.from({ length: 12 }, (_, index) => `Evidence ${index + 1}: resource ${index + 1} is released.`),
    "Final evidence: terminal restoration precedes settlement."
  ].join("\n")
  const presentation = projectToolPresentation({
    status: "done",
    name: "wait_subagents",
    args: { names: [name] },
    result: {
      content: [{ type: "text", text: "wait result" }],
      details: {
        type: "subagent",
        outcome: "success",
        operation: "wait",
        agents: [
          {
            name,
            lifecycle: "idle",
            workCycle: 1,
            completion: {
              workCycle: 1,
              status: "completed",
              text: evidence,
              omittedBytes: 0,
              truncated: false,
              durationMs: 4_500
            }
          }
        ]
      }
    }
  })
  const view = new ToolCallView(
    setup.renderer,
    "wait-agent",
    { status: "done", presentation },
    defaultTheme,
    "/work",
    "Ctrl+O"
  )
  setup.renderer.root.add(view.root)

  try {
    await setup.renderOnce()
    const compact = setup.captureCharFrame()
    expect(compact).toContain("◆ Finished waiting Shutdown reviewer")
    expect(compact).toContain("Shutdown reviewer completed · 4.5s")
    expect(compact).not.toContain("Final evidence")

    view.setExpanded(true)
    await setup.renderOnce()
    const expanded = setup.captureCharFrame()
    expect(expanded).toContain("Shutdown reviewer output:")
    expect(expanded).toContain("Final evidence: terminal restoration precedes settlement.")
  } finally {
    view.destroy()
    setup.renderer.destroy()
  }
})
