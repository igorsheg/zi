#!/usr/bin/env bun

import { readFileSync } from "node:fs"
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join, resolve } from "node:path"

import { createProcessScope, type ProcessScope } from "../packages/coding-agent/src/extensions/process-scope.js"

const acceptanceText = "Native subagent acceptance passed."
const requestLimitBytes = 8 * 1024 * 1024

type Mode = "close" | "crash" | "dispose"

interface ProcessMarker {
  readonly childPid: number
  readonly workerPid: number
}

interface Marker extends ProcessMarker {
  readonly descendantPid: number
}

export async function runSubagentCompiledAcceptance(options: { readonly executable: string }): Promise<void> {
  const temporary = await mkdtemp(join(tmpdir(), "zi-subagent-compiled-"))
  const project = join(temporary, "project")
  await mkdir(project, { recursive: true })

  try {
    for (const mode of ["close", "crash", "dispose"] as const) {
      const agentDirectory = join(temporary, `agent-${mode}`)
      const extensions = join(agentDirectory, "extensions")
      // Each run owns one compiled parent, provider, credential store, extension worker, and process markers.
      // oxlint-disable-next-line no-await-in-loop
      await mkdir(extensions, { recursive: true })
      // oxlint-disable-next-line no-await-in-loop
      await writeFile(join(extensions, "acceptance.ts"), acceptanceExtension())
      // oxlint-disable-next-line no-await-in-loop
      await runMode(options.executable, project, agentDirectory, join(temporary, `${mode}.json`), mode)
    }
  } finally {
    await rm(temporary, { recursive: true, force: true })
  }
}

async function runMode(
  executable: string,
  project: string,
  agentDirectory: string,
  markerPath: string,
  mode: Mode
): Promise<void> {
  const descendantMarkerPath = `${markerPath}.descendant`
  const provider = new SubagentProvider(mode, markerPath, descendantMarkerPath)
  let parent: Bun.Subprocess<"ignore", "pipe", "pipe"> | undefined
  let cleanupScope: ProcessScope | undefined
  let cleanupRefresh: ReturnType<typeof setInterval> | undefined
  let marker: Marker | undefined
  try {
    parent = Bun.spawn(
      [
        executable,
        "--mode",
        "text",
        "--no-session",
        "--cwd",
        project,
        "--agent-dir",
        agentDirectory,
        "--model",
        "azure-openai-responses/gpt-4.1",
        "--thinking",
        "off",
        `Complete the ${mode} native subagent acceptance workflow.`
      ],
      {
        cwd: project,
        env: {
          ...process.env,
          AZURE_OPENAI_API_KEY: "subagent-acceptance",
          AZURE_OPENAI_BASE_URL: provider.baseUrl,
          ZI_AGENT_DIR: agentDirectory,
          ZI_SUBAGENT_ACCEPTANCE_MARKER: markerPath
        },
        stdin: "ignore",
        stdout: "pipe",
        stderr: "pipe",
        // The cleanup scope must not share the acceptance runner's POSIX process group.
        detached: process.platform !== "win32"
      }
    )
    cleanupScope = createProcessScope(parent.pid)
    cleanupRefresh = setInterval(() => {
      try {
        cleanupScope?.refresh()
      } catch {
        cleanupScope?.terminate()
      }
    }, 250)
    cleanupRefresh.unref?.()

    const [exitCode, stdout, stderr] = await settleProcess(parent)
    if (exitCode !== 0 || stderr !== "" || stdout.trim() !== acceptanceText) {
      provider.assertComplete()
      throw new Error(
        `Compiled ${mode} subagent acceptance failed: exit=${exitCode} stdout=${JSON.stringify(stdout)} stderr=${JSON.stringify(stderr)}`
      )
    }
    provider.assertComplete()
    marker = { ...(await readProcessMarker(markerPath)), descendantPid: await readPidMarker(descendantMarkerPath) }
    await waitFor(
      () => !processAlive(marker!.childPid) && !processAlive(marker!.workerPid) && !processAlive(marker!.descendantPid),
      10_000
    )
  } finally {
    if (cleanupRefresh) clearInterval(cleanupRefresh)
    cleanupScope?.terminate()
    cleanupScope?.dispose()
    if (parent && processAlive(parent.pid)) terminateProcess(parent.pid)
    await provider.dispose()
    if (marker) {
      terminateProcess(marker.childPid)
      terminateProcess(marker.workerPid)
      terminateProcess(marker.descendantPid)
    }
  }
}

class SubagentProvider {
  readonly #server: ReturnType<typeof Bun.serve>
  readonly #mode: Mode
  readonly #markerPath: string
  readonly #descendantMarkerPath: string
  #complete = false
  #descendantStarted = false
  #failed: string | undefined

  constructor(mode: Mode, markerPath: string, descendantMarkerPath: string) {
    this.#mode = mode
    this.#markerPath = markerPath
    this.#descendantMarkerPath = descendantMarkerPath
    this.#server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: request => this.#receive(request) })
  }

