import { expect, test } from "bun:test"

import { SessionManager } from "../src/session-manager.js"

test("session entries form one append-only branch", () => {
  const session = new SessionManager({ cwd: "/work", sessionDir: "/unused", persist: false })

  const model = session.appendModelChange("anthropic", "claude")
  const thinking = session.appendThinkingLevelChange("medium")
  const message = session.appendMessage({ role: "user", content: "hello", timestamp: 1 })
  const entries = session.entries()

  expect(entries.map(entry => entry.id)).toEqual([model, thinking, message])
  expect(entries.map(entry => entry.parentId)).toEqual([null, model, thinking])
  expect(session.messages()).toEqual([{ role: "user", content: "hello", timestamp: 1 }])
})
