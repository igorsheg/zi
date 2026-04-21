# agent events and transport boundaries

## status

contract for `zi-5psf.10`.

this doc fixes the cut between public observer/persistence/wire contracts and host-private runtime transport. it follows the [conversation/render v2 cutover adr](./adr/conversation-render-v2-cutover.md), [architecture](./architecture.md), [runtime](./runtime.md), [conversation state](./conversation-state.md), [extension events](./extensions-events.md), [retained objects](./extensions-retained-objects.md), and [extension v2 cutover boundaries](./extensions-cutover-boundaries.md).

the ownership doctrine does not change:

- cross-owner mutation and work go through mailboxes.
- render-speed reads go through published snapshots.
- owner-boundary machinery is not product api. (`docs/architecture.md:8-17`, `docs/runtime.md:10-19`)

## decision

- `AgentEvent` survives only where it is a real product observer contract.
- session persistence remains a product contract, but it is `SessionEntry` / `AgentMessage` shaped, not a replay of internal transport.
- json/rpc/wire serialization remains only at true external wire edges.
- internal agent↔tui mailbox transport is request/conversation-patch/queued-snapshot-shaped. raw `AgentEvent` callbacks still exist as host-private agent-thread plumbing, but they are not the tui mailbox contract.
- `SessionEvent` no longer carries `.agent`; it is retry/compaction lifecycle only.

why: zi already says owner-boundary transport is private and semantic contracts must be defined at the product seam, not by leaking mailboxes, snapshots, or raw runtime structs (`docs/runtime.md:16-19`, `docs/extensions-events.md:18-20`, `docs/extensions-events.md:61-64`, `docs/extensions-cutover-boundaries.md:16-18`).

## model

```text
agent loop
  semantic facts
  (`AgentEvent`, compaction/retry outcomes, committed messages)
           │
           ├──────────────────────────────────────────────────────────────┐
           │                                                              │
           │  real public observer output only                            │
           v                                                              │
   ┌───────────────────────┐                                              │
   │ `AgentEvent` stream   │                                              │
   │ external observers    │                                              │
   └───────────┬───────────┘                                              │
               │                                                          │
               v                                                          │
   ┌───────────────────────┐                                              │
   │ `agent3/json.zig`     │                                              │
   │ batch json / future   │                                              │
   │ rpc wire if explicit  │                                              │
   └───────────────────────┘                                              │
                                                                          │
           committed history only                                         │
           v                                                              │
   ┌───────────────────────┐                                              │
   │ session store         │                                              │
   │ `SessionEntry` jsonl  │                                              │
   │ message/model/etc     │                                              │
   └───────────────────────┘                                              │
                                                                          │
           host-private runtime publication                               │
           v                                                              │
   ┌───────────────────────────────────────────────────────────────────┐  │
   │ runtime host                                                      │  │
   │  - binds raw `AgentEvent` + `SessionEvent` internally            │  │
   │  - publishes conversation patches                                │  │
   │  - publishes queued-message snapshots                            │  │
   │  - owns request queue + run-control mailbox                      │  │
   └───────────────┬───────────────────────────────────────┬───────────┘  │
                   │                                       │              │
                   │ snapshot / patch                      │ request      │
                   v                                       v              │
      ┌──────────────────────────┐          ┌──────────────────────────┐  │
      │ tui conversation         │          │ `AgentRequest` +         │  │
      │ projection               │          │ queued steering/followup │  │
      │ applies patches to       │          │ abort / session control  │  │
      │ owned state, then        │          │ mailboxes                │  │
      │ reconciles render        │          │                          │  │
      └──────────────┬───────────┘          └──────────────────────────┘  │
                     │                                                    │
                     v                                                    │
      ┌──────────────────────────┐                                        │
      │ tui render / transcript  │                                        │
      │ local presentation only  │                                        │
      └──────────────────────────┘                                        │
                                                                          │
           internal extension plumbing only                               │
           v                                                              │
   ┌───────────────────────┐                                              │
   │ event bridge          │                                              │
   │ `AgentEvent` -> lua   │                                              │
   │ observer dispatch     │                                              │
   └───────────────────────┘                                              │
```

