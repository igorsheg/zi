import { expect, test } from "bun:test"

test("the lifecycle extension API exports no runtime authority", async () => {
  const api = await import("../src/index.js")
  expect(Object.keys(api)).toEqual([])
})
