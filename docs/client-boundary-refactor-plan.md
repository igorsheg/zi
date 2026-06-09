# Client Boundary Refactor Plan

Goal: make `src/coding_agent/` the core product/session system with one durable typed client contract, while moving all concrete frontend/client adapters outside it.

This follows the mailbox/protocol/owner direction and explicitly **does not** replace raw `agent.AgentEvent` with a second projected lifecycle model yet. `AgentEvent` remains the single source of truth for agent-loop events until repeated frontend duplication proves a projection is worth promoting.

## Target shape

```text
src/coding_agent/
  client_protocol.zig      typed semantic protocol, owned payloads, queue caps
  session_runtime.zig      sole frontend-facing session owner
  AgentSession.zig         core state machine, private to coding_agent internals
  tools/                   definition-first builtins
  auth/settings/resources/session storage/path policy

src/cli/
  args.zig                 concrete process CLI parsing/dispatch
  root.zig                 top-level app dispatch, may import frontends

src/frontends/print/
  print_mode.zig           text/json adapter over SessionRuntime + ClientEvent

src/frontends/tui/
  interactive.zig          dormant/wire-later TUI adapter; imports coding_agent + tui

src/frontends/rpc/
  stdio.zig                future JSONL transport owner

src/tui/
  terminal product/substrate only; no coding_agent imports
```

Dependency rule:

```text
coding_agent -> std, ai, agent, runtime
coding_agent -X-> tui
coding_agent -X-> frontends

tui -> std, uucode
tui -X-> coding_agent

frontends/* may import coding_agent and, when needed, tui
main/src/cli owns concrete dispatch
```

## Non-negotiable invariants

- `SessionRuntime` is the only client-facing owner of an active session.
- Frontends communicate through `ClientCommand`, `ClientEvent`, bounded queues, and owned snapshots.
- No frontend receives `*AgentSession`, `*SessionManager`, `*agent.Agent`, provider registry, or mutable tool registry.
- `agent.AgentEvent` remains the authoritative agent event vocabulary for now.
- Projections such as `AgentEvent -> TranscriptAppend` live in frontend adapters, not in `coding_agent`.
- Transport codecs are leaves. They map bytes to/from `client_protocol`; they do not own session policy.
- Operational overload degrades through rejection, backpressure, drop/coalesce + overflow event, or shutdown. It must not silently corrupt state.

## Scope

Do now:

1. Move CLI/print concrete client code out of `src/coding_agent`.
2. Complete `client_protocol` with bounded snapshots so frontends do not need helper getters.
3. Make `SessionRuntime` event backpressure safe.
4. Prepare, but do not yet implement, JSONL transport shape.

Do not do now:

- Replace raw `agent.AgentEvent` with app-level `item_delta`/`turn_completed` projection.
- Build HTTP/WebSocket/Unix socket daemon.
- Add extension runtime.
- Add TUI widget/component/surface plugin APIs.
- Add OpenAPI/generated SDK/global event bus/event sourcing.

## Phase 0 — Baseline and guardrails

Status: done

Tasks:

- [x] Record baseline:
  - [x] `zig build test`
  - [x] `zig build`
  - [x] `zig fmt --check src`
- [x] Add/import-check command to this plan and use it after each phase:

```sh
! rg '@import\([^\n]*(tui|frontends)|\.\./tui|\.\./frontends|tui/root|frontends/' src/coding_agent
! rg '@import\([^\n]*coding_agent|\.\./coding_agent|coding_agent/root' src/tui
```

Done when:

- Baseline is known.
- No behavior has moved.

## Phase 1 — Move concrete CLI and print adapters out of coding_agent

Status: done

Intent:

`coding_agent` should not own process-level app dispatch or concrete print frontend behavior.

Tasks:

- [x] Create `src/cli/root.zig` and `src/cli/args.zig` from current `src/coding_agent/cli`.
- [x] Create `src/frontends/print/print_mode.zig` from current `src/coding_agent/print_mode.zig`.
- [x] Update `src/main.zig` to call top-level `cli.main`.
- [x] Keep auth/settings/session construction in `coding_agent` APIs; CLI only dispatches.
- [x] Remove `pub const cli` from `src/coding_agent/root.zig` unless tests need a temporary import.
- [x] Ensure top-level CLI rejects/wires modes without making `coding_agent` import frontends.

Deletion gates:

```sh
! rg 'print_mode|cli/root|cli/args|frontends|tui/root|\.\./tui' src/coding_agent
```

Allowed exceptions:

- Temporary references inside docs only.
- Core protocol/session files may still expose APIs used by print.

Tests:

- [x] CLI parse/usage tests moved with `src/cli`.
- [x] Print text/json tests pass from `src/frontends/print`.
- [x] Auth CLI tests still pass through top-level CLI.
- [x] `zig build test`
- [x] `zig build`
- [x] `zig fmt --check src`

