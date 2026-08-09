import { isRecord } from "../guards.js"

export const maxPeerMessageBytes = 64 * 1024
export const maxPeerRequests = 8
export const maxPeerRequestIdBytes = 64
export const maxPeerAgents = 4

export type PeerAgentLifecycle = "starting" | "idle" | "spawn_admitting" | "running" | "interrupting"

export interface PeerAgent {
  readonly name: string
  readonly lifecycle: PeerAgentLifecycle
}

export type PeerRequest =
  | { readonly id: string; readonly operation: "list" }
  | { readonly id: string; readonly operation: "send"; readonly target: string; readonly text: string }

export type PeerResult = { readonly peers: readonly PeerAgent[] } | { readonly delivered: true }

export type PeerResponse =
  | { readonly id: string; readonly operation: PeerRequest["operation"]; readonly ok: true; readonly result: unknown }
  | { readonly id: string; readonly operation: PeerRequest["operation"]; readonly ok: false; readonly error: string }

export function decodePeerRequestFrame(value: unknown): PeerRequest {
  const frame = requireRecord(value, "peer request")
  if (frame.version !== 1 || !Number.isSafeInteger(frame.sequence)) throw new Error("Invalid peer request frame")
  if (frame.type !== "peer_request") throw new Error("Invalid peer request type")
  const id = peerRequestId(frame.id)
  if (frame.operation === "list") {
    requireKeys(frame, ["version", "sequence", "type", "id", "operation"])
    return Object.freeze({ id, operation: "list" })
  }
  if (frame.operation === "send") {
    requireKeys(frame, ["version", "sequence", "type", "id", "operation", "target", "text"])
    return Object.freeze({
      id,
      operation: "send",
      target: peerName(frame.target, "Peer target"),
      text: boundedString(frame.text, "Peer message", maxPeerMessageBytes)
    })
  }
  throw new Error("Invalid peer request operation")
}

export function decodePeerResponse(value: unknown): PeerResponse | undefined {
  if (!isRecord(value) || value.type !== "peer_response") return undefined
  requireKeys(value, ["version", "type", "id", "operation", "ok", "result", "error"], true)
  if (value.version !== 1) throw new Error("Invalid peer response version")
  const id = peerRequestId(value.id)
  if (value.operation !== "list" && value.operation !== "send") throw new Error("Invalid peer response operation")
  if (value.ok === true) {
    if (!("result" in value) || "error" in value) throw new Error("Invalid successful peer response")
    return Object.freeze({ id, operation: value.operation, ok: true, result: value.result })
  }
  if (value.ok === false) {
    if (!("error" in value) || "result" in value) throw new Error("Invalid failed peer response")
    return Object.freeze({
      id,
      operation: value.operation,
      ok: false,
      error: boundedString(value.error, "Peer response error", maxPeerMessageBytes)
    })
  }
  throw new Error("Invalid peer response outcome")
}

export function validatePeerResult(operation: PeerRequest["operation"], value: unknown): PeerResult {
  const result = requireRecord(value, "peer result")
  if (operation === "send") {
    requireKeys(result, ["delivered"])
    if (result.delivered !== true) throw new Error("Invalid peer delivery result")
    return Object.freeze({ delivered: true as const })
  }
  requireKeys(result, ["peers"])
  if (!Array.isArray(result.peers) || result.peers.length > maxPeerAgents) {
    throw new Error(`Peer list must contain at most ${maxPeerAgents} agents`)
  }
  const peers = result.peers.map(candidate => {
    const peer = requireRecord(candidate, "peer agent")
    requireKeys(peer, ["name", "lifecycle"])
    const name = peerName(peer.name, "Peer name")
    if (!isPeerLifecycle(peer.lifecycle)) throw new Error("Invalid peer lifecycle")
    return Object.freeze({ name, lifecycle: peer.lifecycle })
  })
  return Object.freeze({ peers: Object.freeze(peers) })
}

export function peerResponseFrame(request: PeerRequest, result: PeerResult): Readonly<Record<string, unknown>> {
  return Object.freeze({
    version: 1,
    type: "peer_response",
    id: request.id,
    operation: request.operation,
    ok: true,
    result
  })
}

export function peerFailureFrame(request: PeerRequest, error: string): Readonly<Record<string, unknown>> {
  return Object.freeze({
    version: 1,
    type: "peer_response",
    id: request.id,
    operation: request.operation,
    ok: false,
    error: boundedString(error, "Peer response error", maxPeerMessageBytes)
  })
}

function peerRequestId(value: unknown): string {
  return boundedString(value, "Peer request id", maxPeerRequestIdBytes, true)
}

function peerName(value: unknown, label: string): string {
  const name = boundedString(value, label, 64, true)
  if (!/^[a-z][a-z0-9_-]*$/.test(name)) throw new Error(`${label} is invalid`)
  return name
}

function boundedString(value: unknown, label: string, maxBytes: number, nonBlank = false): string {
  if (typeof value !== "string" || (nonBlank && value.length === 0) || Buffer.byteLength(value) > maxBytes) {
    throw new Error(`${label} must be ${nonBlank ? "a non-empty " : "a "}string of at most ${maxBytes} bytes`)
  }
  return value
}

function isPeerLifecycle(value: unknown): value is PeerAgentLifecycle {
  return (
    value === "starting" ||
    value === "idle" ||
    value === "spawn_admitting" ||
    value === "running" ||
    value === "interrupting"
  )
}

function requireRecord(value: unknown, label: string): Record<string, unknown> {
  if (!isRecord(value)) throw new Error(`Invalid ${label}`)
  return value
}

function requireKeys(value: Record<string, unknown>, keys: readonly string[], optional = false): void {
  const admitted = new Set(keys)
  for (const key of Object.keys(value)) {
    if (!admitted.has(key)) throw new Error(`Unexpected peer protocol field: ${key}`)
  }
  if (optional) return
  for (const key of keys) {
    if (!(key in value)) throw new Error(`Missing peer protocol field: ${key}`)
  }
}
