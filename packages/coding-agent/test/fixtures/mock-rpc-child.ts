import { spawn } from "node:child_process"
import { appendFileSync, existsSync, writeFileSync } from "node:fs"

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
 *   MOCK_RPC_MESSAGES_DELAY_MS — delay before get_messages responds
 *   MOCK_RPC_COMPLETION_DELAY_MS — delay after idle before returning completion evidence
 *   MOCK_RPC_PROMPT_RESPONSE_DELAY_MS — delay an admitted prompt response
 *   MOCK_RPC_INVALID_COMPLETION — return malformed completion evidence
 *   MOCK_RPC_LOG — path to append received methods
 *   MOCK_RPC_ARGV — path to write the child CLI arguments
 *   MOCK_RPC_INTERNAL_API_KEY — path to write the private child credential value
 *   MOCK_RPC_DESCENDANT_PID — path to write a long-lived descendant PID
 *   MOCK_RPC_PROTOCOL_CRASH — emit a malformed protocol frame after startup
 *   MOCK_RPC_EXIT_ON_PROMPT — exit while requests may still be queued on stdin
 *   MOCK_RPC_IGNORE_INTERRUPT — acknowledge interruption without settling work
 *   MOCK_RPC_DROP_INTERRUPT — neither acknowledge nor settle interruption
 *   MOCK_RPC_INTERRUPT_RELEASE — wait for this file before acknowledging interruption
 *   MOCK_RPC_ERROR — assistant error text and failed stop reason
 *   MOCK_RPC_PEER_RESPONSE — path to write one host peer response after the __peer_send__ prompt
 *   MOCK_RPC_PROMPTS_LOG — path to append admitted prompt text
 *   MOCK_RPC_DUPLICATE_PEER_REQUEST — emit the peer request twice
 */
let sequence = 0
const reply = process.env.MOCK_RPC_REPLY ?? "child-done"
const delayMs = Number(process.env.MOCK_RPC_DELAY_MS ?? "30")
const messagesDelayMs = Number(process.env.MOCK_RPC_MESSAGES_DELAY_MS ?? "0")
const completionDelayMs = Number(process.env.MOCK_RPC_COMPLETION_DELAY_MS ?? "0")
const promptResponseDelayMs = Number(process.env.MOCK_RPC_PROMPT_RESPONSE_DELAY_MS ?? "0")
const invalidCompletion = process.env.MOCK_RPC_INVALID_COMPLETION === "1"
const errorMessage = process.env.MOCK_RPC_ERROR
const logPath = process.env.MOCK_RPC_LOG
const descendantPath = process.env.MOCK_RPC_DESCENDANT_PID
const argvPath = process.env.MOCK_RPC_ARGV
const internalApiKeyPath = process.env.MOCK_RPC_INTERNAL_API_KEY
const ignoreInterrupt = process.env.MOCK_RPC_IGNORE_INTERRUPT === "1"
const dropInterrupt = process.env.MOCK_RPC_DROP_INTERRUPT === "1"
const interruptReleasePath = process.env.MOCK_RPC_INTERRUPT_RELEASE
const peerResponsePath = process.env.MOCK_RPC_PEER_RESPONSE
const promptsLogPath = process.env.MOCK_RPC_PROMPTS_LOG
const duplicatePeerRequest = process.env.MOCK_RPC_DUPLICATE_PEER_REQUEST === "1"
const peerOperation = process.env.MOCK_RPC_PEER_OPERATION === "list" ? "list" : "send"
const peerTarget = process.env.MOCK_RPC_PEER_TARGET ?? "worker-b"
let peerRequestScheduled = false

if (argvPath) writeFileSync(argvPath, JSON.stringify(process.argv.slice(2)))
if (internalApiKeyPath) writeFileSync(internalApiKeyPath, process.env.ZI_INTERNAL_SUBAGENT_API_KEY ?? "")

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
      readonly errorMessage?: string
    }

type RequestParams = {
  delivery?: string
  text?: string
  mode?: string
  start?: number
  limit?: number
  completionId?: string
}

const messages: Message[] = []
let busy = false
let eventMode: "all" | "none" = "all"
let activeDelayMs = delayMs
let activeCompletionId: string | undefined
let completionRevision = 0
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