Done when:

- `src/coding_agent` has no concrete frontend/client adapter modules.
- Print/json behavior is unchanged.

## Phase 2 — Make snapshot a first-class client event

Status: done

Intent:

Frontends should initialize/restore state through the mailbox, not by calling helper getters on `SessionRuntime`.

Current helper pressure to eliminate from frontends:

```text
model()
buildHistorySnapshot()
queuedMessagesSnapshot()
dropQueuedMessages()
findToolDefinition()
```

Tasks:

- [x] Add bounded snapshot payloads to `client_protocol.zig`:

```text
ClientEvent.snapshot
  session_id
  session_name?
  model { provider, id }
  queue snapshot
  active_request_id?
  bounded history items
  truncation metadata
  optional tool display metadata, if TUI needs it
```

- [x] Make `ClientCommand.request_snapshot` return `ClientEvent.snapshot`, not only `.snapshot_sent`.
- [x] Add explicit caps:
  - [x] max history items
  - [x] max history bytes
  - [x] max model/provider bytes
  - [x] max tool metadata entries/bytes if included (not included in first snapshot shape)
- [x] Add owned deinit helpers for every snapshot payload.
- [x] Update print/TUI adapters to request/drain snapshot instead of direct getters where practical.
- [x] Keep `agent.AgentEvent` raw for streaming; snapshot only describes current frontend-readable state.

Deletion gates:

```sh
! rg 'buildHistorySnapshot|queuedMessagesSnapshot|model\(\)|findToolDefinition' src/frontends src/cli
```

`dropQueuedMessages` may require a distinct command instead of snapshot:

```text
ClientCommand.drop_queued_messages
```

Add only if the TUI restore behavior still needs it after adapter review.

Tests:

- [x] Snapshot owns and deinits all text.
- [x] Snapshot respects item cap.
- [x] Snapshot respects byte cap.
- [x] Snapshot reports truncation.
- [x] `request_snapshot` emits snapshot with request id.
- [x] No direct helper getter is needed by frontend adapters.
- [x] `zig build test`
- [x] `zig build`
- [x] `zig fmt --check src`

Done when:

- A frontend can seed its display from protocol events only.

## Phase 3 — Make SessionRuntime backpressure safe

Status: done

Intent:

A slow frontend/RPC stdout must not crash the owner loop or silently lose required protocol facts.

Tasks:

- [x] Classify event delivery in `client_protocol.zig` or `session_runtime.zig`:

```text
lossless:
  rejected
  response
  snapshot
  prompt terminal result
  approval/ui request when added
  shutdown_started/shutdown_complete
  event_overflow

best_effort:
  streaming text/thinking/tool-output deltas
  transient status noise
```

- [x] Replace operational `EventQueueFull` owner-loop failure with explicit policy:
  - [x] lossless full queue -> stop progressing/backpressure until frontend drains, or reject before mutation;
  - [x] best-effort full queue -> drop/coalesce and remember overflow marker;
  - [x] overflow marker is eventually emitted losslessly.
- [x] Keep command queue full as submit-time rejection/backpressure.
- [x] Ensure shutdown can still enqueue/drain terminal state.
- [x] Ensure `deinit` cannot race active work.

Note: the first implementation treats all `ClientEvent` values as lossless at the
`SessionRuntime` boundary and backpressures instead of dropping. Best-effort
delta coalescing remains available inside lower owners and can be added to the
client boundary only when measured pressure proves it is needed.

Deletion gate:

```sh
! rg 'EventQueueFull.*return err' src/coding_agent/session_runtime.zig
```

The exact grep may change after implementation; the property is: ordinary event queue pressure does not tear down `step()`.

Tests:

- [x] Full event queue does not crash `SessionRuntime.step()`.
- [x] Required response/snapshot is not dropped.
- [x] Streaming deltas can be dropped/coalesced with overflow accounting.
- [x] Overflow event is emitted once capacity is available.
- [x] Shutdown remains observable under event pressure.
- [x] Command queue full rejects cleanly.
- [x] `zig build test`
- [x] `zig build`
- [x] `zig fmt --check src`

Done when:

- Backpressure behavior is explicit and tested.

## Phase 4 — Prepare JSONL transport as a leaf design

Status: done

Intent:

Record transport shape without adding daemon machinery. The leaf codec now exists
as `src/coding_agent/wire_protocol.zig`; the stdio frontend remains deferred.

Tasks:

- [x] Add ADR or section in this plan for `wire_protocol.zig`:

```text
wire_protocol.zig
  decodeCommand(json bytes) -> client_protocol.CommandEnvelope
  encodeEvent(client_protocol.EventEnvelope) -> json bytes
```

- [x] Define constants before implementation:
  - [x] max input line bytes: `64 * 1024`
  - [x] max output event bytes: `256 * 1024`
  - [x] max pending request ids: `64`
  - [x] max malformed lines before shutdown: `16`
