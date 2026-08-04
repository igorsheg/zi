import { realpathSync } from "node:fs"
import { copyFile, mkdir, mkdtemp, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join, resolve } from "node:path"

import { runRpcCommand, runRpcPrompt } from "../examples/rpc/client.js"
import { interactiveAcceptanceArgument } from "../packages/cli/src/main.js"

const acceptancePrompt = "Call repository_status once, then report success."
const acceptanceResult = "Extension acceptance passed."
const expectedStatus = "?? acceptance.txt"
const maxProviderRequestBytes = 2 * 1024 * 1024
const maxProcessOutputBytes = 8 * 1024 * 1024
const processDeadlineMs = 15_000
const temporaryCleanupDeadlineMs = process.platform === "win32" ? 5_000 : 500
const temporaryCleanupRetryDelayMs = 100

type AcceptanceMode = "text" | "json" | "rpc" | "interactive"

type ProviderState =
  | { readonly type: "awaiting_tool_call" }
  | { readonly type: "awaiting_tool_result" }
  | { readonly type: "complete" }
  | { readonly type: "failed"; readonly message: string }

type CounterProviderState =
  | { readonly type: "awaiting_tool_call" }
  | { readonly type: "awaiting_tool_result" }
  | { readonly type: "awaiting_custom_message" }
  | { readonly type: "complete" }
  | { readonly type: "failed"; readonly message: string }

export interface ExtensionCustomToolAcceptanceOptions {
  readonly executable: string
  readonly extensionSource?: string
  readonly durableExtensionSource?: string
  readonly documentationRoot?: string
}

export async function runExtensionCustomToolAcceptance(options: ExtensionCustomToolAcceptanceOptions): Promise<void> {
  const temporary = await mkdtemp(join(tmpdir(), "zi-extension-acceptance-"))
  const project = join(temporary, "project")
  const agentDirectory = join(temporary, "agent")
  const projectExtension = join(project, ".zi", "extensions", "repository-status", "index.ts")
  const durableProjectExtension = join(project, ".zi", "extensions", "durable-counter", "index.ts")
  const extensionSource =
    options.extensionSource ?? resolve(import.meta.dirname, "../examples/extensions/custom-tool/index.ts")
  const durableExtensionSource =
    options.durableExtensionSource ?? resolve(import.meta.dirname, "../examples/extensions/durable-counter/index.ts")

  try {
    await mkdir(join(project, ".zi", "extensions", "repository-status"), { recursive: true })
    await mkdir(join(project, ".zi", "extensions", "durable-counter"), { recursive: true })
    await mkdir(agentDirectory, { recursive: true })
    await copyFile(extensionSource, projectExtension)
    await copyFile(durableExtensionSource, durableProjectExtension)
    await writeFile(join(project, "acceptance.txt"), "extension acceptance\n")
    initializeRepository(project)
    await writeFile(join(agentDirectory, "trust.json"), JSON.stringify({ [realpathSync.native(project)]: true }))

    for (const mode of ["text", "json", "rpc", "interactive"] as const) {
      const provider = new ToolRoundTripProvider(options.documentationRoot)
      try {
        const env = { ...process.env, AZURE_OPENAI_BASE_URL: provider.baseUrl, TERM: "xterm-256color" }
        if (mode === "rpc") {
          // The copyable client owns correlation, event sequencing, paging, and process settlement.
          const controller = new AbortController()
          const deadline = setTimeout(() => controller.abort(), processDeadlineMs)
          let result: string
          try {
            // oxlint-disable-next-line no-await-in-loop
            result = await runRpcPrompt({
              command: [options.executable, ...rpcProductArguments(project, agentDirectory)],
              cwd: project,
              env,
              prompt: acceptancePrompt,
              signal: controller.signal
            })
          } finally {
            clearTimeout(deadline)
          }
          if (normalizeNewlines(result) !== acceptanceResult) {
            throw new Error(`Compiled RPC mode omitted ${JSON.stringify(acceptanceResult)}`)
          }
        } else if (mode === "interactive") {
          // Release modes share one deterministic project and are intentionally accepted in product order.
          // oxlint-disable-next-line no-await-in-loop
          await runInteractive(options.executable, productArguments(mode, project, agentDirectory), project, env)
        } else {
          // oxlint-disable-next-line no-await-in-loop
          const output = await runHeadless(
            options.executable,
            productArguments(mode, project, agentDirectory),
            project,
            env
          )
          if (mode === "text") validateTextOutput(output)
          else validateJsonOutput(output)
        }
        provider.assertComplete(mode)
      } finally {
        // oxlint-disable-next-line no-await-in-loop
        await provider.dispose()
      }
    }
    await runCommandAcceptance(options.executable, project, agentDirectory)
    await runDurableCounterAcceptance(options.executable, project, agentDirectory)
  } finally {
    await removeTemporaryDirectory(temporary)
  }
}

