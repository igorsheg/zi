import { spawn } from "node:child_process"
import { appendFileSync, writeFileSync } from "node:fs"
import { createInterface } from "node:readline"

import { isRecord } from "../../src/guards.js"

const mode = process.argv[2] ?? "normal"
const ownsDescendant = mode === "runtime" || mode === "required-hang"
const descendant = ownsDescendant
  ? spawn(process.execPath, ["-e", "setInterval(() => {}, 1 << 30)"], { detached: true, stdio: "ignore" })
  : undefined
descendant?.unref()
if (ownsDescendant && process.env.MCP_PID_FILE && descendant?.pid) {
  writeFileSync(process.env.MCP_PID_FILE, JSON.stringify({ server: process.pid, descendant: descendant.pid }))
}
if (mode === "maximum-stubborn") {
  setInterval(() => undefined, 1 << 30)
  process.stdin.on("end", () => {
    if (process.env.MCP_CLOSE_MARKER) writeFileSync(process.env.MCP_CLOSE_MARKER, "closing")
  })
}
let calls = 0
let listRequests = 0
let catalogPhase = 0

if (mode === "exit") process.exit(7)

const lines = createInterface({ input: process.stdin, terminal: false })
lines.on("line", line => {
  const message = JSON.parse(line)
  if (message.id === undefined) return
  if (mode === "hang" && message.method === "initialize") return
  void respond(message)
})

async function respond(request: {
  readonly id: string | number
  readonly method: string
  readonly params?: Record<string, unknown>
}): Promise<void> {
  switch (request.method) {
    case "initialize":
      if (mode === "required-hang") return
      if (mode === "reflect-env-error") {
        sendError(request.id, -32_000, `Rejected secret: ${process.env.MCP_REFLECTED_SECRET ?? "missing"}`)
        return
      }
      send(request.id, {
        protocolVersion: request.params?.protocolVersion ?? "2025-03-26",
        capabilities: { tools: {} },
        serverInfo: { name: "zi-mcp-host-fixture", version: "1.0.0" }
      })
      return
    case "tools/list":
      await list(request.id, request.params ?? {})
      return
    case "tools/call":
      await call(request.id, request.params ?? {})
      return
    default:
      sendError(request.id, -32601, `Unknown method: ${request.method}`)
  }
}

async function list(id: string | number, params: Record<string, unknown>): Promise<void> {
  listRequests++
  const cursor = typeof params.cursor === "string" ? params.cursor : undefined
  if (mode === "list-error-first") {
    sendError(id, -32_000, "first catalog page failed")
    return
  }
  if (mode === "list-error-second") {
    if (cursor === undefined) send(id, { tools: [tool("partial_page", "must not publish")], nextCursor: "page-2" })
    else sendError(id, -32_000, "later catalog page failed")
    return
  }
  if (mode === "close-after-list") {
    sendAndExit(id, { tools: [tool("vanishing", "Must never become searchable")] })
    return
  }
  if (mode === "paged") {
    send(
      id,
      cursor === undefined
        ? { tools: [tool("page_one", "first page")], nextCursor: "page-2" }
        : { tools: [tool("page_two", "second page")] }
    )
    return
  }
  if (mode === "repeated-cursor") {
    send(id, { tools: [tool(`page_${listRequests}`, "repeated cursor")], nextCursor: "repeat" })
    return
  }
  if (mode === "empty-cursor") {
    send(id, { tools: [tool("empty_cursor", "empty cursor")], nextCursor: "" })
    return
  }
  if (mode === "oversized-cursor") {
    send(id, { tools: [tool("large_cursor", "large cursor")], nextCursor: "x".repeat(4_097) })
    return
  }
  if (mode === "over-pages") {
    const page = cursor === undefined ? 0 : Number(cursor)
    send(id, { tools: [tool(`page_${page}`, "bounded page")], nextCursor: String(page + 1) })
    return
  }
  if (mode === "duplicate-pages") {
    send(
      id,
      cursor === undefined
        ? { tools: [tool("same", "first")], nextCursor: "page-2" }
        : { tools: [tool("same", "second")] }
    )
    return
  }
  if (mode === "maximum-slow") {
    await Bun.sleep(150)
    send(id, { tools: catalog() })
    return
  }
  if (mode === "live-refresh") {
    if (listRequests === 1) {
      send(id, { tools: refreshCatalog("old") })
      return
    }
    const requestedPhase = cursor?.startsWith("refresh-") ? Number(cursor.split("-")[1]) : catalogPhase
    if (cursor === undefined && (requestedPhase === 1 || requestedPhase === 4))
      await Bun.sleep(requestedPhase === 4 ? 500 : 120)
    if (requestedPhase === 1) {
      send(
        id,
        cursor === undefined
          ? { tools: [tool("new_page_one", "new first page")], nextCursor: "refresh-1-page-2" }
          : { tools: [tool("new_page_two", "new second page"), tool("refresh_control", "control refresh")] }
      )
      return
    }
    if (requestedPhase === 2) {
      send(id, { tools: refreshCatalog("final") })
      return
    }
    if (requestedPhase === 3) {
      send(
        id,
        cursor === undefined
          ? { tools: [tool("partial_new", "must not publish")], nextCursor: "refresh-3-page-2" }
          : { tools: [tool("partial_new", "duplicate failure")] }
      )
      return
    }
    send(id, { tools: refreshCatalog("stale") })
    return
  }
  send(id, { tools: catalog() })
}