- [x] Define JSONL rules:
  - [x] split only on LF
  - [x] trim one trailing CR
  - [x] stdout protocol only
  - [x] stderr diagnostics only
  - [x] malformed line rejects one command and owner loop continues

Implemented codec contract:

```text
wire_protocol.decodeCommandLine(allocator, raw_line) -> ?CommandEnvelope
  enforces line cap, CR trim, empty-line ignore, prompt text cap
  supports submit_prompt, cancel, clear_queue, request_snapshot, shutdown

wire_protocol.encodeEventEnvelope(allocator, EventEnvelope) -> []u8
  emits one LF-terminated JSON object
  keeps request id at top level when present
  enforces output event cap
```

Transport owner rules for future `src/frontends/rpc/stdio.zig`:

```text
stdin/jsonl -> wire_protocol.decodeCommandLine -> SessionRuntime.submit
SessionRuntime.drainEvent -> wire_protocol.encodeEventEnvelope -> stdout/jsonl
stderr remains diagnostics only
```

Non-goals:

- No JSON-RPC 2.0 ceremony.
- No HTTP/WebSocket/Unix socket.
- No generated SDK.
- No actor registry.

Done when:

- Transport design is recorded and ready for a future RPC implementation.

## Phase 5 — Rewire TUI later through completed mailbox

Status: pending, not part of current core cleanup

Intent:

TUI comes back only as a concrete frontend adapter over the completed client protocol.

Tasks:

- [ ] Top-level dispatch calls `src/frontends/tui/interactive.zig`.
- [ ] TUI adapter initializes from `ClientEvent.snapshot`.
- [ ] TUI adapter maps raw `ClientEvent.agent_event` to `tui.product.Command` locally.
- [ ] TUI adapter maps `tui.product.Effect` to `ClientCommand` locally.
- [ ] No `coding_agent` import of `tui` returns.

Deletion gates:

```sh
! rg '@import\([^\n]*(tui|frontends)|\.\./tui|\.\./frontends|tui/root|frontends/' src/coding_agent
! rg 'buildHistorySnapshot|queuedMessagesSnapshot|model\(\)|findToolDefinition' src/frontends/tui
```

Done when:

- Interactive mode works again without violating core/frontend boundaries.

## Raw AgentEvent decision

Decision: keep raw `agent.AgentEvent` as the authoritative agent-loop client event for now.

Why:

- It avoids frontend handicap from premature projection.
- It avoids split brain between agent events and a parallel app-level event model.
- It keeps projection policy at the frontend edge.
- It lets debug/RPC clients inspect full fidelity.

Rules:

- `ClientEvent.agent_event` stays as an owned envelope.
- Strengthen ownership, serialization, bounds, and deinit for `OwnedAgentEvent` as needed.
- Do not add `item_delta`/`turn_completed` style events merely as aliases for raw `AgentEvent`.
- Add new `ClientEvent` variants only when they represent core/session facts not already represented by `AgentEvent`, such as snapshot, queue, compaction, retry, rejection, response, UI/approval request.

Promotion rule:

A projected event may be promoted only when at least two concrete clients duplicate the same projection and the projection is stable enough to become product protocol.

## Tracking

| Phase | Status | Notes |
| --- | --- | --- |
| 0. Baseline and guardrails | done | `zig build test`, `zig build`, `zig fmt --check src`, and import gates passed. |
| 1. Move CLI/print out of coding_agent | done | `src/cli` and `src/frontends/print` created; `src/coding_agent` no longer imports concrete frontend/client adapters. |
| 2. First-class snapshot event | done | Added `ClientEvent.snapshot`; `request_snapshot` emits an owned bounded snapshot; print/TUI frontends no longer call session helper getters. |
| 3. Backpressure-safe SessionRuntime | done | `SessionRuntime` now parks one pending lossless event and stops consuming/progressing while the frontend event queue is full. |
| 4. JSONL transport design | done | Added `coding_agent/wire_protocol.zig` constants and leaf JSONL encode/decode helpers; stdio transport remains deferred. |
| 5. Rewire TUI through mailbox | pending | later |

## Final acceptance criteria

- [ ] `src/coding_agent` has no TUI or frontend adapter imports.
- [ ] `src/tui` has no `coding_agent` imports.
- [ ] Concrete CLI/print/TUI/RPC adapters live outside `src/coding_agent`.
- [ ] `SessionRuntime + client_protocol` is sufficient for frontend state initialization and commands.
- [ ] Raw `agent.AgentEvent` remains the only agent-loop event truth.
- [ ] Snapshot payloads are bounded, owned, and tested.
- [ ] Event queue pressure has explicit policy and tests.
- [ ] No operational frontend lag tears down the session owner loop.
- [ ] `zig build test` passes.
- [ ] `zig build` passes.
- [ ] `zig fmt --check src` passes.