async function runCommandAcceptance(executable: string, project: string, agentDirectory: string): Promise<void> {
  const incremented = await invokeAcceptedCommand(executable, project, agentDirectory, "new", "increment")
  if (incremented !== "Counter: 1") {
    throw new Error(`Compiled extension command returned unexpected output: ${JSON.stringify(incremented)}`)
  }
  const restored = await invokeAcceptedCommand(executable, project, agentDirectory, "continue", "show")
  if (restored !== "Counter: 1") {
    throw new Error(`Compiled extension command did not restore its state: ${JSON.stringify(restored)}`)
  }
}

async function invokeAcceptedCommand(
  executable: string,
  project: string,
  agentDirectory: string,
  session: "new" | "continue",
  arguments_: string
): Promise<string | undefined> {
  const controller = new AbortController()
  const deadline = setTimeout(() => controller.abort(), processDeadlineMs)
  try {
    return await runRpcCommand({
      command: [executable, ...rpcCommandArguments(project, agentDirectory, session)],
      cwd: project,
      env: process.env,
      name: "counter",
      arguments: arguments_,
      signal: controller.signal
    })
  } finally {
    clearTimeout(deadline)
  }
}

async function runDurableCounterAcceptance(executable: string, project: string, agentDirectory: string): Promise<void> {
  for (const expectedCount of [1, 2] as const) {
    const provider = new DurableCounterProvider(expectedCount)
    try {
      const env = { ...process.env, AZURE_OPENAI_BASE_URL: provider.baseUrl }
      // The second process must observe the journal committed by the first.
      // oxlint-disable-next-line no-await-in-loop
      const output = await runHeadless(
        executable,
        durableCounterArguments(project, agentDirectory, expectedCount === 1 ? "new" : "continue"),
        project,
        env
      )
      if (output.exitCode !== 0 || output.stderr !== "") throw processFailure("durable counter", output)
      if (normalizeNewlines(output.stdout) !== `Durable counter ${expectedCount} passed.\n`) {
        throw new Error(`Compiled durable counter returned unexpected output: ${JSON.stringify(output.stdout)}`)
      }
      provider.assertComplete()
    } finally {
      // oxlint-disable-next-line no-await-in-loop
      await provider.dispose()
    }
  }
}

class DurableCounterProvider {
  readonly #server: ReturnType<typeof Bun.serve>
  readonly #expectedCount: 1 | 2
  #state: CounterProviderState = { type: "awaiting_tool_call" }

  constructor(expectedCount: 1 | 2) {
    this.#expectedCount = expectedCount
    this.#server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: request => this.#receive(request) })
  }

  get baseUrl(): string {
    return `${this.#server.url}v1`
  }

