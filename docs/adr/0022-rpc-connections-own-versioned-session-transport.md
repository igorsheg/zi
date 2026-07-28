# ADR 0022: RPC connections own versioned session transport

## Status

Accepted.

## Context

Zi needs a supported process boundary for external applications that cannot embed coding-agent internals. Print mode completes a fixed prompt list and JSON mode emits events for that one invocation, but neither supports a long-lived client that observes state, submits steering or follow-up input, interrupts work, waits for settlement, or changes model policy.

Pi's RPC mode proves that JSONL over process stdin and stdout is sufficient for this product shape. Zi must preserve its own ownership boundaries: `AgentSession` remains authoritative for conversation policy, the CLI remains responsible only for invocation and process exit, and a client must not receive mutable runtime or provider objects. The transport also crosses an untrusted process boundary, so framing, input, output, concurrency, and shutdown require explicit bounds.

## Decision

`packages/coding-agent` owns one `runRpcMode()` connection over an existing `AgentSession`. The connection translates a closed version-1 request union into session operations and projects session state, model descriptors, ordered events, and correlated results back to the client. It does not copy session policy into an RPC facade or expose `AgentRuntime`, model credentials, extension hosts, or terminal concepts.

RPC uses strict UTF-8 JSONL. Every request carries `version: 1`, a bounded required `id`, one supported method, and method-specific parameters. Every server frame carries `version: 1` and a monotonically increasing connection `sequence`. The first frame is `ready` with an authoritative session snapshot; later frames are `session_event`, correlated `response`, or recoverable `protocol_error` records. Committed messages are read through bounded indexed pages instead of placing a possible 64 MiB session tail in the ready frame.

The initial method catalog is deliberately closed:

- session state and message pages;
- direct, steering, and follow-up text input;
- run interruption and idle settlement;
- model catalog and selection;
- thinking-level catalog and scoped selection.

The connection admits command effects concurrently so an interruption can cross a pending `session.await_idle` request. It bounds ordinary in-flight operations and reserves one separate interruption slot. One output owner serializes frames and bounds record size, queued records, queued bytes, and pending writes. Output failure, fatal framing failure, external cancellation, or stdin EOF stops admission, requests queue-discarding interruption, rejects stale output, and performs a bounded settlement wait. Only the CLI-created runtime is disposed by the CLI after mode settlement.

`--mode rpc` treats stdin as the protocol stream and rejects positional prompts. Protocol stdout remains JSONL-only; startup diagnostics and process failures remain on stderr.

## Consequences

- External applications gain a versioned process building block without depending on private TypeScript packages.
- `AgentSessionEvent` remains the semantic event authority; the RPC connection only replaces sensitive model objects with public descriptors and adds transport ordering.
- New capabilities require explicit version-1 methods and result types or a future protocol version; there is no generic command or event registry.
- Session replacement, authentication interaction, extension UI, images, and a packaged client remain separate slices.
- Compiled acceptance must keep proving that standalone Zi can start RPC mode and exchange ordered frames over ordinary pipes.
