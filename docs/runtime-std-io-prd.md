# Runtime std.Io Decoupling PRD

Zi is moving runtime ownership to a `std.Io`-first seam. zio may remain as a private backend adapter while the migration is in flight, but no product code should depend on zio-native tasks, wait protocols, channels, fd readiness, or select.

## Status

This PRD is closed as the accepted migration plan. Implementation is intentionally incremental and tracked by the task checklist below.

Current implementation state:

```text
accepted plan: closed
implementation: in progress
next implementation slice: TUI bounded input reader design retry after PRD
```

Closeout rule: do not reopen the PRD for normal implementation work. Update task checkboxes and notes in this file as slices land. Create a follow-up PRD only if the target architecture changes.

## Problem

Zi currently exposes zio-shaped runtime concepts above `src/runtime`:

```text
runtime.select
runtime.Task
runtime.Timeout as a select waitable
runtime.ResetEvent async wait protocol
EventPipe.Stream.asyncNext
ReadableFd.asyncReadable
```

This makes zio an architectural dependency instead of an implementation detail. It also makes the owner loops depend on zio's heterogeneous wait protocol rather than Zi's preferred shape:

```text
producer -> bounded queue/result slot -> owner wake -> owner drains and mutates
```

## Goals

- Make `std.Io` the public runtime seam.
- Keep zio imports confined to one private backend adapter while zio remains vendored.
- Remove zio-native wait/select protocols from product code.
- Preserve bounded resident state, explicit cancellation, terminate/drain order, and TUI input responsiveness.
- Make zio deletion a final mechanical step once a std backend passes tests/traces.

## Non-goals

- Do not rewrite provider, agent, or TUI policy during this migration.
- Do not introduce unbounded queues, unowned worker loops, or best-effort shutdown.
- Do not replace Vaxis terminal ownership.
- Do not use `std.process.run`-style unbounded child-output capture.

## Current checkpoint

Completed in the first migration slices:

- [x] Direct `@import("zio")` isolated to `src/runtime/zio_backend.zig`.
- [x] Runtime docs updated to `std.Io`-first, zio-private-backend.
- [x] `runtime.sleep` takes explicit `std.Io`.
- [x] OAuth login race moved from `runtime.select` to `std.Io.Queue`.
- [x] TUI foreground input poll moved from `runtime.select` to `runtime.pollReadableFd` backed by `std.posix.poll`.
- [x] AgentSession compaction test driver moved from `runtime.select` to stream polling plus cooperative yield.
- [x] `runtime.WakeEvent` added with a `std.Io` public surface.
- [x] `CancelSource` moved from `runtime.ResetEvent` storage to `runtime.WakeEvent`.

Remaining zio-shaped surfaces:

```text
runtime backend host still uses private zio adapter
TUI input still polls stdin directly instead of bounded byte ingestion
```

## Invariants

- `std.Io` enters at the process/runtime seam and is passed explicitly.
- Owners mutate state only at drain/apply sites.
- Every producer path has a named bound and overflow/backpressure policy.
- Wakeups are coalesced facts; owners inspect state after waking.
- Cancellation intent is not completion; terminal outcomes must be observed.
- Shutdown order is request -> stop accepting -> cancel -> drain -> stopped -> deinit.
- Terminal input may be read outside the TUI owner only as bytes; Vaxis parsing and App mutation stay owner-local.

## Migration tasks

### 1. Enforce zio import hygiene

- [x] Add a build or test gate that fails when `@import("zio")` appears outside `src/runtime/zio_backend.zig`.
- [x] Add a second check or narrow grep for `zio.` references outside that file.
- [x] Document the check in this PRD or `AGENTS.md` once wired.

Acceptance:

```sh
grep -R '@import("zio")\|\bzio\.' -n src | grep -v 'src/runtime/zio_backend.zig'
# no output
```

### 2. Introduce a Zi-owned wake primitive

Add a runtime wake primitive with a `std.Io` public surface:

```zig
runtime.WakeEvent
  set(io: std.Io)
  reset()
  isSet()
  wait(io: std.Io)
  waitTimeout(io: std.Io, timeout: std.Io.Timeout or std.Io.Duration)
```

Tasks:

- [x] Add `src/runtime/wake_event.zig`.
- [x] Implement initially over the current backend if needed.
- [x] Export from `src/runtime/root.zig`.
- [x] Add tests for set/reset/wait/timeout semantics.
- [x] Ensure no zio types appear in public signatures.

Acceptance:

