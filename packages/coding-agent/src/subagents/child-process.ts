/**
 * One ChildZiProcess owns exactly one spawned Zi RPC child, its stdin write tail,
 * stdout reader, protocol validation, diagnostics, and termination.
 *
 * Adapted from examples/rpc/client.ts; no private Zi imports.
 */

import type { ProcessScope, ProcessTreeTracker } from "../processes/process-tree.js"

export const rpcProtocolVersion = 1 as const
export const maxRpcFrameBytes = 16 * 1024 * 1024
export const maxRpcPendingRequests = 32
export const maxRpcPendingWriteBytes = 16 * 1024 * 1024
export const maxRpcStderrBytes = 64 * 1024
export const maxRpcMessagePages = 1_024
export const maxCompletionBytes = 50 * 1024
export const rpcReadyTimeoutMs = 10_000
export const rpcRequestTimeoutMs = 5 * 60_000
export const rpcCloseGraceMs = 5_000
export const rpcCloseForceMs = 5_000

export type ChildLifecycleState =
  | { readonly type: "starting"; readonly startedAt: number }
  | { readonly type: "idle"; readonly nextWorkCycle: number }
  | { readonly type: "spawn_admitting"; readonly workCycle: number; readonly startedAt: number }
  | { readonly type: "running"; readonly workCycle: number; readonly startedAt: number }
  | { readonly type: "interrupting"; readonly workCycle: number; readonly requestedAt: number }
  | { readonly type: "closing"; readonly reason: string; readonly requestedAt: number }
  | { readonly type: "exited"; readonly outcome: ChildExitOutcome }

export type ChildExitOutcome =
  | { readonly type: "closed"; readonly code: number | null }
  | { readonly type: "failed"; readonly message: string; readonly code: number | null }
  | { readonly type: "killed"; readonly message: string }

export type SubagentCompletionStatus = "completed" | "failed" | "cancelled"

export type SubagentCompletion = {
  readonly name: string
  readonly workCycle: number
  readonly status: SubagentCompletionStatus
  readonly text: string
  readonly originalBytes: number
  readonly omittedBytes: number
  readonly truncated: boolean
  readonly durationMs: number
  readonly reason?: string | undefined
  readonly error?: string | undefined
}

export type ChildSnapshot = {
  readonly name: string
  readonly lifecycle: ChildLifecycleState["type"]
  readonly workCycle?: number | undefined
  readonly elapsedMs?: number | undefined
  readonly sessionId?: string | undefined
  readonly completion?: SubagentCompletion | undefined
}

type PendingRequest = {
  readonly method: string
  readonly resolve: (value: unknown) => void
  readonly reject: (cause: unknown) => void
  readonly timeout: ReturnType<typeof setTimeout>
}

export type ChildZiProcessOptions = {
  readonly name: string
  readonly command: readonly string[]
  readonly cwd: string
  readonly env: Readonly<Record<string, string | undefined>>
  readonly processTreeTracker: ProcessTreeTracker
  readonly onStateChange?: () => void
  readonly onCompletion?: (completion: SubagentCompletion) => void
  readonly onFatal?: (error: Error) => void
}

export class ChildZiProcess {
  readonly name: string
  readonly #child: Bun.Subprocess<"pipe", "pipe", "pipe">
  readonly #onStateChange: (() => void) | undefined
  readonly #onCompletion: ((completion: SubagentCompletion) => void) | undefined
  readonly #onFatal: ((error: Error) => void) | undefined
  readonly #ready = deferred<void>()
  readonly #pending = new Map<string, PendingRequest>()
  readonly #stdoutSettlement: Promise<void>
  readonly #stderrSettlement: Promise<void>
  readonly #processScope: ProcessScope
  #state: ChildLifecycleState
  #sessionId: string | undefined
  #messageCountAtCycleStart = 0
  #admissionRevision = 0
  #pendingCycleAdmission = 0
  #idleWatch: { readonly revision: number; readonly promise: Promise<void> } | undefined
  #interruptInFlight = false
  #nextRequestId = 0
  #nextSequence = 1
  #writeTail = Promise.resolve()
  #pendingWriteBytes = 0
  #stderr = ""
  #latestCompletion: SubagentCompletion | undefined
  #cycleStartedAt = 0