## boundary taxonomy

| boundary type | shape after cutover | rule | evidence |
| --- | --- | --- | --- |
| public semantic observer contract | semantic observer payloads; `AgentEvent` only where zi intentionally exports that observer stream | keep only real product observers. semantic meaning survives; owner-boundary transport does not | `docs/extensions-events.md:18-20`, `docs/extensions-events.md:52-64`, `src/agent3/types.zig:428-440`, `src/coding_agent/cli/run_batch.zig:115-123` |
| public persistence contract | `SessionHeader` + `SessionEntry` jsonl; message/model/thinking/compaction/session metadata | keep session history as product data. it is not a replay log of agent↔tui transport | `src/session/protocol.zig:7-35`, `src/session/protocol.zig:38-85`, `src/session/json.zig:12-144`, `src/coding_agent/session/store.zig:169-227` |
| public wire contract | json serialization for explicit external outputs such as batch json, and any future rpc surface that is intentionally product-facing | serialize only at real wire edges. shared writer code does not make every internal seam a wire contract | `src/agent3/json.zig:1-108`, `src/coding_agent/cli/run_batch.zig:64-69`, `src/coding_agent/cli/run_batch.zig:115-123` |
| internal snapshot/patch transport | `ConversationPatch`, `QueuedMessageSnapshot`, tui-owned projection state, family-scoped semantic publication | keep host-private. it exists so tui can render and reconcile safely | `docs/runtime.md:12-19`, `docs/extensions-retained-objects.md:133-161`, `src/coding_agent/runtime_host.zig:302-408`, `src/tui/conversation_projection.zig:179-215`, `src/tui/conversation_projection.zig:412-445` |
| internal request/run-control transport | `AgentRequest`, request queue, queued steering/follow-up, abort, new/resume/compact/shutdown control | keep host-private. mutate through owner mailboxes; do not turn mailbox payloads into product api | `docs/architecture.md:12-15`, `docs/runtime.md:12-19`, `src/coding_agent/request.zig:7-86`, `src/coding_agent/runtime_host.zig:153-192` |
| deleted / transitional glue | the old `SessionEvent.agent` wrapper is already gone; `SessionEvent` now carries only retry/compaction lifecycle, and raw `AgentEvent` stays on a separate internal subscription path | do not preserve wrapper glue as product contract or reintroduce it because a private callback path exists | `src/coding_agent/session_event.zig:43-49`, `src/coding_agent/agent_session.zig:546-599`, `docs/extensions-cutover-boundaries.md:16-18` |

## seam matrix

