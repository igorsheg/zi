import { expect, test } from "bun:test"

import { fauxAssistantMessage, fauxToolCall } from "@earendil-works/pi-ai"

import { parseAgentPath, rootAgentPath } from "../src/agent-team/path.js"
import { maxSessionFailures, projectSessionFailures } from "../src/session-failures.js"
import { SessionManager } from "../src/session-manager.js"

test("projects a typed tool failure from durable call and result messages", () => {
  const session = SessionManager.inMemory("/work", "session-1")
  session.appendMessage(
    fauxAssistantMessage(fauxToolCall("read", { path: "missing.ts" }, { id: "read-1" }), { stopReason: "toolUse" })
  )
  const result = session.appendMessage({
    role: "toolResult",
    toolCallId: "read-1",
    toolName: "read",
    content: [{ type: "text", text: "File not found: missing.ts" }],
    details: { outcome: "error", reason: "not_found", error: "File not found: missing.ts" },
    isError: true,
    timestamp: 2
  })

  expect(projectSessionFailures(session.entries())).toEqual({
    failures: [
      {
        kind: "tool",
        id: "tool/read-1",
        name: "read",
        status: "failed",
        code: "not_found",
        message: "File not found: missing.ts",
        timestamp: result.timestamp,
        sourceEntryId: result.id
      }
    ],
    omitted: 0
  })
})

test("projects stable codes for mutation tool failures", () => {
  const session = SessionManager.inMemory("/work", "session-1")
  session.appendMessage(
    fauxAssistantMessage(
      [
        fauxToolCall("write", { path: ".", content: "x" }, { id: "write-1" }),
        fauxToolCall("edit", { path: "missing.ts", edits: [] }, { id: "edit-1" })
      ],
      { stopReason: "toolUse" }
    )
  )
  const write = session.appendMessage({
    role: "toolResult",
    toolCallId: "write-1",
    toolName: "write",
    content: [{ type: "text", text: "Path is not writable as a file: ." }],
    details: { outcome: "error", reason: "not_file", bytes: 1, lines: 1, error: "Path is not writable as a file: ." },
    isError: true,
    timestamp: 2
  })
  const edit = session.appendMessage({
    role: "toolResult",
    toolCallId: "edit-1",
    toolName: "edit",
    content: [{ type: "text", text: "File not found: missing.ts" }],
    details: { outcome: "error", reason: "not_found", error: "File not found: missing.ts" },
    isError: true,
    timestamp: 3
  })

  expect(projectSessionFailures(session.entries()).failures).toEqual([
    expect.objectContaining({
      id: "tool/write-1",
      code: "not_file",
      message: "Path is not writable as a file: .",
      sourceEntryId: write.id
    }),
    expect.objectContaining({
      id: "tool/edit-1",
      code: "not_found",
      message: "File not found: missing.ts",
      sourceEntryId: edit.id
    })
  ])
})

test("projects a caught nested Code Mode failure beneath a successful outer call", () => {
  const session = SessionManager.inMemory("/work", "session-1")
  session.appendMessage(
    fauxAssistantMessage(fauxToolCall("code", { description: "Inspect", code: "return undefined" }, { id: "code-1" }), {
      stopReason: "toolUse"
    })
  )
  const result = session.appendMessage({
    role: "toolResult",
    toolCallId: "code-1",
    toolName: "code",
    content: [{ type: "text", text: "completed" }],
    details: {
      type: "code_mode",
      version: 1,
      outcome: "success",
      calls: [
        {
          state: "failed",
          id: 3,
          name: "read",
          arguments: { path: "missing.ts" },
          startedAt: 10,
          durationMs: 4,
          stage: "invoke",
          error: "Nested Zi tool read failed: not_found"
        }
      ],
      logs: []
    },
    isError: false,
    timestamp: 20
  })

  expect(projectSessionFailures(session.entries())).toEqual({
    failures: [
      {
        kind: "code_call",
        id: "tool/code-1/code/3",
        parentId: "tool/code-1",
        name: "read",
        status: "failed",
        code: "invoke",
        message: "Nested Zi tool read failed: not_found",
        timestamp: result.timestamp,
        durationMs: 4,
        sourceEntryId: result.id
      }
    ],
    omitted: 0
  })
})

