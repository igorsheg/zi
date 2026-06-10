# zio runtime baseline

status: accepted baseline

date: 2026-06-01

## decision

Zi vendors `lalinsky/zio` as the runtime substrate for concurrent work while
keeping Zi product ownership at the existing owner drain sites. zio is the
mechanism for tasks, channels, timed waits, pipe reads, process wait, and
selectable completion. It is not app policy.

## baseline

The current Zi runtime surface is intentionally small:

- `runtime.runProcess`
- `runtime.CancelSource` / `runtime.CancelToken`
- `runtime.EventPipe`
- `runtime.BoundedQueue`
- `runtime.ByteBuilder`
- `runtime.JsonOwned`
- `runtime.OperationIdAllocator`
- `runtime.Process`

`runtime.CompletionQueue` and `runtime.TaskGroup` were removed because their
real use belonged to product owners.

`ai.provider_stream_stepper` was also removed after audit. It had no production
owner and only tested itself, so keeping it would preserve a speculative
producer/consumer primitive instead of forcing the next real fan-in boundary to
declare its owner, queue bound, and terminal behavior.

## runtime gate

Zi vendors zio under `vendor/zio` and uses the normal project gates for the
runtime path:

```sh
zig build test
ziglint src/coding_agent src/runtime src/agent src/ai
zig build
```

The production tests exercise:

- `zio.Runtime`
- `zio.Channel`
- a zio-native shell command runner using child process wait, zio pipe reads,
  bounded output buffers, timeout, external cancel, kill, and reader draining

This keeps zio coverage attached to the production primitives instead of a
separate spike executable.

## current finding

The first real bash/process comparison split into two paths:

- `std.process.run` through `runtime.io()` currently reports `error.WouldBlock`
  while reading child stdout pipes.
- A zio-native runner around `std.process.spawn`, `child.wait(runtime.io())`,
  `zio.Pipe.read`, zio task handles, and `zio.select` passes echo,
  output limit, timeout/kill, and external cancellation checks.

That is useful evidence: zio is not a drop-in replacement for Zi's bash tool
through the `std.Io` process path. The likely pressure point is zio's current
process spawn implementation, which delegates spawn to `std.Io.Threaded`, marks
child pipes nonblocking, and then relies on zio's `std.Io` file-read path to
consume those pipes.

The native path became the production path because it gives the bash tool the
primitives Zi actually needs:

- process wait is an OS-backed zio completion, not sleep polling;
- stdout and stderr drain concurrently through zio pipe operations;
- timeout and external cancellation are explicit and owned by the process runner;
- output-limit overflow is a selectable completion that kills and drains the
  child immediately;
- non-BrokenPipe reader faults are also selectable completions, so output
  collection errors do not wait behind a still-running child;
- cancellation intent is distinct from process death and reader drain;
- output memory has caller-supplied byte bounds.

The second real pressure point was the agent loop's parallel tool worker path.
That path previously used a `std.Io.Group` plus `std.Io.Queue` as a bounded
multi-producer event handoff. It now uses zio task handles and
`zio.Channel(ToolWorkerEvent)`:

```text
prepared tool call
  -> zio task
  -> fixed zio task handles
  -> bounded zio channel
  -> agent loop owner drain
  -> source-order finalization
```

This keeps a Zi-owned worker group because `zio.Group` reports aggregate
completion/failure, while the agent loop needs one source-indexed result slot
per prepared tool call. The zio primitives still do the concurrency work:
bounded task handles run workers, and a bounded channel carries live updates and
completion data back to the owner. The channel capacity is explicit:

```text
max_tool_calls_per_turn + max_tool_updates_per_batch
```

and the owner still owns all transcript mutation. A focused test now proves
that tool update spam stops at `max_tool_updates_per_batch` before the worker
result is completed.

`runtime.EventPipe` is now the same pattern: a Zi semantic wrapper over
`zio.Channel(Event)`. The wrapper keeps the terminal-result invariant while zio
owns bounded producer/consumer wakeup and graceful drain.

`runtime.CancelSource` is also zio-backed now. It keeps Zi's generation and
stale-token semantics while using `zio.ResetEvent` for broadcast wakeup. This is
stronger than `zio.Notify`, which is stateless and loses signals when no task is
waiting. Its public API no longer carries dummy `std.Io` parameters from the
old queue-backed implementation: owners call `request()`, tokens call `wait()`,
and retry sleeps call `sleepUntilCancel(zio_runtime, ...)`. Cancelable sleeps now
use `zio.ResetEvent.timedWait` directly, so the timeout path is one zio timed
wait instead of two spawned tasks plus a select.

The process runner now has direct runtime-level coverage, not only bash-tool
coverage:

- interleaved stdout/stderr drain concurrently and preserve each stream.
- stderr byte limits return `error.StreamTooLong`.
- exact stdout/stderr byte limits are accepted without off-by-one truncation.
- a quiet output stream drains EOF after child exit while the other stream has
  data.
- stderr-only output drains EOF after child exit while stdout stays quiet.
- larger stdout/stderr streams drain without truncation inside explicit byte
  bounds.
- infinite stdout is stopped by the output-bound completion, not by voluntary
  child exit.
- output allocation failure wakes the owner, kills the child, and returns the
  allocation error instead of waiting for timeout.
- timeout wins while stdout is flowing and terminates the child through the
  single process-wait owner.
- timeout escalates from TERM to KILL after a bounded grace period and kills the
  POSIX process group, so stubborn descendants do not survive the tool call.
- external cancellation terminates the child through the same single-wait-owner
  path.
- spawn failure returns before result ownership exists.

The OAuth callback/manual input race now has local zio coverage:

