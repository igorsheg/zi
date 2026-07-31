# Native subagent process orchestration specification

Status: accepted architecture; local implementation in progress; not yet a supported release

Ownership decision: [ADR 0027](adr/0027-session-owned-native-subagents.md)
Retained RPC subprocess and containment decision: [ADR 0026](adr/0026-subagent-orchestration-supervises-rpc-processes.md)

This specification defines Zi V1 native subagents. One parent `AgentSession` owns delegation policy and one `SubagentSupervisor`; each child remains a long-lived `zi --mode rpc --no-session` subprocess. Extensions may register declarative subagent definitions, but they do not own spawning, RPC, mailboxes, durability, cancellation, or shutdown.

The implementation and a release-shaped compiled acceptance gate exist in the local tree. The gate has not yet passed on all five targets, so native subagents are not yet release-supported. Acceptance must include real Windows Job Object containment.

## Motivation

Text and JSON modes are fixed invocations. RPC already provides a reusable, correlated, interruptible process contract over one authoritative `AgentSession`, so it is the least powerful sufficient child transport:

| Requirement                                                      | Mode   |
| ---------------------------------------------------------------- | ------ |
| One task whose only result is final assistant text               | `text` |
| One fixed invocation whose complete event history is the product | `json` |
| Reusable, interruptible, multi-turn delegated work               | `rpc`  |

JSONL over inherited pipes is inspectable and negligible beside model and coding-tool work. A binary encoding, daemon, socket, ACP adapter, or generic transport does not solve a demonstrated V1 problem.

The original extension spike proved this process design but assigned the wrong product owner. Delegation changes the session's built-in tool catalog, prompt policy, interruption behavior, durable evidence, completion context, and disposal. Those are universal coding-agent policies, so `AgentSession` owns them. The extension seam is only the declarative definition catalog.

## V1 outcomes

V1 provides:

1. seven native model tools: spawn, queue-only send, atomic continue, bounded wait, interrupt, close, and list;
2. one session-owned supervisor for child identity, four-child admission, process lifetime, work cycles, mailbox delivery, retention, and shutdown;
3. one concrete child-process owner with strict RPC validation and bounded startup, I/O, diagnostics, requests, and termination;
4. a native bounded completion mailbox distinct from parent steering and follow-up queues;
5. append-only native journal evidence and bounded parent-context completion notices;
6. the built-in `general` definition plus bounded declarative extension definitions;
7. direct-child topology, depth one, and no child-to-child channel;
8. graceful and forced process-tree containment proven against compiled Zi before release.

V1 does not provide:

- nested subagents or arbitrary graph topology;
- an in-process child `AgentSession` adapter or generic `AgentTransport`;
- resumable child processes after parent restart;
- a daemon, remote agent service, ACP, MCP, A2A, socket, WebSocket, or binary transport;
- a sandbox or narrower filesystem, environment, credential, extension, or network authority;
- automatic parent turns on child completion;
- parent-history forks, child conversation persistence, worktrees, merge policy, or permission derivation;
- procedural extension methods for spawning or controlling children;
- RPC `agent.*` topology methods;
- a combined shell-task and subagent registry.

## Language

A **subagent** is one delegated child Zi agent session. Its conversation remains authoritative inside that child `AgentSession`.

The **subagent supervisor** is the state and resource owner attached to one parent `AgentSession`. It owns direct-child identity, admission, process lifetimes, work cycles, completion mailbox, durable evidence, retention, and shutdown. It does not own or copy child conversations.

A **subagent definition** is immutable policy data containing `name`, `description`, and `instructions`. A child snapshots one admitted definition at spawn. A definition is not a runner, permission set, model route, or tool filter.

A **child Zi process** is the concrete V1 runtime for one subagent. It owns one RPC connection over stdin/stdout and remains reusable across work cycles until explicitly closed or the parent session is disposed.

A **work cycle** begins when an idle child receives direct or atomic-continue input and ends at revision-validated child quiescence. Steering and follow-up admitted before quiescence extend the cycle; queue-only input that reaches an idle child remains queued for a later cycle.

A **subagent completion** is one bounded result projected from a settled work cycle: identity, status, final assistant text, duration, omission facts, and error information when applicable. It is not a child transcript.

The **subagent mailbox** is the supervisor-owned bounded set of pending, durable, and delivered completions. It is separate from the parent session's steering and follow-up input queues.