  get baseUrl(): string {
    return `${this.#server.url}v1`
  }

  assertComplete(): void {
    if (this.#failed) throw new Error(`Compiled ${this.#mode} subagent provider failed: ${this.#failed}`)
    if (!this.#complete) throw new Error(`Compiled ${this.#mode} subagent provider did not complete`)
  }

  async dispose(): Promise<void> {
    await this.#server.stop(true)
  }

  async #receive(request: Request): Promise<Response> {
    try {
      if (request.method !== "POST" || new URL(request.url).pathname !== "/v1/responses") {
        throw new Error(`Unexpected provider request: ${request.method} ${request.url}`)
      }
      const payload = record(JSON.parse(await readBoundedRequest(request)), "provider payload")
      const tools = Array.isArray(payload.tools) ? payload.tools : []
      const isParent = tools.some(tool => record(tool, "tool").name === "spawn_subagent")
      const outputs = functionOutputs(payload.input)
      if (!isParent) {
        if (!outputs.has("acceptance_descendant")) {
          return eventStreamResponse(
            toolEvents("bash", "acceptance_descendant", {
              command: containmentProbeCommand(this.#descendantMarkerPath),
              description: "Start descendant containment probe",
              background: true,
              timeout: 600
            })
          )
        }
        const descendantOutput = outputs.get("acceptance_descendant")!
        let descendantPid: number
        try {
          descendantPid = await readPidMarker(this.#descendantMarkerPath)
        } catch (cause) {
          throw new Error(
            `${cause instanceof Error ? cause.message : String(cause)}; bash output=${JSON.stringify(descendantOutput)}`,
            { cause }
          )
        }
        if (!processAlive(descendantPid)) throw new Error("Compiled subagent descendant exited before cleanup")
        this.#descendantStarted = true
        return eventStreamResponse(textEvents("Compiled child completed.", "child"))
      }

      const spawnOutput = outputs.get("acceptance_spawn")
      if (!spawnOutput) {
        return eventStreamResponse(
          toolEvents("spawn_subagent", "acceptance_spawn", { prompt: "Return one sentence.", type: "acceptance" })
        )
      }
      const agentId = parseAgentId(spawnOutput)
      if (this.#mode === "dispose") {
        await waitFor(
          () => this.#descendantStarted,
          10_000,
          "Compiled child did not confirm its descendant before parent disposal"
        )
        this.#complete = true
        return eventStreamResponse(textEvents(acceptanceText, "dispose"))
      }
      if (!outputs.has("acceptance_wait")) {
        return eventStreamResponse(
          toolEvents("wait_subagents", "acceptance_wait", { agent_ids: [agentId], timeout_ms: 25_000 })
        )
      }
      assertCompletedWait(outputs.get("acceptance_wait")!)
      if (this.#mode === "crash" && !outputs.has("acceptance_list")) {
        const marker = await readProcessMarker(this.#markerPath)
        process.kill(marker.childPid, "SIGKILL")
        await waitFor(() => !processAlive(marker.childPid), 5_000, "Forced subagent child did not exit")
        return eventStreamResponse(toolEvents("list_subagents", "acceptance_list", {}))
      }
      if (this.#mode === "close" && !outputs.has("acceptance_close")) {
        return eventStreamResponse(toolEvents("close_subagent", "acceptance_close", { agent_id: agentId }))
      }
      this.#complete = true
      return eventStreamResponse(textEvents(acceptanceText, this.#mode))
    } catch (cause) {
      this.#failed = cause instanceof Error ? cause.message : String(cause)
      return Response.json({ error: { message: this.#failed } }, { status: 500 })
    }
  }
}

function acceptanceExtension(): string {
  return `import type { ExtensionFactory } from "@with-zi/extension-api"

const extension: ExtensionFactory = zi => {
  if (process.env.ZI_SUBAGENT_DEPTH === "1") {
    const marker = process.env.ZI_SUBAGENT_ACCEPTANCE_MARKER
    if (!marker) throw new Error("missing subagent acceptance marker")
    Bun.write(marker, JSON.stringify({ childPid: process.ppid, workerPid: process.pid }))
  }
  zi.registerSubagentType({
    name: "acceptance",
    description: "Compiled native subagent acceptance",
    instructions: "Return a concise result."
  })
}

export default extension
`
}

function functionOutputs(input: unknown): Map<string, string> {
  const outputs = new Map<string, string>()
  if (!Array.isArray(input)) return outputs
  for (const value of input) {
    const item = record(value, "provider input")
    if (item.type === "function_call_output" && typeof item.call_id === "string" && typeof item.output === "string") {
      outputs.set(item.call_id, item.output)
    }
  }
  return outputs
}

function parseAgentId(output: string): string {
  const match = /"agent_id"\s*:\s*"([^"]+)"/.exec(output)
  if (!match?.[1]) throw new Error(`Spawn output omitted agent_id: ${JSON.stringify(output)}`)
  return match[1]
}

function assertCompletedWait(output: string): void {
  const result = record(JSON.parse(output), "wait result")
  if (
    !Array.isArray(result.agents) ||
    !result.agents.some(
      agent => isRecord(agent) && isRecord(agent.completion) && agent.completion.status === "completed"
    )
  ) {
    throw new Error(`Compiled subagent wait did not return a completed child: ${JSON.stringify(output)}`)
  }
}

function toolEvents(name: string, callId: string, args: Record<string, unknown>): readonly Record<string, unknown>[] {
  const itemId = `item_${callId}`
  const argumentsText = JSON.stringify(args)
  const item = {
    type: "function_call",
    id: itemId,
    call_id: callId,
    name,
    arguments: argumentsText,
    status: "completed"
  }
  return [
    { type: "response.created", response: { id: `response_${callId}` } },
    { type: "response.output_item.added", output_index: 0, item: { ...item, arguments: "", status: "in_progress" } },
    { type: "response.function_call_arguments.delta", output_index: 0, item_id: itemId, delta: argumentsText },
    { type: "response.function_call_arguments.done", output_index: 0, item_id: itemId, arguments: argumentsText },
    { type: "response.output_item.done", output_index: 0, item },
    { type: "response.completed", response: terminalResponse(`response_${callId}`) }
  ]
}

function textEvents(text: string, id: string): readonly Record<string, unknown>[] {
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
  return new Response(`${events.map(event => `data: ${JSON.stringify(event)}\n\n`).join("")}data: [DONE]\n\n`, {
    headers: { "content-type": "text/event-stream" }
  })
}

async function settleProcess(child: Bun.Subprocess<"ignore", "pipe", "pipe">): Promise<[number, string, string]> {
  const settlement = Promise.all([
    child.exited,
    new Response(child.stdout).text(),
    new Response(child.stderr).text()
  ] as const)
  let timeout: ReturnType<typeof setTimeout> | undefined
  const timedOut = new Promise<never>((_, reject) => {
    timeout = setTimeout(() => {
      child.kill()
      reject(new Error("Compiled subagent acceptance timed out"))
    }, 45_000)
  })
  try {
    return await Promise.race([settlement, timedOut])
  } finally {
    if (timeout) clearTimeout(timeout)
  }
}

async function readBoundedRequest(request: Request): Promise<string> {
  const text = await request.text()
  if (Buffer.byteLength(text) > requestLimitBytes) throw new Error("Provider request exceeded acceptance bound")
  return text
}

async function readProcessMarker(path: string): Promise<ProcessMarker> {
  let marker: ProcessMarker | undefined
  await waitFor(
    () => {
      try {
        const value = record(JSON.parse(readFileSync(path, "utf8")), "marker")
        if (typeof value.childPid !== "number" || typeof value.workerPid !== "number") return false
        marker = { childPid: value.childPid, workerPid: value.workerPid }
        return true
      } catch {
        return false
      }
    },
    10_000,
    `Process marker did not appear: ${path}`
  )
  return marker!
}

async function readPidMarker(path: string): Promise<number> {
  let pid: number | undefined
  await waitFor(
    () => {
      try {
        const value = Number(readFileSync(path, "utf8"))
        if (!Number.isInteger(value) || value <= 0) return false
        pid = value
        return true
      } catch {
        return false
      }
    },
    10_000,
    `PID marker did not appear: ${path}`
  )
  return pid!
}

function containmentProbeCommand(markerPath: string): string {
  if (process.platform === "win32") {
    const encodedPath = Buffer.from(markerPath, "utf16le").toString("base64")
    return `powershell.exe -NoProfile -NonInteractive -Command "$path=[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('${encodedPath}')); [IO.File]::WriteAllText($path,[string]$PID); Start-Sleep -Seconds 600"`
  }
  return `/bin/sh -c 'printf "%s" "$$" > "$1"; exec sleep 600' zi-probe ${shellQuote(markerPath)}`
}

function shellQuote(value: string): string {
  return `'${value.replaceAll("'", `'\\''`)}'`
}

async function waitFor(
  predicate: () => boolean,
  timeoutMs: number,
  failure = "Compiled subagent process did not settle before the deadline"
): Promise<void> {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    if (predicate()) return
    // oxlint-disable-next-line no-await-in-loop -- bounded process settlement poll
    await Bun.sleep(25)
  }
  throw new Error(failure)
}

function terminateProcess(pid: number): void {
  try {
    process.kill(pid, "SIGKILL")
  } catch {
    // already dead
  }
}

function processAlive(pid: number): boolean {
  try {
    process.kill(pid, 0)
    return true
  } catch {
    return false
  }
}

function record(value: unknown, label: string): Record<string, unknown> {
  if (!isRecord(value)) throw new Error(`${label} must be an object`)
  return value
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}

if (import.meta.main) {
  const executable = process.argv[2] ? resolve(process.argv[2]) : undefined
  if (!executable) throw new Error("Usage: bun scripts/subagent-compiled-acceptance.ts <zi-executable>")
  await runSubagentCompiledAcceptance({ executable })
}