  constructor(options: ChildZiProcessOptions) {
    this.name = options.name
    this.#onStateChange = options.onStateChange
    this.#onCompletion = options.onCompletion
    this.#onFatal = options.onFatal
    this.#state = { type: "starting", startedAt: Date.now() }
    this.#child = Bun.spawn([...options.command], {
      cwd: options.cwd,
      env: options.env,
      stdin: "pipe",
      stdout: "pipe",
      stderr: "pipe",
      detached: process.platform !== "win32",
      windowsHide: true
    })
    this.#processScope = createChildProcessScope(this.#child, options.processTreeTracker, cause => this.#fail(cause))
    this.#stdoutSettlement = this.#consumeStdout().catch(cause => this.#fail(cause))
    this.#stderrSettlement = this.#consumeStderr().catch(cause => this.#fail(cause))
    void this.#child.exited.then(async code => {
      await settleWithin(this.#stderrSettlement, 1_000)
      if (this.#state.type !== "closing" && this.#state.type !== "exited") {
        const diagnostic = this.#stderr.trim()
        this.#fail(
          new Error(
            `Subagent ${this.name} exited unexpectedly with code ${String(code)}${diagnostic ? `: ${diagnostic}` : ""}`
          )
        )
      }
      return undefined
    })
  }

  get state(): ChildLifecycleState {
    return this.#state
  }

  snapshot(): ChildSnapshot {
    const state = this.#state
    const activeSince =
      state.type === "starting" || state.type === "spawn_admitting" || state.type === "running"
        ? state.startedAt
        : state.type === "interrupting"
          ? this.#cycleStartedAt
          : undefined
    return {
      name: this.name,
      lifecycle: state.type,
      ...(state.type === "running" ||
      state.type === "spawn_admitting" ||
      state.type === "interrupting" ||
      state.type === "idle"
        ? {
            workCycle:
              state.type === "idle"
                ? Math.max(0, state.nextWorkCycle - 1)
                : "workCycle" in state
                  ? state.workCycle
                  : undefined
          }
        : {}),
      ...(activeSince !== undefined
        ? { elapsedMs: Math.max(0, Date.now() - activeSince) }
        : this.#latestCompletion
          ? { elapsedMs: this.#latestCompletion.durationMs }
          : {}),
      ...(this.#sessionId ? { sessionId: this.#sessionId } : {}),
      ...(this.#latestCompletion ? { completion: this.#latestCompletion } : {})
    }
  }

  async start(): Promise<void> {
    const reached = await settleWithin(
      Promise.all([this.#ready.promise, this.#processScope.admitted]).then(() => undefined),
      rpcReadyTimeoutMs
    )
    if (!reached) {
      const error = new Error(`Subagent ${this.name} did not become ready within ${rpcReadyTimeoutMs}ms`)
      this.#fail(error)
      throw error
    }
    await this.request("connection.set_events", { mode: "none" })
    const state = await this.request("session.get_state")
    if (isRecord(state)) {
      if (typeof state.sessionId === "string") this.#sessionId = state.sessionId
      if (typeof state.messageCount === "number") this.#messageCountAtCycleStart = state.messageCount
    }
    this.#transition({ type: "idle", nextWorkCycle: 1 })
  }

  async spawnAdmit(prompt: string): Promise<void> {
    const state = this.#state
    if (state.type !== "idle") throw new Error(`Subagent ${this.name} cannot spawn-admit while ${state.type}`)
    const workCycle = state.nextWorkCycle
    this.#transition({ type: "spawn_admitting", workCycle, startedAt: Date.now() })
    this.#cycleStartedAt = Date.now()
    this.#messageCountAtCycleStart = await this.#currentMessageCount()
    this.#beginCycleAdmission()
    try {
      await this.request("session.prompt", { delivery: "direct", text: prompt })
    } catch (cause) {
      this.#endCycleAdmission()
      throw cause
    }
    this.#endCycleAdmission()
    this.#transition({ type: "running", workCycle, startedAt: this.#cycleStartedAt })
    this.#watchIdle(this.#admissionRevision)
  }

  async sendFollowUp(text: string): Promise<void> {
    const state = this.#state
    if (state.type !== "idle" && state.type !== "running" && state.type !== "interrupting") {
      throw new Error(`Subagent ${this.name} cannot accept send while ${state.type}`)
    }
    const running = state.type === "running" || state.type === "interrupting"
    if (running) this.#beginCycleAdmission()
    try {
      await this.request("session.prompt", { delivery: "follow_up", text })
    } catch (cause) {
      if (running) this.#endCycleAdmission()
      throw cause
    }
    if (running) {
      this.#endCycleAdmission()
      this.#watchIdle(this.#admissionRevision)
    }
  }

  async continueWith(text: string): Promise<void> {
    const state = this.#state
    if (state.type === "idle") {
      const workCycle = state.nextWorkCycle
      this.#transition({ type: "running", workCycle, startedAt: Date.now() })
      this.#cycleStartedAt = Date.now()
      this.#messageCountAtCycleStart = await this.#currentMessageCount()
      this.#beginCycleAdmission()
      try {
        await this.request("session.prompt", { delivery: "continue", text })
      } catch (cause) {
        this.#endCycleAdmission()
        // Failed continue after idle transition: recover via get_state.
        await this.#recoverAfterFailedContinue()
        throw cause
      }
      this.#endCycleAdmission()
      this.#watchIdle(this.#admissionRevision)
      return
    }
    if (state.type !== "running" && state.type !== "interrupting") {
      throw new Error(`Subagent ${this.name} cannot continue while ${state.type}`)
    }
    this.#beginCycleAdmission()
    try {
      await this.request("session.prompt", { delivery: "continue", text })
    } catch (cause) {
      this.#endCycleAdmission()
      await this.#recoverAfterFailedContinue()
      throw cause
    }
    this.#endCycleAdmission()
    this.#watchIdle(this.#admissionRevision)
  }

  async interrupt(): Promise<"interrupted" | "already_idle"> {
    const state = this.#state
    if (state.type === "idle") return "already_idle"
    if (state.type === "interrupting") return "interrupted"
    if (state.type !== "running" && state.type !== "spawn_admitting") {
      throw new Error(`Subagent ${this.name} cannot interrupt while ${state.type}`)
    }
    if (this.#interruptInFlight) return "interrupted"
    const workCycle = state.workCycle
    this.#transition({ type: "interrupting", workCycle, requestedAt: Date.now() })
    this.#beginCycleAdmission()
    this.#interruptInFlight = true
    try {
      await this.request("session.interrupt")
    } finally {
      this.#interruptInFlight = false
      this.#endCycleAdmission()
    }
    this.#watchIdle(this.#admissionRevision)
    return "interrupted"
  }

  async close(reason = "close", graceMs = rpcCloseGraceMs, forceMs = rpcCloseForceMs): Promise<void> {
    const state = this.#state
    if (state.type === "exited") return
    if (state.type === "closing") {
      await this.#waitExit()
      return
    }
    this.#transition({ type: "closing", reason, requestedAt: Date.now() })
    this.#rejectPending(new Error(`Subagent ${this.name} is closing`))
    await this.#writeTail.catch(() => {})
    try {
      await this.#child.stdin.end()
    } catch {
      // already closed
    }
    let exitCode = await settleValueWithin(this.#child.exited, graceMs)
    if (exitCode === timeoutValue) {
      try {
        this.#child.kill()
      } catch {
        // already dead
      }
      exitCode = await settleValueWithin(this.#child.exited, forceMs)
    }
    await this.#processScope.terminate()
    await settleWithin(
      Promise.allSettled([this.#stdoutSettlement, this.#stderrSettlement]).then(() => undefined),
      1_000
    )
    if (exitCode === timeoutValue) {
      this.#transition({
        type: "exited",
        outcome: { type: "killed", message: `Subagent ${this.name} did not exit within close bounds` }
      })
      return
    }
    const code = typeof exitCode === "number" ? exitCode : null
    this.#transition({
      type: "exited",
      outcome:
        code === 0 || code === null ? { type: "closed", code } : { type: "failed", message: this.#stderr.trim(), code }
    })
  }

  request(method: string, params?: Readonly<Record<string, unknown>>): Promise<unknown> {
    if (this.#state.type === "closing" || this.#state.type === "exited") {
      return Promise.reject(new Error(`Subagent ${this.name} is ${this.#state.type}`))
    }
    if (this.#state.type === "starting" && method !== "connection.set_events" && method !== "session.get_state") {
      // Only startup methods before ready transition to idle.
    }
    if (this.#pending.size >= maxRpcPendingRequests) {
      return Promise.reject(new Error(`Subagent ${this.name} has too many pending RPC requests`))
    }
    const id = String(++this.#nextRequestId)
    const line = `${JSON.stringify({ version: rpcProtocolVersion, id, method, ...(params ? { params } : {}) })}\n`
    const bytes = Buffer.byteLength(line)
    if (bytes > maxRpcFrameBytes) {
      return Promise.reject(new Error(`RPC request exceeds ${maxRpcFrameBytes} bytes`))
    }
    if (this.#pendingWriteBytes + bytes > maxRpcPendingWriteBytes) {
      return Promise.reject(new Error(`RPC pending writes exceed ${maxRpcPendingWriteBytes} bytes`))
    }
    const settlement = deferred<unknown>()
    const timeout = setTimeout(() => {
      const pending = this.#pending.get(id)
      if (!pending) return
      this.#pending.delete(id)
      const error = new Error(`RPC request ${method} timed out`)
      pending.reject(error)
      this.#fail(error)
    }, rpcRequestTimeoutMs)
    this.#pending.set(id, { method, resolve: settlement.resolve, reject: settlement.reject, timeout })
    this.#enqueueWrite(line, bytes)
    return settlement.promise
  }

  async #currentMessageCount(): Promise<number> {
    const state = await this.request("session.get_state")
    if (isRecord(state) && typeof state.messageCount === "number") return state.messageCount
    return this.#messageCountAtCycleStart
  }

  #beginCycleAdmission(): void {
    this.#admissionRevision++
    this.#pendingCycleAdmission++
    this.#idleWatch = undefined
  }

  #endCycleAdmission(): void {
    this.#pendingCycleAdmission = Math.max(0, this.#pendingCycleAdmission - 1)
  }

  #watchIdle(revision: number): void {
    const promise = this.request("session.await_idle")
      .then(() => this.#onIdle(revision))
      .catch(cause => {
        if (this.#state.type === "closing" || this.#state.type === "exited") return
        this.#fail(cause)
      })
    this.#idleWatch = { revision, promise }
  }

  async #onIdle(revision: number): Promise<void> {
    if (this.#idleWatch?.revision !== revision) return
    if (this.#pendingCycleAdmission > 0) return
    if (this.#admissionRevision !== revision) return
    const state = this.#state
    if (state.type !== "running" && state.type !== "interrupting") return

    // Settled work is a containment admission barrier for background processes started during the cycle.
    if ((await this.#processScope.refresh()).type === "overflow") {
      throw new Error("Subagent process scope exceeded tracked descendant capacity")
    }
    const completion = await this.#readCompletion(state.workCycle)
    this.#latestCompletion = completion
    try {
      this.#onCompletion?.(completion)
    } catch {
      // Process ownership cannot cross into an observer.
    }
    this.#transition({ type: "idle", nextWorkCycle: state.workCycle + 1 })
  }

  async #recoverAfterFailedContinue(): Promise<void> {
    try {
      const state = await this.request("session.get_state")
      const activity = isRecord(state) && isRecord(state.activity) ? state.activity.type : undefined
      if (activity === "idle") {
        const current = this.#state
        const workCycle =
          current.type === "running" || current.type === "interrupting" || current.type === "spawn_admitting"
            ? current.workCycle
            : 0
        this.#transition({ type: "idle", nextWorkCycle: workCycle + 1 })
        return
      }
      this.#watchIdle(this.#admissionRevision)
    } catch (cause) {
      this.#fail(cause)
    }
  }

  async #readCompletion(workCycle: number): Promise<SubagentCompletion> {
    const durationMs = Math.max(0, Date.now() - this.#cycleStartedAt)
    let start = this.#messageCountAtCycleStart
    let latest: { readonly text: string; readonly stopReason: string; readonly error?: string } | undefined

    let completeSuffix = false
    for (let pageIndex = 0; pageIndex < maxRpcMessagePages; pageIndex++) {
      // Sequential pages keep one cursor for the settled suffix.
      // oxlint-disable-next-line no-await-in-loop
      const result = await this.request("session.get_messages", { start, limit: 100 })
      const page = messagePage(result)
      if (page.start !== start) throw new Error("RPC message page start mismatch")
      for (const message of page.messages) {
        const assistant = assistantMessage(message)
        if (assistant) latest = assistant
      }
      if (page.nextStart === null) {
        completeSuffix = true
        break
      }
      if (page.nextStart <= start) throw new Error("RPC message pagination did not advance")
      start = page.nextStart
    }
    if (!completeSuffix) throw new Error(`RPC message suffix exceeded ${maxRpcMessagePages} pages`)

    if (!latest) {
      return baseCompletion(this.name, workCycle, durationMs, "failed", "", "missing_assistant")
    }
    const clipped = clipUtf8(latest.text, maxCompletionBytes)
    if (latest.stopReason === "aborted") {
      return {
        ...baseCompletion(this.name, workCycle, durationMs, "cancelled", clipped.text),
        originalBytes: clipped.originalBytes,
        omittedBytes: clipped.omittedBytes,
        truncated: clipped.omittedBytes > 0
      }
    }
    if (latest.stopReason === "error") {
      return {
        ...baseCompletion(this.name, workCycle, durationMs, "failed", clipped.text, "provider_error"),
        ...(latest.error !== undefined ? { error: latest.error } : {}),
        originalBytes: clipped.originalBytes,
        omittedBytes: clipped.omittedBytes,
        truncated: clipped.omittedBytes > 0
      }
    }
    if (latest.stopReason === "toolUse") {
      return baseCompletion(this.name, workCycle, durationMs, "failed", clipped.text, "missing_final_answer")
    }
    if (latest.stopReason === "pending") {
      return baseCompletion(this.name, workCycle, durationMs, "failed", clipped.text, "incomplete_final_answer")
    }
    return {
      ...baseCompletion(this.name, workCycle, durationMs, "completed", clipped.text),
      originalBytes: clipped.originalBytes,
      omittedBytes: clipped.omittedBytes,
      truncated: latest.stopReason === "length" || clipped.omittedBytes > 0
    }
  }

  async #consumeStdout(): Promise<void> {
    const reader = this.#child.stdout.getReader()
    const decoder = new JsonLineDecoder()
    try {
      while (true) {
        // oxlint-disable-next-line no-await-in-loop
        const next = await reader.read()
        if (next.done) break
        for (const line of decoder.push(next.value)) this.#receive(line)
      }
      for (const line of decoder.finish()) this.#receive(line)
    } finally {
      reader.releaseLock()
    }
  }

  async #consumeStderr(): Promise<void> {
    const reader = this.#child.stderr.getReader()
    const decoder = new TextDecoder("utf-8", { fatal: true })
    let bytes = 0
    try {
      while (true) {
        // oxlint-disable-next-line no-await-in-loop
        const next = await reader.read()
        if (next.done) break
        bytes += next.value.byteLength
        if (bytes > maxRpcStderrBytes) throw new Error(`Subagent stderr exceeded ${maxRpcStderrBytes} bytes`)
        this.#stderr += decoder.decode(next.value, { stream: true })
      }
      this.#stderr += decoder.decode()
    } catch (cause) {
      if (cause instanceof TypeError) throw new Error("Subagent stderr must be valid UTF-8", { cause })
      throw cause
    } finally {
      reader.releaseLock()
    }
  }

  #receive(line: string): void {
    let frame: unknown
    try {
      frame = JSON.parse(line)
    } catch {
      throw new Error("Subagent RPC emitted invalid JSONL")
    }
    if (!isRecord(frame) || frame.version !== 1 || !Number.isSafeInteger(frame.sequence)) {
      throw new Error("Subagent RPC emitted an invalid server frame")
    }
    if (frame.sequence !== this.#nextSequence) {
      throw new Error(`RPC sequence gap: expected ${this.#nextSequence}, received ${String(frame.sequence)}`)
    }
    this.#nextSequence++

    switch (frame.type) {
      case "ready":
        if (this.#state.type !== "starting" || !isRecord(frame.state)) {
          throw new Error("Subagent RPC emitted an invalid ready frame")
        }
        if (typeof frame.state.sessionId === "string") this.#sessionId = frame.state.sessionId
        if (typeof frame.state.messageCount === "number") this.#messageCountAtCycleStart = frame.state.messageCount
        this.#ready.resolve()
        return
      case "session_event":
        // Events should be suppressed after startup; ignore any that race the mode change.
        return
      case "response":
        this.#receiveResponse(frame)
        return
      case "protocol_error":
        throw new Error(
          `Subagent RPC protocol error: ${typeof frame.message === "string" ? frame.message : "protocol error"}`
        )
      default:
        throw new Error(`Subagent RPC unknown frame type: ${String(frame.type)}`)
    }
  }

  #receiveResponse(frame: Record<string, unknown>): void {
    if (typeof frame.id !== "string" || typeof frame.method !== "string") {
      throw new Error("Subagent RPC emitted an invalid response")
    }
    const pending = this.#pending.get(frame.id)
    if (!pending) throw new Error(`Subagent RPC responded to unknown request ${frame.id}`)
    if (pending.method !== frame.method) {
      throw new Error(`Subagent RPC method mismatch: expected ${pending.method}, received ${frame.method}`)
    }
    clearTimeout(pending.timeout)
    this.#pending.delete(frame.id)
    if (frame.ok === true) {
      pending.resolve(frame.result)
      return
    }
    if (frame.ok !== false || !isRecord(frame.error) || typeof frame.error.message !== "string") {
      throw new Error("Subagent RPC emitted an invalid failure response")
    }
    pending.reject(new Error(frame.error.message))
  }

  #enqueueWrite(line: string, bytes: number): void {
    this.#pendingWriteBytes += bytes
    const write = this.#writeTail.then(async () => {
      await this.#child.stdin.write(line)
      await this.#child.stdin.flush()
      return undefined
    })
    this.#writeTail = write.then(
      () => {
        this.#pendingWriteBytes -= bytes
        return undefined
      },
      cause => {
        this.#pendingWriteBytes -= bytes
        this.#fail(cause)
        return undefined
      }
    )
  }

  #fail(cause: unknown): void {
    if (this.#state.type === "exited" || this.#state.type === "closing") return
    const error = cause instanceof Error ? cause : new Error(String(cause))
    if (this.#state.type === "starting") this.#ready.reject(error)
    this.#rejectPending(error)
    try {
      this.#onFatal?.(error)
    } catch {
      // Process ownership cannot cross into an observer.
    }
    this.#transition({ type: "closing", reason: "fatal", requestedAt: Date.now() })
    void this.#processScope.terminate().catch(() => {})
    try {
      this.#child.kill()
    } catch {
      // already dead
    }
    void this.#waitExit()
      .then(code => {
        this.#transition({ type: "exited", outcome: { type: "failed", message: error.message, code } })
        return undefined
      })
      .catch(() => {
        this.#transition({ type: "exited", outcome: { type: "failed", message: error.message, code: null } })
        return undefined
      })
  }

  async #waitExit(): Promise<number | null> {
    const code = await this.#child.exited
    await settleWithin(
      Promise.allSettled([this.#stdoutSettlement, this.#stderrSettlement]).then(() => undefined),
      1_000
    )
    await this.#processScope.terminate()
    return typeof code === "number" ? code : null
  }

  #rejectPending(cause: Error): void {
    for (const pending of this.#pending.values()) {
      clearTimeout(pending.timeout)
      pending.reject(cause)
    }
    this.#pending.clear()
  }

  #transition(next: ChildLifecycleState): void {
    this.#state = next
    try {
      this.#onStateChange?.()
    } catch {
      // Process ownership cannot cross into an observer.
    }
  }
}

