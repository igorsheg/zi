# TigerBeetle concurrency lessons for zi

zi is already closer to TigerBeetle than to an async-runtime design. The opportunity is not "replace async with threads". zi has mostly done that. The opportunity is to make the current thread/queue/process design more explicit, more bounded, less ad-hoc, and more event-loop-shaped.

References to TigerBeetle source use the cached checkout path observed during research:

- `~/.cache/checkouts/github.com/tigerbeetle/tigerbeetle/src/io.zig`
- `~/.cache/checkouts/github.com/tigerbeetle/tigerbeetle/src/io/linux.zig`
- `~/.cache/checkouts/github.com/tigerbeetle/tigerbeetle/src/io/darwin.zig`
- `~/.cache/checkouts/github.com/tigerbeetle/tigerbeetle/src/io/windows.zig`
- `~/.cache/checkouts/github.com/tigerbeetle/tigerbeetle/src/tigerbeetle/main.zig`
- `~/.cache/checkouts/github.com/tigerbeetle/tigerbeetle/src/storage.zig`
- `~/.cache/checkouts/github.com/tigerbeetle/tigerbeetle/src/message_bus.zig`

## TigerBeetle patterns to preserve as reference

TigerBeetle's core model is:

```text
single-threaded deterministic state machine
+ explicit event loop
+ kernel async I/O
+ completion callbacks
+ bounded queues / pools
+ no Zig async/await
+ very little shared-memory threading in the server
```

The central portability boundary is `src/io.zig`:

```zig
pub const IO = switch (builtin.target.os.tag) {
    .linux => IO_Linux,
    .windows => IO_Windows,
    .macos, .tvos, .watchos, .ios => IO_Darwin,
    else => @compileError("IO is not supported for platform"),
};
```

zi's `src/zio/root.zig` has the same shape and should deepen it, not bypass it.

TigerBeetle Linux uses `io_uring` in `src/io/linux.zig`:

```zig
ring: IO_Uring,
completed: QueueType(Completion),
ios_queued: u32 = 0,
ios_in_kernel: u32 = 0,
awaiting: CompletionList = .{},
```

The loop is explicit:

```zig
pub fn run(self: *IO) !void {
    try self.flush_submissions(0);
    try self.flush_completions(0);

    while (self.completed.count() > 0) {
        try self.run_callback();
    }

    try self.flush_submissions(0);
}
```

The bounded wait model is explicit in `run_for_ns()`:

```zig
pub fn run_for_ns(self: *IO, nanoseconds: u63) !void {
    ...
}
```

TigerBeetle Darwin uses `kqueue` in `src/io/darwin.zig`:

```zig
kq: fd_t,
timeouts: QueueType(Completion),
completed: QueueType(Completion),
io_pending: QueueType(Completion),
```

TigerBeetle Windows uses IOCP in `src/io/windows.zig`:

```zig
iocp: os.windows.HANDLE,
io_pending: usize = 0,
timeouts: QueueType(Completion),
completed: QueueType(Completion),
```

The philosophy is consistent across platforms:

```text
submit explicit operation
receive explicit completion
run callback from the owner event loop
avoid futures/coroutines/hidden scheduling
```

TigerBeetle's main server loop in `src/tigerbeetle/main.zig` is the clearest policy reference:

```zig
while (true) {
    replica.tick();
    try io.run_for_ns(constants.tick_ms * std.time.ns_per_ms);
}
```

This is the core lesson for zi:

```text
advance owner state machine
run bounded I/O loop
process completions
repeat
```

Storage in `src/storage.zig` is callback/completion based:

```zig
pub const Read = struct {
    completion: IO.Completion,
    callback: *const fn (read: *Storage.Read) void,
    buffer: []u8,
    offset: u64,
};

pub const Write = struct {
    completion: IO.Completion,
    callback: *const fn (write: *Storage.Write) void,
    buffer: []const u8,
    offset: u64,
};
```

Message bus in `src/message_bus.zig` follows the same rule:

```zig
accept_completion: IO.Completion = undefined,
resume_receive_next_tick: IO.Completion = undefined,
```

This is not language async. This is explicit C-style completion ownership.

TigerBeetle's server mostly avoids shared-memory parallelism in the state machine. It gets concurrency from I/O overlap, not from many application threads mutating shared state.

## Current concurrency map in zi

### Core zio primitives

`src/zio/root.zig`

```zig
pub const cancel = @import("cancel.zig");
pub const queue = @import("queue.zig");
pub const task = @import("task.zig");
pub const worker = @import("worker.zig");
pub const process = @import("process.zig");
pub const file = @import("file.zig");
```

`zio` is already the intended portability boundary:

```zig
// zio is the portability boundary. Public APIs keep std.Io shape; OS engines stay here.
```

