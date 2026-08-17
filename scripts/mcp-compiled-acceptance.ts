import { realpathSync } from "node:fs"
import { copyFile, mkdir, mkdtemp, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join, resolve } from "node:path"

import { isRecord } from "../packages/coding-agent/src/guards.js"

const acceptancePrompt = "Use the compiled MCP server and report the acceptance result."
const acceptanceResult = "MCP compiled acceptance passed."
const maxProviderRequestBytes = 2 * 1024 * 1024
const maxProcessOutputBytes = 8 * 1024 * 1024
const processDeadlineMs = 15_000
const processExitDeadlineMs = 2_000
const temporaryCleanupDeadlineMs = process.platform === "win32" ? 5_000 : 500
const temporaryCleanupRetryDelayMs = 100

interface AcceptancePids {
  readonly server: number
  readonly descendant: number
}

type ProviderState =
  | { readonly type: "awaiting_code_call" }
  | { readonly type: "awaiting_code_result" }
  | { readonly type: "complete"; readonly pids: AcceptancePids }
  | { readonly type: "failed"; readonly message: string }

export async function runMcpCompiledAcceptance(options: { readonly executable: string }): Promise<void> {
  const temporary = await mkdtemp(join(tmpdir(), "zi-mcp-compiled-"))
  const project = join(temporary, "project")
  const home = join(temporary, "home")
  const agentDirectory = join(temporary, "agent")
  const fixture = join(temporary, "mcp-server.mjs")
  const pidFile = join(temporary, "mcp-pids.json")
  const source = resolve(import.meta.dirname, "fixtures/mcp-compiled-server.mjs")
  let child: Bun.Subprocess | undefined
  let provider: McpAcceptanceProvider | undefined
  let pids: AcceptancePids | undefined

  try {
    await mkdir(join(project, ".zi"), { recursive: true })
    await mkdir(home, { recursive: true })
    await mkdir(agentDirectory, { recursive: true })
    await copyFile(source, fixture)
    await writeFile(
      join(project, ".zi", "settings.json"),
      `${JSON.stringify(
        {
          mcpServers: {
            compiled: {
              transport: "stdio",
              command: [process.execPath, fixture],
              required: true,
              environment: { MCP_ACCEPTANCE_PID_FILE: pidFile }
            }
          }
        },
        null,
        2
      )}\n`
    )
    await writeFile(join(agentDirectory, "trust.json"), JSON.stringify({ [realpathSync.native(project)]: true }))

    provider = new McpAcceptanceProvider()
    child = Bun.spawn(
      [
        options.executable,
        "--mode",
        "text",
        "--no-session",
        "--code-only",
        "--cwd",
        project,
        "--model",
        "azure-openai-responses/gpt-4.1",
        "--api-key",
        "mcp-compiled-acceptance",
        "--thinking",
        "off",
        acceptancePrompt
      ],
      {
        cwd: project,
        env: {
          ...process.env,
          HOME: home,
          ZI_AGENT_DIR: agentDirectory,
          AZURE_OPENAI_BASE_URL: provider.baseUrl,
          TERM: "xterm-256color"
        },
        stdin: "ignore",
        stdout: "pipe",
        stderr: "pipe"
      }
    )

    if (!child.stdout || typeof child.stdout === "number" || !child.stderr || typeof child.stderr === "number") {
      throw new Error("Compiled MCP acceptance did not expose stdout and stderr pipes")
    }
    const [exitCode, stdout, stderr] = await settleProcess(
      child,
      readBoundedStream(child.stdout, "stdout"),
      readBoundedStream(child.stderr, "stderr")
    )
    if (exitCode !== 0 || normalizeNewlines(stdout) !== `${acceptanceResult}\n` || stderr !== "") {
      throw new Error(
        `Compiled MCP acceptance exited with ${exitCode}: stdout=${JSON.stringify(stdout)} stderr=${JSON.stringify(stderr)}`
      )
    }

    const providerPids = provider.completePids()
    pids = await readPidMarker(pidFile)
    if (pids.server !== providerPids.server || pids.descendant !== providerPids.descendant) {
      throw new Error("Compiled MCP result did not match the owned fixture process identities")
    }
    await Promise.all([waitForExit(pids.server), waitForExit(pids.descendant)])
  } finally {
    child?.kill()
    if (!pids && (await Bun.file(pidFile).exists())) pids = await readPidMarker(pidFile).catch(() => undefined)
    if (pids) {
      killSurvivor(pids.server)
      killSurvivor(pids.descendant)
    }
    await provider?.dispose()
    await removeTemporaryDirectory(temporary)
  }
}