function createChildProcessScope(
  child: Bun.Subprocess<"pipe", "pipe", "pipe">,
  processTreeTracker: ProcessTreeTracker,
  onFailure: (error: Error) => void
): ProcessScope {
  try {
    return processTreeTracker.track(child.pid, onFailure)
  } catch (cause) {
    try {
      child.kill()
    } catch {
      // The process already exited while containment was being admitted.
    }
    throw cause
  }
}

function baseCompletion(
  name: string,
  workCycle: number,
  durationMs: number,
  status: SubagentCompletionStatus,
  text: string,
  reason?: string
): SubagentCompletion {
  const originalBytes = Buffer.byteLength(text)
  return {
    name,
    workCycle,
    status,
    text,
    originalBytes,
    omittedBytes: 0,
    truncated: false,
    durationMs,
    ...(reason ? { reason } : {})
  }
}

export function clipUtf8(
  text: string,
  maxBytes: number
): { readonly text: string; readonly originalBytes: number; readonly omittedBytes: number } {
  const encoded = Buffer.from(text)
  const originalBytes = encoded.byteLength
  if (originalBytes <= maxBytes) return { text, originalBytes, omittedBytes: 0 }
  let end = Math.max(0, Math.min(maxBytes, originalBytes))
  while (end > 0 && (encoded[end]! & 0xc0) === 0x80) end--
  const clipped = encoded.subarray(0, end).toString("utf8")
  return { text: clipped, originalBytes, omittedBytes: originalBytes - end }
}