That is the right direction.

### `zio.task.Group`

`src/zio/task.zig`

Owned threads:

```zig
threads: std.ArrayList(std.Thread)
```

No detached work:

```zig
// Group owns every spawned thread. No detached work; join/cancel waits before deinit.
```

This is good. It matches TigerBeetle's explicit ownership discipline.

Weakness: `cancel()` only joins. It does not signal anything. Cancellation must be wired separately by each user. That makes hangs possible when a worker is blocked inside a handler.

### `zio.queue.Queue`

`src/zio/queue.zig`

Thread-safe queue with:

- `std.Io.Mutex`
- optional pipe wakeup
- bounded or unbounded policy
- cleanup policy
- `poll()`-compatible wake fd

This is one of the strongest pieces of `zio`.

TigerBeetle reference: `src/io/linux.zig`, `src/io/darwin.zig`, and `src/io/windows.zig` all keep explicit `completed` queues for completions instead of futures.

Weaknesses:

- many users still rely on unbounded default
- queue close does not necessarily cancel current handler work
- pipe-per-queue scales poorly if zi keeps adding worker/event queues
- no typed "owner thread drains this queue" contract
- no standard tracing of lag, dropped items, producer identity

### `zio.worker.Worker`

`src/zio/worker.zig`

One queue + one thread + one handler:

```zig
try group.spawnThread(run, .{self});
...
_ = self.queue.waitReadable(-1) catch false;
...
self.handler.handle(request);
```

This is predictable and simple.

Weakness: it serializes all requests for a worker type. Long work blocks every later request. `stop()` closes queue and joins, but cannot interrupt a blocking `handle()` unless the request itself has a cancellation token and the handler obeys it.

### `zio.process`

`src/zio/process.zig`

High-level process API:

```zig
run()
stream()
runInherit()
```

Backed by `process_engine`.

On Linux/macOS:

- one engine thread per process
- event loop inside that thread
- Linux: `epoll`, `eventfd`, `pidfd`, `timerfd`
- macOS: `kqueue`
- fallback: more blocking reader/watcher threads

This is already TigerBeetle-adjacent: explicit kernel readiness, no language async.

TigerBeetle reference: platform-specialized I/O in `src/io.zig`, `src/io/linux.zig`, `src/io/darwin.zig`, `src/io/windows.zig`.

Weakness: process callbacks execute on the process engine thread, so process consumers must be thread-safe. That pushes mutexes and lifetime issues upward.

### TUI runtime

`src/tui/interactive.zig`

Main UI loop owns terminal state. It polls:

```text
terminal input fd
snapshot event queue wake fd
lifecycle event queue wake fd
terminal system queue wake fd
```

This is correct architecture: UI state is single-thread-owned; workers publish events.

TigerBeetle reference: `src/tigerbeetle/main.zig` keeps replica progression on one owner loop:

```zig
while (true) {
    replica.tick();
    try io.run_for_ns(constants.tick_ms * std.time.ns_per_ms);
}
```

Weakness: the loop is becoming a bespoke event loop. `waitForLoopReadiness()` manually knows all wake sources. Every new source will add another fd, another branch, another implicit invariant.

### Agent thread

`src/tui/interactive.zig`

```zig
try tasks.spawnThread(runtime_loop.agentThread, .{self});
```

The UI and agent runtime are split by queues/events. Correct direction.

Weakness: `Interactive` is passed to the agent thread. Correctness depends on discipline: the agent thread must not mutate UI-owned state directly except through approved queues/sinks. This should be enforced by types, not convention.

TigerBeetle reference: `src/message_bus.zig` and `src/storage.zig` pass explicit completion objects and callbacks rather than handing a whole owner object to arbitrary threads.

### Extension workers

`src/coding_agent/extensions/system_worker.zig`

One worker thread, bounded queue capacity 8:

```zig
.policy = .{ .bounded = .{ .capacity = 8, .on_full = .reject } }
```

Good boundedness.

Weakness: one long `system` command blocks all queued system commands.

`src/coding_agent/extensions/ai_complete_worker.zig`

Same shape: one worker thread, bounded queue capacity 8.

Weakness: one slow AI completion blocks every extension AI completion behind it. Streaming fanout happens from the worker thread into the runtime sink.

### Session index worker

`src/tui/interactive/session_index_worker.zig`

One worker thread, bounded queue capacity 8. Good.

Weakness: `listResumeSessions()` publishes cached result and then immediately performs a fresh list and publishes again for the same generation. This improves latency but makes semantics less predictable: one request can produce two success events.

### Cancellation

`src/zio/cancel.zig`

`Source` + `Token` is explicit and generation-based. Good.