## Architecture and ownership

```text
parent AgentSession
  authoritative parent conversation and native journal
  SubagentSupervisor
    admitted definition catalog
    bounded completion mailbox and waiters
    ChildZiProcess A
      stdin/stdout JSONL
      <current zi command> --mode rpc --no-session --cwd <parent cwd> ...
        child AgentSession
    ChildZiProcess B
      ...
  built-in subagent tools (thin adapters)
```

### Parent `AgentSession`

The parent owns:

- admission of the native capability and its built-in tools;
- the supervisor lifetime and final shutdown;
- native `subagent` journal entries;
- client-neutral snapshots and `subagent_changed` events;
- the generated next-turn notice for undelivered durable completions;
- atomic replacement of extension-provided definitions after extension reload.

The parent remains authoritative for its own conversation, model, queues, compaction, retries, and durability. It never retains child messages or a copied child transcript.

`createAgentSession()` creates a supervisor only when all of these are available:

- a selected model;
- a concrete child Zi command supplied by runtime construction;
- root depth rather than the private depth-one child marker;
- `subagentsEnabled` is not disabled in admitted settings.

A lower-level SDK caller that supplies no child command receives no subagent tools.

### `SubagentSupervisor`

One supervisor owns:

- `open -> stopping -> closed` admission state;
- random child IDs and at most four live child owners;
- immutable definition snapshots selected at spawn;
- one serialized operation tail per child;
- completion capacity, mailbox delivery state, waiters, and bounded exited projections;
- append-only native lifecycle and completion evidence;
- concurrent bounded shutdown of every child it created.

The supervisor does not become a general session registry, transport abstraction, command bus, or owner of extension generations.

### `ChildZiProcess`

One child owner owns:

- exactly one spawned process and its process-containment scope;
- one stdin write tail and concurrent stdout/stderr readers;
- strict frame decoding, sequence validation, correlation, and pending requests;
- bounded stderr, pending writes, requests, pages, and deadlines;
- one explicit lifecycle state and admission revision;
- graceful EOF followed by bounded hard termination;
- one completion projection per settled work cycle.

Only this owner writes child stdin or closes and terminates the child. The supervisor requests operations through it.

### Child `AgentSession`

The child remains authoritative for its messages, tools, queues, model, retry, compaction, and active/idle transition. `runRpcMode()` adapts that owner; it does not become a second conversation owner.

The parent passes its admitted model and thinking level explicitly. Credentials and provider variables follow ordinary Zi policy. Child process isolation is fault containment, not a sandbox.

## Native tool contract

Separate tools keep invalid parameter combinations out of one action object.

### `spawn_subagent`

```ts
{
  prompt: string
  type?: string // defaults to "general"
}
```

The supervisor resolves and snapshots the definition, allocates an opaque ID, reserves live-child and mailbox capacity, appends native `starting` evidence, spawns the child, waits for RPC readiness, suppresses child session events, appends `work_cycle_started`, prepends the definition instructions to the delegated prompt, and admits direct input.

Cancellation before initial prompt admission closes the half-created child. After admission, ownership transfers to background work and later parent-run interruption does not cancel the child.

### `send_subagent`

```ts
{
  agent_id: string
  text: string
}
```

Queue-only delivery maps to RPC `session.prompt` with `delivery: "follow_up"`. An idle child keeps the input queued; a running child consumes it according to normal follow-up policy.

### `continue_subagent`

```ts
{
  agent_id: string
  text: string
}
```

Wake delivery maps to RPC `session.prompt` with `delivery: "continue"`. The child `AgentSession` atomically starts direct work when idle or queues follow-up work when running. Admission revisions prevent an older idle response from finalizing the work cycle around that request.

### `wait_subagents`

```ts
{ agent_ids: string[]; timeout_ms?: number }
```

The operation accepts one through sixteen distinct IDs, defaults to ten seconds, and waits at most twenty-five seconds. It returns current snapshots in request order. A durable completion is included and becomes delivered. Timeout returns current state, never cancels a child, and is not a child failure. Cancelling a wait removes only that waiter.

### `interrupt_subagent`

Interrupts current child work through RPC while preserving the child process for another cycle. A child already idle reports `already_idle`. Interruption and close remain separate transitions.

### `close_subagent`

Stops admission, closes RPC stdin, waits boundedly for graceful child settlement, escalates to process-tree termination when necessary, and releases live-child capacity. IDs are never reused.

