import { expect, test } from "bun:test"

import {
  textWidth,
  truncateToCells,
  wrapHeadToCells,
  wrapTailToCells,
  wrapToCells
} from "../src/components/cell-text.js"

test("bounded cell wrapping preserves the corresponding full-wrap edges", () => {
  const text = "a界b界c"
  const all = wrapToCells(text, 3)
  expect(all).toEqual(["a界", "b界", "c"])
  expect(wrapHeadToCells(text, 3, 2)).toEqual({ lines: all.slice(0, 2), hasMore: true })
  expect(wrapTailToCells(text, 3, 2)).toEqual({ lines: all.slice(-2), hasMore: true })
})

test("native cell measurement and truncation count tabs as two cells", () => {
  expect(textWidth("\t")).toBe(2)
  expect(textWidth("a\tb")).toBe(4)
  expect(truncateToCells("a\tbc", 4)).toBe("a...")
  expect(truncateToCells("a\tbc", 5)).toBe("a\tbc")
  expect(wrapHeadToCells("a\t\tb", 3, 3)).toEqual({ lines: ["a\t", "\tb"], hasMore: false })
})

test("wrapping preserves grapheme source while measuring modern Unicode", () => {
  const text = "e\u0301🙂x"
  const lines = wrapToCells(text, 2)
  expect(lines).toEqual(["e\u0301", "🙂", "x"])
  expect(lines.join("")).toBe(text)
  expect(textWidth(text)).toBe(4)
  expect(wrapToCells("🙂", 1)).toEqual(["🙂"])
})

test("tail cell wrapping retains bounded rows for one oversized logical line", () => {
  const tail = wrapTailToCells("x".repeat(100_000), 10, 5)
  expect(tail).toEqual({ lines: Array.from({ length: 5 }, () => "x".repeat(10)), hasMore: true })
})