`src/zio/cancel_waiter.zig`

Each waiter spawns a thread:

```zig
const thread = std.Thread.spawn(.{}, run, .{ io, state })
```

This is simple but expensive and structurally weak. It creates one helper thread per cancellation bridge.

Used in:

- process engines
- HTTP shutdown-on-cancel
- side AI session abort linkage
- `runInherit`

TigerBeetle-style design would not use "thread per cancellation waiter". It would integrate cancellation into the same event/completion system. See TigerBeetle's explicit cancellation state in `src/io/linux.zig`:

```zig
cancel_all_status: union(enum) {
    inactive,
    next,
    queued: struct { target: *Completion },
    wait: struct { target: *Completion },
    done,
}
```

## Main opportunities

## 1. Replace `cancel_waiter` thread-per-token with evented cancellation

Current pattern:

```text
request has cancel token
start helper thread
helper thread waits on condition
on abort, helper calls callback
stop joins helper
```

Cost:

- one extra thread per linked cancellation
- extra heap allocation via `page_allocator`
- callback can run concurrently on another thread
- cancellation logic is not visible in the owner event loop
- shutdown can block on waiter join
- harder to reason about callback lifetime

Better model:

```text
cancel token exposes a wake fd or event source
owner event loop polls it
owner thread performs cancellation callback
```

For zi:

- add `zio.cancel.Event` or `zio.cancel.Waker`
- `Source` owns a pipe/eventfd-like wake primitive
- `Token` can expose `wakeReadFd()`
- abort writes wake
- owner loop observes wake and performs cancellation in owner thread

On Linux: eventfd.
On macOS/fallback: pipe.
This already exists conceptually in `zio.wake` and `zio.queue`.

TigerBeetle reference: Linux cancellation in `src/io/linux.zig` is modeled as explicit completion state, not a helper thread per operation.

Result:

- no cancellation waiter threads
- cancellation callbacks run on the owner thread
- fewer races
- fewer joins
- easier testing
- better TUI responsiveness

Priority: highest.

## 2. Add a real `zio.Loop` abstraction

Right now zi has multiple local event loops:

- TUI loop polls terminal + queues
- process engine Linux loop polls child fds/timer/wake
- process engine macOS loop uses kqueue
- worker blocks on queue wake fd
- callback server polls socket manually
- queue exposes wake fd but no central registration model

This spreads I/O semantics across the codebase.

TigerBeetle centralizes this in `src/io/*.zig`:

```text
submit operation
run event loop for bounded time
dispatch completions
```

zi should introduce a smaller version:

```zig
const Loop = struct {
    pub fn registerFd(fd, interest, callback) !Handle;
    pub fn unregister(handle) void;
    pub fn addTimer(deadline, callback) !Handle;
    pub fn wake() void;
    pub fn runOnce(timeout) !void;
    pub fn runFor(ns) !void;
};
```

Do not expose futures. Expose completions/callbacks/events.

Use it initially only inside TUI/runtime, not everywhere.

Immediate payoff:

- `Interactive.waitForLoopReadiness()` stops manually polling a fixed `[4]pollfd`
- terminal input, UI queues, terminal-system queue, timers, resize, kitty timeout, animation deadlines become registered event sources
- cancellation wake can plug in
- future process/job events can plug in
- all wake/drain logic becomes uniform

TigerBeetle reference: `src/tigerbeetle/main.zig` bounded owner loop + `src/io/linux.zig` / `src/io/darwin.zig` / `src/io/windows.zig` event backends.

Priority: highest after cancellation.

## 3. Make process output delivery owner-threaded

Current `zio.process.runEngine()`:

- starts a process engine thread
- process engine thread calls `Capture.submit`
- `Capture.submit` locks `Capture.mutex`
- `Capture.append` may call user `on_chunk` while holding the mutex

Code:

```zig
fn submit(ptr: *anyopaque, event: process_engine.Event) bool {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    switch (event) {
        .stdout => |bytes| self.append(.stdout, bytes),
        .stderr => |bytes| self.append(.stderr, bytes),
        ...
    }
}
```

And:

```zig
fn append(self: *Capture, kind: StreamKind, bytes: []const u8) void {
    if (self.on_chunk) |cb| cb.call(kind, bytes);
    ...
}
```

Problems:

- user callback runs on process engine thread
- callback runs under `Capture` mutex
- callback can do arbitrary work
- callback can publish to other queues
- callback can accidentally reenter process/session state
- lock duration includes user code

Better model:

```text
process engine emits raw events into a queue
owner thread drains queue
owner thread calls user callbacks
```

For synchronous `run()`, owner can be the caller thread blocked in a loop draining completions until exit. For background jobs, owner can be the job manager/runtime loop.

