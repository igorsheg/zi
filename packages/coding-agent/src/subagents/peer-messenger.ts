import type { AgentTool } from "@earendil-works/pi-agent-core"
import { Type } from "@earendil-works/pi-ai"

import {
  maxPeerAgents,
  maxPeerMessageBytes,
  maxPeerRequests,
  type PeerRequest,
  type PeerResponse,
  type PeerResult,
  validatePeerResult
} from "./peer-protocol.js"

const peerRequestTimeoutMs = 30_000
const maxRetiredPeerRequests = 32
const targetParameters = Type.Object({
  name: Type.String({
    minLength: 1,
    maxLength: 64,
    pattern: "^[a-z][a-z0-9_-]*$",
    description: "Sibling runtime name returned by list_peer_subagents"
  }),
  text: Type.String({ minLength: 1, maxLength: maxPeerMessageBytes, description: "Context to send" })
})
const emptyParameters = Type.Object({})

type PeerRequestTransport = (request: PeerRequest) => void

type PendingPeerRequest = {
  readonly operation: PeerRequest["operation"]
  readonly resolve: (result: PeerResult) => void
  readonly reject: (cause: unknown) => void
  readonly timer: ReturnType<typeof setTimeout>
  readonly removeAbort?: () => void
}

export class PeerMessenger {
  readonly #pending = new Map<string, PendingPeerRequest>()
  readonly #retired: string[] = []
  #transport: PeerRequestTransport | undefined
  #nextRequestId = 0
  #disposed = false

  createTools(): readonly AgentTool[] {
    const list: AgentTool<typeof emptyParameters> = {
      name: "list_peer_subagents",
      label: "list_peer_subagents",
      description: `List the other live subagents owned by your parent session. Returns at most ${maxPeerAgents} sibling runtime names and lifecycle states.`,
      parameters: emptyParameters,
      executionMode: "parallel",
      execute: async (_id, _input, signal) => {
        const result = await this.#request({ operation: "list" }, signal)
        if (!("peers" in result)) throw new Error("Peer list returned an invalid result")
        return { content: [{ type: "text", text: JSON.stringify({ peers: result.peers }) }], details: {} }
      }
    }
    const send: AgentTool<typeof targetParameters> = {
      name: "send_peer_message",
      label: "send_peer_message",
      description:
        "Send context to a live sibling subagent through the parent-owned relay. Delivery is queue-only: it reaches active work promptly but never starts an idle sibling turn. The parent derives your sender identity.",
      parameters: targetParameters,
      executionMode: "parallel",
      execute: async (_id, input, signal) => {
        const result = await this.#request({ operation: "send", target: input.name, text: input.text }, signal)
        if (!("delivered" in result)) throw new Error("Peer delivery returned an invalid result")
        return { content: [{ type: "text", text: `Sent context to sibling ${input.name}.` }], details: {} }
      }
    }
    return Object.freeze([list, send])
  }

  bind(transport: PeerRequestTransport): () => void {
    if (this.#disposed) throw new Error("Peer messaging is disposed")
    if (this.#transport) throw new Error("Peer messaging transport is already bound")
    this.#transport = transport
    return () => {
      if (this.#transport !== transport) return
      this.#transport = undefined
      this.#rejectPending(new Error("Parent peer relay disconnected"))
    }
  }

  accept(response: PeerResponse): boolean {
    const pending = this.#pending.get(response.id)
    if (!pending) {
      const retired = this.#retired.indexOf(response.id)
      if (retired === -1) return false
      this.#retired.splice(retired, 1)
      return true
    }
    if (pending.operation !== response.operation) throw new Error("Peer response operation mismatch")
    if (!response.ok) {
      this.#settle(response.id, pending)
      pending.reject(new Error(response.error))
      return true
    }
    let result: PeerResult
    try {
      result = validatePeerResult(response.operation, response.result)
    } catch (cause) {
      this.#settle(response.id, pending)
      pending.reject(cause)
      throw cause
    }
    this.#settle(response.id, pending)
    pending.resolve(result)
    return true
  }

  dispose(): void {
    if (this.#disposed) return
    this.#disposed = true
    this.#transport = undefined
    this.#rejectPending(new Error("Peer messaging is disposed"))
  }

  #request(
    request:
      | Omit<Extract<PeerRequest, { operation: "list" }>, "id">
      | Omit<Extract<PeerRequest, { operation: "send" }>, "id">,
    signal?: AbortSignal
  ): Promise<PeerResult> {
    if (this.#disposed) return Promise.reject(new Error("Peer messaging is disposed"))
    if (request.operation === "send") {
      if (!/^[a-z][a-z0-9_-]*$/.test(request.target) || Buffer.byteLength(request.target) > 64) {
        return Promise.reject(new Error("Peer target is invalid"))
      }
      if (request.text.length === 0 || Buffer.byteLength(request.text) > maxPeerMessageBytes) {
        return Promise.reject(new Error(`Peer message must contain 1 through ${maxPeerMessageBytes} bytes`))
      }
    }
    const transport = this.#transport
    if (!transport) return Promise.reject(new Error("Parent peer relay is unavailable"))
    if (this.#pending.size >= maxPeerRequests) {
      return Promise.reject(new Error(`At most ${maxPeerRequests} peer requests may be pending`))
    }
    if (signal?.aborted) return Promise.reject(abortError(signal))
    const id = `peer-${++this.#nextRequestId}`
    const admitted = Object.freeze({ id, ...request }) as PeerRequest
    return new Promise<PeerResult>((resolve, reject) => {
      const timer = setTimeout(() => {
        const pending = this.#pending.get(id)
        if (!pending) return
        this.#pending.delete(id)
        this.#retire(id)
        pending.removeAbort?.()
        reject(new Error("Parent peer relay timed out"))
      }, peerRequestTimeoutMs)
      timer.unref?.()
      const abort = (): void => {
        const pending = this.#pending.get(id)
        if (!pending) return
        this.#pending.delete(id)
        this.#retire(id)
        clearTimeout(timer)
        reject(abortError(signal))
      }
      const removeAbort = signal
        ? (() => {
            signal.addEventListener("abort", abort, { once: true })
            return () => signal.removeEventListener("abort", abort)
          })()
        : undefined
      this.#pending.set(id, {
        operation: admitted.operation,
        resolve,
        reject,
        timer,
        ...(removeAbort ? { removeAbort } : {})
      })
      try {
        transport(admitted)
      } catch (cause) {
        this.#pending.delete(id)
        clearTimeout(timer)
        removeAbort?.()
        reject(cause)
      }
    })
  }

  #settle(id: string, pending: PendingPeerRequest): void {
    this.#pending.delete(id)
    clearTimeout(pending.timer)
    pending.removeAbort?.()
  }

  #retire(id: string): void {
    this.#retired.push(id)
    if (this.#retired.length > maxRetiredPeerRequests) this.#retired.shift()
  }

  #rejectPending(cause: Error): void {
    for (const pending of this.#pending.values()) {
      clearTimeout(pending.timer)
      pending.removeAbort?.()
      pending.reject(cause)
    }
    this.#pending.clear()
    this.#retired.length = 0
  }
}

export function peerMessagingDoctrine(): string {
  return `# Peer subagents

You are a child agent in a parent-owned team. Use list_peer_subagents to discover live siblings and send_peer_message to share relevant findings or coordinate active work directly.

Peer messages are context-only. They join a sibling's active work promptly but do not start an idle sibling turn. Your final response is still delivered to your parent.`
}

function abortError(signal: AbortSignal | undefined): Error {
  return signal?.reason instanceof Error ? signal.reason : new Error("Peer request aborted")
}
