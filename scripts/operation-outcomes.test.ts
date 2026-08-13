import { expect, test } from "bun:test"

import type { OperationOutcome } from "../packages/coding-agent/src/operation-outcomes.js"
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

test("operation outcome script emits lossless JSON and generic text rows", () => {
  const report = buildOperationOutcomeReport(
    [
      {
        id: "session-a",
        outcomes: [
          {
            type: "operation_outcome",
            id: "deploy-entry",
            parentId: null,
            operationId: "deploy/release/42",
            timestamp: "2026-08-12T11:00:00.000Z",
            capability: "release_pipeline",
            operation: "deploy",
            result: "failed",
            durationMs: 1200,
            evidence: { region: "eu-west", attempt: 2 }
          },
          {
            type: "operation_outcome",
            id: "cache-entry",
            parentId: null,
            operationId: "cache/warm/42",
            timestamp: "2026-08-12T10:00:00.000Z",
            capability: "cache",
            operation: "warm",
            result: "cancelled",
            durationMs: 800,
            evidence: "superseded"
          }
        ] satisfies readonly OperationOutcome[]
      }
    ],
    { cwd: "/workspace/project", generatedAt }
  )

  expect(JSON.parse(renderOperationOutcomeScriptReport(report, "json"))).toEqual(report)
  const text = renderOperationOutcomeScriptReport(report, "text")
  expect(text).toContain("release_pipeline/deploy")
  expect(text).toContain('evidence={"region":"eu-west","attempt":2}')
  expect(text).toContain("cache/warm")
  expect(text).toContain('evidence="superseded"')
  expect(text).toContain("operation=deploy/release/42")
  expect(text).toContain("session=session-a")
  expect(text).toContain("Daily trend")
  expect(text).not.toContain("Subagent work cycles")
  expect(text).not.toContain("Background tasks")
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
