# TUI Bounded Input Reader PRD

## Status

```text
accepted plan: draft
implementation: code complete; pending manual/trace validation
reason: first implementation attempt was rolled back because it froze idle TUI input
```

This PRD exists because the runtime std.Io migration still wants terminal input to follow:

```text
stdin reader -> bounded raw-byte queue -> owner wake -> TUI owner parses bytes
```

The first attempt violated the wake-loop invariant: a background reader woke a `std.Io.Event` that the TUI owner was not always waiting on, so composer input could sleep behind the idle frame timeout. A second attempt used a raw thread but still coupled a frontend input wake to `SessionRuntime` internals. Do not reintroduce that shape.

## Problem

Today the TUI owner loop polls stdin readiness directly and then calls `tui.Terminal.readAvailableInput()`:

```text
owner poll stdin fd -> owner read bytes -> Vaxis parser -> App mutation
```

This is responsive and single-owner, but it keeps fd readiness in the product loop. The runtime std.Io PRD wants product loops to stop depending on zio-shaped fd readiness and eventually remove zio-native wait protocols.

Moving stdin reads outside the owner is delicate because terminal input is foreground work. A broken wake path makes Zi appear frozen even if the reader has bytes queued.

## Goals

- Keep `tui.Terminal` / the TUI owner as the only Vaxis parser and App mutator.
- Move only raw-byte reads out of the owner loop.
- Bound queued bytes explicitly.
- Preserve composer responsiveness: typed input wakes the owner immediately.
- Avoid tying frontend input wake semantics to `SessionRuntime` policy state.
- Preserve external editor suspension: no background reader may consume editor input.
- Preserve idle behavior: no spin while idle.

## Non-goals

- Do not introduce `vaxis.Loop`.
- Do not move Vaxis parsing to a worker.
- Do not parse terminal escape sequences outside `tui.Terminal`.
- Do not create a second App mutation path.
- Do not use a background reader that can block the cooperative std.Io executor.

## Required Architecture

The frontend owner must own a frontend wake that can be signaled by both input and session progress:

```text
stdin reader -> bounded byte queue -> frontend_wake.set()
session progress -> frontend_wake.set()
frame deadline -> timeout
frontend owner wakes -> priority drain:
  1. queued input bytes
  2. session step/client events
  3. frame/render
```

Do **not** make the input reader signal `SessionRuntime.owner_wake` directly. SessionRuntime may expose progress as a wake source or event source, but the concrete frontend owns the combined scheduling decision.

## Design Requirements

### Input reader

- Lives outside `src/tui`.
- Owns only:
  - stdin fd readiness/read calls
  - raw byte queue writes
  - EOF fact
  - cancellation/shutdown of its worker
- Does not import `tui`.
- Does not parse bytes.
- Does not mutate session or App state.

### Queue

- Explicit capacity: proposed `16 KiB` raw bytes.
- Overflow policy: backpressure reader, not drop, for typed input.
- Owner drain budget: drain at most one bounded chunk per foreground turn, then render foreground if needed.
- EOF is a bounded fact, not an unbounded event stream.

### Wake

The wake primitive must be proven to work across the producer boundary used by the reader.

Acceptable options:

1. A runtime-owned cross-thread wake primitive backed by an OS pipe/eventfd/kqueue-safe mechanism and waited by the frontend owner.
2. A std backend where `std.Io.Event.set()` from the reader boundary reliably wakes the owner wait.
3. No reader until such a wake exists.

Unacceptable:

- Raw thread calls `SessionRuntime.owner_wake.set()` and assumes the TUI owner is waiting on it.
- Cooperative `std.Io.concurrent` task calls blocking `poll()` or `read()`.
- Input wake only affects a queue but not the owner wait.

### External editor / terminal suspension

Shutdown order around external programs:

```text
stop accepting input reads
cancel reader
join/drain reader
suspend terminal
run external program
resume terminal
restart reader
```

A reader must not remain active while raw mode is suspended or while an editor owns the terminal.

## Owner Loop Shape

Target loop sketch:

```text
while running:
  drain queued input first
  service bounded session work
  render if due
  wait on frontend_wake with timeout(next frame/session deadline)
```