- Callers can wait with `std.Io` only.
- No `asyncWait` method is required above runtime internals.

### 3. Move CancelSource to WakeEvent

Tasks:

- [x] Replace `CancelSource`'s `runtime.ResetEvent` storage with `WakeEvent`.
- [x] Update `CancelToken.wait` to retain explicit `std.Io` from source initialization.
- [x] Update `sleepUntilCancel` to use `WakeEvent.waitTimeout`.
- [x] Preserve generation semantics: old tokens remain canceled after reset.
- [x] Keep cancellation tests covering wake, reset, and sleep interruption.

Acceptance:

- `cancel.zig` has no zio-shaped wait protocol dependency.
- Allocation/deallocation ownership remains unchanged.

### 4. Consolidate owner wakes in SessionRuntime

Current `SessionRuntime.waitAndApplyWake` selects over many independent waitables. Target shape:

```text
producer/task/event/input -> bounded queue/result slot -> owner_wake.set()
owner waitTimeout(frame/retry deadline)
owner wakes -> inspect state in priority order
```

Tasks:

- [x] Add one owner wake to `SessionRuntime` for command, public-event, active-progress, retry/frame re-checks.
- [x] Make command submit set the owner wake.
- [x] Make public event enqueue set the owner wake.
- [x] Make completion workers set the owner wake when their result slot is ready.
- [x] Make active agent/compaction event production set the owner wake.
- [x] Keep per-turn drain budgets intact.

Acceptance:

- `SessionRuntime.step` remains the only mutation path.
- Wakes carry no payload; state is inspected after wake.
- Overflow behavior remains explicit.

### 5. Replace `SessionRuntime.waitAndApplyWake`

Tasks:

- [x] Remove heterogeneous `runtime.select` from `waitAndApplyWake`.
- [x] Compute next timeout from frame deadline and retry deadline.
- [x] Wait on the coalesced owner wake with timeout.
- [x] On wake or timeout, inspect in priority order:
  - [x] terminal/input availability
  - [x] command wake
  - [x] active prompt/compaction progress
  - [x] completion result
  - [x] public events
  - [x] retry due
  - [x] frame due
- [x] Preserve foreground input priority.
- [x] Preserve frame-gated rendering semantics.

Acceptance:

- No `runtime.select` in `src/coding_agent/session_runtime.zig`.
- Composer responsiveness trace does not regress.

### 6. Replace terminal fd select with bounded input reader

The current TUI still has session-level input readiness. Target:

```text
stdin reader task -> bounded raw-byte queue -> owner wake -> TUI owner parses bytes
```

Tasks:

- [ ] Add a concrete TUI frontend input reader outside `src/tui`.
- [ ] Reader owns only fd reads and byte queue writes.
- [ ] Vaxis parser remains owned by `tui.Terminal` / TUI owner.
- [ ] Queue has explicit byte/item capacity.
- [ ] Full queue backpressures or drops with a named policy.
- [ ] Shutdown cancels reader, drains, then deinitializes.
- [x] Remove `ReadableFd.asyncReadable` use from product code.

Acceptance:

- No product loop needs zio fd readiness.
- TUI input remains foreground priority.
- Idle Zi does not spin.

### 7. Rewrite EventPipe on std.Io primitives

Target:

```text
std.Io.Queue(Event) + WakeEvent + terminal result
```

Tasks:

- [x] Remove zio channel backing from `EventPipe`.
- [x] Remove `Stream.asyncNext` from public API.
- [x] Preserve bounded capacity.
- [x] Preserve terminal event/result ordering.
- [x] Preserve abort behavior.
- [x] Add wake-on-emit/end/abort behavior for owner loops.
- [x] Update agent prompt stream and compaction stream users.

Acceptance:

- `src/runtime/event_pipe.zig` has no zio backend dependency.
- EventPipe tests still cover ordering, full producer blocking/backpressure, terminal result, and abort.

### 8. Replace runtime.Task at owner boundaries

Tasks:

- [x] Inventory all `runtime.Task` use.
- [x] For simple await/cancel tasks, migrate to `std.Io.Future` or `std.Io.Group`.
- [x] For owner-loop completions, replace polling with result slots/queues plus owner wake.
- [x] Remove `hasResult`-based polling where possible.
- [x] Keep cancellation/join ownership explicit.

Known users:

```text
src/agent/loop.zig
src/agent/tool_runner.zig
src/coding_agent/session_runtime.zig
src/runtime/process_runner.zig
```

Acceptance:

- No public `runtime.Task` needed outside runtime internals.
- Completion is data, not authority.

