import { expect, test } from "bun:test"

import { createMarkdownTreeSitterClient } from "../../src/interactive/transcript/markdown-highlighting.js"

test("standalone markdown never starts OpenTUI's external TreeSitter worker", async () => {
  const client = createMarkdownTreeSitterClient(true)
  if (!client) throw new Error("Expected standalone markdown client")

  let result
  for (let index = 0; index < 500; index++) {
    // The production failure retried one worker after each rejected highlight.
    // oxlint-disable-next-line no-await-in-loop
    result = await client.highlightOnce(`const value = ${index}`, "typescript")
  }
  expect(result).toEqual({})
  expect(client.isInitialized()).toBe(false)
  await client.destroy()
})

test("development markdown keeps OpenTUI syntax highlighting", () => {
  expect(createMarkdownTreeSitterClient(false)).toBeUndefined()
})
