#!/usr/bin/env bun

import { readFileSync } from "node:fs"
import { mkdir, mkdtemp, readdir, readFile, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join, resolve } from "node:path"

import { isRecord } from "../packages/coding-agent/src/guards.js"
import { createProcessTreeTracker, type ProcessScope } from "../packages/coding-agent/src/processes/process-tree.js"
import { SessionManager } from "../packages/coding-agent/src/session-manager.js"

const acceptanceText = "Profile-driven subagent acceptance passed."
const acceptanceApiKey = "compiled-subagent-private-key"
const requestLimitBytes = 8 * 1024 * 1024
const agentToolNames = Object.freeze([
  "spawn_agent",
  "send_message",
  "followup_task",
  "wait_agent",
  "list_agents",
  "interrupt_agent"
])

type Mode = "close" | "crash" | "dispose"
type Declaration = "markdown" | "programmatic"

interface ProcessMarker {
  readonly agentPid: number
  readonly workerPid: number
  readonly apiKeyVisible: false
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
      const declaration: Declaration = mode === "close" ? "markdown" : "programmatic"
      // Each run owns one compiled parent, provider, credential store, extension worker, and process markers.
      // oxlint-disable-next-line no-await-in-loop
      await mkdir(extensions, { recursive: true })
      // oxlint-disable-next-line no-await-in-loop
      await writeFile(join(extensions, "acceptance.ts"), acceptanceExtension())
      if (declaration === "markdown") {
        const profiles = join(agentDirectory, "subagents")
        // oxlint-disable-next-line no-await-in-loop
        await mkdir(profiles, { recursive: true })
        // oxlint-disable-next-line no-await-in-loop
        await writeFile(join(profiles, "acceptance.md"), acceptanceMarkdownProfile())
      }
      // oxlint-disable-next-line no-await-in-loop
      await runMode(options.executable, project, agentDirectory, join(temporary, `${mode}.json`), mode, declaration)
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
  mode: Mode,
  declaration: Declaration
): Promise<void> {
  const descendantMarkerPath = `${markerPath}.descendant`
  const provider = new SubagentProvider(mode, markerPath, descendantMarkerPath)
  let parent: Bun.Subprocess<"ignore", "pipe", "pipe"> | undefined
  const cleanupTracker = createProcessTreeTracker()
  let cleanupScope: ProcessScope | undefined
  let marker: Marker | undefined
  try {
    parent = Bun.spawn(
      [
        executable,
        "--mode",
        "text",
        "--new-session",
        "--session-dir",
        join(agentDirectory, "acceptance-sessions"),
        "--cwd",
        project,
        "--agent-dir",
        agentDirectory,
        "--model",
        "azure-openai-responses/gpt-4.1",
        "--api-key",
        acceptanceApiKey,
        "--thinking",
        "off",
        `Complete the ${mode} ${declaration} profile-driven subagent acceptance workflow.`
      ],
      {
        cwd: project,
        env: {
          ...process.env,
          AZURE_OPENAI_API_KEY: "subagent-acceptance",
          AZURE_OPENAI_BASE_URL: provider.baseUrl,
          ZI_AGENT_DIR: agentDirectory,
          ZI_SUBAGENT_ACCEPTANCE_MARKER: markerPath,
          ZI_SUBAGENT_PROFILE_DECLARATION: declaration
        },
        stdin: "ignore",
        stdout: "pipe",
        stderr: "pipe",
        // The cleanup scope must not share the acceptance runner's POSIX process group.
        detached: process.platform !== "win32"
      }
    )
    cleanupScope = cleanupTracker.track(parent.pid)
    await cleanupScope.admitted

    const [exitCode, stdout, stderr] = await settleProcess(parent, mode, () => provider.diagnostic())
    if (stdout.includes(acceptanceApiKey) || stderr.includes(acceptanceApiKey)) {
      throw new Error(`Compiled ${mode} subagent acceptance exposed the ephemeral API key`)
    }
    if (exitCode !== 0 || stderr !== "" || stdout.trim() !== acceptanceText) {
      const processFailure = `exit=${exitCode} stdout=${JSON.stringify(stdout)} stderr=${JSON.stringify(stderr)}`
      provider.assertComplete(processFailure)
      throw new Error(`Compiled ${mode} subagent acceptance failed: ${processFailure}`)
    }
    provider.assertComplete()
    if (mode === "close") {
      await runRestorationProbe(executable, project, agentDirectory, markerPath, declaration, provider, 1)
      await compactDeliveredCompletion(agentDirectory)
      await runRestorationProbe(executable, project, agentDirectory, markerPath, declaration, provider, 0)
    }
    await assertNativeJournal(agentDirectory, provider.name, mode)
    marker = { ...(await readProcessMarker(markerPath)), descendantPid: await readPidMarker(descendantMarkerPath) }
    if (marker.agentPid !== parent.pid) {
      throw new Error(`Compiled ${mode} extension marker named agent PID ${marker.agentPid} instead of ${parent.pid}`)
    }
    await waitFor(
      () => !processAlive(marker!.agentPid) && !processAlive(marker!.workerPid) && !processAlive(marker!.descendantPid),
      10_000
    )
  } finally {
    await cleanupScope?.terminate()
    await cleanupTracker.dispose()
    if (parent && processAlive(parent.pid)) terminateProcess(parent.pid)
    await provider.dispose()
    if (marker) {
      terminateProcess(marker.agentPid)
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
  #childInitialReplySent = false
  #childProviderRequests = 0
  #resultProbeCount = 0
  #restorationOccurrences: number | undefined
  #name: string | undefined
  #parentPhase = "starting"
  #childPhase = "starting"
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

  get name(): string {
    if (!this.#name) throw new Error(`Compiled ${this.#mode} subagent provider did not observe a subagent name`)
    return this.#name
  }

  diagnostic(): string {
    return `parent=${this.#parentPhase}; child=${this.#childPhase}; child requests=${this.#childProviderRequests}; result probes=${this.#resultProbeCount}; failure=${this.#failed ?? "none"}`
  }

  beginRestorationProbe(expectedOccurrences: number): void {
    this.#complete = false
    this.#restorationOccurrences = expectedOccurrences
    this.#parentPhase = "restoring"
  }

  assertComplete(processFailure?: string): void {
    const suffix = processFailure ? `; ${processFailure}` : ""
    if (this.#failed) throw new Error(`Compiled ${this.#mode} subagent provider failed: ${this.#failed}${suffix}`)
    if (!this.#complete) throw new Error(`Compiled ${this.#mode} subagent provider did not complete${suffix}`)
  }

  async dispose(): Promise<void> {
    await this.#server.stop(true)
  }

  async #receive(request: Request): Promise<Response> {
    try {
      if (request.method !== "POST" || new URL(request.url).pathname !== "/v1/responses") {
        throw new Error(`Unexpected provider request: ${request.method} ${request.url}`)
      }
      const requestApiKey =
        request.headers.get("api-key") ?? request.headers.get("authorization")?.replace(/^Bearer /, "")
      const payloadText = await readBoundedRequest(request)
      if (payloadText.includes(acceptanceApiKey)) throw new Error("Provider payload exposed the ephemeral API key")
      const payload = record(JSON.parse(payloadText), "provider payload")
      const tools = Array.isArray(payload.tools) ? payload.tools : []
      const isParent = payload.model === "gpt-4.1"
      const expectedApiKey = isParent ? acceptanceApiKey : "subagent-acceptance"
      if (requestApiKey !== expectedApiKey) {
        throw new Error(`Provider ${isParent ? "parent" : "child"} request used the wrong API key`)
      }
      assertProviderSelection(payload, isParent)
      const outputs = functionOutputs(payload.input)
      if (!isParent) return this.#receiveChild(payloadText, tools, outputs)
      return await this.#receiveParent(payloadText, outputs)
    } catch (cause) {
      this.#failed ??= cause instanceof Error ? cause.message : String(cause)
      return Response.json({ error: { message: this.#failed } }, { status: 500 })
    }
  }

  async #receiveChild(
    payloadText: string,
    tools: readonly unknown[],
    outputs: ReadonlyMap<string, string>
  ): Promise<Response> {
    this.#childProviderRequests++
    this.#childPhase = [...outputs.keys()].at(-1) ?? "initial"
    for (const name of agentToolNames) {
      if (!tools.some(tool => record(tool, "child tool").name === name)) {
        throw new Error(`Compiled direct child omitted collaboration tool ${name}`)
      }
    }

    if (this.#mode === "crash" && outputs.has("acceptance_crash")) {
      if (tools.some(tool => record(tool, "child tool").name === "acceptance_crash")) {
        throw new Error("Compiled child retained tools from its crashed extension worker")
      }
      const marker = await readProcessMarker(this.#markerPath)
      await waitFor(() => !processAlive(marker.workerPid), 5_000, "Crashed child extension worker did not exit")
      this.#childInitialReplySent = true
      return eventStreamResponse(textEvents("Compiled child survived its extension worker crash.", "child-crash"))
    }
    if (payloadText.includes("Reuse after active interruption.")) {
      if (
        !payloadText.includes("Queue this without waking.") ||
        !payloadText.includes("Complete the second cycle.") ||
        !payloadText.includes("Interrupt the active third cycle.")
      ) {
        throw new Error("Compiled child context omitted queued or continued input")
      }
      return eventStreamResponse(textEvents("Compiled child reused.", "child-reused"))
    }
    if (payloadText.includes("Interrupt the active third cycle.")) {
      this.#childPhase = "interrupt-tool"
      return eventStreamResponse(toolEvents("acceptance_hang", "acceptance_interrupt_probe", {}))
    }
    if (payloadText.includes("Complete the second cycle.")) {
      return eventStreamResponse(textEvents("Compiled second cycle completed.", "child-second-cycle"))
    }
    if (
      !payloadText.includes("Complete the acceptance task and return bounded evidence.") ||
      !payloadText.includes("Return one sentence.")
    ) {
      throw new Error("Compiled child did not receive profile instructions and the delegated prompt")
    }
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
    if (this.#mode === "crash") {
      return eventStreamResponse(toolEvents("acceptance_crash", "acceptance_crash", {}))
    }
    this.#childInitialReplySent = true
    return eventStreamResponse(textEvents("Compiled child completed.", "child"))
  }

  async #receiveParent(payloadText: string, outputs: ReadonlyMap<string, string>): Promise<Response> {
    this.#parentPhase = [...outputs.keys()].at(-1) ?? "initial"
    const completionMarker = "Agent completion from /root/acceptance-worker:"
    const completionOccurrences = payloadText.split(completionMarker).length - 1

    if (this.#restorationOccurrences !== undefined) {
      if (completionOccurrences !== this.#restorationOccurrences) {
        throw new Error(
          `Compiled restoration retained ${completionOccurrences} agent completions instead of ${this.#restorationOccurrences}`
        )
      }
      this.#restorationOccurrences = undefined
      this.#complete = true
      return eventStreamResponse(textEvents(acceptanceText, "restored"))
    }

    const spawnOutput = outputs.get("acceptance_spawn")
    if (!spawnOutput) {
      return eventStreamResponse(
        toolEvents("spawn_agent", "acceptance_spawn", {
          task_name: "acceptance-worker",
          message: "Return one sentence.",
          agent_type: "acceptance"
        })
      )
    }
    const path = parseAgentPathResult(spawnOutput)
    this.#name ??= path
    if (this.#name !== path) throw new Error("Compiled parent changed the agent path")

    if (this.#mode === "dispose") {
      await waitFor(
        () => this.#descendantStarted,
        10_000,
        "Compiled child did not confirm its descendant before parent disposal"
      )
      this.#complete = true
      return eventStreamResponse(textEvents(acceptanceText, "dispose"))
    }

    if (completionOccurrences > 1) throw new Error("Compiled parent duplicated passive agent completion context")
    if (completionOccurrences === 1) {
      const expected =
        this.#mode === "crash" ? "Compiled child survived its extension worker crash." : "Compiled child completed."
      if (!payloadText.includes(expected)) throw new Error("Compiled passive completion omitted child evidence")
      this.#complete = true
      return eventStreamResponse(textEvents(acceptanceText, this.#mode))
    }

    await waitFor(
      () => this.#childInitialReplySent,
      10_000,
      "Compiled child did not finish before completion observation"
    )
    if (++this.#resultProbeCount > 100) {
      throw new Error(`Compiled completion did not become durable during revision wait (${this.diagnostic()})`)
    }
    return eventStreamResponse(
      toolEvents("wait_agent", `acceptance_wait_${this.#resultProbeCount}`, { timeout_ms: 1_000 })
    )
  }
}

function acceptanceExtension(): string {
  return `import { Schema, type ExtensionFactory } from "@with-zi/extension-api"

const marker = process.env.ZI_SUBAGENT_ACCEPTANCE_MARKER
if (!marker) throw new Error("missing subagent acceptance marker")

const extension: ExtensionFactory = zi => {
  if (process.env.ZI_SUBAGENT_PROFILE_DECLARATION === "programmatic") {
    zi.registerAgentRole({
      name: "acceptance",
      description: "Exercise the compiled profile-driven subagent system",
      instructions: "Complete the acceptance task and return bounded evidence.",
      model: "azure-openai-responses/gpt-5.4",
      thinking: "high"
    })
  }
  zi.on("session_start", async (_event, context) => {
    if (context.session.type !== "journal" || !/[\\\\/]agents[\\\\/]/.test(context.session.file)) return
    const apiKeyVisible = Object.values(process.env).includes(${JSON.stringify(acceptanceApiKey)})
    await Bun.write(marker, JSON.stringify({ agentPid: process.ppid, workerPid: process.pid, apiKeyVisible }))
  })
  zi.registerTool({
    name: "acceptance_hang",
    description: "Wait until the acceptance run interrupts this tool.",
    parameters: Schema.object({}),
    outputSchema: Schema.object({ settled: Schema.boolean() }),
    async execute(_input, { signal }) {
      await Bun.write(marker + ".tool", "started")
      await new Promise(resolve => {
        if (signal.aborted) resolve(undefined)
        else signal.addEventListener("abort", resolve, { once: true })
      })
      return { settled: false }
    }
  })
  zi.registerTool({
    name: "acceptance_crash",
    description: "Crash this child session's extension worker.",
    parameters: Schema.object({}),
    execute: () => process.exit(17)
  })
}

export default extension
`
}

function acceptanceMarkdownProfile(): string {
  return `---
description: Exercise the compiled profile-driven subagent system
model: azure-openai-responses/gpt-5.4
thinking: high
---
Complete the acceptance task and return bounded evidence.
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

function parseAgentPathResult(output: string): string {
  const result = record(JSON.parse(output), "spawn result")
  const agent = record(result.agent, "spawned agent")
  if (typeof agent.path !== "string") throw new Error(`Spawn output omitted agent path: ${JSON.stringify(output)}`)
  return agent.path
}

function assertProviderSelection(payload: Record<string, unknown>, isParent: boolean): void {
  const expectedModel = isParent ? "gpt-4.1" : "gpt-5.4"
  if (payload.model !== expectedModel) {
    throw new Error(
      `Compiled ${isParent ? "parent" : "child"} selected ${String(payload.model)} instead of ${expectedModel}`
    )
  }
  if (isParent) {
    if (payload.reasoning !== undefined) throw new Error("Compiled parent did not retain thinking off")
    return
  }
  const reasoning = record(payload.reasoning, "child reasoning")
  if (reasoning.effort !== "high") throw new Error("Compiled child did not select profile thinking high")
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

async function runRestorationProbe(
  executable: string,
  project: string,
  agentDirectory: string,
  markerPath: string,
  declaration: Declaration,
  provider: SubagentProvider,
  expectedOccurrences: number
): Promise<void> {
  provider.beginRestorationProbe(expectedOccurrences)
  const probe = Bun.spawn(
    [
      executable,
      "--mode",
      "text",
      "--continue",
      "--session-dir",
      join(agentDirectory, "acceptance-sessions"),
      "--cwd",
      project,
      "--agent-dir",
      agentDirectory,
      "--model",
      "azure-openai-responses/gpt-4.1",
      "--api-key",
      acceptanceApiKey,
      "--thinking",
      "off",
      "Verify the restored subagent delivery evidence."
    ],
    {
      cwd: project,
      env: {
        ...process.env,
        AZURE_OPENAI_API_KEY: "subagent-acceptance",
        AZURE_OPENAI_BASE_URL: provider.baseUrl,
        ZI_AGENT_DIR: agentDirectory,
        ZI_SUBAGENT_ACCEPTANCE_MARKER: markerPath,
        ZI_SUBAGENT_PROFILE_DECLARATION: declaration
      },
      stdin: "ignore",
      stdout: "pipe",
      stderr: "pipe"
    }
  )
  const [exitCode, stdout, stderr] = await settleProcess(probe, "close", () => provider.diagnostic())
  if (stdout.includes(acceptanceApiKey) || stderr.includes(acceptanceApiKey)) {
    throw new Error("Compiled restoration exposed the ephemeral API key")
  }
  if (exitCode !== 0 || stderr !== "" || stdout.trim() !== acceptanceText) {
    const failure = `exit=${exitCode} stdout=${JSON.stringify(stdout)} stderr=${JSON.stringify(stderr)}`
    provider.assertComplete(failure)
    throw new Error(`Compiled subagent restoration failed: ${failure}`)
  }
  provider.assertComplete()
}

async function compactDeliveredCompletion(agentDirectory: string): Promise<void> {
  const directory = join(agentDirectory, "acceptance-sessions")
  const files = (await readdir(directory)).filter(file => file.endsWith(".jsonl"))
  if (files.length !== 1) throw new Error(`Compiled compaction probe found ${files.length} parent journals`)
  const session = SessionManager.open(join(directory, files[0]!))
  const firstKept = session.entries().findLast(entry => entry.type === "message" && entry.message.role === "user")
  if (!firstKept) throw new Error("Compiled compaction probe found no retained user boundary")
  session.appendCompaction({
    reason: "manual",
    summary: "The compiled subagent acceptance workflow completed.",
    firstKeptEntryId: firstKept.id,
    tokensBefore: 100,
    estimatedTokensAfter: 10,
    details: { readFiles: [], modifiedFiles: [], omittedReadFiles: 0, omittedModifiedFiles: 0 }
  })
}

async function settleProcess(
  child: Bun.Subprocess<"ignore", "pipe", "pipe">,
  mode: Mode,
  diagnostic: () => string
): Promise<[number, string, string]> {
  const settlement = Promise.all([
    child.exited,
    new Response(child.stdout).text(),
    new Response(child.stderr).text()
  ] as const)
  let timeout: ReturnType<typeof setTimeout> | undefined
  const timedOut = new Promise<never>((_, reject) => {
    timeout = setTimeout(() => {
      child.kill()
      reject(new Error(`Compiled ${mode} subagent acceptance timed out: ${diagnostic()}`))
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

async function assertNativeJournal(agentDirectory: string, path: string, mode: Mode): Promise<void> {
  const directory = join(agentDirectory, "acceptance-sessions")
  const files = (await readdir(directory)).filter(file => file.endsWith(".jsonl"))
  if (files.length !== 1) throw new Error(`Compiled ${mode} acceptance wrote ${files.length} root journals`)
  const journal = await readFile(join(directory, files[0]!), "utf8")
  if (journal.includes(acceptanceApiKey)) throw new Error(`Compiled ${mode} journal exposed the ephemeral API key`)
  const entries = journal
    .trim()
    .split("\n")
    .map((line, index) => record(JSON.parse(line), `journal line ${index + 1}`))

  const reserved = entries.filter(entry => entry.type === "agent_spawn_reserved" && entry.path === path)
  const committed = entries.filter(entry => entry.type === "agent_spawn_committed")
  if (reserved.length !== 1 || committed.length !== 1) {
    throw new Error(`Compiled ${mode} journal omitted one committed AgentTeam spawn`)
  }
  if (mode === "dispose") return

  const settled = entries.filter(entry => entry.type === "agent_turn_settled" && entry.path === path)
  const delivered = entries.filter(entry => entry.type === "agent_completion_delivered" && entry.path === path)
  if (settled.length !== 1 || delivered.length !== 1) {
    throw new Error(
      `Compiled ${mode} journal retained settled=${settled.length} delivered=${delivered.length} instead of one each`
    )
  }
}

async function readProcessMarker(path: string): Promise<ProcessMarker> {
  let marker: ProcessMarker | undefined
  await waitFor(
    () => {
      try {
        const value = record(JSON.parse(readFileSync(path, "utf8")), "marker")
        if (
          typeof value.agentPid !== "number" ||
          typeof value.workerPid !== "number" ||
          value.apiKeyVisible !== false
        ) {
          return false
        }
        marker = { agentPid: value.agentPid, workerPid: value.workerPid, apiKeyVisible: false }
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
    const pathLiteral = markerPath.replaceAll("'", "''")
    const script = `[IO.File]::WriteAllText('${pathLiteral}',[string]$PID); Start-Sleep -Seconds 600`
    const encoded = Buffer.from(script, "utf16le").toString("base64")
    return `powershell.exe -NoProfile -NonInteractive -EncodedCommand ${encoded}`
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

if (import.meta.main) {
  const executable = process.argv[2] ? resolve(process.argv[2]) : undefined
  if (!executable) throw new Error("Usage: bun scripts/subagent-compiled-acceptance.ts <zi-executable>")
  await runSubagentCompiledAcceptance({ executable })
}
