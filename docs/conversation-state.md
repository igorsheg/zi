# conversation state

## status

contract for `zi-5psf.3`.

documents the semantic conversation state model and the private mailbox shapes the tui consumes.

this does **not** close `zi-5psf.2`. the broader cutover still carries open design work.

cross-links:
- [conversation/render v2 cutover doctrine](./adr/conversation-render-v2-cutover.md)
- [architecture](./architecture.md)
- [runtime ownership](./runtime.md)
- [agent events and transport boundaries](./agent-events-and-transport-boundaries.md)

## decision

- the agent runtime is the sole owner of live assistant and tool execution semantics.
- the canonical render input across the agent→tui owner boundary is authoritative `ConversationSnapshotEnvelope` publication.
- each publication carries `session_generation`, `conversation_version`, and the full `ConversationView` payload.
- because each publication is authoritative, dropped intermediate mailbox entries are recoverable from the next snapshot. correctness does not depend on deltas.
- the main semantic shape is cold committed history plus one optional hot in-flight turn.
- queued steering and follow-up state is an adjacent snapshot family owned by run control, not tui-local reconstruction.
- tui projection is a consumer of authoritative semantic snapshots. it derives render rows and local caches; it does not become a second conversation owner.

more concretely:

- `src/agent3/agent.zig` owns `shared_committed`, `in_flight`, and run-control queues.
- `src/coding_agent/runtime_host.zig` publishes authoritative `ConversationSnapshotEnvelope` and `QueuedMessageSnapshot` values.
- `src/tui/ui_event.zig` carries those authoritative snapshots across the mailbox as `.conversation_snapshot` and `.queued_snapshot`.
- `src/tui/conversation_projection.zig` stores the last authoritative view and queued state, derives transcript rows from that snapshot, and keeps render-local caches.

## model

```text
                          agent owner thread

    ┌───────────────────────────────────────────────────────────────┐
    │ agent                                                        │
    │                                                               │
    │  committed                                                    │
    │  ┌─────────────────────────────────────────────────────────┐  │
    │  │ `SharedCommitted`                                      │  │
    │  │  - immutable committed `AgentMessage` history          │  │
    │  │  - canonical ordered slice: `flat`                     │  │
    │  └─────────────────────────────────────────────────────────┘  │
    │                                                               │
    │  hot frontier                                                 │
    │  ┌─────────────────────────────────────────────────────────┐  │
    │  │ `?InFlightTurn`                                        │  │
    │  │  assistant: `?AssistantMessage`                        │  │
    │  │  tool_executions: `[]ToolExecution`                    │  │
    │  └─────────────────────────────────────────────────────────┘  │
    │                                                               │
    │  adjacent queued family                                       │
    │  ┌─────────────────────────────────────────────────────────┐  │
    │  │ run control                                             │  │
    │  │  steering[]                                             │  │
    │  │  follow_up[]                                            │  │
    │  │  version                                                 │  │
    │  └─────────────────────────────────────────────────────────┘  │
    └───────────────┬───────────────────────────────┬──────────────┘
                    │                               │
                    │ publish authoritative         │ publish queued
                    │ conversation snapshot         │ snapshot
                    v                               v
        ┌─────────────────────────────┐  ┌──────────────────────────┐
        │ `ConversationSnapshotEnvelope`│  │ `QueuedMessageSnapshot` │
        │  generation + version + view │  │  { steering,            │
        │  (`ConversationView`)        │  │    follow_up, version } │
        └───────────────┬──────────────┘  └──────────────┬──────────┘
                        │                                │
                        └───────────────┬────────────────┘
                                        v
                            tui mailbox / `UiEvent`
                                        │
                                       v
                         ┌──────────────────────────────┐
                         │ tui projection               │
                         │  owns last authoritative view│
                         │  derives transcript rows     │
                         │  keeps render-local cache    │
                         └──────────────┬───────────────┘
                                        v
                              transcript / render tree
```

the mailbox carries this input via `UiEvent.conversation_snapshot`. because that payload is authoritative and versioned, the tui projection can always rebuild from the latest snapshot even if bounded mailbox delivery drops intermediate states.

## committed state

`SharedCommitted` is the committed conversation history.

contract:
- it contains only committed `AgentMessage` values.
- it is immutable once constructed.
- `flat` is the canonical ordered history slice consumers read.
- published views retain the shared handle instead of deep-cloning committed history per publish.

non-contract internal detail:
- segment layout and refcount mechanics exist so old publishes stay alive cheaply. consumers should care about immutable ordered history, not segment topology.

## in-flight turn