The frontend wake must be set by:

- input reader after bytes or EOF are queued
- session runtime when commands/progress/events/completions are ready
- any explicit command wake

Frame deadlines are timeouts, not queued events.

## Acceptance Criteria

- Composer echoes typed characters immediately while idle.
- Composer remains responsive during streaming model/tool output.
- Idle Zi does not spin.
- External editor input is not consumed by Zi's reader.
- `tui.Terminal` remains the only Vaxis parser owner.
- Input queue capacity and backpressure policy are documented in code.
- No product loop uses zio fd readiness or `ReadableFd.asyncReadable`.
- TUI trace shows no regression in:
  - input drain latency
  - wait wake latency
  - render foreground latency

## Tests / Validation

Required before checking off runtime PRD task 6:

```sh
zig build test
zig build
zig fmt --check src
```

Manual/trace validation:

```sh
ZI_TUI_TRACE=1 zig build run -- "hello"
```

Latest trace samples (`zig build run -- zi tui trace`, 2026-06-28):

- First trace:
  - input reader enqueue -> owner drain max: `0.049ms`.
  - input drain max: `1.361ms`.
  - foreground render flush max: `6.498ms`; background render flush max: `18.226ms`.
  - idle wait still parks: frame wait max reached `30001.071ms`.
  - no foreground render was forced to carry pending background work.
  - follow-up trace should keep the slowest samples (not the latest samples) because
    this run showed `session_step_prompt_progress` at `52.071ms`, while the retained
    slow-sample ring was filled by later `assistant_queue_wait` samples.
- Second trace after slowest-sample retention:
  - input reader enqueue -> owner drain max: `0.054ms`.
  - input drain max: `0.514ms`.
  - idle wait still parks: frame wait max reached `30001.035ms`.
  - slowest retained samples confirm `session_step_prompt_progress` dominates
    (`38.385ms`, `25.631ms`, `19.431ms`) rather than input/render.
  - next trace splits prompt progress into stream poll, apply, and public-event drain.
- Third trace after prompt-progress split:
  - input reader enqueue -> owner drain max: `0.059ms`.
  - input drain max: `0.557ms`.
  - `session_step_prompt_progress` still dominates at `26.108ms`.
  - stream poll is not the cause (`0.050ms`), public-event drain is not the cause
    (`0.638ms`), and measured apply work is bounded (`7.906ms`).
  - the remaining gap is the cooperative `runtime.yield()` on empty stream polls.
    A follow-up attempt to skip that yield when `frontend_wake` was installed
    starved producer progress: the TUI stayed in "working" with no transcript.
    Keep the yield until runtime offers a producer-driving wait that does not
    cost a full foreground turn.
- Fourth trace after restoring the yield:
  - transcript progress is restored.
  - input reader enqueue -> owner drain max: `0.253ms`.
  - input drain max: `0.315ms`.
  - `session_step_prompt_progress` reached `133.972ms`; split timings show poll
    (`0.439ms`), apply (`12.531ms`), and public-event drain (`1.175ms`) are not
    enough to explain it.
- Automated tmux trace after adding direct yield timing:
  - prompt: `Reply with exactly: OK`.
  - transcript completed and TUI exited with `ctrl+d`.
  - input reader enqueue -> owner drain max: `0.061ms`.
  - input drain max: `0.074ms`.
  - `session_step_prompt_progress` max: `17.621ms`.
  - `session_step_prompt_progress_yield` max: `17.619ms`.
  - conclusion: the bounded input reader path is healthy; the remaining foreground
    turn cost is zio producer-driving yield, not terminal input, frontend event
    drain, transcript projection, or render.

Scenarios:

- Start TUI idle, type in composer immediately.
- Hold a key while model stream is active.
- Open external editor, type in editor, exit, continue typing in composer.
- Paste a large bounded payload.
- Resize terminal while input reader is active.

## Rollback Note

A previous implementation attempt added `src/frontends/tui/input_reader.zig` and wired it to `SessionRuntime.owner_wake`. It was rolled back because the TUI could freeze immediately: input bytes were queued but the owner could be waiting on a different path or an idle timeout. The next implementation must introduce a frontend-owned combined wake before moving reads off the owner loop.