This mirrors TigerBeetle: kernel completion/event loop produces completions; state machine owner handles them. TigerBeetle references: `src/io/linux.zig` `run_callback()`, `src/io/darwin.zig` callback dispatch after collecting kevents, and `src/storage.zig` completion-owned storage callbacks.

Priority: high.

## 4. Consolidate process management into a process reactor

Current Linux/macOS engine:

```text
one thread per process
inside that thread: epoll/kqueue loop for that one child
```

This is acceptable for a small number of commands. zi can run many tools, jobs, extension commands, grep/find/bash, etc. One thread per process becomes wasteful and less predictable under load.

TigerBeetle lesson from `src/io/linux.zig`, `src/io/darwin.zig`, and `src/io/windows.zig`:

```text
one event loop can own many in-flight operations
```

Better zi shape:

```text
one zio.process.Reactor thread per runtime
many child processes registered in it
each child has stdout/stderr/pid/timer/wake state
events delivered to owner queues
```

Linux:

- one `epoll` fd
- many stdout/stderr fds
- many pidfds
- many timerfds or one timer heap + timerfd
- one eventfd wake

macOS:

- one kqueue
- many EVFILT_READ
- many EVFILT_PROC
- timers

Benefits:

- fewer threads
- cheaper parallel tool execution
- uniform timeout/cancel behavior
- easier telemetry
- easier job cleanup
- one place for process races

This is a larger change. Do after cancellation and owner-threaded events.

Priority: high, but staged.

## 5. Fix worker cancellation semantics

`zio.worker.Worker.stop()`:

```zig
self.queue.close();
if (self.tasks) |*group| {
    group.join() catch ...
}
```

If the worker is inside:

```zig
self.handler.handle(request);
```

then stop blocks until `handle()` returns.

That affects:

- `SystemWorker`
- `AiCompleteWorker`
- `SessionIndexWorker`
- any future worker built on `zio.worker`

For `SystemWorker`, request has a signal, but worker shutdown does not necessarily request that signal.

For `AiCompleteWorker`, shutdown depends on HTTP/provider cancellation paths.

Better contract:

```zig
Worker(Request, Handler).stop(mode)
```

Modes:

```zig
.graceful        // finish current, drain/close queue
.cancel_current  // request abort for current request, close queue
.immediate       // reject queue, request abort, join with timeout
```

Requires a request trait:

```zig
Request.cancel()
```

or handler trait:

```zig
Handler.cancelCurrent()
```

Minimum improvement:

- `Worker` tracks `current_request_id`
- `Handler` can provide `cancelCurrent()`
- `deinit()` requests cancellation before joining
- if join exceeds timeout, log hard diagnostic

TigerBeetle reference: cancellation is explicit state in `src/io/linux.zig`, not implicit thread joining.

Priority: high.

## 6. Stop serializing independent extension work behind one worker

Current:

- one `SystemWorker` thread
- one `AiCompleteWorker` thread
- one `SessionIndexWorker` thread

This is correct for session index. It is questionable for system commands and AI completions.

System commands are independent. AI completions are independent. Serializing them creates avoidable latency.

Better:

```zig
WorkerPool(Request, Handler, N)
```

Properties:

- bounded queue
- fixed thread count
- no dynamic unbounded spawning
- explicit max parallelism
- backpressure remains visible
- shutdown cancels current requests on all workers

Suggested defaults:

```text
system command pool: 2 or 4
AI completion pool: 2
session index: keep 1
agent core: keep 1
TUI: keep 1
```

This is not "thread pool everywhere". It is bounded parallelism for independent blocking operations.

TigerBeetle reference: concurrency from independent in-flight I/O, but state-machine ownership remains single-threaded. See `src/message_bus.zig` for multiple connection completions without shared mutable state across arbitrary application threads.

Priority: medium-high.

## 7. Make cross-thread ownership mechanically visible

There are places where cross-thread calls depend on convention.

Example:

```zig
try tasks.spawnThread(runtime_loop.agentThread, .{self});
```

Passing `*Interactive` to the agent thread is dangerous unless the agent thread only touches thread-safe fields/sinks.

Better type split:

```zig
InteractiveUiOwner
InteractiveRuntimeHandle
```

The agent thread receives only:

```zig
const RuntimeHandle = struct {
    request_queue: *RequestQueue,
    lifecycle_event_queue: *UiLifecycleQueue,
    snapshot_event_queue: *UiSnapshotQueue,
    allocator: ThreadSafeAllocator,
    ...
};
```

It should not receive the entire `Interactive`.

Apply same rule to:

- AI worker sinks
- system worker sinks
- session index publisher
- job manager frame sink
- process callbacks