class McpAcceptanceProvider {
  readonly #server: ReturnType<typeof Bun.serve>
  #state: ProviderState = { type: "awaiting_code_call" }

  constructor() {
    this.#server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: request => this.#receive(request) })
  }

  get baseUrl(): string {
    return `${this.#server.url}v1`
  }

  completePids(): AcceptancePids {
    if (this.#state.type === "complete") return this.#state.pids
    const detail = this.#state.type === "failed" ? `: ${this.#state.message}` : ` (${this.#state.type})`
    throw new Error(`Compiled MCP provider round trip did not complete${detail}`)
  }

  async dispose(): Promise<void> {
    await this.#server.stop(true)
  }

  async #receive(request: Request): Promise<Response> {
    try {
      if (request.method !== "POST" || new URL(request.url).pathname !== "/v1/responses") {
        throw new Error(`Unexpected MCP provider request: ${request.method} ${request.url}`)
      }
      const payload: unknown = JSON.parse(await readBoundedRequest(request))
      validateCodeOnlyTools(payload)
      switch (this.#state.type) {
        case "awaiting_code_call":
          this.#state = { type: "awaiting_code_result" }
          return eventStreamResponse(codeCallEvents())
        case "awaiting_code_result": {
          const pids = validateCodeResult(payload)
          this.#state = { type: "complete", pids }
          return eventStreamResponse(textResponseEvents(acceptanceResult, "mcp-final"))
        }
        case "complete":
          throw new Error("MCP acceptance provider received more than two requests")
        case "failed":
          throw new Error(this.#state.message)
        default:
          return assertNever(this.#state)
      }
    } catch (cause) {
      const message = cause instanceof Error ? cause.message : String(cause)
      this.#state = { type: "failed", message }
      return Response.json({ error: { message } }, { status: 500 })
    }
  }
}

function validateCodeOnlyTools(value: unknown): void {
  const payload = requireRecord(value, "MCP provider payload")
  const names = requireArray(payload.tools, "provider tools").map(tool => {
    const registration = requireRecord(tool, "provider tool")
    if (typeof registration.name !== "string") throw new Error("Provider tool name must be a string")
    return registration.name
  })
  if (names.length !== 1 || names[0] !== "code") {
    throw new Error(`Code-only MCP acceptance exposed unexpected provider tools: ${JSON.stringify(names)}`)
  }
}

function validateCodeResult(value: unknown): AcceptancePids {
  const payload = requireRecord(value, "MCP result payload")
  const result = requireArray(payload.input, "provider input")
    .map(item => requireRecord(item, "provider input item"))
    .find(item => item.type === "function_call_output" && item.call_id === "mcp_code_call")
  if (typeof result?.output !== "string") throw new Error("MCP acceptance omitted the Code Mode result")

  const output: unknown = JSON.parse(result.output)
  const projected = requireRecord(output, "Code Mode MCP output")
  const selected = requireRecord(projected.selected, "selected MCP tool")
  const contract = requireRecord(projected.contract, "MCP tool contract")
  const call = requireRecord(projected.call, "MCP tool result")
  const structured = requireRecord(call.structuredContent, "MCP structured result")
  if (selected.server !== "compiled" || selected.tool !== "process_info") {
    throw new Error("Compiled MCP search did not select compiled/process_info")
  }
  if (contract.server !== "compiled" || contract.name !== "process_info") {
    throw new Error("Compiled MCP describe did not return the process_info contract")
  }
  if (!isPositiveInteger(structured.server) || !isPositiveInteger(structured.descendant)) {
    throw new Error("Compiled MCP call did not return process identities")
  }
  return { server: structured.server, descendant: structured.descendant }
}

function codeCallEvents(): readonly Record<string, unknown>[] {
  const item = {
    type: "function_call",
    id: "mcp_code_item",
    call_id: "mcp_code_call",
    name: "code",
    arguments: JSON.stringify({
      description: "Exercise the compiled MCP facade",
      code: `
const [selected] = await zi.mcp_search({ query: "process_info", limit: 1 });
if (!selected) throw new Error("Compiled MCP tool was not discovered");
const contract = await zi.mcp_describe({ server: selected.server, tool: selected.tool });
const call = await zi.mcp_call({ server: selected.server, tool: selected.tool, arguments: {} });
return { selected, contract, call };
`
    }),
    status: "completed"
  }
  return [
    { type: "response.created", response: { id: "mcp_response" } },
    { type: "response.output_item.added", output_index: 0, item: { ...item, arguments: "", status: "in_progress" } },
    {
      type: "response.function_call_arguments.delta",
      output_index: 0,
      item_id: "mcp_code_item",
      delta: item.arguments
    },
    {
      type: "response.function_call_arguments.done",
      output_index: 0,
      item_id: "mcp_code_item",
      arguments: item.arguments
    },
    { type: "response.output_item.done", output_index: 0, item },
    { type: "response.completed", response: terminalResponse("mcp_response") }
  ]
}

function textResponseEvents(text: string, id: string): readonly Record<string, unknown>[] {
  const responseId = `response_${id}`
  const messageId = `message_${id}`
  return [
    { type: "response.created", response: { id: responseId } },
    {
      type: "response.output_item.added",
      output_index: 0,
      item: { type: "message", id: messageId, role: "assistant", status: "in_progress", content: [] }
    },
    { type: "response.output_text.delta", output_index: 0, content_index: 0, item_id: messageId, delta: text },
    {
      type: "response.output_item.done",
      output_index: 0,
      item: {
        type: "message",
        id: messageId,
        role: "assistant",
        status: "completed",
        content: [{ type: "output_text", text, annotations: [] }]
      }
    },
    { type: "response.completed", response: terminalResponse(responseId) }
  ]
}

function terminalResponse(id: string): Record<string, unknown> {
  return {
    id,
    status: "completed",
    output: [],
    usage: {
      input_tokens: 1,
      output_tokens: 1,
      total_tokens: 2,
      input_tokens_details: { cached_tokens: 0 },
      output_tokens_details: { reasoning_tokens: 0 }
    }
  }
}

function eventStreamResponse(events: readonly Record<string, unknown>[]): Response {
  const body = `${events.map(event => `data: ${JSON.stringify(event)}\n\n`).join("")}data: [DONE]\n\n`
  return new Response(body, { headers: { "content-type": "text/event-stream" } })
}

async function settleProcess<T extends readonly Promise<string>[]>(
  child: Bun.Subprocess,
  ...outputs: T
): Promise<[number, ...{ [K in keyof T]: string }]> {
  let deadline: ReturnType<typeof setTimeout> | undefined
  const timeout = new Promise<never>((_, reject) => {
    deadline = setTimeout(() => {
      child.kill()
      reject(new Error(`Compiled MCP acceptance did not settle within ${processDeadlineMs}ms`))
    }, processDeadlineMs)
  })
  const settlement = Promise.all([child.exited, ...outputs]) as Promise<[number, ...{ [K in keyof T]: string }]>
  try {
    return await Promise.race([settlement, timeout])
  } catch (cause) {
    child.kill()
    await Promise.allSettled([child.exited, ...outputs])
    throw cause
  } finally {
    if (deadline) clearTimeout(deadline)
  }
}

async function readBoundedStream(stream: ReadableStream<Uint8Array>, name: string): Promise<string> {
  const reader = stream.getReader()
  const decoder = new TextDecoder()
  let bytes = 0
  let text = ""
  try {
    while (true) {
      // One reader owns stream order and rejects before retaining oversized process output.
      // oxlint-disable-next-line no-await-in-loop
      const next = await reader.read()
      if (next.done) break
      bytes += next.value.byteLength
      if (bytes > maxProcessOutputBytes) throw new Error(`${name} exceeded ${maxProcessOutputBytes} bytes`)
      text += decoder.decode(next.value, { stream: true })
    }
    return text + decoder.decode()
  } finally {
    reader.releaseLock()
  }
}

async function readBoundedRequest(request: Request): Promise<string> {
  if (!request.body) return ""
  const reader = request.body.getReader()
  const chunks: Uint8Array[] = []
  let bytes = 0
  try {
    while (true) {
      // Provider input remains bounded independently of model and tool payload sizes.
      // oxlint-disable-next-line no-await-in-loop
      const next = await reader.read()
      if (next.done) break
      bytes += next.value.byteLength
      if (bytes > maxProviderRequestBytes) throw new Error(`Provider request exceeded ${maxProviderRequestBytes} bytes`)
      chunks.push(next.value)
    }
  } finally {
    reader.releaseLock()
  }
  const body = new Uint8Array(bytes)
  let offset = 0
  for (const chunk of chunks) {
    body.set(chunk, offset)
    offset += chunk.byteLength
  }
  return new TextDecoder("utf-8", { fatal: true }).decode(body)
}

async function readPidMarker(path: string): Promise<AcceptancePids> {
  const file = Bun.file(path)
  if (file.size > 4 * 1024) throw new Error("MCP acceptance PID marker exceeded 4096 bytes")
  const value: unknown = JSON.parse(await file.text())
  if (!isRecord(value) || !isPositiveInteger(value.server) || !isPositiveInteger(value.descendant)) {
    throw new Error("MCP acceptance PID marker was invalid")
  }
  return { server: value.server, descendant: value.descendant }
}

async function waitForExit(pid: number): Promise<void> {
  const deadline = Date.now() + processExitDeadlineMs
  while (isAlive(pid)) {
    if (Date.now() >= deadline) throw new Error(`MCP acceptance process ${pid} remained alive after Zi exited`)
    // Process settlement is externally observable and bounded by one fixed deadline.
    // oxlint-disable-next-line no-await-in-loop
    await Bun.sleep(10)
  }
}

function isAlive(pid: number): boolean {
  try {
    process.kill(pid, 0)
    return true
  } catch {
    return false
  }
}

function killSurvivor(pid: number): void {
  try {
    process.kill(pid, "SIGKILL")
  } catch {
    // The process already settled.
  }
}

async function removeTemporaryDirectory(path: string): Promise<void> {
  const deadline = Date.now() + temporaryCleanupDeadlineMs
  while (true) {
    try {
      // Cleanup attempts are serialized because each observes handles released by the previous attempt.
      // oxlint-disable-next-line no-await-in-loop
      await rm(path, { recursive: true, force: true })
      return
    } catch (cause) {
      if (!isRetryableCleanupError(cause) || Date.now() >= deadline) throw cause
      // oxlint-disable-next-line no-await-in-loop
      await Bun.sleep(temporaryCleanupRetryDelayMs)
    }
  }
}

function isRetryableCleanupError(cause: unknown): boolean {
  if (!(cause instanceof Error) || !("code" in cause)) return false
  return ["EACCES", "EBUSY", "ENOTEMPTY", "EPERM"].includes(String(cause.code))
}

function normalizeNewlines(value: string): string {
  return value.replaceAll("\r\n", "\n")
}

function isPositiveInteger(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value > 0
}

function requireRecord(value: unknown, name: string): Record<string, unknown> {
  if (!isRecord(value)) throw new Error(`${name} must be an object`)
  return value
}

function requireArray(value: unknown, name: string): unknown[] {
  if (!Array.isArray(value)) throw new Error(`${name} must be an array`)
  return value
}

function assertNever(value: never): never {
  throw new Error(`Unexpected MCP provider state: ${JSON.stringify(value)}`)
}

if (import.meta.main) {
  const executable = process.argv[2]
  if (!executable) throw new Error("Usage: bun scripts/mcp-compiled-acceptance.ts <zi-executable>")
  await runMcpCompiledAcceptance({ executable: resolve(executable) })
}