- manual input can win and shuts down the callback waiter.
- manual input can also win with an unavailable/error result while still
  shutting down the callback waiter.
- callback input can win while manual input is suspended.
- loser task results are canceled/drained through the owner path.

Agent stream producers now have direct zio ownership coverage:

- live prompt runs use an explicit 64-event bounded stream buffer.
- producer success closes `runtime.EventPipe` with a bounded `agent_end` marker.
- producer failure aborts the pipe and leaves no terminal result.
- canceling a producer blocked on bounded event-pipe backpressure drains the
  zio task before stream deinit.
- canceling a producer while it is inside a tool cancellation point drains as
  `error.Canceled` instead of completing as a synthetic tool result.

The TUI idle path no longer sleeps for 16 ms when there is no work. It blocks on
the terminal queue and then drains terminal and host events from the single owner
site after wake. The active-run path now has a zio-native prompt-progress
primitive: the stream channel is selectable, and `AgentSession` applies the
selected event from the owner instead of letting the producer mutate session
state. TUI can race terminal queue wake against prompt stream progress while
keeping all session mutation in the TUI owner.

The terminal wake path now uses one bounded bridge task instead of spawning a
one-shot task per active-run tick:

```text
libvaxis input thread
  -> vaxis queue
  -> Zi terminal bridge task
  -> bounded zio.Channel(tui.terminal.Event)
  -> TUI owner drain/apply
```

This still leaves libvaxis's internal queue in the stack, but it removes
per-wait task churn and gives Zi a zio-selectable terminal event source with
bounded backpressure. The bridge is initialized in place before the pump task is
spawned; the pump must never hold a pointer into a returned-by-value temporary.

Runtime and agent tests now use `zio.ResetEvent` for owned readiness handshakes
where the test owns the worker entry point. This removes scheduler-delay polling
from the cancel-source, event-pipe, and tool-cancellation tests. Bash/host
cancellation now waits for an owner-visible `tool_execution_start` event instead
of assuming scheduler timing.

`agent.Agent` and the agent loop now require an explicit runtime. Public
agent/session signatures name Zi's `runtime.Runtime` boundary, while internal
agent-loop task orchestration uses zio handles and channels directly. A valid
agent can no longer be constructed and then fail later with
`error.ConcurrencyUnavailable` when parallel tool execution needs to spawn zio
tasks. `AgentSession` and `AgentSessionRuntimeHost` now also require an explicit
runtime. Runtime ownership lives at `main`/`RuntimeServices` or at the direct
test owner; session construction no longer has a hidden fallback allocation path.
Production CLI and TUI paths pass the process-owned runtime into SDK-created
`RuntimeServices`, which borrows it and derives service I/O from the same
runtime. Standalone service owners still create exactly one zio runtime when no
process runtime exists. Host/session creation no longer accepts a second
`std.Io` handle that can drift from the runtime owner.

Provider stream requests now carry the same explicit `*runtime.Runtime`. Faux
provider delay simulation and Codex retry backoff no longer reach for ambient
spawn/sleep helpers; the runtime comes from the session/agent owner through
`ai.StreamRequest`. Tests construct real zio-backed runtimes for stream requests
instead of using dummy runtime fields, so the provider boundary matches
production ownership even when a particular test path does not sleep.
Test setup intentionally keeps runtime creation and `deinit()` local to each
test unless a narrower owner object already exists. Repetition is acceptable
here because it makes runtime ownership and lifetime visible; do not replace it
with a hidden shared test runtime.

Tool execution now carries the explicit runtime through
`agent.ExecuteToolHook` as `agent.ToolRuntime`. This lets product tools use zio
primitives without recovering a runtime from `std.Io` or relying on ambient task
state, while tools that do not use runtime primitives avoid importing zio just
to satisfy the hook signature. The bash tool passes that runtime into
`runtime.runProcess`; the process runner spawns child wait, timeout, cancel,
stdout, and stderr tasks from the same runtime and no longer creates a fake
long-sleep cancel branch when no cancel token exists.

The CLI process boundary now stores both `std.Io` and the owning
`*runtime.Runtime`. OAuth login receives that runtime explicitly, so the
callback/manual-code race uses runtime-owned zio tasks instead of standalone
`zio.spawn`.

Sleep-based test synchronization was removed from the agent event-pipe
cancellation test and the runtime-host bash cancellation test. The first now
uses the bounded queue state itself: draining the first event proves the
producer reached the pipe. The second waits for the public `tool_execution_start`
event with bounded cooperative yields before canceling, so the test observes an
owner-visible readiness signal instead of assuming scheduler timing.

## retained zio primitives

- `ProcessWait` plus `Pipe` for the bash tool.
- zio task handles plus `zio.select` for first-completion-wins owner control.
- `Group` for scoped child tasks, with care: it records failure but does not
  return each child task's error to the owner.
- `Channel(T)` for bounded in-runtime handoff where the owner drains state.
- `CompletionQueue` only if Zi needs dynamic fan-in of heterogeneous zio
  completions. Do not reintroduce it as an app event queue.

## remaining hardening

The remaining work is not to decide whether zio is viable. The remaining work is
to keep replacing old timing and handoff patterns with owner-visible zio-backed
primitives:

1. add child-exits-while-reader-blocked cases around
   `runtime.runProcess`;
2. stress the OAuth callback/manual race with a real blocking terminal stdin,
   not only suspended test callbacks.
3. decide whether to keep the bounded terminal bridge around libvaxis or replace
   the substrate input reader itself with a zio-native terminal source.
4. continue replacing integration sleeps with owner-visible readiness signals
   where the product API can expose them without test-only hooks.

Keep zio only where it deletes more Zi-owned runtime machinery than it adds, and
where ownership/cancellation paths become clearer.