function messagePage(value: unknown): {
  readonly start: number
  readonly total: number
  readonly nextStart: number | null
  readonly messages: readonly unknown[]
} {
  if (
    !isRecord(value) ||
    !Number.isSafeInteger(value.start) ||
    !Number.isSafeInteger(value.total) ||
    (value.nextStart !== null && !Number.isSafeInteger(value.nextStart)) ||
    !Array.isArray(value.messages)
  ) {
    throw new Error("Invalid RPC message page")
  }
  const start = value.start
  const total = value.total
  const nextStart = value.nextStart
  if (typeof start !== "number" || typeof total !== "number") throw new Error("Invalid RPC message page")
  if (nextStart !== null && typeof nextStart !== "number") throw new Error("Invalid RPC message page")
  return { start, total, nextStart, messages: value.messages }
}

function assistantMessage(
  value: unknown
): { readonly text: string; readonly stopReason: string; readonly error?: string } | undefined {
  if (!isRecord(value) || value.role !== "assistant" || !Array.isArray(value.content)) return undefined
  let text = ""
  for (const part of value.content) {
    if (!isRecord(part) || part.type !== "text" || typeof part.text !== "string") continue
    text += part.text
  }
  return {
    text,
    stopReason: typeof value.stopReason === "string" ? value.stopReason : "unknown",
    ...(typeof value.errorMessage === "string" ? { error: value.errorMessage } : {})
  }
}

