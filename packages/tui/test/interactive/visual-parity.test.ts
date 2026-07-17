import { expect, test } from "bun:test"

import { TextAttributes } from "@opentui/core"
import { createAgentSession, type AgentMessage, SessionManager } from "@openzi/coding-agent"
import {
  createModels,
  createTestAgentRuntime as createAgentRuntime,
  fauxAssistantMessage,
  fauxProvider,
  fauxText,
  fauxThinking,
  fauxToolCall
} from "@openzi/coding-agent/testing"

import { createInteractiveTest } from "./harness.js"

test("representative session keeps the accepted visual hierarchy at normal and constrained sizes", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  const bootstrap = await createAgentRuntime({ cwd: "/workspace/openzi", model: "faux/faux-1", models, persist: false })
  const model = bootstrap.session.model
  bootstrap.session.dispose()
  const sessionManager = SessionManager.inMemory("/workspace/openzi")
  for (const message of representativeMessages()) sessionManager.appendMessage(message)
  const session = await createAgentSession({ services: bootstrap.services, sessionManager, model, tools: [] })
  const setup = await createInteractiveTest(session, { width: 80, height: 30 })

  try {
    await setup.renderOnce()
    expect(frameRows(setup.captureCharFrame(), 30)).toEqual([
      "",
      " Inspect the session UI.",
      " Keep the output concise.",
      "",
      "",
      " Checking spacing and semantic color.",
      "",
      " Result",
      "",
      " The layout keeps content readable and highlights code.",
      "",
      " Read src/app.tsx · 1-1 of 1",
      "",
      " Bash $ bun test · task task-1 (error)",
      " ╭───",
      " │ 1 test failed",
      " ╰───",
      " [Command exited with code 1]",
      "",
      " The failed command remains visible without overwhelming the prompt.",
      "",
      "",
      "",
      "",
      "",
      "",
      "",
      "╭─/workspace/openzi────────────────────────────────────────────────────────────╮",
      "│                                                                              │",
      "╰───────────────────────────────────────────────────────────────────────faux-1─╯"
    ])

    const spans = setup.captureSpans().lines.flatMap(line => line.spans)
    expect(span(spans, "Inspect the session UI.").bg.toInts()).toEqual([13, 18, 24, 255])
    expect(span(spans, "Checking spacing and semantic color.").attributes).toBe(TextAttributes.ITALIC)
    expect(span(spans, "Result").fg.toInts()).toEqual([230, 195, 132, 255])
    expect(span(spans, "Result").attributes).toBe(TextAttributes.BOLD)
    expect(span(spans, "code").fg.toInts()).toEqual([122, 168, 159, 255])
    expect(span(spans, "╭───").fg.toInts()).toEqual([228, 104, 118, 255])

    setup.resize(40, 8)
    await setup.renderOnce()
    expect(frameRows(setup.captureCharFrame(), 8)).toEqual([
      " [Command exited with code 1]",
      "",
      " The failed command remains visible",
      " without overwhelming the prompt.",
      "",
      "╭─/workspace/openzi────────────────────╮",
      "│                                      │",
      "╰───────────────────────────────faux-1─╯"
    ])

    setup.resize(20, 4)
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("prompt.")
  } finally {
    session.dispose()
    setup.destroy()
  }
})

function representativeMessages(): AgentMessage[] {
  return [
    {
      role: "user",
      content: [{ type: "text", text: "Inspect the session UI.\nKeep the output concise." }],
      timestamp: 1
    },
    fauxAssistantMessage([
      fauxThinking("Checking spacing and semantic color."),
      fauxText("## Result\n\nThe layout keeps **content** readable and highlights `code`."),
      fauxToolCall("read", { path: "src/app.tsx" }, { id: "read-1" })
    ]),
    {
      role: "toolResult",
      toolCallId: "read-1",
      toolName: "read",
      content: [{ type: "text", text: "export function App() {}" }],
      details: {
        outcome: "success",
        startLine: 1,
        endLine: 1,
        totalLines: 1,
        truncation: {
          truncated: false,
          truncatedBy: null,
          totalLines: 1,
          totalBytes: 24,
          outputLines: 1,
          outputBytes: 24,
          firstLineExceedsLimit: false,
          lastLinePartial: false
        }
      },
      isError: false,
      timestamp: 3
    },
    fauxAssistantMessage(fauxToolCall("bash", { command: "bun test" }, { id: "bash-1" })),
    {
      role: "toolResult",
      toolCallId: "bash-1",
      toolName: "bash",
      content: [{ type: "text", text: "1 test failed" }],
      details: {
        outcome: "error",
        taskId: "task-1",
        state: "completed",
        timeoutSeconds: 120,
        finalOutcome: { type: "exited", exitCode: 1 },
        error: "Command exited with code 1",
        output: {
          truncation: {
            truncated: false,
            truncatedBy: null,
            totalLines: 1,
            totalBytes: 13,
            outputLines: 1,
            outputBytes: 13,
            firstLineExceedsLimit: false,
            lastLinePartial: false
          },
          fullOutput: { type: "available", path: "/tmp/task-1.log", bytes: 13, truncated: false }
        }
      },
      isError: true,
      timestamp: 5
    },
    fauxAssistantMessage(fauxText("The failed command remains visible without overwhelming the prompt."))
  ]
}

function frameRows(frame: string, height: number): string[] {
  return frame
    .split("\n")
    .slice(0, height)
    .map(line => line.trimEnd())
}

function span<T extends { text: string }>(spans: readonly T[], text: string): T {
  const found = spans.find(candidate => candidate.text === text)
  if (!found) throw new Error(`Missing span: ${text}`)
  return found
}
