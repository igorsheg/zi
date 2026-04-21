# conversation state

## status

contract for `zi-5psf.3`.

documents the current semantic conversation state model and the private mailbox shapes the tui consumes today.

this does **not** close `zi-5psf.2`. the broader cutover still carries open design work, but the internal conversation path now uses landed `ConversationPatch` plus separate `QueuedMessageSnapshot` transport.

cross-links:
- [conversation/render v2 cutover doctrine](./adr/conversation-render-v2-cutover.md)
- [architecture](./architecture.md)
- [runtime ownership](./runtime.md)
- [agent events and transport boundaries](./agent-events-and-transport-boundaries.md)

## decision

- the agent runtime is the sole owner of live assistant and tool execution semantics.
- the canonical render input today is snapshot-first, with `replace_all` used for cold sync and private conversation patches used for hot updates.
- the main semantic shape today is cold committed history plus one optional hot in-flight turn.
- queued steering and follow-up state is an adjacent snapshot family owned by run control, not tui-local reconstruction.
- tui projection is a consumer of semantic snapshots plus private conversation patches. it derives render rows and local caches; it does not become a second conversation owner.

more concretely:

- `src/agent3/agent.zig` owns `shared_committed`, `in_flight`, and run-control queues.
- `src/coding_agent/runtime_host.zig` publishes `ConversationPatch` (`replace_all` for full sync; frontier/commit deltas for hot updates) and `QueuedMessageSnapshot`.
- `src/tui/ui_event.zig` carries those payloads across the mailbox as `.conversation_patch` and `.queued_snapshot`.
- `src/tui/conversation_projection.zig` stores owned view/queued state, applies patches, and rebuilds or reconciles transcript state from that owned state.

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
                    │ publish `replace_all` / patch │ publish snapshot
                    v                               v
        ┌──────────────────────────┐    ┌──────────────────────────┐
        │ `ConversationPatch`      │    │ `QueuedMessageSnapshot` │
        │  - `replace_all` =>      │    │  { steering,            │
        │    `ConversationViewSnapshot` │    follow_up, version } │
        │  - frontier / commit     │    └──────────────┬──────────┘
        │    deltas                │                   │
        └──────────────┬───────────┘                   │
                       │                               │
                       └───────────────┬───────────────┘
                                       v
                           tui mailbox / `UiEvent`

                     `.conversation_patch`  `.queued_snapshot`
                                       │
                                       v
                         ┌──────────────────────────────┐
                         │ tui projection               │
                         │  owns last view/queue state  │
                         │  applies patches             │
                         │  derives transcript rows     │
                         │  keeps render-local cache    │
                         └──────────────┬───────────────┘
                                        v
                              transcript / render tree
```

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

## `ConversationView` and `ConversationViewSnapshot`

`ConversationView` is the semantic conversation payload:

- `committed: *SharedCommitted`
- `in_flight: ?InFlightTurn`

`ConversationViewSnapshot` is the full-sync payload carried by `ConversationPatch.replace_all`:

- `view: ConversationView`

notes:
- today the envelope is intentionally thin. the semantic cut is `committed` plus optional `in_flight`, not a transport-heavy wrapper.
- snapshot-first does **not** mean replaying the committed slice at token speed. the current code retains `SharedCommitted` and deep-clones only the hot frontier on publish.

## adjacent queued snapshot family

queued steering and follow-up are not embedded in `ConversationView`.

today they live beside it as `QueuedMessageSnapshot`:

- `steering: []QueuedMessageText`
- `follow_up: []QueuedMessageText`
- `version: u64`

contract:
- this is agent-owned run-control state.
- it is published separately from the conversation patch stream.
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
- queued steering and follow-up mutate through run control, publish independently, and can change without a conversation patch publish.

## relation to projection and rendering

`src/tui/conversation_projection.zig` consumes conversation state in three buckets after applying `ConversationPatch` to its owned view state:

1. committed rows from `view.committed.flat`
2. transient rows from `view.in_flight.assistant` and `view.in_flight.tool_executions`
3. queued rows from `QueuedMessageSnapshot`

that projector may retain rows, reuse committed metadata when the same `*SharedCommitted` pointer reappears, and drop stale queued snapshots by `version`.

those are projection optimizations and render concerns. they do not make the tui a semantic owner. if projection state is dropped, the tui rebuilds from snapshots.

## transport note: the private patch vocabulary is current

`zi-5psf.2` also proposed a mailbox patch vocabulary:

- `replace_all`
- `append_committed`
- `replace_frontier`
- `append_frontier_content`
- `commit_frontier`

that vocabulary is now the landed private conversation mailbox contract.

today's mailbox contract for conversation rendering is:
- `ConversationPatch` via `UiEvent.conversation_patch`
- separate `QueuedMessageSnapshot` via `UiEvent.queued_snapshot`

`replace_all` remains the full resync path. queued state stays separate from the conversation patch stream.

so this doc is still about the current semantic model and snapshot families. it is not a claim that this host-private patch transport is public api.

## non-goals

- this is not a public patch or diff protocol.
- this is not a public extension api or wire contract.
- this does not freeze projection caches, transcript item ids, or renderer internals as semantic contract.
- this does not redefine session persistence or external observer payloads.
- this does not promise that `ConversationViewSnapshot` stays wrapper-identical forever; it only states what the tui consumes today.
