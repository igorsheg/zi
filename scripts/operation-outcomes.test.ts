import { expect, test } from "bun:test"

import type { ProjectedOperationOutcome } from "../packages/coding-agent/src/operation-outcomes.js"
import { buildOperationOutcomeReport } from "./operation-outcome-report.js"
import {
  parseOperationOutcomeScriptOptions,
  renderOperationOutcomeScriptReport,
  runOperationOutcomeScript
} from "./operation-outcomes.js"

const generatedAt = "2026-08-12T12:00:00.000Z"

test("operation outcome script options resolve scope and bounded report controls", () => {
  expect(
    parseOperationOutcomeScriptOptions(
      [
        "--cwd",
        "project",
        "--agent-dir",
        "agent",
        "--days",
        "7",
        "--sessions",
        "12",
        "--recent",
        "4",
        "--format",
        "text"
      ],
      new Date(generatedAt),
      "/workspace"
    )
  ).toEqual({
    cwd: "/workspace/project",
    agentDir: "/workspace/agent",
    since: "2026-08-05T12:00:00.000Z",
    sessionLimit: 12,
    recentLimit: 4,
    format: "text",
    compact: false
  })
  expect(() => parseOperationOutcomeScriptOptions(["--recent", "101"])).toThrow(
    "--recent must be an integer from 0 to 100"
  )
  expect(() => parseOperationOutcomeScriptOptions(["--since", generatedAt, "--days", "1"])).toThrow(
    "Use either --since or --days once"
  )
  expect(() => parseOperationOutcomeScriptOptions(["--since", "August 12, 2026"])).toThrow(
    "--since must be a UTC ISO 8601 timestamp"
  )
  expect(() => parseOperationOutcomeScriptOptions(["--since", "2026-02-30T00:00:00Z"])).toThrow(
    "--since must be a UTC ISO 8601 timestamp"
  )
  expect(() => parseOperationOutcomeScriptOptions(["--format", "text", "--compact"])).toThrow(
    "--compact requires --format json"
  )
})

test("operation outcome script emits lossless JSON and capability-owned text evidence", () => {
  const report = buildOperationOutcomeReport(
    [
      {
        id: "session-a",
        outcomes: [subagentOutcome(), backgroundTaskOutcome()] satisfies readonly ProjectedOperationOutcome[]
      }
    ],
    { cwd: "/workspace/project", generatedAt }
  )

  expect(JSON.parse(renderOperationOutcomeScriptReport(report, "json"))).toEqual(report)
  const text = renderOperationOutcomeScriptReport(report, "text")
  expect(text).toContain("subagent/work_cycle")
  expect(text).toContain("provider_error")
  expect(text).toContain("shell/background_task")
  expect(text).toContain("exit_nonzero")
  expect(text).toContain("operation=subagent/reviewer/work_cycle/1")
  expect(text).not.toContain("private prompt")
})

test("operation outcome script keeps help on stdout and failures on stderr", async () => {
  let stdout = ""
  let stderr = ""
  const output = { write: (value: string | Uint8Array) => ((stdout += String(value)), true) }
  const errors = { write: (value: string | Uint8Array) => ((stderr += String(value)), true) }

  expect(await runOperationOutcomeScript(["--help"], output, errors)).toBe(0)
  expect(stdout).toStartWith("Usage: bun run outcomes")
  expect(stderr).toBe("")

  stdout = ""
  expect(await runOperationOutcomeScript(["--recent", "many"], output, errors)).toBe(1)
  expect(stdout).toBe("")
  expect(stderr).toContain("Unable to report operation outcomes: --recent must be an integer")
})

function subagentOutcome(): ProjectedOperationOutcome {
  return {
    type: "operation_outcome",
    capability: "subagent",
    operation: "work_cycle",
    operationId: "subagent/reviewer/work_cycle/1",
    sourceEntryId: "subagent-entry",
    timestamp: "2026-08-12T11:00:00.000Z",
    durationMs: 1200,
    name: "reviewer",
    workCycle: 1,
    profile: "reviewer",
    preview: "safe evidence",
    originalBytes: 13,
    omittedBytes: 0,
    truncated: false,
    result: "failed",
    errorCode: "provider_error",
    errorMessage: "provider unavailable"
  }
}

function backgroundTaskOutcome(): ProjectedOperationOutcome {
  return {
    type: "operation_outcome",
    capability: "shell",
    operation: "background_task",
    operationId: "shell/background_task/11111111-1111-4111-8111-111111111111",
    sourceEntryId: "shell-entry",
    timestamp: "2026-08-12T10:00:00.000Z",
    durationMs: 800,
    taskId: "11111111-1111-4111-8111-111111111111",
    origin: "requested",
    outputBytes: 2048,
    result: "failed",
    errorCode: "exit_nonzero",
    exitCode: 2
  }
}