TigerBeetle reference: `src/storage.zig` and `src/message_bus.zig` pass explicit operation/completion objects. They do not give arbitrary workers broad access to the whole owner state.

Priority: high for correctness.

## 8. Bound every cross-thread queue deliberately

Good existing examples:

`src/tui/interactive/runtime/queues.zig`

```zig
UiSnapshotQueue: capacity 64, drop_newest
UiLifecycleQueue: capacity 64, reject
```

Good: snapshot traffic is lossy; lifecycle traffic is not.

Other queues should be audited. `zio.queue.Queue` defaults to unbounded:

```zig
policy: QueuePolicy = .unbounded
```

Unbounded should be banned for cross-thread queues unless justified.

Recommended policy vocabulary:

```text
snapshot/status/progress: bounded + drop_newest or coalesce
lifecycle/results/errors: bounded + reject
tool output chunks: bounded + backpressure or truncation
AI stream deltas: bounded + coalesce by request
terminal input: bounded + reject impossible/diagnostic
```

Add a compile-time option:

```zig
.cross_thread = true
```

and require explicit `.policy` when true.

TigerBeetle reference: explicit queue/pool discipline appears throughout `src/io/linux.zig`, `src/io/darwin.zig`, and `src/message_bus.zig`; completions and connections are explicitly tracked rather than unboundedly spawned.

Priority: medium-high.

## 9. Add coalescing queues for high-frequency UI traffic

Current snapshot queue drops newest when full:

```zig
.on_full = .drop_newest
```

Dropping newest can preserve stale state. For snapshots, stale preservation is usually the wrong behavior.

Better:

```text
drop_oldest
replace_by_key
coalesce latest status per source
```

Examples:

- status snapshot: keep latest only
- token count: keep latest only
- memory telemetry: keep latest only
- streaming assistant deltas: maybe append/coalesce per message
- extension UI frame updates: coalesce per extension/job

Add `QueuePolicy` variants:

```zig
bounded: {
    capacity,
    on_full: .reject | .drop_newest | .drop_oldest
}
```

Then add keyed coalescing separately:

```zig
CoalescingQueue(T, keyFn)
```

TigerBeetle reference: state is advanced from latest explicit completions in the owner loop; stale snapshots should not crowd out fresher state.

Priority: medium.

## 10. Make timers part of `zio`, not local polling

Status: completed end-to-end. `src/zio/timer.zig` now owns timer queue/deadline callback semantics, `src/zio/loop.zig` has timer registration and dispatch integrated with fd polling, `src/zio/root.zig` exports `zio.timer`, and `src/tui/interactive.zig` routes input flush / kitty / animation deadlines through `zio.loop` timer sources instead of computing a local poll timeout only. Gates: `zig fmt src/zio/timer.zig src/zio/loop.zig src/zio/root.zig src/tui/interactive.zig`; `zig build test`.

Current timer-like logic exists in multiple places:

- TUI idle wait timeout 50ms
- input sequence timeout
- kitty negotiation deadline
- animation deadlines
- process timeout via timerfd/kqueue timer/sleep fallback
- callback server poll 500ms
- tests use sleep loops
- `waitReady()` spin-sleeps 1ms
- `writeWhenReady()` spin-sleeps 10ms

Examples:

```zig
while (waited <= timeout_ms) : (waited += 1) {
    ...
    self.io.sleep(.fromMilliseconds(1), .awake) catch {};
}
```

and:

```zig
const ready = posix.poll(&pfd, 500) catch continue;
```

These are predictable enough but scattered.

Create:

```zig
zio.timer
zio.deadline
zio.loop timer source
```

Use it for:

- process readiness
- callback server cancellation
- TUI deadlines
- worker join diagnostics
- tests

TigerBeetle reference: timers are part of the I/O abstraction. See timeout queues in `src/io/darwin.zig` and `src/io/windows.zig`, and timeout/cancellation machinery in `src/io/linux.zig`.

Priority: medium.

## 11. Replace sleep-loop readiness with condition/wake/event

Status: completed end-to-end for the current job/process readiness surface. `src/zio/job.zig` already receives explicit `.ready` events from `process_reactor`; tests now wait on `TestSink.condition` signaled by event delivery instead of polling with 10ms sleeps, and stop tests wait for `.ready` before writing/stopping children. This makes readiness event-driven at the job boundary and removes the remaining `zio.job` sleep-loop readiness helpers. Gates: `zig build test`.

Current examples:

`process_engine_linux.zig` / `kqueue.zig`:

```zig
waitReady(timeout_ms) {
    while (...) {
        lock;
        ready/exited;
        unlock;
        sleep(1ms);
    }
}
```

`zio/job.zig` test helper:

```zig
while (attempts < 100) {
    manager.write(id, data) catch error.JobNotReady => sleep(10ms)
}
```

