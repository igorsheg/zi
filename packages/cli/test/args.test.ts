import { expect, test } from "bun:test"

import { parseArgs } from "../src/args.js"

test("CLI parses a memory-only API-key override beside its model", () => {
  const args = parseArgs(["--cwd", "/work", "--model", "provider/model", "--api-key", "test-key", "--no-session"])

  expect(args).toEqual({
    cwd: "/work",
    model: "provider/model",
    apiKey: "test-key",
    noSession: true,
    print: false,
    messages: [],
    help: false,
    version: false
  })
})

test("CLI parses print modes and ordered positional prompts", () => {
  expect(parseArgs(["-p", "--mode", "json", "first", "second"])).toEqual({
    cwd: process.cwd(),
    noSession: false,
    print: true,
    mode: "json",
    messages: ["first", "second"],
    help: false,
    version: false
  })
})

test("CLI parses the version flag without admitting a prompt", () => {
  expect(parseArgs(["-V"])).toMatchObject({ version: true, messages: [] })
})

test("CLI keeps RPC explicitly deferred", () => {
  expect(() => parseArgs(["--mode", "rpc"])).toThrow("RPC mode is not available yet")
})

test("CLI requires an API-key value", () => {
  expect(() => parseArgs(["--api-key"])).toThrow("--api-key requires a value")
})