### `list_subagents`

Returns bounded direct-child snapshots and latest mailbox delivery facts. It never returns child conversations.

### Tool failures

Invalid arguments and IDs are tool input errors. A fifth live spawn fails immediately with `Subagent capacity exceeded: at most 4 live children`; there is no hidden spawn queue. Process and protocol failures include the subagent ID and bounded diagnostics without exposing raw frames or credentials.

## Definition catalog and extension contract

Zi always provides:

- `general` — general coding, research, and repository work with normal Zi tools and authority.

Trusted extensions may add definitions during factory execution:

```ts
import type { ExtensionAPI } from "@with-zi/extension-api"

export default function (zi: ExtensionAPI): void {
  zi.registerSubagentType({
    name: "reviewer",
    description: "Review a change for correctness and missing tests",
    instructions: "Inspect the requested change. Do not edit files. Return findings with paths and line numbers."
  })
}
```

Source precedence is the extension load order:

1. explicit `--extension` sources;
2. trusted project `<cwd>/.zi/extensions/` sources;
3. global `$HOME/.zi/agent/extensions/` sources.

The first admitted name wins. A duplicate registration fails the later source, and `general` cannot be replaced. The catalog and every field are bounded and protocol-validated. Registration is atomic per source and allowed only while its factory runs.

Reload commits one candidate extension catalog atomically. Existing children retain their spawn-time definition snapshots. Removing a definition prevents later spawns but does not mutate or close a live child. Extension worker crash removes extension definitions until reload; it does not terminate native children.

V1 definitions deliberately contain no executable, model, tools, permissions, worktree, resume, context-fork, or sandbox fields. Prompt instructions are guidance, not authority; a definition must not claim read-only enforcement that Zi does not provide.

## RPC child transport

The child uses RPC version 1 as documented in [`rpc.md`](rpc.md): strict UTF-8 JSONL, bounded request IDs and records, connection-local sequence numbers, correlated responses, recoverable request errors, and fatal framing errors.

The child owner validates before admitting a frame into state:

- the protocol version and exact next sequence;
- one first `ready` frame;
- response method and outstanding request identity;
- result shape and pagination progress;
- no duplicate settlement.

A protocol violation fails that child; the owner does not resynchronize a corrupted stream.

Startup is:

1. spawn and begin concurrent bounded stdout/stderr consumption;
2. validate `ready` within ten seconds;
3. call `connection.set_events { mode: "none" }`;
4. read current state and message count;
5. admit the requested operation.

Event suppression is connection-owned. It removes cumulative token-stream traffic that the child supervisor does not consume. `ready`, correlated responses, and protocol errors remain unsuppressed.

`delivery: "continue"` is decided inside the child session. Idle starts direct work; running queues follow-up. Aborting, compacting, reloading, failed, and disposed child states reject it. The response means admission, not work settlement.

### Completion projection

The child records the message count before direct input. A current idle response with no pending cycle-affecting admission pages only the settled suffix and selects its last assistant message. Pagination is sequential and bounded.

Projection rules are:

- no assistant: failed with `missing_assistant`;
- `aborted`: cancelled, with optional bounded partial text;
- `error`: failed, with bounded provider error and optional partial text;
- `toolUse`: failed with `missing_final_answer`;
- `pending`: failed with `incomplete_final_answer`;
- `stop`: completed, including empty text;
- `length`: completed with `truncated: true`.

A failed work cycle does not by itself make a valid child process unusable.

## States and transitions

### Supervisor

```ts
type SupervisorState = { type: "open" } | { type: "stopping" } | { type: "closed" }
```

Only `open` admits operations. Session disposal records `stopping`, closes all children concurrently under one deadline, then records `closed`. Reload is not a supervisor transition.

### Child

```ts
type ChildState =
  | { type: "starting"; startedAt: number }
  | { type: "idle"; nextWorkCycle: number }
  | { type: "spawn_admitting"; workCycle: number; startedAt: number }
  | { type: "running"; workCycle: number; startedAt: number }
  | { type: "interrupting"; workCycle: number; requestedAt: number }
  | { type: "closing"; reason: string; requestedAt: number }
  | { type: "exited"; outcome: ChildExitOutcome }
```

Allowed transitions are:

