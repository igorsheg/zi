import { expect, test } from "bun:test"

import { projectToolPresentation } from "../src/tools/presentation/project.js"

const agent = {
  path: "/root/shutdown-reviewer" as const,
  parentPath: "/root" as const,
  taskName: "shutdown-reviewer",
  agentType: "worker",
  residency: "unloaded" as const,
  turnState: "idle" as const,
  turnNumber: 1,
  settledStatus: "completed" as const
}

const success = { type: "agent_team" as const, outcome: "success" as const }

test("spawn presents the delegated task and durable agent identity without JSON", () => {
  const presentation = projectToolPresentation({
    status: "done",
    name: "spawn_agent",
    args: {
      task_name: "shutdown-reviewer",
      message: "Review AgentTeam shutdown\nand report ownership races.",
      agent_type: "worker"
    },
    result: {
      content: [{ type: "text", text: '{"agent":{"path":"/root/shutdown-reviewer"}}' }],
      details: { ...success, operation: "spawn", agent: { ...agent, residency: "resident", turnState: "running" } }
    }
  })

  expect(presentation.header).toEqual({
    label: "Spawn",
    subject: { type: "text", text: "Shutdown reviewer" },
    details: ["admitted", "type worker", "working", "resident", "/root/shutdown-reviewer"]
  })
  expect(presentation.body).toEqual({
    type: "text",
    text: "Review AgentTeam shutdown\nand report ownership races.",
    tone: "muted"
  })
  expect(presentation.preview.compact).toEqual({ type: "hidden" })
  expect(JSON.stringify(presentation)).not.toContain('"agent"')
})

test("wait presents mailbox activity without completion content", () => {
  const presentation = projectToolPresentation({
    status: "done",
    name: "wait_agent",
    args: { timeout_ms: 30_000 },
    result: {
      content: [{ type: "text", text: '{"message":"Wait completed.","timed_out":false}' }],
      details: { ...success, operation: "wait", activity: "mailbox", timedOut: false }
    }
  })

  expect(presentation.header).toEqual({ label: "Wait", subject: { type: "text", text: "Agent update" }, details: [] })
  expect(presentation.body).toBeUndefined()
  expect(presentation.preview.compact).toEqual({ type: "hidden" })
})

test("wait timeout stays concise", () => {
  const presentation = projectToolPresentation({
    status: "done",
    name: "wait_agent",
    args: { timeout_ms: 100 },
    result: {
      content: [{ type: "text", text: '{"message":"Wait timed out.","timed_out":true}' }],
      details: { ...success, operation: "wait", activity: "timed_out", timedOut: true }
    }
  })

  expect(presentation.header).toEqual({
    label: "Wait",
    subject: { type: "text", text: "No agent updates" },
    details: ["timed out"]
  })
  expect(presentation.body).toBeUndefined()
})

test("list presents bounded semantic agent rows instead of the model JSON envelope", () => {
  const presentation = projectToolPresentation({
    status: "done",
    name: "list_agents",
    args: { path_prefix: "/root" },
    result: {
      content: [{ type: "text", text: '{"agents":[{"path":"/root/shutdown-reviewer"}]}' }],
      details: {
        ...success,
        operation: "list",
        agents: [
          agent,
          {
            ...agent,
            path: "/root/active-worker",
            taskName: "active-worker",
            residency: "resident",
            turnState: "running",
            turnNumber: 2,
            settledStatus: "not_started"
          }
        ]
      }
    }
  })

  expect(presentation.header).toEqual({
    label: "Agents",
    subject: { type: "text", text: "2 agents" },
    details: ["1 working", "1 completed"]
  })
  expect(presentation.body).toEqual({
    type: "text",
    text: "Shutdown reviewer — type worker · completed · unloaded · turn 1 — /root/shutdown-reviewer\nActive worker — type worker · working · resident · turn 2 — /root/active-worker",
    tone: "muted"
  })
  expect(presentation.preview.compact).toEqual({ type: "head", rows: 2 })
  expect(JSON.stringify(presentation)).not.toContain("parentPath")
})

test("message, follow-up, and interruption operations remain header-first", () => {
  const cases = [
    {
      name: "send_message",
      args: { target: agent.path, message: "Include the shutdown timeout." },
      details: { ...success, operation: "send" as const, target: agent.path },
      label: "Send",
      headerDetails: ["delivered", agent.path]
    },
    {
      name: "followup_task",
      args: { target: agent.path, message: "Check restoration too." },
      details: { ...success, operation: "followup" as const, target: agent.path, delivery: "started" as const },
      label: "Follow up",
      headerDetails: ["started turn", agent.path]
    },
    {
      name: "interrupt_agent",
      args: { target: agent.path },
      details: {
        ...success,
        operation: "interrupt" as const,
        target: agent.path,
        previousTurn: "running" as const,
        result: "interrupted" as const
      },
      label: "Interrupt",
      headerDetails: ["interrupted", "was working", agent.path]
    }
  ]

  for (const item of cases) {
    const presentation = projectToolPresentation({
      status: "done",
      name: item.name,
      args: item.args,
      result: { content: [{ type: "text", text: '{"internal":"result"}' }], details: item.details }
    })
    expect(presentation.header).toEqual({
      label: item.label,
      subject: { type: "text", text: "Shutdown reviewer" },
      details: item.headerDetails
    })
    expect(presentation.preview.compact).toEqual({ type: "hidden" })
    expect(JSON.stringify(presentation)).not.toContain("internal")
  }
})

test("all six AgentTeam tools retain semantic headers for partial and malformed results", () => {
  for (const name of ["spawn_agent", "send_message", "followup_task", "wait_agent", "list_agents", "interrupt_agent"]) {
    const partial = projectToolPresentation({ status: "preparing", name, args: {} })
    expect(partial.header.label).not.toBe("Tool")

    const malformed = projectToolPresentation({
      status: "done",
      name,
      args: {},
      result: { content: [{ type: "text", text: "malformed result" }], details: undefined }
    })
    expect(malformed.header.label).not.toBe("Tool")
  }
})
