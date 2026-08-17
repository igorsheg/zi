import { expect, test } from "bun:test"

import { builtInToolFailureReason } from "../src/tools/outcome.js"

const emptyOutput = {
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
} as const

test("nested Bash failure reasons retain privacy-safe exit evidence", () => {
  expect(
    builtInToolFailureReason("bash", {
      outcome: "error",
      taskId: "task-1",
      state: "completed",
      timeoutSeconds: 120,
      output: emptyOutput,
      finalOutcome: { type: "exited", exitCode: 7 },
      error: "Command exited with code 7"
    })
  ).toBe("exit_nonzero (exit 7)")
})
