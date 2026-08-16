import { expect, test } from "bun:test"

import { createTestRenderer } from "@opentui/core/testing"
import { projectToolPresentation } from "@with-zi/coding-agent"

import { ToolCallView } from "../../src/interactive/transcript/tool-view.js"
import { createSyntaxStyle, defaultTheme } from "../../src/theme.js"

const success = { type: "agent_team" as const, outcome: "success" as const }

const agent = {
  path: "/root/durable_probe" as const,
  parentPath: "/root" as const,
  taskName: "durable_probe",
  residency: "unloaded" as const,
  turnState: "idle" as const,
  turnNumber: 1,
  settledStatus: "completed" as const
}

test("AgentTeam rows replace JSON envelopes with semantic terminal presentation", async () => {
  const setup = await createTestRenderer({ width: 88, height: 20, useThread: false })
  const syntaxStyle = createSyntaxStyle(defaultTheme)
  const spawn = projectToolPresentation({
    status: "done",
    name: "spawn_agent",
    args: { task_name: "durable_probe", message: "Remember the durable token." },
    result: {
      content: [{ type: "text", text: '{"agent":{"path":"/root/durable_probe"}}' }],
      details: {
        ...success,
        operation: "spawn",
        agent: { ...agent, residency: "resident", turnState: "running", settledStatus: "not_started" }
      }
    }
  })
  const list = projectToolPresentation({
    status: "done",
    name: "list_agents",
    args: { path_prefix: "/root/durable_probe" },
    result: {
      content: [{ type: "text", text: '{"agents":[{"path":"/root/durable_probe"}]}' }],
      details: { ...success, operation: "list", agents: [agent] }
    }
  })
  const spawnView = new ToolCallView(
    setup.renderer,
    "spawn-agent",
    { status: "done", presentation: spawn },
    defaultTheme,
    syntaxStyle,
    "/work",
    "Ctrl+O"
  )
  const listView = new ToolCallView(
    setup.renderer,
    "list-agents",
    { status: "done", presentation: list },
    defaultTheme,
    syntaxStyle,
    "/work",
    "Ctrl+O"
  )
  setup.renderer.root.add(spawnView.root)
  setup.renderer.root.add(listView.root)

  try {
    await setup.renderOnce()
    const frame = setup.captureCharFrame()
    expect(frame).toContain("◆ Spawn Durable probe · admitted · working · resident · /root/durable_probe")
    expect(frame).toContain("◆ Agents 1 agent · 1 completed")
    expect(frame).toContain("Durable probe — completed · unloaded · turn 1 — /root/durable_probe")
    expect(frame).not.toContain('"agent"')
    expect(frame).not.toContain("Arguments:")
    expect(frame).not.toContain("Result:")
  } finally {
    spawnView.destroy()
    listView.destroy()
    syntaxStyle.destroy()
    setup.renderer.destroy()
  }
})
