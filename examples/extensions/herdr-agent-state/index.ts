import { createConnection } from "node:net"

import type { ExtensionAPI, ExtensionSession } from "@with-zi/extension-api"

const source = "herdr:zi"
const agent = "zi"
const firstAttemptTimeoutMs = 500
const retryAttemptTimeoutMs = 1_500

type AgentState = "working" | "idle"

type HerdrRequest = Readonly<{
  id: string
  method: "pane.report_agent" | "pane.report_agent_session"
  params: Readonly<Record<string, string | number>>
}>

interface QueuedState {
  readonly state: AgentState
  readonly sequence: number
}

interface DeliveryAttempt {
  cancel(): void
}

type ReporterState =
  | {
      readonly type: "open"
      readonly attempts: Set<DeliveryAttempt>
      readonly tasks: Set<Promise<void>>
      queued: QueuedState | undefined
      draining: Promise<void> | undefined
    }
  | { readonly type: "closing"; readonly settlement: Promise<void> }
  | { readonly type: "closed" }

export function herdrSocketEndpoint(socketPath: string, platform = process.platform): string {
  return platform === "win32" ? `\\\\.\\pipe\\${socketPath}` : socketPath
}

export class HerdrReporter {
  readonly #endpoint: string
  readonly #paneId: string
  readonly #session: ExtensionSession
  #sequence = Date.now() * 1_000
  #lastState: AgentState | undefined
  #state: ReporterState = {
    type: "open",
    attempts: new Set(),
    tasks: new Set(),
    queued: undefined,
    draining: undefined
  }

  constructor(endpoint: string, paneId: string, session: ExtensionSession) {
    this.#endpoint = endpoint
    this.#paneId = paneId
    this.#session = session
  }

  async reportSession(startSource?: string): Promise<void> {
    const state = this.#state
    if (state.type !== "open") return
    const sequence = this.#nextSequence()
    const delivery = this.#sendRequest(state, {
      id: `${source}:session:${sequence}`,
      method: "pane.report_agent_session",
      params: {
        pane_id: this.#paneId,
        source,
        agent,
        seq: sequence,
        ...(startSource ? { session_start_source: startSource } : {}),
        ...sessionReference(this.#session)
      }
    })
    state.tasks.add(delivery)
    try {
      await delivery
    } finally {
      state.tasks.delete(delivery)
    }
  }

  queueState(agentState: AgentState): void {
    const state = this.#state
    if (state.type !== "open" || this.#lastState === agentState) return
    this.#lastState = agentState
    state.queued = { state: agentState, sequence: this.#nextSequence() }
    if (state.draining) return
    state.draining = this.#drain(state)
  }

  async close(): Promise<void> {
    const state = this.#state
    if (state.type === "closed") return
    if (state.type === "closing") {
      await state.settlement
      return
    }

    state.queued = undefined
    const settlement = Promise.all([state.draining, ...state.tasks]).then(() => undefined)
    this.#state = { type: "closing", settlement }
    for (const attempt of state.attempts) attempt.cancel()
    await settlement
    if (this.#state.type === "closing" && this.#state.settlement === settlement) {
      this.#state = { type: "closed" }
    }
  }

  async #drain(state: Extract<ReporterState, { type: "open" }>): Promise<void> {
    try {
      while (this.#state === state && state.queued) {
        const next = state.queued
        state.queued = undefined
        // Keep reports ordered while allowing a newer queued state to replace an obsolete one.
        // oxlint-disable-next-line no-await-in-loop
        await this.#sendState(state, next)
      }
    } finally {
      state.draining = undefined
      if (this.#state === state && state.queued) state.draining = this.#drain(state)
    }
  }

  async #sendState(state: Extract<ReporterState, { type: "open" }>, report: QueuedState): Promise<void> {
    await this.#sendRequest(state, {
      id: `${source}:state:${report.sequence}`,
      method: "pane.report_agent",
      params: {
        pane_id: this.#paneId,
        source,
        agent,
        state: report.state,
        seq: report.sequence,
        ...sessionReference(this.#session)
      }
    })
  }

  async #sendRequest(state: Extract<ReporterState, { type: "open" }>, request: HerdrRequest): Promise<void> {
    if (await this.#sendAttempt(state, request, firstAttemptTimeoutMs)) return
    if (this.#state !== state) return
    await this.#sendAttempt(state, request, retryAttemptTimeoutMs)
  }

  #sendAttempt(
    state: Extract<ReporterState, { type: "open" }>,
    request: HerdrRequest,
    timeoutMs: number
  ): Promise<boolean> {
    return new Promise(resolve => {
      let destroySocket: (() => void) | undefined
      let timeout: ReturnType<typeof setTimeout> | undefined
      let settled = false
      const attempt: DeliveryAttempt = { cancel: () => finish(false) }
      const finish = (delivered: boolean): void => {
        if (settled) return
        settled = true
        if (timeout) clearTimeout(timeout)
        state.attempts.delete(attempt)
        destroySocket?.()
        // finish is idempotent across socket, timeout, and explicit cancellation callbacks.
        // oxlint-disable-next-line promise/no-multiple-resolved
        resolve(delivered)
      }

      state.attempts.add(attempt)
      try {
        const socket = createConnection(this.#endpoint)
        destroySocket = () => socket.destroy()
        socket.on("error", () => finish(false))
        socket.on("connect", () => {
          try {
            socket.write(`${JSON.stringify(request)}\n`)
          } catch {
            finish(false)
          }
        })
        socket.on("data", () => finish(true))
        socket.on("end", () => finish(false))
        socket.on("close", () => finish(false))
        timeout = setTimeout(() => finish(false), timeoutMs)
        timeout.unref?.()
      } catch {
        finish(false)
      }
    })
  }

  #nextSequence(): number {
    this.#sequence += 1
    return this.#sequence
  }
}

export default function install(zi: Pick<ExtensionAPI, "on">): void {
  if (process.env.HERDR_ENV !== "1") return
  const socketPath = process.env.HERDR_SOCKET_PATH
  const paneId = process.env.HERDR_PANE_ID
  if (!socketPath || !paneId) return

  const endpoint = herdrSocketEndpoint(socketPath)
  let reporter: HerdrReporter | undefined

  zi.on("session_start", async (event, context) => {
    if (context.mode !== "interactive") return
    const next = new HerdrReporter(endpoint, paneId, context.session)
    reporter = next
    await next.reportSession(event.reason)
    next.queueState("idle")
  })

  zi.on("agent_start", () => reporter?.queueState("working"))

  zi.on("agent_settled", () => reporter?.queueState("idle"))

  zi.on("session_shutdown", async () => {
    const current = reporter
    reporter = undefined
    await current?.close()
  })
}

function sessionReference(session: ExtensionSession): Readonly<Record<string, string>> {
  return session.type === "journal" ? { agent_session_path: session.file } : { agent_session_id: session.id }
}
