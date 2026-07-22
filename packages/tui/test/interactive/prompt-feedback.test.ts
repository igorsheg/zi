import { expect, test } from "bun:test"

import { createTestRenderer } from "@opentui/core/testing"

import { PromptFeedbackView } from "../../src/interactive/prompt/feedback-view.js"
import { defaultTheme } from "../../src/theme.js"

test("prompt feedback opens each browser request once even when a later request repeats the URL", async () => {
  const setup = await createTestRenderer({ width: 60, height: 4, useThread: false })
  const opened: string[] = []
  const view = new PromptFeedbackView(
    setup.renderer,
    { open: async url => void opened.push(url), dispose() {} },
    defaultTheme
  )
  setup.renderer.root.add(view.root)

  try {
    const feedback = { type: "auth_link" as const, requestId: 1, message: "Open", url: "https://example.com/login" }
    expect(view.update(feedback, 60)).toBe(true)
    expect(view.update(feedback, 60)).toBe(true)
    expect(opened).toEqual(["https://example.com/login"])

    view.update({ ...feedback, requestId: 2 }, 60)
    expect(opened).toEqual(["https://example.com/login", "https://example.com/login"])
  } finally {
    view.destroy()
    setup.renderer.destroy()
  }
})
