# Runtime zio capability inventory

Status: verified on 2026-07-09 against the `interactive` branch working tree.
This is a living inventory of the zio surface Zi actually depends on. It is
intended to keep zio replaceable and private.

## Boundary rule

Production code must not import `zio` directly. The only source file allowed to
import the module is `src/runtime/zio_backend.zig`, and `zig build test` depends
on `check-zio-imports` to enforce that rule (`build.zig`). All product layers use
`src/runtime/root.zig` and explicit `std.Io` values instead.

```text
product / frontend / agent / ai
        -> src/runtime/root.zig + std.Io
        -> src/runtime/zio_backend.zig
        -> @import("zio")
```

The replacement surface for zio is therefore the runtime package, not every
callsite that currently receives `std.Io`.

## Capabilities in use

### 1. Runtime host and `std.Io` provider

**zio surface:** `zio.Runtime.init`, `Runtime.deinit`, `Runtime.io`.

**Zi wrapper:** `src/runtime/Runtime.zig` exposes `runtime.Runtime.init`,
`deinit`, and `io`.

**Current users:**

- `src/tui/root.zig` creates the interactive task runtime and passes
  `task_runtime.io()` into `RuntimeServices`, `AgentSession`, terminal code, and
  the frame loop.
- `src/cli/root.zig` creates task runtimes for auth and print prompt modes.
- Tests create task runtimes directly for agent, coding-agent, OAuth, tool, and
  runtime behavior.

**Contract:** the runtime owns the backing executor/thread-pool state for the
`std.Io` value. Owners must drain/cancel/settle tasks before `Runtime.deinit`.
Executor loops must outlive late linked-work completion callbacks.

### 2. Concurrent tasks and futures

**zio surface:** zio-backed `std.Io.concurrent`, `std.Io.Future`,
`zio.JoinHandle`, `Runtime.spawn`, and `Runtime.spawnBlocking`.

**Zi wrappers/callers:**

- `runtime.Runtime.Task(T)` wraps `zio.JoinHandle(T)` and exposes `join`,
  `cancel`, `hasResult`, and `getResult`.
- `runtime.Runtime.spawn` is used by tests and support code that needs a typed
  joinable task.
- `runtime.Runtime.spawnBlocking` is used by `src/tui/Loop.zig` for the file
  index build task.
- `std.Io.concurrent(task_runtime.io(), ...)` is used for:
  - agent prompt/continue stream producers (`src/agent/loop.zig`),
  - parallel tool workers (`src/agent/tool_runner.zig`),
  - OAuth callback/manual-code race tasks (`src/ai/utils/oauth/openai_codex.zig`),
  - process wait, stdout/stderr readers, timeout, cancel wait, and grace-kill
    timer (`src/runtime/process_runner.zig`).

**Contract:** cancellation is two phase. A caller may request cancel, but the
owning code must still drain/await/observe terminal completion before freeing
memory visible to the task. Producers do not mutate owner state directly; they
publish into bounded queues/slots and wake the owner.

### 3. Timers and cooperative yielding

**zio surface:** zio-backed `std.Io.sleep` and `zio.yield`.

**Zi wrappers/callers:**

- `runtime.sleep(io, duration)` and `Runtime.sleep` call `io.sleep(duration,
  .awake)`.
- `runtime.sleepUntilCancel` races sleep with a `CancelToken` wake.
- Retry delays, faux-provider streaming delays, print retry delays, TUI panic-test
  delay, tests, and process timeouts use this path.
- `runtime.yield()` wraps `zio.yield()` and is used where an owner/test needs
  cooperative progress without introducing another timing policy.

**Contract:** sleeps are runtime waits, not UI pacing. UI frame cadence remains
owned by the frame loop; producers may sleep only for product policy such as
retry, timeout, faux streaming, or cancellation waits.

### 4. Wake events

**zio surface:** zio-backed `std.Io.Event` through `std.Io`.

**Zi wrapper:** `runtime.WakeEvent` in `src/runtime/wake_event.zig` exposes
`set`, `reset`, `wait`, and `waitTimeout`.

**Current users:**

- TUI and print run handles register one wake on `AgentEventStream`.
- `EventPipe` wakes owners after emit/end/abort.
- `CancelSource` wakes cancellation waiters.
- `process_runner` wakes its owner when process, timeout, cancel, reader, or
  output state changes.
- Tests prove `WakeEvent.set` can be called from a raw `std.Thread` while the
  owner waits on runtime `std.Io`.