  assertComplete(): void {
    if (this.#state.type === "complete") return
    const detail = this.#state.type === "failed" ? `: ${this.#state.message}` : ` (${this.#state.type})`
    throw new Error(`Compiled durable counter did not complete its append/resume round trip${detail}`)
  }

  async dispose(): Promise<void> {
    await this.#server.stop(true)
  }

  async #receive(request: Request): Promise<Response> {
    try {
      if (request.method !== "POST" || new URL(request.url).pathname !== "/v1/responses") {
        throw new Error(`Unexpected durable-counter provider request: ${request.method} ${request.url}`)
      }
      const payload: unknown = JSON.parse(await readBoundedRequest(request))
      switch (this.#state.type) {
        case "awaiting_tool_call":
          validateCounterRegistration(payload)
          this.#state = { type: "awaiting_tool_result" }
          return eventStreamResponse(counterToolCallEvents(this.#expectedCount))
        case "awaiting_tool_result":
          validateCounterResult(payload, this.#expectedCount)
          this.#state = { type: "awaiting_custom_message" }
          return eventStreamResponse(
            textResponseEvents("Counter tool completed.", `counter-tool-${this.#expectedCount}`)
          )
        case "awaiting_custom_message":
          validateCounterMessage(payload, this.#expectedCount)
          this.#state = { type: "complete" }
          return eventStreamResponse(
            textResponseEvents(`Durable counter ${this.#expectedCount} passed.`, `counter-final-${this.#expectedCount}`)
          )
        case "complete":
          throw new Error("Durable-counter provider received more than three requests")
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

class ToolRoundTripProvider {
  readonly #server: ReturnType<typeof Bun.serve>
  readonly #documentationRoot: string | undefined
  #state: ProviderState = { type: "awaiting_tool_call" }

  constructor(documentationRoot: string | undefined) {
    this.#documentationRoot = documentationRoot
    this.#server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: request => this.#receive(request) })
  }

  get baseUrl(): string {
    return `${this.#server.url}v1`
  }

  assertComplete(mode: AcceptanceMode): void {
    if (this.#state.type === "complete") return
    const detail = this.#state.type === "failed" ? `: ${this.#state.message}` : ` (${this.#state.type})`
    throw new Error(`Compiled ${mode} mode did not complete the custom-tool provider round trip${detail}`)
  }

  async dispose(): Promise<void> {
    await this.#server.stop(true)
  }

  async #receive(request: Request): Promise<Response> {
    try {
      if (request.method !== "POST" || new URL(request.url).pathname !== "/v1/responses") {
        throw new Error(`Unexpected provider request: ${request.method} ${request.url}`)
      }
      const payload: unknown = JSON.parse(await readBoundedRequest(request))
      switch (this.#state.type) {
        case "awaiting_tool_call":
          validateToolRegistration(payload)
          if (this.#documentationRoot) validateProductDocumentation(payload, this.#documentationRoot)
          this.#state = { type: "awaiting_tool_result" }
          return eventStreamResponse(toolCallEvents())
        case "awaiting_tool_result":
          validateToolResult(payload)
          this.#state = { type: "complete" }
          return eventStreamResponse(textEvents())
        case "complete":
          throw new Error("Provider received more than two requests")
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

interface ProcessOutput {
  readonly exitCode: number
  readonly stdout: string
  readonly stderr: string
}

function productArguments(mode: Exclude<AcceptanceMode, "rpc">, project: string, agentDirectory: string): string[] {
  return [
    "--mode",
    mode,
    "--no-session",
    "--cwd",
    project,
    "--agent-dir",
    agentDirectory,
    "--model",
    "azure-openai-responses/gpt-4.1",
    "--api-key",
    "extension-acceptance",
    "--thinking",
    "off",
    acceptancePrompt
  ]
}

function durableCounterArguments(project: string, agentDirectory: string, session: "new" | "continue"): string[] {
  return [
    "--mode",
    "text",
    session === "new" ? "--new-session" : "--continue",
    "--cwd",
    project,
    "--agent-dir",
    agentDirectory,
    "--model",
    "azure-openai-responses/gpt-4.1",
    "--api-key",
    "extension-acceptance",
    "--thinking",
    "off",
    "Call increment_counter exactly once."
  ]
}

function rpcCommandArguments(project: string, agentDirectory: string, session: "new" | "continue"): string[] {
  return [session === "new" ? "--new-session" : "--continue", "--cwd", project, "--agent-dir", agentDirectory]
}

function rpcProductArguments(project: string, agentDirectory: string): string[] {
  return [
    "--no-session",
    "--cwd",
    project,
    "--agent-dir",
    agentDirectory,
    "--model",
    "azure-openai-responses/gpt-4.1",
    "--api-key",
    "extension-acceptance",
    "--thinking",
    "off"
  ]
}

async function runHeadless(
  executable: string,
  args: readonly string[],
  cwd: string,
  env: Readonly<Record<string, string | undefined>>
): Promise<ProcessOutput> {
  const child = Bun.spawn([executable, ...args], { cwd, env, stdin: "ignore", stdout: "pipe", stderr: "pipe" })
  const stdout = readBoundedStream(child.stdout, "stdout")
  const stderr = readBoundedStream(child.stderr, "stderr")
  const [exitCode, capturedStdout, capturedStderr] = await settleProcess(child, stdout, stderr)
  return { exitCode, stdout: capturedStdout, stderr: capturedStderr }
}

async function runInteractive(
  executable: string,
  args: readonly string[],
  cwd: string,
  env: Readonly<Record<string, string | undefined>>
): Promise<void> {
  const output =
    process.platform === "win32"
      ? await runWindowsInteractive(executable, args, cwd, env)
      : await runPosixInteractive(executable, args, cwd, env)
  if (output.exitCode !== 0) throw processFailure("interactive", output)

  const terminalOutput = output.stdout + output.stderr
  if (!terminalOutput.includes(acceptanceResult)) {
    throw new Error(`Compiled interactive mode omitted ${JSON.stringify(acceptanceResult)}`)
  }
  if (process.platform === "win32") {
    if (!terminalOutput.includes("\u001b[?25l") || !terminalOutput.includes("\u001b[?25h")) {
      throw new Error("Compiled interactive mode did not restore the Windows terminal cursor")
    }
  } else if (!terminalOutput.includes("\u001b[?1049h") || !terminalOutput.includes("\u001b[?1049l")) {
    throw new Error("Compiled interactive mode did not enter and restore the alternate terminal screen")
  }
}

async function runPosixInteractive(
  executable: string,
  args: readonly string[],
  cwd: string,
  env: Readonly<Record<string, string | undefined>>
): Promise<ProcessOutput> {
  const capture = new BoundedTextCapture("terminal")
  let child: Bun.Subprocess | undefined
  let exitTimer: ReturnType<typeof setTimeout> | undefined
  let fallbackTimer: ReturnType<typeof setTimeout> | undefined
  let exitRequested = false
  const terminal = new Bun.Terminal({
    cols: 100,
    rows: 30,
    data(current, data) {
      if (!capture.append(data)) child?.kill()
      if (!exitRequested && capture.includes(acceptanceResult)) {
        exitRequested = true
        exitTimer = setTimeout(() => {
          if (current.closed) return
          current.write("\x04")
          fallbackTimer = setTimeout(() => {
            if (!current.closed) current.write("\x03\x03")
          }, 500)
        }, 100)
      }
    }
  })

  try {
    child = Bun.spawn([executable, ...args], { cwd, env, terminal })
    const [exitCode] = await settleProcess(child)
    return { exitCode, stdout: capture.finish(), stderr: "" }
  } finally {
    if (exitTimer) clearTimeout(exitTimer)
    if (fallbackTimer) clearTimeout(fallbackTimer)
    terminal.close()
  }
}

async function runWindowsInteractive(
  executable: string,
  args: readonly string[],
  cwd: string,
  env: Readonly<Record<string, string | undefined>>
): Promise<ProcessOutput> {
  const child = Bun.spawn([executable, ...args, interactiveAcceptanceArgument], {
    cwd,
    env: { ...env, COLUMNS: "100", LINES: "30" },
    stdin: "pipe",
    stdout: "pipe",
    stderr: "pipe",
    windowsHide: true
  })
  let exitTimer: ReturnType<typeof setTimeout> | undefined
  let fallbackTimer: ReturnType<typeof setTimeout> | undefined
  let exitRequested = false
  const requestExit = (text: string): void => {
    if (exitRequested || !text.includes(acceptanceResult)) return
    exitRequested = true
    exitTimer = setTimeout(() => {
      sendInteractiveInput(child.stdin, "\x04")
      fallbackTimer = setTimeout(() => sendInteractiveInput(child.stdin, "\x03\x03"), 500)
    }, 100)
  }
  const stdout = readBoundedStream(child.stdout, "terminal stdout", requestExit)
  const stderr = readBoundedStream(child.stderr, "terminal stderr", requestExit)

  try {
    const [exitCode, capturedStdout, capturedStderr] = await settleProcess(child, stdout, stderr)
    return { exitCode, stdout: capturedStdout, stderr: capturedStderr }
  } finally {
    if (exitTimer) clearTimeout(exitTimer)
    if (fallbackTimer) clearTimeout(fallbackTimer)
    await child.stdin.end()
  }
}

function validateTextOutput(output: ProcessOutput): void {
  if (output.exitCode !== 0) throw processFailure("text", output)
  if (normalizeNewlines(output.stdout) !== `${acceptanceResult}\n` || output.stderr !== "") {
    throw new Error(
      `Compiled text mode corrupted its output protocol: stdout=${JSON.stringify(output.stdout)} stderr=${JSON.stringify(output.stderr)}`
    )
  }
}

function validateJsonOutput(output: ProcessOutput): void {
  if (output.exitCode !== 0) throw processFailure("JSON", output)
  if (output.stderr !== "") throw new Error(`Compiled JSON mode wrote to stderr: ${JSON.stringify(output.stderr)}`)

  let records: Record<string, unknown>[]
  try {
    records = normalizeNewlines(output.stdout)
      .trimEnd()
      .split("\n")
      .map(line => requireRecord(JSON.parse(line), "JSONL record"))
  } catch (cause) {
    throw new Error("Compiled JSON mode emitted invalid JSONL", { cause })
  }
  const toolEnd = records.find(record => record.type === "tool_execution_end")
  if (toolEnd?.toolName !== "repository_status") {
    throw new Error("Compiled JSON mode omitted the custom tool execution event")
  }
  const result = requireRecord(toolEnd.result, "custom tool result")
  const content = requireArray(result.content, "custom tool result content")
  const resultText = content
    .map(item => requireRecord(item, "custom tool result item"))
    .find(item => item.type === "text")?.text
  if (typeof resultText !== "string" || !normalizeNewlines(resultText).includes(expectedStatus)) {
    throw new Error("Compiled JSON mode omitted the custom tool result")
  }
  const finalAssistant = records.findLast(record => {
    if (record.type !== "message_end") return false
    const message = record.message
    if (!isRecord(message) || message.role !== "assistant") return false
    const serializedContent = JSON.stringify(message.content)
    return typeof serializedContent === "string" && serializedContent.includes(acceptanceResult)
  })
  if (!finalAssistant) throw new Error("Compiled JSON mode omitted the final assistant response")
}

async function settleProcess<T extends readonly Promise<string>[]>(
  child: Bun.Subprocess,
  ...outputs: T
): Promise<[number, ...{ [K in keyof T]: string }]> {
  let deadline: ReturnType<typeof setTimeout> | undefined
  const timeout = new Promise<never>((_, reject) => {
    deadline = setTimeout(() => {
      try {
        child.kill()
      } catch {}
      reject(new Error(`Compiled Zi did not settle within ${processDeadlineMs}ms`))
    }, processDeadlineMs)
  })
  const settlement = Promise.all([child.exited, ...outputs]) as Promise<[number, ...{ [K in keyof T]: string }]>

  try {
    return await Promise.race([settlement, timeout])
  } catch (cause) {
    try {
      child.kill()
    } catch {}
    await Promise.allSettled([child.exited, ...outputs])
    throw cause
  } finally {
    if (deadline) clearTimeout(deadline)
  }
}

async function readBoundedStream(
  stream: ReadableStream<Uint8Array>,
  name: string,
  onText?: (text: string) => void
): Promise<string> {
  const capture = new BoundedTextCapture(name)
  const reader = stream.getReader()
  try {
    while (true) {
      // One reader owns stream order and the retained byte bound.
      // oxlint-disable-next-line no-await-in-loop
      const next = await reader.read()
      if (next.done) break
      if (!capture.append(next.value)) throw new Error(`${name} exceeded ${maxProcessOutputBytes} bytes`)
      onText?.(capture.text)
    }
    return capture.finish()
  } finally {
    reader.releaseLock()
  }
}

class BoundedTextCapture {
  readonly #name: string
  readonly #decoder = new TextDecoder()
  #bytes = 0
  #text = ""
  #failure: string | undefined
  #finished = false

  constructor(name: string) {
    this.#name = name
  }

  get text(): string {
    return this.#text
  }

  append(data: Uint8Array): boolean {
    if (this.#finished || this.#failure) return false
    this.#bytes += data.byteLength
    if (this.#bytes > maxProcessOutputBytes) {
      this.#failure = `${this.#name} exceeded ${maxProcessOutputBytes} bytes`
      return false
    }
    this.#text += this.#decoder.decode(data, { stream: true })
    return true
  }

  includes(value: string): boolean {
    return this.#text.includes(value)
  }

  finish(): string {
    if (this.#failure) throw new Error(this.#failure)
    if (!this.#finished) {
      this.#finished = true
      this.#text += this.#decoder.decode()
    }
    return this.#text
  }
}

async function readBoundedRequest(request: Request): Promise<string> {
  if (!request.body) return ""
  const reader = request.body.getReader()
  const chunks: Uint8Array[] = []
  let bytes = 0
  try {
    while (true) {
      // One reader owns request order and rejects before retaining an oversized body.
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

function validateToolRegistration(value: unknown): void {
  const payload = requireRecord(value, "first provider payload")
  const tools = requireArray(payload.tools, "provider tools")
  const registration = tools
    .map(tool => requireRecord(tool, "provider tool"))
    .find(tool => tool.name === "repository_status")
  if (!registration || registration.description !== "Show concise Git status for the repository or one path") {
    throw new Error("First provider request omitted the canonical custom tool")
  }
  const parameters = requireRecord(registration.parameters, "custom tool parameters")
  const properties = requireRecord(parameters.properties, "custom tool properties")
  const path = requireRecord(properties.path, "custom tool path parameter")
  if (parameters.type !== "object" || path.type !== "string") {
    throw new Error("First provider request changed the custom tool schema")
  }
}

function validateProductDocumentation(value: unknown, root: string): void {
  const payload = JSON.stringify(value)
  const normalizedRoot = root.replaceAll("\\", "/")
  for (const path of [
    `${normalizedRoot}/docs/extensions.md`,
    `${normalizedRoot}/docs/skills.md`,
    `${normalizedRoot}/docs/subagents.md`,
    `${normalizedRoot}/examples/extensions/`,
    `${normalizedRoot}/examples/skills/`,
    `${normalizedRoot}/examples/subagents/`
  ]) {
    if (!payload.includes(path)) throw new Error(`Compiled provider prompt omitted packaged documentation: ${path}`)
  }
}

function validateCounterRegistration(value: unknown): void {
  const payload = requireRecord(value, "counter provider payload")
  const tools = requireArray(payload.tools, "counter provider tools")
  const registration = tools
    .map(tool => requireRecord(tool, "counter provider tool"))
    .find(tool => tool.name === "increment_counter")
  if (!registration || registration.description !== "Increment a counter persisted in the current Zi session") {
    throw new Error("Counter provider request omitted the durable counter tool")
  }
}

function validateCounterResult(value: unknown, expectedCount: number): void {
  const payload = requireRecord(value, "counter result payload")
  const input = requireArray(payload.input, "counter result input")
  const result = input
    .map(item => requireRecord(item, "counter result item"))
    .find(item => item.type === "function_call_output" && item.call_id === `counter_call_${expectedCount}`)
  if (result?.output !== String(expectedCount)) {
    throw new Error(`Counter provider expected tool result ${expectedCount}`)
  }
}

function validateCounterMessage(value: unknown, expectedCount: number): void {
  const payload = requireRecord(value, "counter custom-message payload")
  if (!JSON.stringify(payload.input).includes(`Counter: ${expectedCount}`)) {
    throw new Error(`Counter provider omitted custom message ${expectedCount}`)
  }
}

function validateToolResult(value: unknown): void {
  const payload = requireRecord(value, "second provider payload")
  const input = requireArray(payload.input, "provider input")
  const result = input
    .map(item => requireRecord(item, "provider input item"))
    .find(item => item.type === "function_call_output" && item.call_id === "call_1")
  if (typeof result?.output !== "string" || !normalizeNewlines(result.output).includes(expectedStatus)) {
    throw new Error("Second provider request omitted the custom tool result")
  }
}

function eventStreamResponse(events: readonly Record<string, unknown>[]): Response {
  const body = `${events.map(event => `data: ${JSON.stringify(event)}\n\n`).join("")}data: [DONE]\n\n`
  return new Response(body, { headers: { "content-type": "text/event-stream" } })
}

function toolCallEvents(): readonly Record<string, unknown>[] {
  const item = {
    type: "function_call",
    id: "fc_1",
    call_id: "call_1",
    name: "repository_status",
    arguments: "{}",
    status: "completed"
  }
  return [
    { type: "response.created", response: { id: "resp_1" } },
    { type: "response.output_item.added", output_index: 0, item: { ...item, arguments: "", status: "in_progress" } },
    { type: "response.function_call_arguments.delta", output_index: 0, item_id: "fc_1", delta: "{}" },
    { type: "response.function_call_arguments.done", output_index: 0, item_id: "fc_1", arguments: "{}" },
    { type: "response.output_item.done", output_index: 0, item },
    { type: "response.completed", response: terminalResponse("resp_1") }
  ]
}

function counterToolCallEvents(expectedCount: number): readonly Record<string, unknown>[] {
  const itemId = `counter_fc_${expectedCount}`
  const callId = `counter_call_${expectedCount}`
  const item = {
    type: "function_call",
    id: itemId,
    call_id: callId,
    name: "increment_counter",
    arguments: "{}",
    status: "completed"
  }
  return [
    { type: "response.created", response: { id: `counter_resp_${expectedCount}` } },
    { type: "response.output_item.added", output_index: 0, item: { ...item, arguments: "", status: "in_progress" } },
    { type: "response.function_call_arguments.delta", output_index: 0, item_id: itemId, delta: "{}" },
    { type: "response.function_call_arguments.done", output_index: 0, item_id: itemId, arguments: "{}" },
    { type: "response.output_item.done", output_index: 0, item },
    { type: "response.completed", response: terminalResponse(`counter_resp_${expectedCount}`) }
  ]
}

function textEvents(): readonly Record<string, unknown>[] {
  return textResponseEvents(acceptanceResult, "acceptance")
}

function textResponseEvents(text: string, id: string): readonly Record<string, unknown>[] {
  const responseId = `resp_${id}`
  const messageId = `msg_${id}`
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

function initializeRepository(cwd: string): void {
  const git = Bun.spawnSync(["git", "init", "--quiet"], { cwd })
  if (git.exitCode !== 0) throw new Error(`Could not initialize acceptance repository: ${git.stderr.toString()}`)
}

async function removeTemporaryDirectory(path: string): Promise<void> {
  const deadline = Date.now() + temporaryCleanupDeadlineMs
  while (true) {
    try {
      // Cleanup attempts are sequential because each observes handles released by the previous attempt.
      // oxlint-disable-next-line no-await-in-loop
      await rm(path, { recursive: true, force: true })
      return
    } catch (cause) {
      if (!isRetryableCleanupError(cause) || Date.now() >= deadline) {
        if (process.platform !== "win32") throw cause
        const detail = windowsAcceptanceProcesses(path)
        throw new Error(`${cause instanceof Error ? cause.message : String(cause)}${detail ? `\n${detail}` : ""}`, {
          cause
        })
      }
      // oxlint-disable-next-line no-await-in-loop
      await Bun.sleep(temporaryCleanupRetryDelayMs)
    }
  }
}

function isRetryableCleanupError(cause: unknown): boolean {
  if (!(cause instanceof Error) || !("code" in cause)) return false
  return ["EACCES", "EBUSY", "ENOTEMPTY", "EPERM"].includes(String(cause.code))
}

function windowsAcceptanceProcesses(path: string): string {
  const script = `$needle = ${JSON.stringify(path.toLowerCase())}
Get-CimInstance Win32_Process |
  Where-Object {
    ($_.CommandLine -and $_.CommandLine.ToLower().Contains($needle)) -or
    $_.Name -match "^(zi|conhost|OpenConsole)\\.exe$"
  } |
  Select-Object ProcessId, ParentProcessId, Name, CommandLine |
  ConvertTo-Json -Compress`
  const encoded = Buffer.from(script, "utf16le").toString("base64")
  const snapshot = Bun.spawnSync(
    ["powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive", "-EncodedCommand", encoded],
    { stdout: "pipe", stderr: "ignore", windowsHide: true }
  )
  if (snapshot.exitCode !== 0) return ""
  const output = new TextDecoder().decode(snapshot.stdout.slice(0, 16 * 1024)).trim()
  return output ? `Windows acceptance processes: ${output}` : ""
}

function sendInteractiveInput(stdin: Bun.FileSink, data: string): void {
  void (async () => {
    await stdin.write(data)
    await stdin.flush()
  })().catch(() => {})
}

function processFailure(mode: string, output: ProcessOutput): Error {
  return new Error(
    `Compiled ${mode} mode exited with ${output.exitCode}: stdout=${JSON.stringify(output.stdout)} stderr=${JSON.stringify(output.stderr)}`
  )
}

function normalizeNewlines(value: string): string {
  return value.replaceAll("\r\n", "\n")
}

function requireRecord(value: unknown, name: string): Record<string, unknown> {
  if (!isRecord(value)) throw new Error(`${name} must be an object`)
  return value
}

function requireArray(value: unknown, name: string): unknown[] {
  if (!Array.isArray(value)) throw new Error(`${name} must be an array`)
  return value
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}

function assertNever(value: never): never {
  throw new Error(`Unexpected provider state: ${JSON.stringify(value)}`)
}

if (import.meta.main) {
  const executable = process.argv[2]
  if (!executable) throw new Error("Usage: bun scripts/extension-custom-tool-acceptance.ts <zi-executable>")
  await runExtensionCustomToolAcceptance({ executable: resolve(executable) })
}
