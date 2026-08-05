import { expect, test } from "bun:test"
import { mkdtemp, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { runRpcPrompt } from "../examples/rpc/client.js"

test("the reference RPC client completes a prompt through correlated ordered frames", async () => {
  const temporary = await mkdtemp(join(tmpdir(), "zi-rpc-client-"))
  const server = join(temporary, "server.ts")
  const requests = join(temporary, "requests.jsonl")

  try {
    await Bun.write(server, mockServer(requests, false))
    expect(
      await runRpcPrompt({ command: [process.execPath, server], cwd: temporary, env: process.env, prompt: "hello" })
    ).toBe("done")
    expect(
      (await Bun.file(requests).text())
        .trimEnd()
        .split("\n")
        .map(line => JSON.parse(line).method)
    ).toEqual(["session.prompt", "session.await_idle", "session.get_messages"])
  } finally {
    await rm(temporary, { recursive: true, force: true })
  }
})

test("the reference RPC client force-bounds a server that ignores graceful shutdown", async () => {
  const temporary = await mkdtemp(join(tmpdir(), "zi-rpc-client-force-close-"))
  const server = join(temporary, "server.ts")
  const requests = join(temporary, "requests.jsonl")

  try {
    await Bun.write(server, mockServer(requests, false, true))
    expect(
      await runRpcPrompt({ command: [process.execPath, server], cwd: temporary, env: process.env, prompt: "hello" })
    ).toBe("done")
  } finally {
    await rm(temporary, { recursive: true, force: true })
  }
}, 15_000)

test("the reference RPC client cancellation owns its child process", async () => {
  const temporary = await mkdtemp(join(tmpdir(), "zi-rpc-client-cancel-"))
  const server = join(temporary, "server.ts")
  const controller = new AbortController()

  try {
    await Bun.write(
      server,
      `process.stdout.write(JSON.stringify({ version: 1, sequence: 1, type: "ready", state: { sessionId: "test" } }) + "\\n")
for await (const _chunk of process.stdin) {}
`
    )
    const running = runRpcPrompt({
      command: [process.execPath, server],
      cwd: temporary,
      env: process.env,
      prompt: "hello",
      signal: controller.signal
    })
    await Bun.sleep(20)
    controller.abort()
    expect(running).rejects.toThrow("RPC client was cancelled")
  } finally {
    await rm(temporary, { recursive: true, force: true })
  }
})

test("the reference RPC client rejects a server sequence gap", async () => {
  const temporary = await mkdtemp(join(tmpdir(), "zi-rpc-client-gap-"))
  const server = join(temporary, "server.ts")
  const requests = join(temporary, "requests.jsonl")

  try {
    await Bun.write(server, mockServer(requests, true))
    expect(
      runRpcPrompt({ command: [process.execPath, server], cwd: temporary, env: process.env, prompt: "hello" })
    ).rejects.toThrow("RPC server sequence gap")
  } finally {
    await rm(temporary, { recursive: true, force: true })
  }
})

function mockServer(requests: string, sequenceGap: boolean, resistShutdown = false): string {
  return `import { appendFileSync } from "node:fs"
${resistShutdown ? 'process.on("SIGTERM", () => {})\nsetInterval(() => {}, 1000)' : ""}
let sequence = 0
const send = value => process.stdout.write(JSON.stringify({ version: 1, sequence: ++sequence, ...value }) + "\\n")
send({ type: "ready", state: { sessionId: "test" } })
let buffer = ""
for await (const chunk of process.stdin) {
  buffer += chunk.toString()
  while (buffer.includes("\\n")) {
    const newline = buffer.indexOf("\\n")
    const line = buffer.slice(0, newline)
    buffer = buffer.slice(newline + 1)
    if (!line) continue
    appendFileSync(${JSON.stringify(requests)}, line + "\\n")
    const request = JSON.parse(line)
    if (request.method === "session.prompt") {
      ${sequenceGap ? "sequence++" : ""}
      send({ type: "response", id: request.id, method: request.method, ok: true, result: { delivery: "direct" } })
    } else if (request.method === "session.await_idle") {
      send({ type: "session_event", event: { type: "agent_settled" } })
      send({ type: "response", id: request.id, method: request.method, ok: true, result: {} })
    } else if (request.method === "session.get_messages") {
      send({
        type: "response",
        id: request.id,
        method: request.method,
        ok: true,
        result: {
          start: 0,
          total: 2,
          nextStart: null,
          messages: [
            { role: "user", content: [{ type: "text", text: "hello" }] },
            { role: "assistant", stopReason: "stop", content: [{ type: "text", text: "done" }] }
          ]
        }
      })
    }
  }
}
`
}
