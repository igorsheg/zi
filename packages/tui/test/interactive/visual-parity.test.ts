import { expect, test } from "bun:test"

import { TextAttributes } from "@opentui/core"
import { createAgentSession, type AgentMessage, SessionManager } from "@with-zi/coding-agent"
import {
  createModels,
  createTestAgentRuntime as createAgentRuntime,
  fauxAssistantMessage,
  fauxProvider,
  fauxText,
  fauxThinking,
  fauxToolCall
} from "@with-zi/coding-agent/testing"

import { createInteractiveTest } from "./harness.js"

test("representative session keeps the accepted visual hierarchy at normal and constrained sizes", async () => {
  const models = createModels()
  const faux = fauxProvider({ models: [{ id: "faux-1", reasoning: true, contextWindow: 247_000 }] })
  models.setProvider(faux.provider)
  const bootstrap = await createAgentRuntime({
    cwd: "/workspace/zi",
    model: "faux/faux-1",
    models,
    session: { type: "new", persist: false },
    settings: { defaultThinkingLevel: "high" }
  })
  const model = bootstrap.session.model
  bootstrap.session.dispose()
  const sessionManager = SessionManager.inMemory("/workspace/zi")
  for (const message of representativeMessages()) sessionManager.appendMessage(message)
  const { session } = await createAgentSession({ services: bootstrap.services, sessionManager, model, tools: [] })
  const setup = await createInteractiveTest(session, { width: 80, height: 40 })

  try {
    await setup.renderOnce()
    await setup.renderOnce()
    expect(frameRows(setup.captureCharFrame(), 40)).toEqual([
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
      " ◆ Read app.tsx",
      "",
      " ◆ Edit app.tsx +1/-1",
      " │ 1 − export function App() {}",
      " │ 1 + export function Application() {}",
      " ╰───",
      "",
      " ◆ Write generated.ts · 1 line · 30 bytes",
      "",
      " ◆ Run bun test · exit 1",
      " │ 1 test failed",
      " │ Command exited with code 1",
      " ╰───",
      "",
      " The failed command remains visible without overwhelming the prompt.",
      "",
      "",
      "",
      "",
      "",
      "",
      "",
      "",
      "",
      "",
      "",
      "╭─/workspace/zi───────────────────────────────────ctx 15%/247k • faux-1 (high)─╮",
      "│                                                                              │",
      "╰──────────────────────────────────────────────────────────────────────────────╯"
    ])

    const spans = setup.captureSpans().lines.flatMap(line => line.spans)
    expect(span(spans, "Inspect the session UI.").bg.toInts()).toEqual([13, 18, 24, 255])
    expect(span(spans, "Checking ").attributes).toBe(TextAttributes.ITALIC)
    expect(span(spans, "spacing").attributes).toBe(TextAttributes.BOLD | TextAttributes.ITALIC)
    expect(span(spans, "spacing").fg.toInts()).toEqual([127, 131, 129, 255])
    expect(span(spans, "Result").fg.toInts()).toEqual([230, 195, 132, 255])
    expect(span(spans, "Result").attributes).toBe(TextAttributes.BOLD)
    expect(span(spans, "code").fg.toInts()).toEqual([122, 168, 159, 255])
    expect(spans.filter(candidate => candidate.text === "◆ ").map(candidate => candidate.fg.toInts())).toContainEqual([
      228, 104, 118, 255
    ])

    setup.resize(40, 8)
    await setup.renderOnce()
    expect(frameRows(setup.captureCharFrame(), 8)).toEqual([
      " ╰───",
      "",
      " The failed command remains visible",
      " without overwhelming the prompt.",
      "",
      "╭─/workspace/zi───────────ctx 15%/247k─╮",
      "│                                      │",
      "╰──────────────────────────────────────╯"
    ])

    setup.resize(20, 4)
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("prompt.")
  } finally {
    session.dispose()
    setup.destroy()
  }
})

test("composer distinguishes estimated context after compaction", async () => {
  const models = createModels()
  const faux = fauxProvider({ provider: "estimated-context", models: [{ id: "model", contextWindow: 4_000 }] })
  models.setProvider(faux.provider)
  const bootstrap = await createAgentRuntime({
    cwd: "/work",
    models,
    session: { type: "new", persist: false },
    settings: { compactionReserveTokens: 100, compactionKeepRecentTokens: 1 }
  })
  const model = bootstrap.session.model
  bootstrap.session.dispose()
  const history = SessionManager.inMemory("/work")
  history.appendMessage({ role: "user", content: "x".repeat(1_000), timestamp: 1 })
  history.appendMessage(fauxAssistantMessage("old answer"))
  history.appendMessage({ role: "user", content: "recent", timestamp: 3 })
  history.appendMessage(fauxAssistantMessage("recent answer"))
  const { session } = await createAgentSession({
    services: bootstrap.services,
    sessionManager: history,
    model,
    tools: []
  })
  faux.setResponses([fauxAssistantMessage("checkpoint")])
  await session.compact()
  const setup = await createInteractiveTest(session, { width: 80, height: 6 })

  try {
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toMatch(/ctx ~\d+%\/4k/)
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
      fauxThinking("Checking **spacing** and semantic color."),
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
    fauxAssistantMessage(
      fauxToolCall(
        "edit",
        { path: "src/app.tsx", edits: [{ oldText: "App", newText: "Application" }] },
        { id: "edit-1" }
      )
    ),
    {
      role: "toolResult",
      toolCallId: "edit-1",
      toolName: "edit",
      content: [{ type: "text", text: "Successfully replaced 1 block in src/app.tsx" }],
      details: {
        outcome: "success",
        replacements: 1,
        additions: 1,
        deletions: 1,
        diff: "--- a/src/app.tsx\n+++ b/src/app.tsx\n@@ -1,1 +1,1 @@\n-export function App() {}\n+export function Application() {}",
        diffTruncated: false,
        firstChangedLine: 1
      },
      isError: false,
      timestamp: 4
    },
    fauxAssistantMessage(
      fauxToolCall("write", { path: "src/generated.ts", content: "export const generated = true\n" }, { id: "write-1" })
    ),
    {
      role: "toolResult",
      toolCallId: "write-1",
      toolName: "write",
      content: [{ type: "text", text: "Successfully wrote 30 bytes to src/generated.ts" }],
      details: { outcome: "success", bytes: 30, lines: 1 },
      isError: false,
      timestamp: 4
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
    {
      ...fauxAssistantMessage(fauxText("The failed command remains visible without overwhelming the prompt.")),
      usage: {
        input: 36_000,
        output: 1_000,
        cacheRead: 0,
        cacheWrite: 0,
        totalTokens: 37_000,
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 }
      }
    }
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
