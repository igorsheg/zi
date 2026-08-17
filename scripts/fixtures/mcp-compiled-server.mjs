import { spawn } from "node:child_process"
import { writeFileSync } from "node:fs"
import { createInterface } from "node:readline"

const marker = process.env.MCP_ACCEPTANCE_PID_FILE
if (!marker) throw new Error("MCP_ACCEPTANCE_PID_FILE is required")

const descendant = spawn(process.execPath, ["-e", "setInterval(() => {}, 1 << 30)"], {
  detached: true,
  stdio: "ignore"
})
descendant.unref()
if (!descendant.pid) throw new Error("MCP acceptance descendant did not start")
writeFileSync(marker, JSON.stringify({ server: process.pid, descendant: descendant.pid }))

const lines = createInterface({ input: process.stdin, terminal: false })
lines.on("line", line => {
  const request = JSON.parse(line)
  if (request.id === undefined) return
  switch (request.method) {
    case "initialize":
      send(request.id, {
        protocolVersion: request.params?.protocolVersion ?? "2025-03-26",
        capabilities: { tools: {} },
        serverInfo: { name: "compiled-mcp-acceptance", version: "1.0.0" }
      })
      return
    case "tools/list":
      send(request.id, {
        tools: [
          {
            name: "process_info",
            description: "Return the compiled MCP fixture process identities",
            inputSchema: { type: "object", additionalProperties: false }
          }
        ]
      })
      return
    case "tools/call":
      if (request.params?.name !== "process_info") {
        sendError(request.id, -32_602, "Unknown acceptance tool")
        return
      }
      send(request.id, {
        content: [{ type: "text", text: `server ${process.pid}, descendant ${descendant.pid}` }],
        structuredContent: { server: process.pid, descendant: descendant.pid }
      })
      return
    default:
      sendError(request.id, -32_601, `Unknown method: ${request.method}`)
  }
})

function send(id, result) {
  process.stdout.write(`${JSON.stringify({ jsonrpc: "2.0", id, result })}\n`)
}

function sendError(id, code, message) {
  process.stdout.write(`${JSON.stringify({ jsonrpc: "2.0", id, error: { code, message } })}\n`)
}