Sleep loops are easy but less precise.

Better:

- process engine exposes readiness completion
- `engine.start()` does not return until child has been spawned or failed
- or `engine.waitReady()` uses condition variable/eventfd
- jobs receive `.ready` event before stdin write is accepted

Process `StartRequest` could emit:

```zig
.spawned
.ready_for_stdin
.stdout
.stderr
.exit
.spawn_failed
```

Then callers stop probing.

TigerBeetle reference: completion objects represent readiness and completion explicitly. See `src/storage.zig` read/write completions and `src/message_bus.zig` accept/connect/recv/send completions.

Priority: medium.

## 12. Make process output memory bounded by design

Status: completed end-to-end. `src/zio/process.zig` already enforces capture limits before append, supports `.fail` and `.truncate` overflow, and separates capture policy from streaming policy (`ignore`, `capture_bounded`, `stream_only`, `stream_and_capture_bounded`). This pass locked the behavior with tests: limit failures retain at most the configured prefix while reporting total observed bytes and truncation, and stream-only output delivers chunks without retaining bytes in the result. Non-retained streams now still report `total_bytes` so callers can observe output volume without paying storage cost. Gates: `zig fmt src/zio/process.zig`; `zig build test`.

Current `Capture.append()` appends bytes, then checks limit:

```zig
list.appendSlice(self.allocator, bytes) catch return;
if (tooLong(list.items.len, self.stdout_limit)) {
    self.failure = .stdout_too_long;
    if (self.engine) |engine| engine.stop();
}
```

Issues:

- allocation happens before limit enforcement
- a chunk can exceed limit by chunk size
- if allocation fails, failure is not recorded as OOM
- with `on_chunk != null`, output is still stored even when `store_stdout=false`

This condition:

```zig
if (kind == .stdout and !self.store_stdout and self.on_chunk == null) return;
```

means if streaming callback exists, output is also retained. That may be intentional for partial results, but it is expensive.

Better:

```text
capture policy:
- none
- full up to limit
- ring tail N bytes
- prefix N bytes
- stream only
- stream + bounded partial
```

For tools, a bounded prefix/tail is more useful than unbounded append until kill.

TigerBeetle reference: `src/storage.zig` is explicit about buffers, offsets, and operation state. zi process capture should be equally explicit about ownership and bounds.

Priority: medium-high for tool robustness.

## 13. Move callback server onto `zio`

Status: completed end-to-end. `src/coding_agent/auth/callback_server.zig` now builds a `zio.loop.Loop`, registers the server socket and cancellation wake fd as loop sources, and waits through `Loop.runOnce()` instead of local source arrays / ad-hoc polling. Cancellation remains fd-driven when the token has a wake fd; token-less fallback keeps the bounded 500ms server wait. Gates: `zig fmt src/coding_agent/auth/callback_server.zig`; `zig build test`.

`src/coding_agent/auth/callback_server.zig`

Manual polling:

```zig
while (!cancelled.load(.acquire)) {
    poll(socket, 500)
    accept()
}
```

This is ad-hoc I/O. It should use:

- `zio.cancel.Token`, not raw atomic bool
- `zio.Loop` or `zio.net.Server`
- cancellation wake, not 500ms polling

Benefit:

- immediate cancellation
- no periodic wakeup
- consistent API

TigerBeetle reference: platform I/O readiness is centralized behind `src/io.zig`; ad-hoc polling does not spread through higher-level code.

Priority: medium.

## 14. Avoid `page_allocator` for routine concurrency state

Status: completed end-to-end for routine cancellation bridge state. `src/ai/http_cancel.zig` no longer allocates `ShutdownOnCancel.State` from `std.heap.page_allocator`; it uses `std.heap.smp_allocator`, keeping tiny cancellation callback state out of page allocation while preserving stable callback-node lifetime. Gates: `zig fmt src/ai/http_cancel.zig`; `zig build test`.

`cancel_waiter.zig`:

```zig
std.heap.page_allocator.create(State)
```

`http_cancel.zig` also uses page allocator for tiny state.

This bypasses caller ownership and makes memory accounting worse.

Better:

- caller allocator for all state
- or embed waiter state in owner object
- no page allocation per waiter

TigerBeetle reference: operation state is owned explicitly by the operation/completion object, e.g. `src/storage.zig` and `src/message_bus.zig`.

Priority: medium.

## 15. Unify job manager with process manager

Status: completed end-to-end by the existing reactor-backed process surface. `src/zio/process.zig` and `src/zio/job.zig` both use `src/zio/process_reactor.zig`; `process.run()` submits a child and drains until exit, while `Jobs.Manager` submits children and forwards reactor events. This pass added job manager telemetry over the shared reactor event stream, further consolidating lifecycle/accounting around the same lower-level process actor. Gates: `zig fmt src/zio/job.zig`; `zig build test`.