class JsonLineDecoder {
  readonly #decoder = new TextDecoder("utf-8", { fatal: true })
  #buffer = ""
  #bufferBytes = 0

  push(chunk: Uint8Array): string[] {
    try {
      this.#buffer += this.#decoder.decode(chunk, { stream: true })
    } catch {
      throw new Error("Subagent RPC stdout must be valid UTF-8")
    }
    this.#bufferBytes += chunk.byteLength
    return this.#takeLines()
  }

  finish(): string[] {
    try {
      this.#buffer += this.#decoder.decode()
    } catch {
      throw new Error("Subagent RPC stdout must be valid UTF-8")
    }
    const lines = this.#takeLines()
    if (this.#buffer.length > 0) {
      lines.push(this.#buffer.endsWith("\r") ? this.#buffer.slice(0, -1) : this.#buffer)
      this.#buffer = ""
      this.#bufferBytes = 0
    }
    return lines
  }

  #takeLines(): string[] {
    const lines: string[] = []
    while (true) {
      const newline = this.#buffer.indexOf("\n")
      if (newline === -1) break
      const line = this.#buffer.slice(0, newline)
      const bytes = Buffer.byteLength(line)
      if (bytes > maxRpcFrameBytes) throw new Error(`RPC frame exceeds ${maxRpcFrameBytes} bytes`)
      lines.push(line.endsWith("\r") ? line.slice(0, -1) : line)
      this.#buffer = this.#buffer.slice(newline + 1)
      this.#bufferBytes -= bytes + 1
    }
    if (this.#bufferBytes > maxRpcFrameBytes) throw new Error(`RPC frame exceeds ${maxRpcFrameBytes} bytes`)
    return lines
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}

function deferred<T>() {
  let resolve!: (value: T | PromiseLike<T>) => void
  let reject!: (cause?: unknown) => void
  const promise = new Promise<T>((resolvePromise, rejectPromise) => {
    resolve = resolvePromise
    reject = rejectPromise
  })
  return { promise, resolve, reject }
}

const timeoutValue: unique symbol = Symbol("timeout")

async function settleWithin(operation: Promise<void>, timeoutMs: number): Promise<boolean> {
  return (
    (await settleValueWithin(
      operation.then(() => true),
      timeoutMs
    )) !== timeoutValue
  )
}

function settleValueWithin<T>(operation: Promise<T>, timeoutMs: number): Promise<T | typeof timeoutValue> {
  let timeout: ReturnType<typeof setTimeout> | undefined
  return Promise.race([
    operation,
    new Promise<typeof timeoutValue>(resolveTimeout => {
      timeout = setTimeout(() => resolveTimeout(timeoutValue), timeoutMs)
    })
  ]).finally(() => {
    if (timeout) clearTimeout(timeout)
  })
}
