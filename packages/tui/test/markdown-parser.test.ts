import { describe, expect, test } from "bun:test"

import {
  maxMarkdownSourceBytes,
  parseMarkdown,
  type MarkdownNode
} from "../src/interactive/transcript/markdown-parser.js"

describe("Markdown parser adapter", () => {
  test("projects healed md4x nodes and presentation metadata", () => {
    expect(nodes("**bold")).toEqual([["p", {}, ["strong", {}, "bold"]]])
    expect(nodes("3. item")).toEqual([["ol", { start: 3 }, ["li", {}, "item"]]])
    expect(nodes("```ts [main.ts]\nconst value = 1")).toEqual([
      ["pre", { language: "ts", filename: "main.ts" }, ["code", { class: "language-ts" }, "const value = 1\n"]]
    ])
    expect(nodes("![alt *text*](image.png)")).toEqual([["p", {}, ["img", { src: "image.png", alt: "alt text" }]]])
    expect(nodes("<!-- comment -->")).toEqual([[null, {}, " comment "]])
  })

  test("omits frontmatter while preserving GFM tables and alerts", () => {
    expect(nodes("---\ntitle: Hidden\n---\n\n> [!NOTE]\n> visible")).toEqual([
      ["alert", { type: "note" }, ["p", {}, "visible"]]
    ])
    expect(nodes("| A | B |\n| - | - |\n| x | y |")).toEqual([
      [
        "table",
        {},
        ["thead", {}, ["tr", {}, ["th", {}, "A"], ["th", {}, "B"]]],
        ["tbody", {}, ["tr", {}, ["td", {}, "x"], ["td", {}, "y"]]]
      ]
    ])
  })

  test("digests only presentation-relevant block data", () => {
    const first = parsed("one\n\n---\n\ntwo")
    const second = parsed("one\n\n---\n\ntwo!")
    expect(first).toHaveLength(3)
    expect(second).toHaveLength(3)
    expect(first[0]!.digest).toEqual(second[0]!.digest)
    expect(first[1]!.digest).toEqual(second[1]!.digest)
    expect(first[2]!.digest).not.toEqual(second[2]!.digest)

    const duplicateHeading = parsed("# Same\n\n# Same")[1]!
    const uniqueHeading = parsed("# Other\n\n# Same")[1]!
    expect(duplicateHeading.node).not.toEqual(uniqueHeading.node)
    expect(duplicateHeading.digest).toEqual(uniqueHeading.digest)
  })

  test("bounds source bytes and retained top-level blocks", () => {
    expect(parseMarkdown("x".repeat(maxMarkdownSourceBytes + 1))).toEqual({ ok: false, reason: "source_limit" })
    expect(parseMarkdown("界".repeat(Math.floor(maxMarkdownSourceBytes / 3) + 1))).toEqual({
      ok: false,
      reason: "source_limit"
    })

    const result = parsed("---\n\n".repeat(520))
    expect(result).toHaveLength(512)
    expect(result.at(-1)?.node).toMatch(/^\[\d+ additional Markdown blocks omitted\.\]$/)
  })
})

function parsed(source: string) {
  const result = parseMarkdown(source)
  if (!result.ok) throw new Error(`Markdown parsing failed: ${result.reason}`)
  return result.blocks
}

function nodes(source: string): readonly MarkdownNode[] {
  return parsed(source).map(block => block.node)
}
