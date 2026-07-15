import { expect, test } from "bun:test"

import { parseArgs } from "../src/args.js"

test("CLI parses a memory-only API-key override beside its model", () => {
  const args = parseArgs(["--cwd", "/work", "--model", "provider/model", "--api-key", "test-key", "--no-session"])

  expect(args).toEqual({ cwd: "/work", model: "provider/model", apiKey: "test-key", noSession: true })
})

test("CLI requires an API-key value", () => {
  expect(() => parseArgs(["--api-key"])).toThrow("--api-key requires a value")
})