| seam / consumer | current shape | survives / re-derived / deleted | owning contract after cutover | evidence |
| --- | --- | --- | --- | --- |
| `AgentEvent` observer stream in batch json | `run_batch` installs an `AgentSession` event handler and writes each `AgentEvent` as one json object per line | survives | public semantic observer contract exposed on a public wire edge | `src/coding_agent/cli/run_batch.zig:64-69`, `src/coding_agent/cli/run_batch.zig:115-123`, `src/agent3/types.zig:428-440` |
| `agent3/json` serialization | `writeAgentEvent` maps `AgentEvent` variants to batch json wire objects and reuses session message writers for payload bodies | survives | public wire contract, but only for explicit external outputs | `src/agent3/json.zig:1-14`, `src/agent3/json.zig:18-108` |
| session persistence / jsonl (`session/json.zig`, `session/store.zig`, session protocol) | session files are `SessionHeader` + `SessionEntry`; persistence appends message/model/thinking/compaction/session entries, and `message_end` stores the committed message | survives | public persistence contract | `src/session/protocol.zig:7-35`, `src/session/protocol.zig:38-85`, `src/session/json.zig:33-144`, `src/coding_agent/session/store.zig:171-227`, `src/coding_agent/agent_session.zig:794-796` |
| `SessionEvent` union and `.agent` wrapper | `SessionEvent` now carries only retry/compaction lifecycle; raw `AgentEvent` uses the separate agent-event subscription path | deleted | none public; the wrapper is already gone and the remaining lifecycle union stays internal | `src/coding_agent/session_event.zig:43-49`, `src/coding_agent/agent_session.zig:546-599` |
| `RuntimeHost` event/snapshot publication | runtime host binds raw `AgentEvent` and `SessionEvent`, publishes `ConversationPatch` to the tui mailbox, and publishes `QueuedMessageSnapshot` separately | re-derived | internal snapshot/patch transport plus internal lifecycle plumbing | `src/coding_agent/runtime_host.zig:36-52`, `src/coding_agent/runtime_host.zig:137-169`, `src/coding_agent/runtime_host.zig:302-408`, `src/tui/interactive.zig:2776-2789`, `docs/runtime.md:12-19` |
| request queue / run-control mailbox | `AgentRequest` is the tui→agent mailbox payload; queued steering/follow-up and abort go through runtime-host run control | survives | internal request/run-control transport | `src/coding_agent/request.zig:7-35`, `src/coding_agent/request.zig:47-86`, `src/coding_agent/runtime_host.zig:153-192`, `docs/runtime.md:12-19` |
| tui conversation projection | projection owns `view_snapshot` and `queued_snapshot`, applies `ConversationPatch`, and reconciles transcript/render state from that owned state | re-derived | internal snapshot/patch transport feeding tui-owned projection/render | `src/tui/conversation_projection.zig:128-215`, `src/tui/conversation_projection.zig:256-337`, `src/tui/conversation_projection.zig:412-445`, `src/tui/interactive.zig:1142-1180` |
| extension event bridge | internal bridge subscribes to `AgentEvent`, translates payloads to lua tables, and dispatches observers on the runner | re-derived | extension-facing public semantic observer contract; the bridge itself stays internal plumbing | `src/coding_agent/extensions/event_bridge.zig:1-26`, `src/coding_agent/extensions/event_bridge.zig:40-89`, `docs/extensions-events.md:18-20`, `docs/extensions-events.md:61-64` |
| future rpc surface by rule | no full rpc contract is implemented here today; the doctrine already says external payloads must be semantic and owner-boundary machinery stays private | re-derived | public semantic observer contract and/or public retained capability contract, serialized only at the true external edge | `docs/extensions-events.md:18-20`, `docs/extensions-events.md:52-64`, `docs/extensions-retained-objects.md:133-161`, `docs/extensions-cutover-boundaries.md:16-18` |

## alignment with `zi-fex.12`

this matches `zi-fex.12`'s cutover rule: repo consumers move together, `AgentEvent` survives only on intentional observer products, and internal agent↔tui mailbox transport stays request/conversation-patch/queued-snapshot-shaped (`docs/extensions-cutover-boundaries.md:16-18`, `docs/extensions-cutover-boundaries.md:41-42`, `docs/extensions-cutover-boundaries.md:57-60`).

extension-facing contracts therefore inherit from only two places:

- public semantic events/interceptors (`docs/extensions-events.md:10-20`, `docs/extensions-events.md:93-143`)
- public retained capabilities / semantic snapshots (`docs/extensions-retained-objects.md:12-16`, `docs/extensions-retained-objects.md:133-161`)

never from these:

- mailbox payloads such as `AgentRequest`
- run-control queue internals
- `ConversationViewSnapshot` / `QueuedMessageSnapshot` as extension api
- tui projection caches or render-local state
- `SessionEvent.agent` or similar wrapper glue

that matters because extension capability parity is about truthful product seams, not about letting extension code borrow host transport that exists for ownership and redraw mechanics (`docs/extensions-events.md:18-20`, `docs/extensions-events.md:61-64`, `docs/extensions-retained-objects.md:14-16`, `docs/extensions-cutover-boundaries.md:16-18`).

## non-goals

- this is not an implementation plan.
- this is not a file inventory.
- this does not freeze internal snapshot, patch, mailbox, or wrapper structs as public api.
- this does not define every external observer field; batch json and session persistence keep owning those field-level contracts.
- this does not bless the current extension bridge payload tables as the long-term public extension contract.