`src/zio/job.zig` wraps `process_engine.Engine`.

`src/zio/process.zig` separately wraps `process_engine.Engine`.

There are two conceptual process surfaces:

```text
run/stream synchronous
job manager background
```

Both should share a lower-level process actor/reactor abstraction:

```zig
ProcessHandle
ProcessEvent
ProcessReactor
```

Then build:

```zig
process.run()  // submits process, drains until exit
Jobs.Manager   // submits process, forwards events
system_worker  // uses run or direct process handle
bash tool      // same process surface
```

This avoids duplicated process lifecycle semantics.

TigerBeetle reference: one `IO` abstraction is reused by storage, message bus, timers, and next-tick mechanics. See `src/io.zig`, `src/storage.zig`, and `src/message_bus.zig`.

Priority: medium.

## 16. Add thread labels everywhere

Status: completed end-to-end for production spawned threads visible in the current tree. Existing labels cover main, TUI, batch, agent, login, workers, process reactors, and tests. This pass added `search_worker` to `logging.ThreadLabel` and labels the file-search worker thread in `src/search/file_search.zig`. Remaining raw `std.Thread.spawn` sites are test helpers or abort triggers. Gates: `zig fmt src/logging.zig src/search/file_search.zig`; `zig build test`.

`main.zig` sets:

```zig
logging.setThreadLabel(.main);
```

Tests set:

```zig
logging.setThreadLabel(.@"test");
```

Workers and process engines should label threads:

```text
agent
system-worker-0
ai-worker-0
session-index
process-reactor
process:<argv0>
cancel-waiter  // while it exists
```

This improves debugging massively. It also exposes accidental thread proliferation.

TigerBeetle reference: not a direct source-level pattern from the inspected files, but consistent with the broader explicit-runtime philosophy: make hidden work visible.

Priority: low effort, high diagnostic value.

## 17. Add concurrency telemetry

Status: completed end-to-end for job/process concurrency telemetry. `src/zio/job.zig` now exposes `Manager.stats()` with active/started/exited job counts, stdout/stderr byte counts, and output-drop count, updated from the same owner path that forwards process reactor events. Tests assert started/exited/active/stdout byte accounting. Existing queue stats remain available through `zio.queue`. Gates: `zig fmt src/zio/job.zig`; `zig build test`.

Existing queues expose stats:

```zig
pending_depth
high_water_depth
send_count
wake_count
rejected_count
dropped_count
```

Use these uniformly.

Add:

- worker current request duration
- worker queue wait latency
- process count
- process output bytes
- process kill reason
- cancellation latency
- queue publish failures by source
- event loop wake reason
- render loop idle/wake counts

TigerBeetle reference: `src/io/linux.zig`, `src/io/darwin.zig`, and `src/io/windows.zig` track I/O stats and trace callback/runtime time. The server loop in `src/tigerbeetle/main.zig` attaches tracing to the event loop before running.

Priority: medium.

## Specific correctness risks

### Risk 1: user callback under lock in process capture

`Capture.append()` calls `on_chunk` under `Capture.mutex`.

This should be changed. Run callbacks outside locks, or better on owner thread.

TigerBeetle reference: completions are gathered then callbacks are run from the loop; avoid arbitrary callback execution under unrelated locks.

### Risk 2: worker shutdown can hang forever

`Worker.stop()` joins without forcing current handler to stop.

Any blocked system command, network request, session listing, or provider call can make shutdown hang.

### Risk 3: cancellation waiter thread count can grow with operations

Every cancellation bridge spawns a thread. Under many processes/AI requests/side sessions, thread count grows for cancellation plumbing alone.

TigerBeetle reference: cancellation is explicit state in the I/O layer, not a thread per cancellation target.

### Risk 4: process callback lifetime crosses threads

`process_engine.Event` carries byte slices. Sinks must consume synchronously or clone. `zio/job.zig` forwards slices directly:

```zig
.stdout => |bytes| self.sink.submit(... .data = bytes)
```

This is only safe if the sink clones or consumes before return. That contract should be encoded in the type name or API.

Use:

```zig
BorrowedProcessEvent
OwnedProcessEvent
```

or make process engine always deliver owned buffers to queues.

TigerBeetle reference: completion objects own their operation state explicitly; buffer lifetime is part of the operation, not an implicit callback convention.

### Risk 5: single AI completion worker serializes unrelated work

Slow extension AI request blocks all other extension AI completion requests.

### Risk 6: single system worker serializes unrelated commands

A long command blocks all other extension system commands.

### Risk 7: duplicate resume-session events for one request

