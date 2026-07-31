import { spawn } from "node:child_process"
import { appendFileSync, writeFileSync } from "node:fs"

/**
 * Minimal Zi RPC child for subagent vertical-slice tests.
 * Speaks protocol v1 over stdin/stdout JSONL; ignores CLI argv.
 *
 * Concurrent request handling matters: interrupt must be able to land while
 * session.await_idle is still sleeping, matching reserved control capacity.
 *
 * Optional env:
 *   MOCK_RPC_REPLY — assistant text (default "child-done")
 *   MOCK_RPC_DELAY_MS — delay before await_idle settles (default 30)
 *   MOCK_RPC_LOG — path to append received methods
 *   MOCK_RPC_ARGV — path to write the child CLI arguments
 *   MOCK_RPC_DESCENDANT_PID — path to write a long-lived descendant PID
 *   MOCK_RPC_PROTOCOL_CRASH — emit a malformed protocol frame after startup
 */
let sequence = 0
const reply = process.env.MOCK_RPC_REPLY ?? "child-done"
const delayMs = Number(process.env.MOCK_RPC_DELAY_MS ?? "30")
const logPath = process.env.MOCK_RPC_LOG
const descendantPath = process.env.MOCK_RPC_DESCENDANT_PID
const argvPath = process.env.MOCK_RPC_ARGV

if (argvPath) writeFileSync(argvPath, JSON.stringify(process.argv.slice(2)))

if (descendantPath) {
  const descendant = spawn(process.execPath, ["-e", "setInterval(() => {}, 1 << 30)"], { stdio: "ignore" })
  if (!descendant.pid) throw new Error("mock descendant did not start")
  writeFileSync(descendantPath, String(descendant.pid))
  descendant.unref()
}

type Message =
  | { readonly role: "user"; readonly content: readonly [{ readonly type: "text"; readonly text: string }] }
  | {
      readonly role: "assistant"
      readonly stopReason: string
      readonly content: readonly [{ readonly type: "text"; readonly text: string }]
    }

type RequestParams = { delivery?: string; text?: string; mode?: string; start?: number; limit?: number }

const messages: Message[] = []
let busy = false
let writeTail = Promise.resolve()

const send = (value: Record<string, unknown>): void => {
  // Serialize sequence assignment and stdout so concurrent handlers stay ordered.
  writeTail = writeTail.then(() => {
    sequence += 1
    process.stdout.write(`${JSON.stringify({ version: 1, sequence, ...value })}\n`)
    return undefined
  })
}

const log = (method: string): void => {
  if (!logPath) return
  appendFileSync(logPath, `${method}\n`)
}

send({
  type: "ready",
  state: {
    sessionId: "mock-child-session",
    activity: { type: "idle" },
    model: { type: "unselected" },
    thinkingLevel: "off",
    supportedThinkingLevels: ["off"],
    steeringMode: "one-at-a-time",
    followUpMode: "one-at-a-time",
    queuedInputs: { steering: [], followUp: [] },
    messageCount: 0,
    compaction: { type: "idle" },
    retry: { type: "idle" },
    contextUsage: { type: "unavailable", reason: "no_model" }
  }
})

if (process.env.MOCK_RPC_PROTOCOL_CRASH === "1") {
  setTimeout(() => process.stdout.write("not-json\n"), 150)
}

async function handle(request: { id: string; method: string; params?: RequestParams }): Promise<void> {
  const { id, method } = request
  log(method)

  if (method === "connection.set_events") {
    send({ type: "response", id, method, ok: true, result: { mode: request.params?.mode ?? "all" } })
    return
  }
  if (method === "session.get_state") {
    send({
      type: "response",
      id,
      method,
      ok: true,
      result: {
        sessionId: "mock-child-session",
        activity: { type: busy ? "running" : "idle" },
        messageCount: messages.length
      }
    })
    return
  }
  if (method === "session.prompt") {
    const text = request.params?.text ?? ""
    if (text === "__block_prompt__") await Bun.sleep(30_000)
    messages.push({ role: "user", content: [{ type: "text", text }] })
    messages.push({ role: "assistant", stopReason: "stop", content: [{ type: "text", text: reply }] })
    busy = true
    send({ type: "response", id, method, ok: true, result: { delivery: request.params?.delivery ?? "direct" } })
    return
  }
  if (method === "session.await_idle") {
    const wait = Number.isFinite(delayMs) ? delayMs : 30
    const deadline = Date.now() + wait
    while (Date.now() < deadline) {
      if (!busy) break
      // oxlint-disable-next-line no-await-in-loop -- poll so interrupt can clear busy early
      await Bun.sleep(10)
    }
    busy = false
    send({ type: "response", id, method, ok: true, result: {} })
    return
  }
  if (method === "session.get_messages") {
    const start = Math.max(0, request.params?.start ?? 0)
    const limit = Math.max(1, request.params?.limit ?? 100)
    const page = messages.slice(start, start + limit)
    const nextStart = start + page.length < messages.length ? start + page.length : null
    send({
      type: "response",
      id,
      method,
      ok: true,
      result: { start, total: messages.length, nextStart, messages: page }
    })
    return
  }
  if (method === "session.interrupt") {
    const latest = messages.at(-1)
    if (busy && latest && latest.role === "assistant") {
      messages[messages.length - 1] = { role: "assistant", stopReason: "aborted", content: latest.content }
    }
    busy = false
    send({ type: "response", id, method, ok: true, result: {} })
    return
  }
  send({ type: "response", id, method, ok: false, error: { code: "not_found", message: `unknown method ${method}` } })
}

let buffer = ""
const pending: Promise<void>[] = []
for await (const chunk of process.stdin) {
  buffer += chunk.toString()
  while (buffer.includes("\n")) {
    const newline = buffer.indexOf("\n")
    const line = buffer.slice(0, newline)
    buffer = buffer.slice(newline + 1)
    if (!line.trim()) continue
    let request: { id?: string; method?: string; params?: RequestParams }
    try {
      request = JSON.parse(line)
    } catch {
      send({ type: "protocol_error", code: "invalid_json", message: "invalid json" })
      continue
    }
    if (typeof request.id !== "string" || typeof request.method !== "string") {
      send({ type: "protocol_error", code: "invalid_request", message: "missing id/method" })
      continue
    }
    const id = request.id
    const method = request.method
    const params = request.params
    pending.push(
      handle(params === undefined ? { id, method } : { id, method, params }).catch(cause => {
        const message = cause instanceof Error ? cause.message : String(cause)
        send({ type: "response", id, method, ok: false, error: { code: "operation_failed", message } })
      })
    )
  }
}

await Promise.all(pending)
await writeTail
process.exit(0)