```text
starting -> idle | closing | exited
idle -> spawn_admitting | running | closing | exited
spawn_admitting -> running | closing | exited
running -> idle | interrupting | closing | exited
interrupting -> idle | closing | exited
closing -> exited
```

Work-cycle numbers increase only when idle work starts. Async completions carry child ID and work-cycle number so stale completion cannot mutate a later cycle.

### Mailbox delivery

```ts
type CompletionDelivery =
  | { type: "pending"; completion: SubagentCompletion }
  | { type: "durable"; completion: SubagentCompletion; entryId: string }
  | { type: "delivered"; completion: SubagentCompletion; entryId: string }
```

A completion enters `pending`, then moves to `durable` only after its native journal entry commits. `wait_subagents` may return only durable output and moves it to `delivered`. A later parent turn gets a short notice for undelivered durable IDs and must call `wait_subagents` for output. The notice does not enter the parent input queues and does not trigger a turn.

The mailbox retains at most 32 completions. Delivered records are the first eviction candidates. If undelivered records fill capacity, new work fails before child input admission rather than creating an unrecordable completion.

## Native journal evidence and restore

The supervisor appends bounded native `subagent` entries for:

- child starting and ready;
- work-cycle start and finish;
- child closing and exit;
- nonterminal prior evidence marked lost after parent-session restore.

A finished entry contains identity, cycle, status, bounded preview, original and omitted byte counts, truncation, duration, and bounded reason/error fields. It never contains protocol frames or a copied child transcript.

The full model-visible completion is capped at 50 KiB. Durable preview is capped at 8 KiB. Restoring a parent journal recovers bounded evidence and mailbox previews only; it never recreates child processes. A previously nonterminal child becomes `lost` with reason `session_restored`.

Extension reload does not rebuild the supervisor and is not a durability boundary. Parent process exit or session disposal ends all live children.

## Invocation, trust, and authority

Runtime construction supplies the concrete current Zi command. The native product does not read `ZI_SUBAGENT_EXECUTABLE`. The child invocation is:

```text
<current zi command> --mode rpc --no-session --cwd <exact parent cwd> --model <parent model> [--api-key <ephemeral override>] --thinking <parent level>
```

The initial task crosses only RPC, not argv, environment, or a prompt file. A private depth-one marker suppresses native subagent tools in the child. That marker is an invocation constraint, not a security boundary.

The child independently applies normal noninteractive project-trust and extension discovery. A session-only parent trust decision is process-local; explicit parent extension arguments are not reconstructed. Subagent behavior must not assume project resources the child did not independently admit.

The child runs as the current user and may access the same working tree, credentials, filesystem, network, and independently admitted extensions. Concurrent children may edit the same files. V1 has no conflict prevention, transaction, worktree, or reduced permission set.

## Cancellation and shutdown

- Cancelling spawn before initial prompt admission closes the child.
- After spawn returns, parent run interruption does not cancel admitted background child work.
- Cancelling queue-only send or continue rejects only an admission that has not crossed RPC.
- Cancelling wait removes only the waiter.
- `interrupt_subagent` stops active work and preserves the process.
- `close_subagent` ends the process and releases capacity.
- Extension reload changes definitions only and does not affect live children.
- Parent session disposal closes all children concurrently under one bounded deadline.
- Unexpected process exit produces failed completion/evidence and an exited projection.

Ordinary close order is:

1. stop child admission and reject pending operations;
2. close stdin so RPC performs its own bounded settlement;
3. wait up to five seconds for graceful exit;
4. apply hard process-tree termination;
5. wait up to a further five seconds;
6. release process and stream resources and append terminal evidence.

Parent session shutdown gives the supervisor nine seconds total for concurrent child closure. Only the owner that created the supervisor disposes it.

## Process-tree containment release gate

Graceful stdin EOF is primary because it lets each child `AgentSession` dispose its own shell tasks. It is insufficient for wedged children, detached descendants, or a forced parent shutdown. Native release therefore requires one killable process scope owned with each child process:

