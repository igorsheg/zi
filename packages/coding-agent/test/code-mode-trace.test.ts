import { expect, test } from "bun:test"

import { codeModeTraceVersion, isCodeModeDetails, maxCodeModeTerminalDetailsBytes } from "../src/code-mode/trace.js"

const succeeded = {
  state: "succeeded",
  id: 0,
  name: "read",
  arguments: { path: "src/index.ts", offset: 1, limit: 20 },
  startedAt: 1,
  durationMs: 2
} as const

function terminal(calls: readonly unknown[], logs: readonly string[] = []): Record<string, unknown> {
  return { type: "code_mode", version: codeModeTraceVersion, outcome: "success", calls, logs }
}

test("versioned terminal traces reject private and nonterminal fields", () => {
  const invalid = [
    terminal([{ ...succeeded, state: "running" }]),
    terminal([{ ...succeeded, result: "private result" }]),
    terminal([{ ...succeeded, state: "failed", stage: "invoke", error: "x".repeat(16 * 1024 + 1) }]),
    terminal([{ ...succeeded, name: "extension.private", arguments: { token: "secret" } }]),
    terminal([{ ...succeeded, arguments: { path: "src/index.ts", query: "secret" } }]),
    terminal([succeeded], ["private log"]),
    { ...terminal([succeeded]), version: 2 },
    { ...terminal([succeeded]), unexpected: true }
  ]

  for (const details of invalid) expect(isCodeModeDetails(details)).toBe(false)
  expect(isCodeModeDetails(terminal([succeeded]))).toBe(true)
  expect(isCodeModeDetails(terminal([{ ...succeeded, state: "failed", stage: "invoke" }]))).toBe(true)
  expect(
    isCodeModeDetails(terminal([{ ...succeeded, state: "failed", stage: "invoke", error: "nested failure" }]))
  ).toBe(true)
})

test("versioned terminal traces retain bounded nested failure reasons", () => {
  const error = "x".repeat(16 * 1024 + 1)
  expect(isCodeModeDetails(terminal([{ ...succeeded, state: "failed", stage: "invoke", error }]))).toBe(false)
})

test("versioned terminal traces reject aggregate JSON expansion beyond the bound", () => {
  const path = "\u0000".repeat(4096)
  const calls = Array.from({ length: 64 }, (_, id) => ({ ...succeeded, id, arguments: { path } }))
  const details = terminal(calls)

  expect(Buffer.byteLength(JSON.stringify(details))).toBeGreaterThan(maxCodeModeTerminalDetailsBytes)
  expect(isCodeModeDetails(details)).toBe(false)
})