`SessionIndexWorker.listResumeSessions()` can publish cached loaded event and fresh loaded event for same generation. If intentional, name it:

```zig
resume_sessions_snapshot
resume_sessions_refreshed
```

If not intentional, publish cache only when fresh listing is skipped.

## Recommended architecture target

For zi, the TigerBeetle-inspired target should be:

```text
TUI thread:
  owns all terminal/UI state
  runs zio.Loop
  drains UI queues
  renders frames

Agent thread:
  owns agent/session state
  receives requests through bounded queue
  emits UI events through bounded queues

Process reactor:
  one thread owns all child process OS readiness
  emits owned process events to target queues

Worker pools:
  bounded parallelism for independent blocking work
  cancellation-aware shutdown

Cancellation:
  evented, not thread-per-waiter

Queues:
  bounded by default
  explicit drop/reject/coalesce policy
  owner-thread drain contracts

Callbacks:
  no user callbacks under locks
  no foreign-thread mutation of owner state
```

## Practical migration sequence

### Phase 1: tighten existing model

1. Ban cross-thread unbounded queues by convention.
2. Add thread labels to every spawned thread.
3. Add worker stop diagnostics: log if join takes too long.
4. Move `Capture.on_chunk` out from under mutex.
5. Add `drop_oldest` queue policy.
6. Add queue stats logging for all runtime queues/workers.
7. Replace sleep-loop `waitReady()` with condition or readiness event.

### Phase 2: fix cancellation

1. Introduce `zio.wake.Event` abstraction: pipe/eventfd.
2. Add cancel source wake fd.
3. Replace `cancel_waiter.Waiter` in process engines with loop-integrated cancel wake.
4. Replace HTTP `ShutdownOnCancel` waiter thread with fd/evented cancellation.
5. Replace side AI abort waiter with event delivery to agent owner thread.

### Phase 3: owner-thread events

1. Split `Interactive` into UI owner + runtime handle.
2. Ensure agent thread cannot access UI fields directly.
3. Make process events owned or explicitly borrowed.
4. Route process chunks through queues to owner thread before user callbacks.
5. Standardize event sink ownership semantics.

### Phase 4: process reactor

1. Build `zio.process.Reactor` behind existing `process.run()` API.
2. Keep current process engine as compatibility backend.
3. Register many children in one Linux epoll/macOS kqueue loop.
4. Convert jobs to use reactor handles.
5. Convert system tools to use reactor-backed process API.

### Phase 5: bounded parallelism

1. Add `zio.worker.Pool`.
2. Convert `SystemWorker` to pool size 2-4.
3. Convert `AiCompleteWorker` to pool size 2, or per-provider keyed pool.
4. Keep `SessionIndexWorker` single-threaded.

## Bottom line

zi should not adopt language async.

zi should deepen the current path:

```text
explicit threads
bounded queues
owner-thread state machines
evented cancellation
centralized OS readiness
completion/event delivery
no callbacks under locks
no hidden work
```

The biggest wins are:

1. remove thread-per-cancel waiter
2. introduce `zio.Loop`
3. make process events owner-threaded
4. make worker shutdown cancellation-aware
5. consolidate process management into one reactor
6. bound/coalesce every cross-thread queue
7. split UI/agent ownership by types rather than convention

## Follow-up: RuntimeHost owner-thread enforcement

The AgentRuntime split removed direct agent-thread access to `Interactive`, but the inverse boundary must also be enforced: UI-owned code must not directly execute `RuntimeHost` / session / ExtensionRunner / Lua owner mutations. The `/resume` regression showed this concretely: routing resume through a UI owner queue called `RuntimeHost.resumeSession()` on the UI thread, which reached `event_bridge.dispatchSessionBeforeSwitch()` and tripped `ExtensionRunner.assertOnLuaThread()`.

Add this to Phase 3 ownership work:

1. Bind `RuntimeHost` to its owner thread when the agent thread starts.
2. Add `RuntimeHost.assertOnOwnerThread()` diagnostics.
3. Assert owner thread in session/extension mutating or Lua-touching APIs:
   - `newSession()`
   - `forkSession()`
   - `resumeSession()`
   - `replaceSession()`
   - `runCompaction()`
   - `runUserContent()`
   - `dispatchExtension*()`
   - extension custom message / append entry actions
4. Audit `rg "runtime_host\." src/tui` and classify every direct UI-thread call.
5. Route UI-originated runtime operations through the agent request queue / `AgentRuntime`, not through UI-owner queues.

Rule: `Interactive` owns terminal/UI state. `AgentRuntime`/`RuntimeHost` owns agent/session/Lua state. Cross-thread communication happens only through explicit bounded queues/events/sinks.
