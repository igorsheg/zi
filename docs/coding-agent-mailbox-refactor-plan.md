# Coding Agent Mailbox Refactor Plan

Goal: make `src/coding_agent/` a small, client-facing core with one explicit frontend contract, then delete the direct `AgentSession` paths that currently bind interactive/print mode to implementation details.

This is a nuclear refactor plan, not an additive abstraction plan. Every phase must remove or privatize old paths before it is considered done.

## Target shape

```text
frontend clients
  interactive TUI
  print mode
  future RPC/daemon clients
        |
        v
  typed CommandEnvelope queue
        |
        v
coding_agent SessionRuntime owner
  owns RuntimeServices
  owns AgentSession
  owns command queue
  owns client event queue
        |
        v
  typed EventEnvelope queue
        |
        v
frontend adapter maps events to TUI commands/stdout/wire
```

`AgentSession` remains the core state machine. `SessionRuntime` becomes the only frontend-facing owner.

## Non-goals

- Do not import Flow/Thespian as an actor framework.
- Do not add CBOR/MsgPack internally.
- Do not create generic dynamic RPC dispatch inside the process.
- Do not keep direct `AgentSession` calls from frontends after the mailbox path exists.
- Do not support multiple actors until there is a second concrete owner requiring it.

Flow/Thespian is useful as a reference for message thinking, but its stringly CBOR actor style is not the right internal Zi core contract. Internal Zi should be typed Zig unions. Serialization is only for a later external daemon/RPC boundary.

## Runtime primitives to use

Use existing mechanisms:

- `runtime.BoundedQueue(T)` for command/event queues.
- `runtime.ResetEvent` for wakeups.
- `runtime.CancelSource` / `CancelToken` for cancellation.
- `zio select` only where an owner truly waits on multiple wake sources.

Do not build a new actor runtime over zio. The invariant stays:

```text
operation -> owner loop -> bounded queue -> owner drains and mutates
```

## Envelope shape

Internal typed protocol:

```zig
pub const RequestId = u64;

pub const CommandEnvelope = struct {
    id: ?RequestId, // null = notification
    command: ClientCommand,
};

pub const ClientCommand = union(enum) {
    submit_prompt: SubmitPrompt,
    cancel,
    clear_queue,
    compact: Compact,
    request_snapshot,
    shutdown,
};

pub const EventEnvelope = struct {
    request_id: ?RequestId,
    event: ClientEvent,
};

pub const ClientEvent = union(enum) {
    accepted: RequestId,
    rejected: Rejection,
    response: Response,
    transcript: TranscriptEvent,
    status: StatusSnapshot,
    queue: QueueSnapshot,
    tool: ToolEvent,
    diagnostic: Diagnostic,
    shutdown_complete,
};
```

Rules:

- Request ids are allocated by the caller.
- Commands with `id != null` must eventually emit one terminal `.response` or `.rejected` for that id unless shutdown drops them with a shutdown event.
- Streaming events carry the request id when they belong to a prompt run.
- Notifications use `id = null` and do not get responses.
- All owned payloads have explicit `deinit(allocator)`.
- Queue overflow is data: emit/drop according to named policy, never silently corrupt.

Initial payloads should be narrow:

```zig
pub const SubmitPrompt = struct {
    text: []const u8,
    images: []const ai.ImageContent = &.{},
};

pub const Rejection = struct {
    code: enum { busy, queue_full, shutting_down, invalid_command, overflow },
    message: []const u8,
};

pub const Response = union(enum) {
    prompt_finished,
    canceled,
    queue_cleared,
    snapshot: Snapshot,
    compacted,
    shutdown_started,
};
```

Prefer explicit variants over maps/strings. External serialization can map these later.

## New files

Planned files:

- `src/coding_agent/client_protocol.zig`
  - command/event envelope types
  - owned payload deinit helpers
  - bounded constants for command/event queue sizes

