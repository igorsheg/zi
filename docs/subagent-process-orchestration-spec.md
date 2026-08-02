# Subagent child-process substrate specification

Status: active substrate specification under [ADR 0029](adr/0029-subagent-profiles-share-session-owned-orchestration.md). Markdown and programmatic profiles share this session-owned substrate.

## Ownership

One parent `AgentSession` may own one `SubagentSupervisor`. The supervisor owns runtime-name admission, child-process lifetime, serialized child commands, work cycles, bounded completion retention, durable journal evidence, waiters, and shutdown. One `ChildZiProcess` owns each RPC subprocess, pipes, framing, request correlation, diagnostics, cancellation, and bounded forced termination.

`AgentSession` derives the standard model-facing orchestration tools from its admitted profile catalog. Extensions may add specialized policy but receive no supervisor or process handle; the extension host routes versioned, source-attributed session operations to the session owner. Extension generation replacement aborts that generation's pending requests but does not dispose children whose spawn admission already completed. Final session disposal closes every child.

## Runtime contract

A child is launched as a depth-one ephemeral Zi RPC session:

```text
<zi command> --mode rpc --no-session --cwd <parent cwd> --model <selected model> --thinking <selected level>
```

The selected model and thinking value come from the chosen subagent profile or inherit the parent's current selection. An ephemeral API-key override crosses through a private invocation environment value, never argv, and is scrubbed before child extensions or shell tools run. Child sessions cannot recursively admit another supervisor.

A subagent name starts with a lowercase letter, contains only lowercase ASCII letters, numbers, `_`, or `-`, fits within 64 UTF-8 bytes, and remains reserved for the parent session. It is a runtime routing identity, not a profile name.

The standard tools and optional extension API support profile listing, spawn, queue-only send, continue, wait, list, interrupt, and close over the same supervisor. Spawn transfers admitted work to session ownership only after rechecking the supervisor transition after asynchronous child startup and prompt admission; shutdown wins either race and owns teardown. Cancelling before prompt admission closes the starting child. Cancelling wait rejects that waiter with `AbortError`, removes its signal listener, leaves child work running, and does not mark any unreturned completion delivered. The standard wait may omit names to capture a bounded set of currently working or ready children; extension waits remain explicit. Interrupt stops active work while preserving the reusable process. Close terminates one child and releases its live slot.

## Bounds

- four live children per parent session;
- 32 retained child snapshots and ready completions;
- 16 distinct names per wait;
- 64-byte runtime names;
- 8 MiB prompt and message inputs;
- 50 KiB projected completion text;
- 30-second default wait and one-hour maximum;
- bounded RPC frames, pending requests, stderr, output pages, shutdown grace, forced termination, and process-tree observation.

A completion contains runtime identity, completed/failed/cancelled status, bounded final text, duration, and omission facts. Full child conversations remain authoritative only in child sessions. Completion never submits parent input or starts inference.

## Containment and release acceptance

Graceful RPC shutdown is primary. Forced shutdown must terminate descendants through the runtime-owned POSIX process-tree tracker or Windows Job Object. `ExtensionHost` and `SubagentSupervisor` retain distinct process-scope lifetimes even though the runtime shares OS observation mechanics.

Release acceptance must exercise compiled Markdown and programmatic declarations, standard tool activation, profile model/thinking propagation, all child operations, extension replacement with admitted work, protocol failure, cancellation, explicit close, final session disposal, forced child death, and descendant settlement on `darwin-arm64`, `darwin-x64`, `linux-arm64`, `linux-x64`, and `windows-x64`.