function refreshCatalog(prefix: string): readonly Record<string, unknown>[] {
  return [tool(`${prefix}_tool`, `${prefix} catalog`), tool("refresh_control", "control refresh")]
}

function catalog(): readonly Record<string, unknown>[] {
  if (mode === "single") return [tool("echo", "Echo JSON arguments")]
  if (mode === "maximum" || mode === "maximum-slow" || mode === "maximum-stubborn") {
    return Array.from({ length: 256 }, (_, index) => tool(`maximum_${index}`, `Maximum catalog tool ${index}`))
  }
  if (mode === "runtime") {
    return [tool("echo", "Echo JSON arguments"), tool("process_info", "Return owned process identities")]
  }
  if (mode === "progress-exit") return [tool("progress_exit", "Publish progress and exit")]
  if (mode === "reflect-secret") {
    const secret = process.env.MCP_REFLECTED_SECRET ?? "missing"
    return [
      {
        ...tool("rich", `reflected ${secret}`),
        inputSchema: {
          type: "object",
          properties: { reflected: { type: "string", description: secret }, [secret]: { type: "string" } }
        },
        outputSchema: { type: "object", properties: { secret: { const: secret } } }
      },
      tool(secret, "Secret-bearing identity must not publish"),
      tool("slow", "Reflect progress"),
      tool("fail", "Reflect failure")
    ]
  }
  if (mode === "duplicate") {
    return [tool("same", "first"), tool("same", "second")]
  }
  if (mode === "too-many-tools") {
    return Array.from({ length: 257 }, (_, index) => tool(`tool_${index}`, "too many tools"))
  }
  if (mode === "catalog-overflow") {
    return Array.from({ length: 256 }, (_, index) => tool(`large_${index}`, "x".repeat(9 * 1024)))
  }
  if (mode === "ranking-primary") {
    return [
      tool("needle", "exact"),
      tool("a_needle", "name token a"),
      tool("run_needle", "name token run"),
      tool("description_hit", "contains needle in description"),
      tool("unrelated", "other")
    ]
  }
  if (mode === "ranking-server") return [tool("server_hit", "server match")]
  if (mode === "oversized") {
    return [
      {
        ...tool("oversized", "oversized schema"),
        inputSchema: { type: "object", properties: { value: { type: "string", description: "x".repeat(33 * 1024) } } }
      }
    ]
  }
  if (mode === "oversized-output") {
    return [
      {
        ...tool("oversized_output", "oversized output schema"),
        outputSchema: { type: "object", description: "x".repeat(33 * 1024) }
      }
    ]
  }
  if (mode === "task-required") {
    return [
      tool("ordinary", "ordinary tool"),
      { ...tool("deferred", "requires tasks"), execution: { taskSupport: "required" } }
    ]
  }
  if (mode === "bulky") {
    return Array.from({ length: 70 }, (_, index) => tool(`bulky_${index}`, "x".repeat(10 * 1024)))
  }
  return [
    tool("search", "Exact source search"),
    tool("search_code", "Search source code"),
    tool("echo", "Echo JSON arguments"),
    tool("slow", "Wait before returning"),
    tool("rich", "Return text JSON and binary content"),
    tool("fail", "Return a server error"),
    tool("counter", "Return the invocation count"),
    tool("huge", "Return oversized text"),
    tool("many", "Return many binary blocks"),
    tool("raw/tool.name", "Preserve raw protocol identity")
  ]
}

function tool(name: string, description: string): Record<string, unknown> {
  return { name, description, inputSchema: { type: "object", additionalProperties: true } }
}