- `src/coding_agent/session_runtime.zig`
  - owns `RuntimeServices`
  - owns `AgentSession`
  - owns command queue and event queue
  - exposes `submit`, `drainEvent`, `wake`, `step`, `deinit`

Possible later file, only after internal contract is stable:

- `src/coding_agent/wire_protocol.zig`
  - JSON/CBOR/MsgPack encoding for external daemon clients
  - no dependency from `AgentSession` or `SessionRuntime` back to wire code

## Current direct paths to delete

Frontend-facing code must stop calling these directly:

- `AgentSession.startPromptRun`
- `AgentSession.stepPromptRun`
- `AgentSession.destroyPromptRun`
- `AgentSession.cancelPromptRun`
- `AgentSession.cancel`
- `AgentSession.clearQueue`
- `AgentSession.queueSnapshot`
- `AgentSession.publicEventWake`
- `AgentSession.drainPublicEvent`
- `session_history_snapshot.build(... session.manager ...)`
- direct reads of `session.agent.state.model`
- direct reads of `session.manager`

After migration, these should be private or used only by `SessionRuntime`/tests in the owner file.

## Phase checklist

### Phase 0 — Baseline and guardrails

- [ ] Record current `zig build test`, `zig build`, `zig fmt --check src`.
- [ ] Record current `./autoresearch.sh` metrics.
- [ ] Add grep gates to the plan or checks for forbidden direct frontend paths.
- [ ] Confirm no unrelated TUI cleanup is bundled.

Done when: baseline is known and no code behavior changes were made.

### Phase 1 — Define typed protocol only

- [ ] Add `client_protocol.zig` with command/event envelopes.
- [ ] Include deinit helpers for owned payloads.
- [ ] Add focused tests for envelope deinit and queue overflow accounting.
- [ ] Do not change `interactive.zig` or `print_mode.zig` yet.

Deletion requirement: none yet, but no runtime abstraction beyond types.

Done when: protocol compiles and has tests, no behavior moved.

### Phase 2 — Add `SessionRuntime` owner

- [ ] Move `createSessionRuntime` / `resumeSessionRuntime` from `runtime_services.zig` into `session_runtime.zig`.
- [ ] `SessionRuntime` owns:
  - `RuntimeServices`
  - `AgentSession`
  - command buffer + queue
  - event buffer + queue
  - wake event
- [ ] Add `submit(CommandEnvelope)`, `drainEvent()`, `wake()`, `step()`.
- [ ] Convert existing `AgentSessionEvent` to `ClientEvent` inside `SessionRuntime`, not in TUI.
- [ ] Keep old direct frontend use temporarily only for comparison.

Deletion requirement:

- [ ] `runtime_services.zig` no longer names session runtime creation.

Done when: print/interactive still work and `SessionRuntime` can be driven in tests.

### Phase 3 — Move print mode to mailbox

- [ ] `print_mode.zig` submits `.submit_prompt`.
- [ ] `print_mode.zig` drains `ClientEvent` only.
- [ ] JSON/text output is mapped from `ClientEvent`, not `AgentSessionEvent`.
- [ ] Delete print-mode direct prompt run lifecycle.

Deletion gates:

```sh
! rg "startPromptRun|stepPromptRun|destroyPromptRun|drainPublicEvent|publicEventWake" src/coding_agent/print_mode.zig
```

Done when: print tests pass and no print mode direct session calls remain.

### Phase 4 — Move interactive mode to mailbox

- [ ] Terminal input maps to `ClientCommand`.
- [ ] `ClientEvent` maps to `tui.product.Command` in one adapter block.
- [ ] Cancel/clear queue/snapshot/history use mailbox commands/events.
- [ ] Initial model/status/history is emitted by `SessionRuntime` snapshot event.
- [ ] `InteractiveLoop` no longer stores `*AgentSession`.

Deletion gates:

```sh
! rg "AgentSession|session\." src/coding_agent/interactive.zig
! rg "session_history_snapshot|manager|agent\.state|queueSnapshot|clearQueue|publicEventWake|drainPublicEvent" src/coding_agent/interactive.zig
```

