import { expect, test } from "bun:test"

import { SessionManager } from "../src/session-manager.js"
import { createSessionFailuresTool } from "../src/tools/session-failures.js"

function appendFailure(session: SessionManager, index: number): void {
  session.appendMessage({
    role: "toolResult",
    toolCallId: `call-${index}`,
    toolName: "probe",
    content: [{ type: "text", text: `failure-${index}` }],
    isError: true,
    timestamp: index
  })
}

test("session_failures returns bounded journal pages as native Code Mode values", async () => {
  const session = SessionManager.inMemory("/work", "session-1")
  appendFailure(session, 0)
  appendFailure(session, 1)
  appendFailure(session, 2)
  const tool = createSessionFailuresTool(session)
  const signal = new AbortController().signal

  const first = await tool.codeMode.execute("page-1", { cursor: 0, limit: 2 }, signal)
  expect(first.value).toEqual({
    cursor: 0,
    failures: [
      expect.objectContaining({ id: "tool/call-0", message: "failure-0" }),
      expect.objectContaining({ id: "tool/call-1", message: "failure-1" })
    ],
    nextCursor: 2,
    retained: 3,
    omitted: 0
  })

  const second = await tool.codeMode.execute("page-2", { cursor: 2, limit: 2 }, signal)
  expect(second.value).toEqual({
    cursor: 2,
    failures: [expect.objectContaining({ id: "tool/call-2", message: "failure-2" })],
    retained: 3,
    omitted: 0
  })

  expect(tool.codeMode.execute("invalid", { cursor: -1 }, signal)).rejects.toThrow("Invalid session_failures input")
})
