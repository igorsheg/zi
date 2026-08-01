# ADR 0026: Subagent orchestration supervises Zi RPC processes

## Status

Partially superseded by [ADR 0027](0027-session-owned-native-subagents.md).

ADR 0027 supersedes this ADR's extension-generation ownership, extension custom-state completion delivery, and reload-terminates-children decisions. The RPC subprocess transport, `ChildZiProcess` boundary, JSONL protocol additions, depth and capacity bounds, and cross-platform process-containment requirements remain accepted.

## Context

Zi's text and JSON modes support fixed child invocations, while RPC already provides bounded, correlated, interruptible control over one authoritative `AgentSession`. Delegated agent work additionally needs one owner for child identity, topology, process lifetime, queue-only and wake delivery, waiters, completion evidence, and shutdown. The design could construct child sessions in-process, adopt ACP or another wire protocol, or supervise Zi subprocesses through the existing RPC contract.

Subagent orchestration is specialized executable behavior rather than a universal `AgentSession` invariant. An in-process implementation would expose or recreate private runtime construction and couple every child's failures and resource graph to the parent process. A generic transport interface would have only one implementation. ACP, WebSockets, Unix sockets, and binary encodings solve remote, daemon, or high-throughput framing problems that a parent-owned local child process does not have. Inspectable JSONL already satisfies the required process contract; no measurement justifies another encoding.

## Decision

The first subagent implementation is a trusted extension with one generation-scoped `SubagentSupervisor`. It concretely launches long-lived `zi --mode rpc --no-session` child processes over inherited stdin/stdout pipes. The supervisor owns child admission, IDs, topology, per-child operation serialization, retained completions, durable parent-session evidence, and shutdown. One `ChildZiProcess` owns each process, RPC client, protocol validation, diagnostics, deadlines, and termination. Each child `AgentSession` remains authoritative for its own conversation, tools, queues, model, retry, and compaction.

V1 has parent-to-direct-child topology, at most four non-exited child processes, no pending spawn queue, and depth one. Its complete operation set is spawn, queue-only send, atomic continue, bounded wait, interrupt, list, and close, delivered incrementally from a first spawn/wait/close vertical slice. Children never communicate directly; the supervisor routes parent operations and projects bounded completions.

Zi RPC remains the session transport rather than gaining `agent.*` topology methods. RPC V1 adds connection-owned event suppression and a child-owned `continue` prompt delivery. `continue` decides inside the child `AgentSession`: idle starts direct work and running queues follow-up work. The supervisor also generation-stamps its idle watchers so a cycle cannot finalize while a cycle-affecting admission is pending. This closes the cross-process idle/follow-up race without moving topology into `AgentSession`.

Completed work first enters a bounded supervisor delivery buffer. The supervisor retries durable custom-state append only under an explicit bounded policy and flushes again on its own tool admissions and extension shutdown. V1 does not automatically enqueue `next_turn` messages: they consume the parent's pending-input budget and can block reload and compaction. `wait_subagents` is the model-visible completion path. Parent run interruption does not cancel a child after `spawn_subagent` returns; this deliberately differs from Pi's abort-kills-child example so RPC children remain reusable background work.

Unexpected extension-worker death must not orphan child processes. Before background survival ships, the extension host must prove process-tree containment on every release platform: a host-owned POSIX process scope whose live registry retains worker, child, and detached descendant IDs before reparenting and terminates every tracked group, and a Windows Job Object with kill-on-close or an equivalent tested primitive. Stdin EOF remains the graceful path; process-tree termination is the crash fallback. If any release target cannot prove containment, the supported V1 extension does not ship; foreground wait-bound work remains only an internal delivery stage, not a second product mode.

The implementation uses only `@with-zi/extension-api`, the documented CLI, and RPC. It does not introduce an in-process child adapter, generic transport interface, public coding-agent SDK, daemon, direct peer channel, permission derivation, or resumable child topology. A second implementation is considered only after the process extension provides usage and measured startup or memory evidence.

## Relationship to ADR 0027

The extension implementation was a proving spike, not the supported product owner. Its evidence established that reusable Zi RPC subprocesses can provide queue-only and wake delivery, bounded waits, interruption, completion projection, and concrete fault isolation. Research captured in the accepted native design then established delegation as session policy rather than extension-specialized behavior.

The retained decisions migrate as follows:

- one `SubagentSupervisor` now belongs to one `AgentSession`, not one extension generation;
- `ChildZiProcess` remains the concrete child-process and RPC owner;
- native journal entries and a session-owned mailbox replace extension custom entries and the generation delivery pump;
- subagent names and universal child instructions are native supervisor policy; extension reload neither changes them nor terminates admitted children;
- native child process scopes belong to the subagent owner and must not be registered as extension-worker descendants;
- RPC remains a single-session transport and still gains no `agent.*` topology API.

The local implementation does not complete the release gate. Compiled acceptance on all five release targets, including a real Windows Job Object containment test, is still required before native background subagents ship.

## Historical consequences of the superseded extension owner

- Zi composes its existing supported building blocks instead of exposing runtime services or private session constructors.
- Process EOF, stderr, exit status, and process-tree termination give every child a concrete, inspectable lifecycle and fault-containment boundary.
- Process isolation is not a sandbox: children retain the invoked Zi process's filesystem, environment, credential, extension, and network authority.
- V1 child conversations are ephemeral across close, reload, worker crash, and parent restart; only bounded parent-side lifecycle evidence and completion projections are durable.
- Completion durability may lag child settlement while parent custom-state admission is closed, but the bounded delivery owner never mistakes pending evidence for durable evidence.
- RPC event suppression becomes useful to any process client that wants correlated operations and final state without token-stream traffic.
- ADR 0027 removes the complete orchestration extension from the product. The retained protocol, process-tree containment, behavior tests, and compiled acceptance on all release targets remain required before native background subagents are supported.

The migrated native contract, retained process bounds, transitions, and release gates are in [`../subagent-process-orchestration-spec.md`](../subagent-process-orchestration-spec.md). The ownership decision is in [ADR 0027](0027-session-owned-native-subagents.md).