### 9. Port process_runner internals

Keep `runtime.runProcess` as the public API. Replace internals with std.Io-shaped tasks/queues.

Required behavior:

- [x] spawn child with explicit `std.Io`
- [x] read stdout and stderr concurrently
- [x] preserve stdout/stderr byte caps
- [x] preserve streaming observer chunks
- [x] preserve timeout behavior
- [x] preserve cancel behavior
- [x] terminate gracefully, then force after grace
- [x] drain process and output tasks before returning/deinit

Acceptance tests:

- [x] interleaved stdout/stderr
- [x] stdout cap
- [x] stderr cap
- [x] exact-at-cap accepted
- [x] quiet stdout / noisy stderr
- [x] timeout terminates process group
- [x] cancel terminates process group
- [x] observer output bounded and ordered enough for UI policy

### 10. Delete public zio-shaped runtime exports

Tasks:

- [x] Remove `runtime.select` from `root.zig`.
- [x] Remove `runtime.Timeout` if only used for zio select.
- [x] Remove `ReadableFd.asyncReadable` or keep only private runtime tests.
- [x] Remove `ResetEvent.asyncWait` / `asyncCancelWait`.
- [x] Remove `Task.asyncWait` / `asyncCancelWait`.
- [x] Remove `EventPipe.Stream.asyncNext`.

Acceptance:

```sh
grep -R 'runtime.select\|asyncNext\|asyncReadable\|asyncWait' -n src
# no product-level zio wait protocol remains
```

### 11. Add std backend and decide zio deletion

Tasks:

- [ ] Add a std backend host (`std.Io.Threaded` or another Zig 0.16 std backend) behind runtime.
- [ ] Run all tests with that backend.
- [ ] Run TUI trace with real streaming/tool stress.
- [ ] Compare idle CPU, input latency, process-run behavior, and shutdown reliability.
- [ ] If std backend passes, remove zio dependency and vendor directory.
- [ ] Update `CONTEXT.md`, `AGENTS.md`, and `build.zig.zon`.

Acceptance:

```sh
zig build test
zig build
zig fmt --check src
ZI_TUI_TRACE=1 zig build run -- "stress prompt"
```

No responsiveness regression and no zio dependency remains.

## Tracking checklist

Implementation progress checklist:

- [x] zio import hygiene gate is wired into `zig build test`.
- [x] Direct zio imports are isolated to `src/runtime/zio_backend.zig`.
- [x] Runtime architecture docs describe zio as a private backend adapter.
- [x] `runtime.sleep` takes explicit `std.Io`.
- [x] `runtime.WakeEvent` exists with a `std.Io` public surface.
- [x] `CancelSource` stores `WakeEvent` and receives explicit `std.Io` at init.
- [x] OAuth login race uses `std.Io.Queue` instead of `runtime.select`.
- [x] TUI foreground input poll uses `runtime.pollReadableFd` instead of `runtime.select`.
- [x] AgentSession compaction test driver uses stream polling plus cooperative yield instead of `runtime.select`.
- [x] `SessionRuntime.waitAndApplyWake` uses coalesced owner wake instead of `runtime.select`.
- [x] `EventPipe` uses `std.Io` primitives and no `asyncNext` public API.
- [x] `runtime.Task` is removed from product-level owner boundaries.
- [x] `runtime.runProcess` internals use `std.Io` primitives instead of zio-native pipe/channel/select.
- [x] public `runtime.select` and zio-shaped wait exports are deleted.
- [ ] std backend passes tests/traces and zio is deleted or optional only.

End state checklist:

- [ ] `src/runtime/zio_backend.zig` removed or optional only.
- [ ] `build.zig.zon` no longer requires zio, if deleted.
- [x] No zio imports outside backend adapter.
- [x] No `runtime.select` public API.
- [x] No product-level async wait protocol.
- [x] `SessionRuntime.waitAndApplyWake` uses coalesced owner wake.
- [ ] TUI input uses bounded byte ingestion.
- [x] `EventPipe` uses std.Io primitives.
- [x] `runProcess` uses std.Io primitives and preserves tests.
- [ ] Docs match code.

## Validation commands

Run after each slice:

```sh
zig build test
zig build
zig fmt --check src
```

Run after TUI/session slices:

```sh
ZI_TUI_TRACE=1 zig build run -- "hello"
```

Run import hygiene check:

```sh
grep -R '@import("zio")\|\bzio\.' -n src | grep -v 'src/runtime/zio_backend.zig'
```
