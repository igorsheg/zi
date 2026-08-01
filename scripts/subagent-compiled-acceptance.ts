#!/usr/bin/env bun

import { readFileSync } from "node:fs"
import { mkdir, mkdtemp, readdir, readFile, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join, resolve } from "node:path"

import { createProcessTreeTracker, type ProcessScope } from "../packages/coding-agent/src/processes/process-tree.js"

const acceptanceText = "Profile-driven subagent acceptance passed."
const acceptanceApiKey = "compiled-subagent-private-key"
const requestLimitBytes = 8 * 1024 * 1024
const subagentToolNames = Object.freeze([
  "list_subagent_profiles",
  "spawn_subagent",
  "send_subagent",
  "continue_subagent",
  "wait_subagents",
  "interrupt_subagent",
  "close_subagent",
  "list_subagents"
])

type Mode = "close" | "crash" | "dispose"
type Declaration = "markdown" | "programmatic"

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
          ZI_SUBAGENT_DEPTH: "0",
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
      provider.assertComplete()
      throw new Error(
        `Compiled ${mode} subagent acceptance failed: exit=${exitCode} stdout=${JSON.stringify(stdout)} stderr=${JSON.stringify(stderr)}`
      )
    }
    provider.assertComplete()
    await assertNativeJournal(agentDirectory, provider.name, mode)
    marker = { ...(await readProcessMarker(markerPath)), descendantPid: await readPidMarker(descendantMarkerPath) }
    await waitFor(
      () => !processAlive(marker!.childPid) && !processAlive(marker!.workerPid) && !processAlive(marker!.descendantPid),
      10_000
    )
  } finally {
    await cleanupScope?.terminate()
    await cleanupTracker.dispose()
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
  #childInitialReplySent = false
  #childProviderRequests = 0
  #resultProbeId: string | undefined
  #resultProbeCount = 0
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
    return `parent=${this.#parentPhase}; child=${this.#childPhase}; child requests=${this.#childProviderRequests}; result probes=${this.#resultProbeCount}`
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
      const payloadText = await readBoundedRequest(request)
      if (payloadText.includes(acceptanceApiKey)) throw new Error("Provider payload exposed the ephemeral API key")
      const payload = record(JSON.parse(payloadText), "provider payload")
      const tools = Array.isArray(payload.tools) ? payload.tools : []
      const isParent = tools.some(tool => record(tool, "tool").name === "spawn_subagent")
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
    for (const name of subagentToolNames) {
      if (tools.some(tool => record(tool, "child tool").name === name)) {
        throw new Error(`Compiled direct child unexpectedly exposed ${name}`)
      }
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
    this.#childInitialReplySent = true
    return eventStreamResponse(textEvents("Compiled child completed.", "child"))
  }

  async #receiveParent(payloadText: string, outputs: ReadonlyMap<string, string>): Promise<Response> {
    this.#parentPhase = [...outputs.keys()].at(-1) ?? "initial"
    const profileOutput = outputs.get("acceptance_profiles")
    if (!profileOutput) {
      return eventStreamResponse(toolEvents("list_subagent_profiles", "acceptance_profiles", {}))
    }
    assertProfileCatalog(profileOutput)
    const spawnOutput = outputs.get("acceptance_spawn")
    if (!spawnOutput) {
      return eventStreamResponse(
        toolEvents("spawn_subagent", "acceptance_spawn", {
          profile: "acceptance",
          name: "acceptance-worker",
          prompt: "Return one sentence."
        })
      )
    }
    const name = parseName(spawnOutput)
    this.#name ??= name
    if (this.#name !== name) throw new Error("Compiled parent changed the subagent name")

    if (this.#mode === "dispose") {
      await waitFor(
        () => this.#descendantStarted,
        10_000,
        "Compiled child did not confirm its descendant before parent disposal"
      )
      this.#complete = true
      return eventStreamResponse(textEvents(acceptanceText, "dispose"))
    }
    if (this.#mode === "crash") return await this.#receiveCrashParent(outputs, name)
    return await this.#receiveCloseParent(payloadText, outputs, name)
  }

  async #receiveCloseParent(
    payloadText: string,
    outputs: ReadonlyMap<string, string>,
    name: string
  ): Promise<Response> {
    const initialWait = outputs.get("acceptance_wait_initial")
    if (!initialWait) {
      if (this.#resultProbeId) {
        const probeOutput = outputs.get(this.#resultProbeId)
        if (!probeOutput) throw new Error(`Compiled parent omitted ${this.#resultProbeId} output`)
        if (hasReadyCompletion(probeOutput)) {
          if (payloadText.includes("Subagents completed:")) {
            throw new Error("Compiled parent injected an unsolicited subagent completion message")
          }
          return eventStreamResponse(
            toolEvents("wait_subagents", "acceptance_wait_initial", { names: [name], timeout_ms: 25_000 })
          )
        }
      }
      if (++this.#resultProbeCount > 40)
        throw new Error("Compiled completion did not become durable during result probe")
      await Bun.sleep(25)
      this.#resultProbeId = `acceptance_result_probe_${this.#resultProbeCount}`
      return eventStreamResponse(toolEvents("list_subagents", this.#resultProbeId, {}))
    }
    assertWaitCompletion(initialWait, { status: "completed", text: "Compiled child completed." })

    if (!outputs.has("acceptance_send_idle")) {
      return eventStreamResponse(
        toolEvents("send_subagent", "acceptance_send_idle", { name: name, text: "Queue this without waking." })
      )
    }
    if (!outputs.has("acceptance_continue_second")) {
      const childRequests = this.#childProviderRequests
      await Bun.sleep(150)
      if (this.#childProviderRequests !== childRequests || !this.#childInitialReplySent) {
        throw new Error("Compiled queue-only send woke an idle child")
      }
      return eventStreamResponse(
        toolEvents("continue_subagent", "acceptance_continue_second", {
          name: name,
          text: "Complete the second cycle."
        })
      )
    }
    if (!outputs.has("acceptance_wait_second")) {
      return eventStreamResponse(
        toolEvents("wait_subagents", "acceptance_wait_second", { names: [name], timeout_ms: 25_000 })
      )
    }
    assertWaitCompletion(outputs.get("acceptance_wait_second")!, {
      status: "completed",
      text: "Compiled second cycle completed."
    })

    if (!outputs.has("acceptance_continue_interrupt")) {
      return eventStreamResponse(
        toolEvents("continue_subagent", "acceptance_continue_interrupt", {
          name: name,
          text: "Interrupt the active third cycle."
        })
      )
    }
    if (!outputs.has("acceptance_interrupt")) {
      await waitFor(
        () => markerExists(`${this.#markerPath}.tool`),
        5_000,
        "Compiled child extension tool did not start before interruption"
      )
      return eventStreamResponse(toolEvents("interrupt_subagent", "acceptance_interrupt", { name: name }))
    }
    assertInterruptResult(outputs.get("acceptance_interrupt")!, "interrupted")
    if (!outputs.has("acceptance_wait_interrupt")) {
      return eventStreamResponse(
        toolEvents("wait_subagents", "acceptance_wait_interrupt", { names: [name], timeout_ms: 25_000 })
      )
    }
    assertWaitCompletion(outputs.get("acceptance_wait_interrupt")!, { status: "cancelled" })

    if (!outputs.has("acceptance_continue_reuse")) {
      return eventStreamResponse(
        toolEvents("continue_subagent", "acceptance_continue_reuse", {
          name: name,
          text: "Reuse after active interruption."
        })
      )
    }
    if (!outputs.has("acceptance_wait_reuse")) {
      return eventStreamResponse(
        toolEvents("wait_subagents", "acceptance_wait_reuse", { names: [name], timeout_ms: 25_000 })
      )
    }
    assertWaitCompletion(outputs.get("acceptance_wait_reuse")!, { status: "completed", text: "Compiled child reused." })

    if (!outputs.has("acceptance_close")) {
      return eventStreamResponse(toolEvents("close_subagent", "acceptance_close", { name }))
    }
    const close = record(JSON.parse(outputs.get("acceptance_close")!), "close result")
    if (close.name !== name || close.status !== "exited") {
      throw new Error(`Compiled close result omitted its exited state: ${outputs.get("acceptance_close")}`)
    }
    this.#complete = true
    return eventStreamResponse(textEvents(acceptanceText, "close"))
  }

  async #receiveCrashParent(outputs: ReadonlyMap<string, string>, name: string): Promise<Response> {
    if (!outputs.has("acceptance_wait")) {
      return eventStreamResponse(toolEvents("wait_subagents", "acceptance_wait", { names: [name], timeout_ms: 25_000 }))
    }
    assertWaitCompletion(outputs.get("acceptance_wait")!, { status: "completed" })
    if (!outputs.has("acceptance_list")) {
      const marker = await readProcessMarker(this.#markerPath)
      process.kill(marker.childPid, "SIGKILL")
      await waitFor(() => !processAlive(marker.childPid), 5_000, "Forced subagent child did not exit")
      return eventStreamResponse(toolEvents("list_subagents", "acceptance_list", {}))
    }
    this.#complete = true
    return eventStreamResponse(textEvents(acceptanceText, "crash"))
  }
}

function acceptanceExtension(): string {
  return `import { Schema, type ExtensionFactory } from "@with-zi/extension-api"

const extension: ExtensionFactory = zi => {
  if (process.env.ZI_SUBAGENT_DEPTH !== "1") {
    if (process.env.ZI_SUBAGENT_PROFILE_DECLARATION === "programmatic") {
      zi.registerSubagentProfile({
        name: "acceptance",
        description: "Exercise the compiled profile-driven subagent system",
        instructions: "Complete the acceptance task and return bounded evidence.",
        model: "azure-openai-responses/gpt-4.1",
        thinking: "off"
      })
    }
    return
  }
  const marker = process.env.ZI_SUBAGENT_ACCEPTANCE_MARKER
  if (!marker) throw new Error("missing subagent acceptance marker")
  if (process.env.ZI_INTERNAL_SUBAGENT_API_KEY !== undefined) {
    throw new Error("private subagent API key reached the extension worker")
  }
  Bun.write(marker, JSON.stringify({ childPid: process.ppid, workerPid: process.pid }))
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
}

export default extension
`
}

function acceptanceMarkdownProfile(): string {
  return `---
description: Exercise the compiled profile-driven subagent system
model: azure-openai-responses/gpt-4.1
thinking: off
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

function parseName(output: string): string {
  const match = /"name"\s*:\s*"([^"]+)"/.exec(output)
  if (!match?.[1]) throw new Error(`Spawn output omitted name: ${JSON.stringify(output)}`)
  return match[1]
}

function assertProfileCatalog(output: string): void {
  const result = record(JSON.parse(output), "profile catalog")
  const profiles = Array.isArray(result.profiles) ? result.profiles : []
  if (!profiles.some(profile => isRecord(profile) && profile.name === "acceptance")) {
    throw new Error(`Compiled parent omitted the acceptance profile: ${JSON.stringify(output)}`)
  }
}

function assertWaitCompletion(output: string, expected: { readonly status: string; readonly text?: string }): void {
  const result = record(JSON.parse(output), "wait result")
  const agent = Array.isArray(result.subagents) ? result.subagents.find(isRecord) : undefined
  const completion = agent && isRecord(agent.completion) ? agent.completion : undefined
  if (
    !agent ||
    !completion ||
    completion.status !== expected.status ||
    (expected.text !== undefined && completion.text !== expected.text)
  ) {
    throw new Error(`Compiled subagent wait did not return ${expected.status}: ${JSON.stringify(output)}`)
  }
}

function assertInterruptResult(output: string, expected: "interrupted" | "already_idle"): void {
  const result = record(JSON.parse(output), "interrupt result")
  if (result.outcome !== expected) {
    throw new Error(`Compiled subagent interrupt returned ${JSON.stringify(output)} instead of ${expected}`)
  }
}

function hasReadyCompletion(output: string): boolean {
  const result = record(JSON.parse(output), "list result")
  if (!Array.isArray(result.subagents)) return false
  return result.subagents.some(agent => isRecord(agent) && isRecord(agent.result_ready))
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

async function assertNativeJournal(agentDirectory: string, name: string, mode: Mode): Promise<void> {
  const directory = join(agentDirectory, "acceptance-sessions")
  const files = (await readdir(directory)).filter(file => file.endsWith(".jsonl"))
  if (files.length !== 1) throw new Error(`Compiled ${mode} acceptance wrote ${files.length} parent journals`)
  const journal = await readFile(join(directory, files[0]!), "utf8")
  if (journal.includes(acceptanceApiKey)) throw new Error(`Compiled ${mode} journal exposed the ephemeral API key`)
  const lines = journal
    .trim()
    .split("\n")
    .map((line, index) => record(JSON.parse(line), `journal line ${index + 1}`))
  const entries = lines.filter(entry => entry.type === "subagent" && entry.name === name)

  assertJournalEntry(entries, { event: "starting", name: "acceptance-worker" }, mode)
  assertJournalEntry(entries, { event: "ready" }, mode)
  assertJournalEntry(entries, { event: "work_cycle_started", workCycle: 1 }, mode)
  if (mode === "dispose") return

  assertJournalEntry(entries, { event: "work_cycle_finished", workCycle: 1, status: "completed" }, mode)
  assertJournalEntry(entries, { event: "exited" }, mode)
  if (mode === "crash") return

  assertJournalEntry(entries, { event: "work_cycle_started", workCycle: 2 }, mode)
  assertJournalEntry(entries, { event: "work_cycle_finished", workCycle: 2, status: "completed" }, mode)
  assertJournalEntry(entries, { event: "work_cycle_started", workCycle: 3 }, mode)
  assertJournalEntry(entries, { event: "work_cycle_finished", workCycle: 3, status: "cancelled" }, mode)
  assertJournalEntry(entries, { event: "work_cycle_started", workCycle: 4 }, mode)
  assertJournalEntry(entries, { event: "work_cycle_finished", workCycle: 4, status: "completed" }, mode)
  assertJournalEntry(entries, { event: "closing", reason: "close" }, mode)
}

function assertJournalEntry(
  entries: readonly Record<string, unknown>[],
  expected: Readonly<Record<string, unknown>>,
  mode: Mode
): void {
  const found = entries.some(entry => Object.entries(expected).every(([key, value]) => entry[key] === value))
  if (!found) {
    throw new Error(`Compiled ${mode} journal omitted ${JSON.stringify(expected)}: ${JSON.stringify(entries)}`)
  }
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

function markerExists(path: string): boolean {
  try {
    return readFileSync(path, "utf8") === "started"
  } catch {
    return false
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
