import { expect, test } from "bun:test"

import { wrapHeadToCells, wrapTailToCells, wrapToCells } from "../src/components/cell-text.js"

test("bounded cell wrapping preserves the corresponding full-wrap edges", () => {
  const text = "a界b界c"
  const all = wrapToCells(text, 3)
  expect(all).toEqual(["a界", "b界", "c"])
  expect(wrapHeadToCells(text, 3, 2)).toEqual({ lines: all.slice(0, 2), hasMore: true })
  expect(wrapTailToCells(text, 3, 2)).toEqual({ lines: all.slice(-2), hasMore: true })
})

test("tail cell wrapping retains bounded rows for one oversized logical line", () => {
  const tail = wrapTailToCells("x".repeat(100_000), 10, 5)
  expect(tail).toEqual({ lines: Array.from({ length: 5 }, () => "x".repeat(10)), hasMore: true })
})