test("projects a durable background task failure", () => {
  const session = SessionManager.inMemory("/work", "session-1")
  session.appendMessage(
    fauxAssistantMessage(fauxToolCall("bash", { command: "false", background: true }, { id: "bash-1" }), {
      stopReason: "toolUse"
    })
  )
  session.appendMessage({
    role: "toolResult",
    toolCallId: "bash-1",
    toolName: "bash",
    content: [{ type: "text", text: "Command running in background" }],
    details: {
      outcome: "success",
      taskId: "task-1",
      state: "background",
      timeoutSeconds: 120,
      output: {
        truncation: {
          truncated: false,
          truncatedBy: null,
          totalLines: 0,
          totalBytes: 0,
          outputLines: 0,
          outputBytes: 0,
          firstLineExceedsLimit: false,
          lastLinePartial: false
        },
        fullOutput: { type: "evicted", bytes: 0, truncated: false }
      }
    },
    isError: false,
    timestamp: 2
  })
  const result = session.appendBackgroundTaskResult({
    taskId: "task-1",
    origin: "requested",
    result: "failed",
    durationMs: 120,
    outputBytes: 80,
    errorCode: "exit_nonzero",
    exitCode: 7
  })

  expect(projectSessionFailures(session.entries())).toEqual({
    failures: [
      {
        kind: "background_task",
        id: "background-task/task-1",
        parentId: "tool/bash-1",
        name: "bash",
        status: "failed",
        code: "exit_nonzero",
        message: "Command exited with code 7",
        timestamp: result.timestamp,
        durationMs: 120,
        sourceEntryId: result.id
      }
    ],
    omitted: 0
  })
})

test("projects a durable failed agent turn", () => {
  const session = SessionManager.inMemory("/work", "session-1")
  const path = parseAgentPath("/root/research")
  session.appendAgentTeam({
    type: "agent_spawn_reserved",
    operationId: "spawn-1",
    path,
    parentPath: rootAgentPath,
    sessionId: "child-session",
    parentSessionId: "session-1",
    parentEntryId: null,
    generation: 1,
    taskName: "research",
    agentType: "explorer",
    forkTurns: "all",
    execution: { model: { provider: "test", modelId: "model" }, thinkingLevel: "medium" }
  })
  session.appendAgentTeam({ type: "agent_spawn_committed", operationId: "spawn-1" })
  session.appendAgentTeam({ type: "agent_turn_reserved", operationId: "turn-1", path, turn: 1, mailId: "mail-1" })
  const result = session.appendAgentTeam({
    type: "agent_turn_settled",
    operationId: "turn-1",
    path,
    turn: 1,
    result: {
      status: "failed",
      code: "provider_error",
      message: "Provider overloaded",
      durationMs: 450,
      text: "",
      originalBytes: 0,
      omittedBytes: 0,
      truncated: false
    }
  })

  expect(projectSessionFailures(session.entries())).toEqual({
    failures: [
      {
        kind: "agent_turn",
        id: "agent-turn/turn-1",
        name: "/root/research",
        status: "failed",
        code: "provider_error",
        message: "Provider overloaded",
        timestamp: result.timestamp,
        durationMs: 450,
        sourceEntryId: result.id
      }
    ],
    omitted: 0
  })
})

test("projects a provider failure with its retry admission", () => {
  const session = SessionManager.inMemory("/work", "session-1")
  const failed = session.appendMessage(
    fauxAssistantMessage("", { stopReason: "error", errorMessage: "Provider overloaded" })
  )
  session.appendRetry(failed.id, 1)

  expect(projectSessionFailures(session.entries())).toEqual({
    failures: [
      {
        kind: "provider",
        id: `provider/${failed.id}`,
        name: "faux/faux-1",
        status: "failed",
        code: "provider_error",
        message: "Provider overloaded",
        retryAttempt: 1,
        timestamp: failed.timestamp,
        sourceEntryId: failed.id
      }
    ],
    omitted: 0
  })
})

test("bounds retained failures and reports omissions", () => {
  const session = SessionManager.inMemory("/work", "session-1")
  for (let index = 0; index <= maxSessionFailures; index++) {
    session.appendMessage({
      role: "toolResult",
      toolCallId: `call-${index}`,
      toolName: "probe",
      content: [{ type: "text", text: "failed" }],
      isError: true,
      timestamp: index
    })
  }

  const projection = projectSessionFailures(session.entries())
  expect(projection.failures).toHaveLength(maxSessionFailures)
  expect(projection.omitted).toBe(1)
})
