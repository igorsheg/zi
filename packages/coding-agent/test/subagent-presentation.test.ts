import { expect, test } from "bun:test"

import { projectToolPresentation } from "../src/tools/presentation/project.js"

const agent = {
  name: "shutdown-reviewer",
  lifecycle: "idle" as const,
  workCycle: 1,
  completionDelivery: "durable" as const,
  completion: {
    workCycle: 1,
    status: "completed" as const,
    text: "No shutdown leaks found.",
    omittedBytes: 0,
    truncated: false,
    durationMs: 4_500
  }
}

test("spawn presentation leads with the delegated task and keeps machinery in details", () => {
  const presentation = projectToolPresentation({
    status: "done",
    name: "spawn_subagent",
    args: { name: "shutdown-reviewer", prompt: "Review native subagent shutdown\nand report races." },
    result: {
      content: [{ type: "text", text: JSON.stringify({ name: agent.name }) }],
      details: { type: "subagent", outcome: "success", operation: "spawn", agent }
    }
  })

  expect(presentation.header).toEqual({
    label: "Started",
    subject: { type: "text", text: "Shutdown reviewer" },
    details: ["Review native subagent shutdown and report races."]
  })
  expect(presentation.body).toEqual({
    type: "text",
    text: "Review native subagent shutdown\nand report races.",
    tone: "muted"
  })
  expect(presentation.preview.compact).toEqual({ type: "hidden" })
  expect(presentation.notices).toEqual([])
  expect(JSON.stringify(presentation)).not.toContain("name")
})

test("wait presentation summarizes mixed outcomes without JSON envelopes", () => {
  const presentation = projectToolPresentation({
    status: "done",
    name: "wait_subagents",
    args: { names: [agent.name, "failed-agent"] },
    result: {
      content: [{ type: "text", text: '{"agents":[{"completion":{"status":"completed"}}]}' }],
      details: {
        type: "subagent",
        outcome: "success",
        operation: "wait",
        agents: [
          agent,
          {
            name: "test-runner",
            lifecycle: "exited",
            completionDelivery: "durable",
            completion: {
              workCycle: 1,
              status: "failed",
              text: "",
              omittedBytes: 0,
              truncated: false,
              durationMs: 900,
              reason: "tool timeout"
            }
          }
        ]
      }
    }
  })

  expect(presentation.header).toEqual({
    label: "Finished waiting",
    subject: { type: "text", text: "2 agents" },
    details: []
  })
  expect(presentation.body).toEqual({
    type: "text",
    text: "Shutdown reviewer completed · 4.5s — No shutdown leaks found.\nTest runner failed · 0.9s — tool timeout",
    tone: "muted"
  })
  expect(JSON.stringify(presentation.body)).not.toContain("completion")
  expect(presentation.preview.compact).toEqual({ type: "head", rows: 2 })
})

test("expanded wait presentation retains full bounded multiline completion evidence", () => {
  const evidence = [
    "Checked interruption ownership.",
    ...Array.from({ length: 20 }, (_, index) => `Evidence ${index + 1}: resource ${index + 1} is released.`),
    "Final evidence: terminal restoration precedes settlement."
  ].join("\n")
  const presentation = projectToolPresentation({
    status: "done",
    name: "wait_subagents",
    args: { names: [agent.name] },
    result: {
      content: [{ type: "text", text: "bounded wait result" }],
      details: {
        type: "subagent",
        outcome: "success",
        operation: "wait",
        agents: [{ ...agent, completion: { ...agent.completion, text: evidence } }]
      }
    }
  })

  expect(presentation.preview.compact).toEqual({ type: "head", rows: 2 })
  expect(presentation.preview.detailed).toEqual({ type: "head", rows: 200 })
  expect(presentation.body?.text.split("\n")[0]).toContain("Checked interruption ownership. Evidence 1")
  expect(presentation.body?.text).toContain("Shutdown reviewer output:\nChecked interruption ownership.")
  expect(presentation.body?.text).toContain("Final evidence: terminal restoration precedes settlement.")
})