const sendEvent = (event: Record<string, unknown>): void => {
  if (eventMode === "all") send({ type: "session_event", event })
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
    workPlan: { revision: 0, steps: [] },
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
    eventMode = request.params?.mode === "none" ? "none" : "all"
    send({ type: "response", id, method, ok: true, result: { mode: eventMode } })
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
        workPlan: { revision: 0, steps: [] },
        messageCount: messages.length
      }
    })
    return
  }
  if (method === "session.prompt") {
    if (process.env.MOCK_RPC_EXIT_ON_PROMPT === "1") process.exit(7)
    const text = request.params?.text ?? ""
    if (promptsLogPath) appendFileSync(promptsLogPath, `${JSON.stringify(text)}\n`)
    if (peerResponsePath && text === "__peer_send__" && !peerRequestScheduled) {
      peerRequestScheduled = true
      setTimeout(() => {
        const peerRequest =
          peerOperation === "list"
            ? { type: "peer_request", id: "mock-peer-1", operation: "list" }
            : { type: "peer_request", id: "mock-peer-1", operation: "send", target: peerTarget, text: "peer evidence" }
        send(peerRequest)
        if (duplicatePeerRequest) send(peerRequest)
      }, 20)
    }
    if (text === "__reject_prompt__") {
      send({ type: "response", id, method, ok: false, error: { code: "rejected", message: "prompt rejected" } })
      return
    }
    if (request.params?.delivery === "follow_up" && !busy) {
      send({
        type: "response",
        id,
        method,
        ok: true,
        result: { delivery: "follow_up", ...(request.params.completionId ? { completionRevision } : {}) }
      })
      return
    }
    if (request.params?.completionId) {
      if (activeCompletionId !== request.params.completionId) {
        activeCompletionId = request.params.completionId
        completionRevision = 0
      }
      completionRevision++
    }
    if (text === "__block_prompt__") await Bun.sleep(30_000)
    if (text === "__delay_prompt__") await Bun.sleep(150)
    activeDelayMs = text === "__long_work__" ? 30_000 : text === "__short_work__" ? 30 : delayMs
    messages.push({ role: "user", content: [{ type: "text", text }] })
    messages.push({
      role: "assistant",
      stopReason: errorMessage ? "error" : "stop",
      content: [{ type: "text", text: text === "__second_evidence__" ? "second-cycle-evidence" : reply }],
      ...(errorMessage ? { errorMessage } : {})
    })
    sendEvent({ type: "message_start", message: messages.at(-1) })
    sendEvent({ type: "message_update", message: messages.at(-1) })
    busy = true
    if (promptResponseDelayMs > 0) await Bun.sleep(promptResponseDelayMs)
    send({
      type: "response",
      id,
      method,
      ok: true,
      result: {
        delivery: request.params?.delivery ?? "direct",
        ...(request.params?.completionId ? { completionRevision } : {})
      }
    })
    return
  }
  if (method === "session.await_idle") {
    const wait = Number.isFinite(activeDelayMs) ? activeDelayMs : 30
    const deadline = Date.now() + wait
    while (Date.now() < deadline) {
      if (!busy) break
      // oxlint-disable-next-line no-await-in-loop -- poll so interrupt can clear busy early
      await Bun.sleep(10)
    }
    busy = false
    const observedRevision = completionRevision
    const observedLatest = messages.findLast((message): message is Extract<Message, { role: "assistant" }> => {
      return message.role === "assistant"
    })
    if (logPath) appendFileSync(logPath, "session.await_idle:completion\n")
    if (completionDelayMs > 0) await Bun.sleep(completionDelayMs)
    if (!request.params?.completionId) {
      send({ type: "response", id, method, ok: true, result: {} })
      return
    }
    if (request.params.completionId !== activeCompletionId) {
      send({
        type: "response",
        id,
        method,
        ok: false,
        error: { code: "operation_failed", message: "completion watch is not active" }
      })
      return
    }
    if (invalidCompletion) {
      send({ type: "response", id, method, ok: true, result: {} })
      return
    }
    const text = observedLatest?.content.map(part => part.text).join("") ?? ""
    send({
      type: "response",
      id,
      method,
      ok: true,
      result: {
        completionRevision: observedRevision,
        messageCount: messages.length,
        completion: observedLatest
          ? {
              text,
              stopReason: observedLatest.stopReason,
              originalBytes: Buffer.byteLength(text),
              omittedBytes: 0,
              ...(observedLatest.errorMessage ? { error: observedLatest.errorMessage } : {})
            }
          : null
      }
    })
    return
  }
  if (method === "session.get_messages") {
    if (messagesDelayMs > 0) await Bun.sleep(messagesDelayMs)
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
    if (dropInterrupt) return
    if (interruptReleasePath) {
      for (;;) {
        if (existsSync(interruptReleasePath)) break
        // oxlint-disable-next-line no-await-in-loop -- deterministic test barrier.
        await Bun.sleep(5)
      }
    }
    const latest = messages.at(-1)
    if (!ignoreInterrupt && busy && latest && latest.role === "assistant") {
      messages[messages.length - 1] = { role: "assistant", stopReason: "aborted", content: latest.content }
    }
    if (!ignoreInterrupt) busy = false
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
    let request: {
      id?: string
      method?: string
      type?: string
      operation?: string
      ok?: boolean
      result?: unknown
      error?: string
      params?: RequestParams
    }
    try {
      request = JSON.parse(line)
    } catch {
      send({ type: "protocol_error", code: "invalid_json", message: "invalid json" })
      continue
    }
    if (request.type === "peer_response" && typeof request.id === "string") {
      if (peerResponsePath) writeFileSync(peerResponsePath, JSON.stringify(request))
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