| Platform | Required mechanism                                                                                | Forced action                                         |
| -------- | ------------------------------------------------------------------------------------------------- | ----------------------------------------------------- |
| POSIX    | Dedicated child group plus bounded PID/start-identity and descendant-PGID tracking                | Signal every retained group and boundedly reap        |
| Windows  | Job Object configured with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`, containing child and descendants | Close/terminate the job and verify no member survives |

A POSIX group alone is insufficient because child `SessionShell` commands may create detached groups. PID plus start identity prevents killing a reused PID. Tracking is bounded at 256 live identities and overflow fails closed.

Extension-worker scopes remain owned by `ExtensionHost`. Native subagent processes must not be registered as extension-generation descendants; their scope follows the parent `AgentSession` supervisor instead.

Local POSIX tracking and Windows Job Object code are development progress, not acceptance. Release requires execution against compiled real Zi on every target. In particular, a mocked or POSIX-only test does not prove the Windows contract: the release gate includes a real Windows Job Object, forced parent/child failure, and verification that no descendant survives.

## Bounds

| Resource                                  |        V1 bound |
| ----------------------------------------- | --------------: |
| Live child processes                      |               4 |
| Retained exited child projections         |              32 |
| Completion mailbox records                |              32 |
| Subagent IDs in one wait                  |              16 |
| Ready wait                                |      10 seconds |
| Blocking wait                             |      25 seconds |
| Model-visible completion                  |          50 KiB |
| Durable completion preview                |           8 KiB |
| Retained child stderr                     |          64 KiB |
| RPC record                                | existing 16 MiB |
| RPC prompt text                           |  existing 8 MiB |
| RPC ordinary in-flight requests per child |     existing 32 |
| Child pending-write queue                 |          16 MiB |
| RPC message pages per completion          |           1,024 |
| Graceful/forced close stages              |  5 seconds each |
| Parent-session child shutdown             | 9 seconds total |
| Extension-provided definitions            |              32 |
| Definition name                           |  64 UTF-8 bytes |
| Definition description                    |           4 KiB |
| Definition instructions                   |          32 KiB |
| Definition catalog                        |         256 KiB |
| Tracked POSIX process identities          |             256 |

There is no pending spawn queue. Retention and journal growth remain subject to the existing session journal bounds.

## Acceptance

### Local structural and behavior acceptance

- supervisor and child transitions, including forbidden transitions;
- fifth-child rejection and mailbox-capacity refusal before RPC admission;
- queue-only send while idle/running and atomic continue while idle/running;
- idle/continue and idle/follow-up races through admission revisions;
- wait timeout and cancellation without child cancellation;
- interruption racing natural completion and child reuse afterward;
- stale completion after a newer work cycle;
- malformed frames, sequence gaps, duplicate ready, unknown response IDs, method mismatch, and non-advancing pages;
- completion projection for every assistant terminal reason and UTF-8 truncation;
- native pending/durable/delivered mailbox transitions and next-turn notice;
- native journal recovery without process recreation;
- extension definition precedence, duplicate rejection, atomic reload, removal, and immutable live-child snapshots;
- extension reload/worker failure while a native child remains live;
- session disposal rejection of new work and bounded concurrent child shutdown.

### Compiled release acceptance

`scripts/subagent-compiled-acceptance.ts` is part of `scripts/build-release.ts`, and `.github/workflows/subagent-compiled-acceptance.yml` runs that release build on the complete target matrix. The script exercises declarative type loading, real parent-to-child RPC, wait and output recovery, explicit close, forced child death, session disposal, and descendant settlement.

The complete native path must run against compiled standalone Zi on `darwin-arm64`, `darwin-x64`, `linux-arm64`, `linux-x64`, and `windows-x64` and prove:

1. built-in tool admission without an orchestration extension or environment override;
2. child ready and RPC event suppression;
3. typed-definition spawn and initial task completion;
4. queue-only send followed by explicit continue;
5. bounded wait, completion mailbox, native journal evidence, and completion notice;
6. interruption with child reuse and explicit close;
7. startup cancellation and admitted background survival across parent interruption;
8. extension reload replacing definitions without killing a live child;
9. parent-session disposal and forced child failure without surviving descendants;
10. compiled POSIX descendant tracking and a real Windows kill-on-close Job Object;
11. no child task text or credential in argv, diagnostics, or journal evidence;
12. RPC observation without any `agent.*` topology method.

Until the complete matrix passes, native subagents remain local implementation work rather than a supported building block.

## Research provenance

The accepted [native subagent design proposal](subagent-native-design-proposal.md) records the pinned Grok Build and Codex research and the adoption/rejection analysis. ADR 0026 and its extension spike remain the provenance for the RPC process client, queue-only/continue race handling, process-boundary diagnostics, and containment requirement. ADR 0027 changes the product owner; it does not discard that process evidence.
