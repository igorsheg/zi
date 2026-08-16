import { expect, test } from "bun:test"

import { TextRenderable } from "@opentui/core"
import { createTestRenderer } from "@opentui/core/testing"

import { MarkdownView } from "../src/interactive/transcript/markdown-view.js"
import { createSyntaxStyle, defaultTheme } from "../src/theme.js"

test("renders soft line endings as spaces and preserves explicit breaks", async () => {
  const setup = await createTestRenderer({ width: 80, height: 12, useThread: false })
  const syntaxStyle = createSyntaxStyle(defaultTheme)
  const view = new MarkdownView(setup.renderer, {
    content: [
      "1. Give it this task:",
      "   Read the docs and report back.",
      "2. Confirm completion.",
      "",
      "A paragraph",
      "continued on the next source line.",
      "",
      "- **Child path:**",
      "  `/root/durable_probe`",
      "- **Passive completion:**",
      "  `FIRST: Delegate work to agents`",
      "",
      "Hard break  ",
      "stays broken."
    ].join("\n"),
    theme: defaultTheme,
    syntaxStyle
  })

  try {
    expect(textBlocks(view)).toEqual([
      "1. Give it this task: Read the docs and report back.\n2. Confirm completion.",
      "A paragraph continued on the next source line.",
      "• Child path: /root/durable_probe\n• Passive completion: FIRST: Delegate work to agents",
      "Hard break\nstays broken."
    ])
  } finally {
    view.destroyRecursively()
    syntaxStyle.destroy()
    setup.renderer.destroy()
  }
})

function textBlocks(view: MarkdownView): string[] {
  return view.getChildren().map(block => {
    const body = block.getChildren()[0]
    if (!(body instanceof TextRenderable)) throw new Error("Expected Markdown text block")
    return body.plainText
  })
}
