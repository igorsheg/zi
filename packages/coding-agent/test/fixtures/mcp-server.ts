import { spawn } from "node:child_process"
import { createInterface } from "node:readline"

const mode = process.argv[2] ?? "echo"

switch (mode) {
  case "malformed-utf8":
    process.stdout.write(Buffer.from([0xff, 0x0a]))
    setInterval(() => {}, 1 << 30)
    break
  case "malformed-json":
    process.stdout.write("not-json\n")
    setInterval(() => {}, 1 << 30)
    break
  case "unterminated":
    setTimeout(() => {
      process.stdout.write('{"jsonrpc":"2.0"')
      process.stdout.end()
    }, 25)
    break
  case "oversized":
    process.stdout.write(Buffer.alloc(1024 * 1024 + 1, 0x61))
    setInterval(() => {}, 1 << 30)
    break
  case "exit":
    setTimeout(() => process.exit(7), 25)
    break
  default:
    runServer(mode)
    break
}

function runServer(serverMode: string): void {
  if (serverMode === "stderr") {
    process.stderr.write(`${"x".repeat(55 * 1024)}STDERR_TAIL_MARKER`)
  }
  const descendant =
    serverMode === "descendant"
      ? spawn(process.execPath, ["-e", "setInterval(() => {}, 1 << 30)"], { detached: true, stdio: "ignore" })
      : undefined
  descendant?.unref()

  const lines = createInterface({ input: process.stdin, terminal: false })
  lines.on("line", line => {
    const request = JSON.parse(line)
    if (request.id === undefined) return
    const result =
      request.method === "initialize"
        ? {
            protocolVersion: request.params?.protocolVersion ?? "2025-03-26",
            capabilities: { tools: {} },
            serverInfo: { name: "zi-mcp-fixture", version: "1.0.0" },
            ...(descendant?.pid ? { descendantPid: descendant.pid } : {})
          }
        : { echo: request.params ?? null }
    process.stdout.write(`${JSON.stringify({ jsonrpc: "2.0", id: request.id, result })}\n`)
  })
}
