import type { AgentTool } from "@earendil-works/pi-agent-core"
import { Type } from "@earendil-works/pi-ai"

export const maxPeerMessageBytes = 64 * 1024
export const maxPeerOperations = 8
export const maxPeerAgents = 4

export type PeerAgentLifecycle = "idle" | "queued" | "running" | "interrupting"

export interface PeerAgent {
  readonly name: string
  readonly lifecycle: PeerAgentLifecycle
}

export type PeerRelay = (
  request:
    | { readonly operation: "list" }
    | { readonly operation: "send"; readonly target: string; readonly text: string },
  signal?: AbortSignal
) => Promise<{ readonly peers: readonly PeerAgent[] } | { readonly delivered: true }>

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

export function createPeerTools(relay: PeerRelay): readonly AgentTool[] {
  const operations = new PeerOperations(relay)
  const list: AgentTool<typeof emptyParameters> = {
    name: "list_peer_subagents",
    label: "list_peer_subagents",
    description: `List the other live subagents owned by your parent session. Returns at most ${maxPeerAgents} sibling runtime names and lifecycle states.`,
    parameters: emptyParameters,
    executionMode: "parallel",
    execute: async (_id, _input, signal) => {
      const result = await operations.list(signal)
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
      validatePeerMessage(input.text)
      await operations.send(input.name, input.text, signal)
      return { content: [{ type: "text", text: `Sent context to sibling ${input.name}.` }], details: {} }
    }
  }
  return Object.freeze([list, send])
}

export function peerMessagingDoctrine(): string {
  return `# Peer subagents

You are a child agent in a parent-owned team. Use list_peer_subagents to discover live siblings and send_peer_message to share relevant findings or coordinate active work directly.

Peer messages are context-only. They join a sibling's active work promptly but do not start an idle sibling turn. Your final response is still delivered to your parent.`
}

class PeerOperations {
  readonly #relay: PeerRelay
  #pending = 0

  constructor(relay: PeerRelay) {
    this.#relay = relay
  }

  async list(signal?: AbortSignal): Promise<{ readonly peers: readonly PeerAgent[] }> {
    const result = await this.#run(() => this.#relay({ operation: "list" }, signal), signal)
    if (!("peers" in result)) throw new Error("Peer list returned an invalid result")
    return result
  }

  async send(target: string, text: string, signal?: AbortSignal): Promise<{ readonly delivered: true }> {
    const result = await this.#run(() => this.#relay({ operation: "send", target, text }, signal), signal)
    if (!("delivered" in result)) throw new Error("Peer delivery returned an invalid result")
    return result
  }

  #run<Result>(operation: () => Promise<Result>, signal?: AbortSignal): Promise<Result> {
    if (this.#pending >= maxPeerOperations) {
      return Promise.reject(new Error(`At most ${maxPeerOperations} peer operations may be pending`))
    }
    if (signal?.aborted) return Promise.reject(peerAbortError(signal))
    this.#pending++
    let relay: Promise<Result>
    try {
      relay = operation()
    } catch (cause) {
      this.#pending--
      return Promise.reject(cause)
    }
    const settled = relay.finally(() => {
      this.#pending--
    })
    if (!signal) return settled
    return raceWithCancellation(settled, signal)
  }
}

function validatePeerMessage(text: string): void {
  if (text.length === 0 || text.includes("\0") || Buffer.byteLength(text) > maxPeerMessageBytes) {
    throw new Error(`Peer message must contain 1 through ${maxPeerMessageBytes} UTF-8 bytes without NUL`)
  }
}

async function raceWithCancellation<Result>(operation: Promise<Result>, signal: AbortSignal): Promise<Result> {
  if (signal.aborted) throw peerAbortError(signal)
  let rejectCancellation!: (cause: Error) => void
  const cancellation = new Promise<never>((_, reject) => {
    rejectCancellation = reject
  })
  const abort = (): void => rejectCancellation(peerAbortError(signal))
  signal.addEventListener("abort", abort, { once: true })
  try {
    return await Promise.race([operation, cancellation])
  } finally {
    signal.removeEventListener("abort", abort)
  }
}

function peerAbortError(signal: AbortSignal): Error {
  if (signal.reason instanceof Error) return signal.reason
  const error = new Error("Peer operation was cancelled")
  error.name = "AbortError"
  return error
}