`InFlightTurn` is the optional hot frontier.

contract:
- it is present only while the agent has active assistant or tool execution state that is not yet committed.
- `assistant` is the current assistant message as known so far.
- `tool_executions` is the ordered live tool set for that turn.
- tool executions are matched and updated by `tool_call_id`; first sighting establishes order, later events mutate that entry in place.

this is semantic state, not render policy. the agent tracks assistant/tool progress; the tui decides how to draw it.

## `ToolExecution`

| field | meaning now |
| --- | --- |
| `tool_call_id` | stable semantic id for the tool call within the turn. this is the key used to update the same live tool entry across deltas, execution events, and commit. |
| `tool_name` | tool identity used for rendering and result association. |
| `args` | latest parsed argument value the agent has for this tool call. |
| `args_json_source` | raw streaming argument bytes while args are still incomplete. `null` once the arg stream is considered complete or execution starts with a full value. |
| `args_complete` | whether the assistant-side tool-call args are complete. |
| `execution_started` | whether a `tool_execution_start` has been observed for this call. |
| `result` | latest live `AgentToolResult` from tool execution updates or final execution end. |
| `result_message` | committed-style `ToolResultMessage` cloned into frontier state when that message arrives before turn commit. this exists in the snapshot today even though live tool row rendering still reads `result` plus flags. |
| `is_partial` | whether `result` is still partial and may be replaced by a later update. |
| `is_error` | whether the current result state is error-shaped. |

## `ConversationView` and `ConversationSnapshotEnvelope`

`ConversationView` is the semantic conversation payload:

- `committed: *SharedCommitted`
- `in_flight: ?InFlightTurn`

`ConversationSnapshotEnvelope` is the mailbox payload:

- `session_generation: u64`
- `conversation_version: u64`
- `view: ConversationView`

notes:
- the envelope is intentionally thin. the semantic cut is `committed` plus optional `in_flight`, with ordering metadata beside it.
- snapshot-first does **not** mean replaying the committed slice at token speed. the current code retains `SharedCommitted` and deep-clones only the hot frontier on publish.

## adjacent queued snapshot family

queued steering and follow-up are not embedded in `ConversationView`.

today they live beside it as `QueuedMessageSnapshot`:

- `steering: []QueuedMessageText`
- `follow_up: []QueuedMessageText`
- `version: u64`

contract:
- this is agent-owned run-control state.
- it is published separately from the conversation snapshot stream.
- the tui uses it to render pending steering and follow-up rows.
- `version` is monotonic per run-control instance so the tui can drop stale queued publishes that arrive out of order.

that separation is deliberate. queued user intent is conversation-adjacent state, but it is not reconstructed from transcript rows and it is not tui-local state.

## ownership and lifecycle edges

owner split:
- agent owns live conversation semantics and queued input semantics.
- runtime host is the publication point.
- tui owns only projection, transcript retention, scroll/focus, editor history, and other presentation state.

lifecycle edges:
- agent events mutate `in_flight` first.
- committed-only messages can append directly to `SharedCommitted`.
- assistant turns commit on `turn_end`: the assistant message and that turn's `tool_results` move from frontier state into committed history together, then `in_flight` clears.
- `setMessages`, `reset`, session replacement, and similar cold-path operations replace committed history and clear the hot frontier.
- queued steering and follow-up mutate through run control, publish independently, and can change without a conversation snapshot publish.

## relation to projection and rendering

`src/tui/conversation_projection.zig` reconciles render input into three buckets from the authoritative snapshot it holds:

1. committed rows from `view.committed.flat`
2. transient rows from `view.in_flight.assistant` and `view.in_flight.tool_executions`
3. queued rows from `QueuedMessageSnapshot`

that projector may retain rows, reuse committed metadata when the same `*SharedCommitted` pointer reappears, and drop stale queued snapshots by `version`.

those are projection optimizations and render concerns. they do not make the tui a semantic owner. if projection state is dropped, the tui rebuilds from snapshots.

## transport note: the mailbox contract is snapshot-shaped

the truth-bearing mailbox contract is authoritative `ConversationSnapshotEnvelope` publication plus separate `QueuedMessageSnapshot` publication. queued state stays separate from the conversation stream.

## non-goals

- this is not a public patch or diff protocol.
- this is not a public extension api or wire contract.
- this does not freeze projection caches, transcript item ids, or renderer internals as semantic contract.
- this does not redefine session persistence or external observer payloads.
- this does not promise that `ConversationSnapshotEnvelope` stays wrapper-identical forever; it only states what the tui consumes today.