**Contract:** wakes are coalesced and payload-free. A wake does not grant mutation
authority and does not carry the changed value. After waking, the owner inspects
its owned state and drains bounded queues/slots.

### 5. Bounded queues and backpressure

**zio surface:** zio-backed `std.Io.Queue` blocking/close/cancel behavior.

**Zi users:**

- `runtime.EventPipe(Event, TerminalResult)` uses `std.Io.Queue` for bounded
  agent event streams.
- `agent.ToolWorkerChannel` uses `std.Io.Queue` for bounded live tool updates and
  worker completion events.
- `runtime.process_runner.OutputChunkQueue` uses `std.Io.Queue` for bounded
  stdout/stderr observer chunks.

**Contract:** queues are bounded and apply backpressure. Owners drain queues;
producers block rather than allocate unbounded memory or drop events. A terminal
result is committed before the terminal event becomes observable.

### 6. Process, pipe, file, and HTTP I/O through `std.Io`

**zio surface:** zio provides the `std.Io` backend used by Zig std APIs.

**Current users:**

- `runtime.runProcess` uses `std.process.spawn(io, ...)`, `child.wait(io)`,
  `std.Io.File.readStreaming`, and file `close(io)` for bash subprocesses.
- The process runner also uses runtime futures for process wait, pipe readers,
  timeout, cancellation, and forced kill after a grace period.
- Provider HTTP streaming uses `std.http.Client{ .io = request.io }`, not
  `zio.net` directly.
- General filesystem and terminal setup code receives explicit `std.Io` from the
  active runtime or process resources.

**Contract:** subprocess output is bounded by configured stdout/stderr byte caps
and by a fixed live observer queue. After process exit, the owner keeps draining
output until both pipe readers have reported completion; only then may it await
readers and return the owned output.

### 7. Mutex for cross-task queue ownership

**zio surface:** `zio.Mutex`.

**Zi wrapper/user:** `runtime.Mutex` aliases `zio.Mutex`. It is currently used by
`agent.Agent.PendingMessageQueue` to protect queued follow-up/user messages across
owner and producer contexts.

**Contract:** this mutex protects small bounded structures only. It must not
become a general product-state lock or a substitute for owner-loop mutation.

### 8. Test-only pipe helpers

**zio surface:** `zio.createPipe` and `zio.Timeout`.

**Zi user:** `src/runtime/fd_readiness.zig` tests create a pipe to verify
`pollReadableFd` behavior.

**Contract:** this is not a product dependency. If zio is replaced, these tests can
move to a std/posix pipe helper without changing runtime product behavior.

## Re-exported but not product dependencies

`src/runtime/zio_backend.zig` currently re-exports more zio names than Zi product
code uses. These names should be treated as removal candidates unless a concrete
runtime owner proves a need:

- `RuntimeOptions`
- `ResetEvent`
- `Waiter`
- `Pipe`
- `ev`
- `Channel`
- `select`
- `getCurrentExecutor`

The import check prevents these from leaking beyond `src/runtime`, but shrinking
this backend surface would make replacement work easier.

## Capabilities not used directly

Zi does not depend directly on these zio APIs today:

- `zio.net` sockets, DNS, UDP, or TCP APIs,
- zio signal handling,
- zio groups as a public abstraction,
- zio channels/select outside unused backend re-exports,
- zio low-level event-loop APIs outside vendor implementation details.

If a future feature wants one of these, add a narrow `src/runtime` abstraction
first and document the owner, bound, shutdown ordering, and replacement surface.

## Replacement checklist

A non-zio backend must provide or preserve:

1. A `std.Io` compatible runtime usable by `std.http.Client`, filesystem, terminal,
   and subprocess APIs.
2. Joinable/cancelable futures for `std.Io.concurrent` callsites.
3. A bounded queue primitive with blocking put/get, close, and cancellation
   semantics compatible with `EventPipe`, tool workers, and process output.
4. A wake event that can be set from runtime tasks and raw `std.Thread`s while an
   owner waits on `std.Io`.
5. Cancellable sleep/timeouts and a cooperative yield point.
6. Safe subprocess wait plus stdout/stderr pipe reads under owner-drained bounded
   output.
7. A small mutex or equivalent for `PendingMessageQueue` only.
8. Shutdown ordering that prevents late completion callbacks from touching freed
   executor, loop, queue, event, or stack state.

Until this checklist is satisfied, replacing zio is riskier than keeping it
private and tightening the `src/runtime` boundary.