test("wait does not present an earlier cycle as completion of current work", () => {
  const presentation = projectToolPresentation({
    status: "done",
    name: "wait_subagents",
    args: { names: [agent.name] },
    result: {
      content: [{ type: "text", text: "snapshot" }],
      details: {
        type: "subagent",
        outcome: "success",
        operation: "wait",
        agents: [{ ...agent, lifecycle: "running", workCycle: 2 }]
      }
    }
  })

  expect(presentation.body).toEqual({ type: "text", text: "Shutdown reviewer working", tone: "muted" })
})

test("administrative subagent successes remain header-only in compact mode", () => {
  const cases = [
    ["send_subagent", "send", "Messaged"],
    ["continue_subagent", "continue", "Continued"],
    ["interrupt_subagent", "interrupt", "Interrupted"],
    ["close_subagent", "close", "Closed"]
  ] as const

  for (const [name, operation, label] of cases) {
    const details = {
      type: "subagent" as const,
      outcome: "success" as const,
      operation,
      agent,
      ...(operation === "interrupt" ? { result: "interrupted" as const } : {}),
      ...(operation === "close"
        ? { previousStatus: "idle" as const, previousCompletionStatus: "completed" as const }
        : {})
    }
    const presentation = projectToolPresentation({
      status: "done",
      name,
      args: { name: agent.name },
      result: { content: [{ type: "text", text: '{"internal":"result"}' }], details }
    })
    expect(presentation.header.label).toBe(label)
    expect(presentation.preview.compact).toEqual({ type: "hidden" })
    expect(JSON.stringify(presentation)).not.toContain("internal")
  }
})

test("list presentation reports authoritative working and ready counts", () => {
  const presentation = projectToolPresentation({
    status: "done",
    name: "list_subagents",
    args: {},
    result: {
      content: [{ type: "text", text: '{"agents":[]}' }],
      details: {
        type: "subagent",
        outcome: "success",
        operation: "list",
        agents: [agent, { ...agent, name: "active-worker", lifecycle: "running", completionDelivery: "delivered" }],
        workingNames: ["active-worker"],
        readyNames: [agent.name, "active-worker"]
      }
    }
  })

  expect(presentation.header).toEqual({ label: "Checked agents", details: ["1 working", "2 ready"] })
  expect(presentation.preview.compact).toEqual({ type: "hidden" })
  expect(presentation.body).toEqual({
    type: "text",
    text: "Shutdown reviewer — result ready\nActive worker — working · result ready",
    tone: "muted"
  })
})

test("oversized persisted details degrade inside the semantic subagent row", () => {
  const presentation = projectToolPresentation({
    status: "done",
    name: "close_subagent",
    args: { name: agent.name },
    result: {
      content: [{ type: "text", text: "legacy close result" }],
      details: { type: "subagent", outcome: "success", operation: "close", agent: { ...agent, name: "x".repeat(65) } }
    }
  })

  expect(presentation.header).toEqual({ label: "Closed", subject: { type: "text", text: "Agent" }, details: [] })
  expect(presentation.body).toEqual({ type: "text", text: "legacy close result", tone: "muted" })
})

test("all subagent built-ins keep semantic rows for partial and malformed data", () => {
  for (const name of [
    "spawn_subagent",
    "send_subagent",
    "continue_subagent",
    "wait_subagents",
    "interrupt_subagent",
    "close_subagent",
    "list_subagents"
  ]) {
    const partial = projectToolPresentation({ status: "preparing", name, args: {} })
    expect(partial.header.label).not.toBe("Tool")

    const malformed = projectToolPresentation({
      status: "done",
      name,
      args: {},
      result: { content: [{ type: "text", text: "legacy result" }], details: undefined }
    })
    expect(malformed.header.label).not.toBe("Tool")
  }
})
