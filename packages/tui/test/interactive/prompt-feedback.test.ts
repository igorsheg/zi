import { expect, test } from "bun:test"

import { createTestRenderer } from "@opentui/core/testing"

import { PromptFeedbackView } from "../../src/interactive/prompt/feedback-view.js"
import type { AuthCeremony } from "../../src/interactive/prompt/state.js"
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
    const ceremony: AuthCeremony = {
      providerName: "Example",
      methodName: "Example OAuth",
      url: { href: "https://example.com/login", instructions: "Open", requestId: 1 }
    }
    expect(view.update({ type: "none" }, ceremony, 60)).toBeGreaterThan(0)
    expect(view.update({ type: "none" }, ceremony, 60)).toBeGreaterThan(0)
    expect(opened).toEqual(["https://example.com/login"])

    view.update({ type: "none" }, { ...ceremony, url: { ...ceremony.url!, requestId: 2 } }, 60)
    expect(opened).toEqual(["https://example.com/login", "https://example.com/login"])
  } finally {
    view.destroy()
    setup.renderer.destroy()
  }
})

test("auth ceremony keeps URL and device code while prompt and progress update", async () => {
  const setup = await createTestRenderer({ width: 72, height: 12, useThread: false })
  const view = new PromptFeedbackView(setup.renderer, { open: async () => {}, dispose() {} }, defaultTheme)
  setup.renderer.root.add(view.root)

  try {
    const base: AuthCeremony = {
      providerName: "OAuth Provider",
      methodName: "OAuth Subscription",
      url: { href: "https://example.com/login", instructions: "Visit login", requestId: 1 },
      device: { userCode: "ABCD", verificationUri: "https://example.com/device", requestId: 2 }
    }
    const frameOf = async () => {
      await setup.renderOnce()
      return setup.captureCharFrame()
    }

    view.update({ type: "none" }, base, 72)
    let frame = await frameOf()
    expect(frame).toContain("OAuth Subscription")
    expect(frame).toContain("ABCD")
    expect(frame).toContain("https://example.com/login")
    expect(frame).toContain("https://example.com/device")

    view.update(
      { type: "none" },
      {
        ...base,
        prompt: { type: "manual_code", message: "Paste authorization code", placeholder: "http://localhost/callback" }
      },
      72
    )
    frame = await frameOf()
    expect(frame).toContain("https://example.com/login")
    expect(frame).toContain("ABCD")
    expect(frame).toContain("Paste authorization code")
    expect(frame).toContain("e.g. http://localhost/callback")

    view.update(
      { type: "none" },
      {
        providerName: base.providerName,
        methodName: base.methodName,
        ...(base.url ? { url: base.url } : {}),
        ...(base.device ? { device: base.device } : {}),
        status: "Exchanging authorization code"
      },
      72
    )
    frame = await frameOf()
    expect(frame).toContain("https://example.com/login")
    expect(frame).toContain("ABCD")
    expect(frame).toContain("Exchanging authorization code")
  } finally {
    view.destroy()
    setup.renderer.destroy()
  }
})
