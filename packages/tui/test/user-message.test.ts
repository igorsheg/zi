import { expect, test } from "bun:test"

import { TextRenderable } from "@opentui/core"
import { createTestRenderer } from "@opentui/core/testing"

import {
  createPendingUserMessageSurface,
  createUserMessageSurface,
  formatUserMessageContent,
  userMessageChromeRows
} from "../src/components/user-message.js"
import { defaultTheme } from "../src/theme.js"

test("committed and pending user messages share one surface geometry", async () => {
  const setup = await createTestRenderer({ width: 40, height: 12, useThread: false })
  const committed = createUserMessageSurface(setup.renderer, defaultTheme)
  const pending = createPendingUserMessageSurface(setup.renderer)
  const committedBody = new TextRenderable(setup.renderer, { content: "committed" })
  const pendingBody = new TextRenderable(setup.renderer, { content: "pending" })
  committed.add(committedBody)
  pending.add(pendingBody)
  setup.renderer.root.add(committed)
  setup.renderer.root.add(pending)

  try {
    await setup.renderOnce()
    expect(committed.height).toBe(3)
    expect(pending.height).toBe(committed.height)
    expect(committedBody.screenX - committed.screenX).toBe(1)
    expect(committedBody.screenY - committed.screenY).toBe(1)
    expect(pendingBody.screenX - pending.screenX).toBe(1)
    expect(pendingBody.screenY - pending.screenY).toBe(1)
    expect(pending.screenY - committed.screenY).toBe(committed.height + 1)
    expect(userMessageChromeRows).toBe(3)
    expect(committed.backgroundColor.toInts()[3]).toBe(255)
    expect(pending.backgroundColor.toInts()[3]).toBe(0)
  } finally {
    committed.destroyRecursively()
    pending.destroyRecursively()
    if (!setup.renderer.isDestroyed) setup.renderer.destroy()
  }
})

test("user message content formats text and image markers once", () => {
  expect(formatUserMessageContent([{ text: "describe" }, { mimeType: "image/png" }, { mimeType: "image/jpeg" }])).toBe(
    "describe [image #1] [image #2]"
  )
  expect(formatUserMessageContent([{ mimeType: "image/png" }, { text: "caption" }, { mimeType: "image/jpeg" }])).toBe(
    "[image #1] caption [image #2]"
  )
})