Done when: interactive tests pass and `interactive.zig` knows only `SessionRuntime` + `client_protocol`.

### Phase 5 — Privatize `AgentSession` frontend API

- [ ] Make prompt run lifecycle methods private if only `SessionRuntime` uses them.
- [ ] Make public event queue methods private if only `SessionRuntime` uses them.
- [ ] Move or delete tests that only proved old frontend direct APIs.
- [ ] Keep behavior tests at the `SessionRuntime` contract.

Deletion gates:

```sh
! rg "startPromptRun|stepPromptRun|destroyPromptRun|cancelPromptRun|publicEventWake|drainPublicEvent" src/coding_agent -g'*.zig' | rg -v "AgentSession.zig|session_runtime.zig"
```

Done when: `AgentSession` is not a frontend contract.

### Phase 6 — External RPC/wire decision

Only after internal typed protocol is stable.

Decision options:

1. JSON lines
   - easiest to debug
   - larger payloads
   - good first external daemon protocol

2. CBOR/MsgPack
   - smaller
   - more machinery
   - only justified if measurable or if Flow-style interop is required

Rule: wire encoding is a leaf adapter. It must not affect internal `ClientCommand` / `ClientEvent` ownership.

Done when: a wire ADR is written, not before.

## Required deletion gates before completion

The refactor is not complete while any of these remain in frontend files:

```sh
rg "AgentSession" src/coding_agent/interactive.zig src/coding_agent/print_mode.zig
rg "startPromptRun|stepPromptRun|destroyPromptRun|cancelPromptRun" src/coding_agent/interactive.zig src/coding_agent/print_mode.zig
rg "drainPublicEvent|publicEventWake|queueSnapshot|clearQueue" src/coding_agent/interactive.zig src/coding_agent/print_mode.zig
rg "session_history_snapshot|\.manager|agent\.state" src/coding_agent/interactive.zig
```

Expected final state:

```text
interactive.zig imports client_protocol + session_runtime + tui
print_mode.zig imports client_protocol + session_runtime
AgentSession.zig is imported by session_runtime.zig, not frontends
```

## Acceptance criteria

- [ ] No frontend imports `AgentSession.zig`.
- [ ] No frontend drains `AgentSessionEvent` directly.
- [ ] Print and interactive use the same command/event contract.
- [ ] The contract is typed Zig unions, not strings or maps.
- [ ] All command/event queues are bounded.
- [ ] Overflow behavior is explicit and tested.
- [ ] Shutdown path is request -> stop accepting -> cancel -> drain -> stopped -> deinit.
- [ ] `zig build test` passes.
- [ ] `zig build` passes.
- [ ] `zig fmt --check src` passes.
- [ ] `./autoresearch.sh` does not hide regressions via moved/generated code.

## Anti-entropy rules

- Every new path must delete or privatize an old path in the same phase.
- No compatibility shim survives beyond one phase.
- No generic actor, registry, dispatcher, or codec until there are two concrete users.
- No internal CBOR/MsgPack while all participants are Zig code in one process.
- No string command names internally.
- No callbacks that can mutate owner state.
- No unbounded queue or list introduced at the client boundary.
- No frontend receives `*AgentSession`, `*SessionManager`, or `*agent.Agent`.

## Tracking

| Phase | Status | Commit | Notes |
| --- | --- | --- | --- |
| 0. Baseline | done | | `zig build test`, `zig build`, `zig fmt --check src`, `./autoresearch.sh` pass on alpha after merge. |
| 1. Typed protocol | done | | Added `client_protocol.zig` with typed command/event envelopes and deinit tests. |
| 2. SessionRuntime owner | done | | Added `session_runtime.zig`; moved session runtime creation out of `runtime_services.zig`; CLI/interactive now construct through `session_runtime`. |
| 3. Print mode mailbox | pending | | |
| 4. Interactive mailbox | pending | | |
| 5. Privatize AgentSession API | pending | | |
| 6. Wire decision | pending | | |
