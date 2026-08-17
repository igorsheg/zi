import { isRecord } from "../../src/guards.js"

export type McpHttpFixtureMode =
  | "normal"
  | "drop-call"
  | "slow-call"
  | "invalidate-once"
  | "invalidate-once-slow-recovery"
  | "oversized-body"
  | "oversized-headers"
  | "oversized-sse-line"
  | "oversized-sse-event"
  | "slow-list"
  | "refresh-on-call"
  | "terminal-refresh"
  | "reconnect-exhaustion"
  | "reflect-header"
  | "resume-call"
  | "retry-exhaustion"

export interface McpHttpActivity {
  activeLists: number
  maxActiveLists: number
}

export interface McpHttpFixture {
  readonly url: string
  readonly posts: readonly string[]
  readonly gets: readonly string[]
  readonly headers: readonly string[]
  readonly initializeCount: number
  allowRecovery(): void
  close(): Promise<void>
}

export function createMcpHttpFixture(mode: McpHttpFixtureMode = "normal", activity?: McpHttpActivity): McpHttpFixture {
  const posts: string[] = []
  const gets: string[] = []
  const headers: string[] = []
  let initializeCount = 0
  let listCount = 0
  let invalidated = false
  let recoveryAllowed = false
  const invalidatedSessions = new Set<string>()
  let resumeRequestId: string | number = 0
  const server = Bun.serve({
    port: 0,
    async fetch(request) {
      headers.push(request.headers.get("x-fixture-token") ?? "")
      if (request.method === "GET") {
        const eventId = request.headers.get("last-event-id") ?? ""
        gets.push(eventId)
        if (mode === "resume-call" && eventId === "resume-1") {
          return sse(
            `data: ${JSON.stringify(success(resumeRequestId, { content: [{ type: "text", text: "resumed" }] }))}\n\n`
          )
        }
        if (mode === "retry-exhaustion" && eventId === "retry-1") {
          return new Response("retry failed", { status: 500 })
        }
        return new Response(null, { status: 405 })
      }
      if (request.method !== "POST") return new Response(null, { status: 405 })

      const body = await request.text()
      const parsed: unknown = JSON.parse(body)
      if (!isRecord(parsed)) return new Response("invalid", { status: 400 })
      const method = typeof parsed.method === "string" ? parsed.method : "notification"
      posts.push(method)
      if (parsed.id === undefined) return new Response(null, { status: 202 })
      const id = typeof parsed.id === "string" || typeof parsed.id === "number" ? parsed.id : 0
      const params = isRecord(parsed.params) ? parsed.params : {}

      if (method === "initialize") {
        initializeCount++
        if (mode === "reconnect-exhaustion" && initializeCount > 1 && !recoveryAllowed) {
          return new Response("reconnect failed", { status: 500 })
        }
        return json(
          success(id, {
            protocolVersion: typeof params.protocolVersion === "string" ? params.protocolVersion : "2025-11-25",
            capabilities: { tools: {} },
            serverInfo: { name: "zi-http-fixture", version: "1.0.0" }
          }),
          true,
          mode === "invalidate-once-slow-recovery" ? { "mcp-session-id": `fixture-session-${initializeCount}` } : {}
        )
      }
      if (method === "tools/list") {
        listCount++
        if (mode === "terminal-refresh" && listCount === 2) {
          return new Response("refresh session failed", { status: 410 })
        }
        if (activity) {
          activity.activeLists++
          activity.maxActiveLists = Math.max(activity.maxActiveLists, activity.activeLists)
        }
        try {
          if (mode === "slow-list") await Bun.sleep(250)
          if (mode === "refresh-on-call" || (mode === "invalidate-once-slow-recovery" && initializeCount > 1)) {
            await Bun.sleep(100)
          }
        } finally {
          if (activity) activity.activeLists--
        }
        if (mode === "oversized-body") return jsonText("x".repeat(1024 * 1024 + 1))
        if (mode === "oversized-headers") {
          const responseHeaders: Record<string, string> = Object.create(null)
          for (let index = 0; index < 80; index++) responseHeaders[`x-large-${index}`] = "x".repeat(1024)
          return json(success(id, { tools: [tool("echo")] }), false, responseHeaders)
        }
        if (mode === "oversized-sse-line") return sse(`data: ${"x".repeat(64 * 1024)}\n\n`)
        if (mode === "oversized-sse-event") {
          const line = `data: ${"x".repeat(60 * 1024)}\n`
          return sse(`${line.repeat(18)}\n`)
        }
        if (mode === "reflect-header") {
          const reflected = request.headers.get("x-fixture-token") ?? "missing"
          return json(
            success(id, {
              tools: [
                {
                  ...tool("echo"),
                  description: `reflected ${reflected}`,
                  inputSchema: { type: "object", properties: { [reflected]: { const: reflected } } }
                },
                tool(reflected)
              ]
            })
          )
        }
        return json(success(id, { tools: [tool("echo")] }))
      }
      if (method === "tools/call") {
        if (mode === "slow-call") await Bun.sleep(250)
        if (mode === "drop-call") {
          void server.stop(true)
          await Bun.sleep(50)
          return json(success(id, { content: [{ type: "text", text: "must not arrive" }] }))
        }
        if ((mode === "invalidate-once" || mode === "reconnect-exhaustion") && !invalidated) {
          invalidated = true
          return new Response("invalid session", { status: 410 })
        }
        if (mode === "invalidate-once-slow-recovery") {
          const session = request.headers.get("mcp-session-id") ?? ""
          if (!invalidatedSessions.has(session)) {
            invalidatedSessions.add(session)
            return new Response("invalid session", { status: 410 })
          }
        }
        if (mode === "resume-call") {
          resumeRequestId = id
          return sse("id: resume-1\nretry: 0\ndata: \n\n")
        }
        if (mode === "retry-exhaustion") return sse("id: retry-1\nretry: 0\ndata: \n\n")
        if (mode === "refresh-on-call" || mode === "terminal-refresh") {
          const notification = { jsonrpc: "2.0", method: "notifications/tools/list_changed" }
          return sse(
            `data: ${JSON.stringify(notification)}\n\ndata: ${JSON.stringify(success(id, { content: [{ type: "text", text: "echo" }] }))}\n\n`
          )
        }
        if (mode === "reflect-header") {
          const reflected = request.headers.get("x-fixture-token") ?? "missing"
          return json(
            success(id, {
              content: [{ type: "text", text: reflected }],
              structuredContent: { reflected, [reflected]: "reflected-key" }
            })
          )
        }
        return json(success(id, { content: [{ type: "text", text: "echo" }] }))
      }
      return json(error(id, -32_601, `Unknown method: ${method}`))
    }
  })

  return {
    url: `http://127.0.0.1:${server.port}/mcp`,
    posts,
    gets,
    headers,
    get initializeCount() {
      return initializeCount
    },
    allowRecovery() {
      recoveryAllowed = true
    },
    async close() {
      await server.stop(true)
    }
  }
}

function tool(name: string): Record<string, unknown> {
  return { name, description: "HTTP fixture tool", inputSchema: { type: "object", additionalProperties: true } }
}

function success(id: string | number, result: unknown): Record<string, unknown> {
  return { jsonrpc: "2.0", id, result }
}

function error(id: string | number, code: number, message: string): Record<string, unknown> {
  return { jsonrpc: "2.0", id, error: { code, message } }
}

function json(value: unknown, session = false, extraHeaders: Readonly<Record<string, string>> = {}): Response {
  return new Response(JSON.stringify(value), {
    headers: {
      "content-type": "application/json",
      ...(session ? { "mcp-session-id": "fixture-session" } : {}),
      ...extraHeaders
    }
  })
}

function jsonText(value: string): Response {
  return new Response(value, { headers: { "content-type": "application/json" } })
}

function sse(value: string): Response {
  return new Response(value, { headers: { "content-type": "text/event-stream" } })
}