async function call(id: string | number, params: Record<string, unknown>): Promise<void> {
  calls++
  const name = params.name
  const callArguments = isRecord(params.arguments) ? params.arguments : {}
  if (mode === "progress-exit" && name === "progress_exit") {
    const metaValue = params["_meta"]
    const meta = isRecord(metaValue) ? metaValue : undefined
    const progressToken = meta?.progressToken
    if (typeof progressToken === "string" || typeof progressToken === "number") {
      const progress = JSON.stringify({
        jsonrpc: "2.0",
        method: "notifications/progress",
        params: { progressToken, progress: 1, message: "before exit" }
      })
      if (process.env.MCP_CALL_FILE) appendFileSync(process.env.MCP_CALL_FILE, "call\n")
      process.stdout.write(`${progress}\n`, () => process.exit(9))
    } else {
      process.exit(9)
    }
    return
  }
  if (mode === "live-refresh" && name === "refresh_control") {
    const action = callArguments.action
    if (action === "refresh") catalogPhase = 1
    else if (action === "rerun") catalogPhase = 2
    else if (action === "fail") catalogPhase = 3
    else if (action === "stale") catalogPhase = 4
    if (action !== "stats") {
      notify("notifications/tools/list_changed", {})
      if (action === "rerun") notify("notifications/tools/list_changed", {})
    }
    send(id, { content: [{ type: "text", text: String(listRequests) }], structuredContent: { listRequests } })
    return
  }
  if (name === "slow") {
    const metaValue = params["_meta"]
    const meta = isRecord(metaValue) ? metaValue : undefined
    const progressToken = meta?.progressToken
    if (typeof progressToken === "string" || typeof progressToken === "number") {
      notify("notifications/progress", {
        progressToken,
        progress: 1,
        total: 2,
        message: mode === "reflect-secret" ? (process.env.MCP_REFLECTED_SECRET ?? "missing") : "half complete"
      })
    }
    const delay = typeof callArguments.delayMs === "number" ? callArguments.delayMs : 100
    await Bun.sleep(delay)
  }
  if (name === "fail") {
    send(id, {
      content: [
        {
          type: "text",
          text:
            mode === "reflect-secret"
              ? `fixture failure ${process.env.MCP_REFLECTED_SECRET ?? "missing"}`
              : "fixture failure"
        }
      ],
      isError: true
    })
    return
  }
  if (name === "rich") {
    const reflected = mode === "reflect-secret" ? (process.env.MCP_REFLECTED_SECRET ?? "missing") : undefined
    send(id, {
      content: [
        { type: "text", text: reflected ?? "rich text" },
        { type: "image", data: "aW1hZ2U=", mimeType: "image/png" },
        { type: "audio", data: "YXVkaW8=", mimeType: "audio/wav" },
        { type: "resource", resource: { uri: "file:///secret", mimeType: "text/plain", text: "secret body" } },
        { type: "resource_link", uri: "https://example.invalid/secret", name: "secret", mimeType: "text/plain" }
      ],
      structuredContent: reflected ? { answer: reflected, [reflected]: "reflected-key" } : { answer: 42 }
    })
    return
  }
  if (name === "counter") {
    send(id, { content: [{ type: "text", text: String(calls) }], structuredContent: { calls } })
    return
  }
  if (name === "process_info") {
    send(id, {
      content: [{ type: "text", text: `server ${process.pid}` }],
      structuredContent: { server: process.pid, descendant: descendant?.pid ?? null }
    })
    return
  }
  if (name === "huge") {
    send(id, { content: [{ type: "text", text: "x".repeat(300 * 1024) }] })
    return
  }
  if (name === "many") {
    send(id, { content: Array.from({ length: 2_000 }, () => ({ type: "image", data: "eA==", mimeType: "image/png" })) })
    return
  }
  send(id, { content: [{ type: "text", text: JSON.stringify(callArguments) }], structuredContent: callArguments })
}

function send(id: string | number, result: unknown): void {
  process.stdout.write(`${JSON.stringify({ jsonrpc: "2.0", id, result })}\n`)
}

function sendError(id: string | number, code: number, message: string): void {
  process.stdout.write(`${JSON.stringify({ jsonrpc: "2.0", id, error: { code, message } })}\n`)
}

function sendAndExit(id: string | number, result: unknown): void {
  process.stdout.write(`${JSON.stringify({ jsonrpc: "2.0", id, result })}\n`, () => process.exit(0))
}

function notify(method: string, params: unknown): void {
  process.stdout.write(`${JSON.stringify({ jsonrpc: "2.0", method, params })}\n`)
}
