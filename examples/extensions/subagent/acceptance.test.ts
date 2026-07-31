import { expect, test } from "bun:test"

import registerReviewer from "./index.ts"

test("registers the reviewer subagent type", () => {
  let registered: unknown

  registerReviewer({
    registerSubagentType(definition) {
      registered = definition
    }
  })

  expect(registered).toEqual({
    name: "reviewer",
    description: "Review a change for correctness and missing tests",
    instructions: "Inspect the requested change. Do not edit files. Return findings with paths and line numbers."
  })
})
