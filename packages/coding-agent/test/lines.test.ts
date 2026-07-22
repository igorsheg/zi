import { expect, test } from "bun:test"

import { countTextLines, splitTextLines } from "../src/tools/lines.js"
import { DEFAULT_MAX_LINES, truncateHead, truncateTail } from "../src/tools/truncate.js"

test("text line semantics ignore only the terminal split sentinel", () => {
  expect(splitTextLines("")).toEqual([""])
  expect(countTextLines("")).toBe(0)
  expect(splitTextLines("one")).toEqual(["one"])
  expect(countTextLines("one")).toBe(1)
  expect(splitTextLines("one\n")).toEqual(["one"])
  expect(countTextLines("one\n")).toBe(1)
  expect(splitTextLines("one\n\n")).toEqual(["one", ""])
  expect(countTextLines("one\n\n")).toBe(2)
})

test("a terminated 2,000-line body keeps every usable line at either truncation edge", () => {
  const content = `${Array.from({ length: DEFAULT_MAX_LINES }, (_, index) => `line-${index + 1}`).join("\n")}\n`
  for (const truncated of [truncateHead(content), truncateTail(content)]) {
    expect(truncated).toMatchObject({
      content,
      truncated: false,
      totalLines: DEFAULT_MAX_LINES,
      outputLines: DEFAULT_MAX_LINES
    })
  }
})
