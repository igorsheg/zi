# adr 0001: make concurrency explicit at the runtime boundary

status: accepted

date: 2026-05-28

## context

zi is moving from a mostly synchronous command-line coding agent into a system that needs real concurrency. the first concrete pressure point surfaced in oauth login for `openai-codex`:

```text
auth login owner
  |
  | prints browser url
  v
callback server waits for browser redirect
manual stdin waits for pasted redirect/code
```

in a node/typescript product this is usually hidden behind `Promise.race`, the event loop, libuv, streams, and platform cancellation behavior. in zig, zi must choose where that behavior lives and who owns mutation after an operation completes.

zi already has the start of a runtime vocabulary:

- `src/runtime/operation.zig`: operation ids.
- `src/runtime/bounded_queue.zig`: bounded FIFO for owner-drained event paths.
- `src/runtime/cancel.zig`: wakeable cancel source/token and cancelable sleep races.
- `src/runtime/event_pipe.zig`: queue-backed producer/consumer event pipe.

but zi does not yet have a clear boundary for blocking operations that must run concurrently with owner code. the oauth login bug made this visible: printing the auth URL and prompt without flushing caused the process to appear to do nothing, then fixing the flush exposed the deeper serialization bug: manual input is requested before the callback server waits for the browser redirect.

## decision

zi will make concurrency an explicit runtime boundary instead of importing an ambient scheduler model from pi-mono/node.

all blocking or long-running work must follow this shape:

```text
operation request
  -> backend / worker / std.Io task
  -> bounded completion path
  -> owner drain/apply site
```

workers and backend tasks may block, read, accept, stream, run tools, or perform provider I/O. they must not mutate auth, session, transcript, persistence, or ui state. owners drain completions and perform all product mutation.

for the first implementation, zi will use zig 0.16 `std.Io` primitives before building or copying a custom os backend:

- use `std.Io` concurrency primitives when operations must run concurrently.
- use `std.Io.Select` for race-shaped waits.
- use existing zi operation ids, cancel tokens, and bounded queues where product-level lifecycle needs identity and draining.
- add small zi runtime adapters only where stdlib primitives do not encode product ownership.

zi will not verbatim copy `prise`, `zag`, or `pz` runtime code. instead, zi will adopt the specific lifecycle disciplines that match its invariants.

## core invariant

```text
+--------------------------------------------------------------+
| owner                                                        |
|                                                              |
| auth_mode / AgentSession / agent.Agent / session host         |
|                                                              |
| - drains completions                                         |
| - validates winner                                           |
| - mutates state                                              |
| - persists                                                   |
| - requests cancellation                                      |
| - joins/drains losers                                        |
+-----------------------------^--------------------------------+
                              |
                              | bounded completions / select result
                              |
+-----------------------------+--------------------------------+
| backend / workers                                             |
|                                                              |
| - stdin read                                                  |
| - oauth callback accept/read                                  |
| - provider http/sse stream                                    |
| - tool subprocess/file/network work                           |
| - sleeps/timers                                               |
|                                                              |
| never mutate auth/session/transcript/history/ui directly      |
+--------------------------------------------------------------+
```

## why not copy prise wholesale

`prise` implements a pre-0.16 custom async I/O abstraction:

```text
src/io.zig
  tests -> src/io/mock.zig
  linux -> src/io/io_uring.zig
  macos -> src/io/kqueue.zig

public shape:
  Loop
  Task { id, ctx }
  Context { ptr, msg, cb }
  Completion { userdata, msg, callback, result }
  Result union { socket, connect, accept, read, recv, send, close, timer, waitpid, err }
```

references:

- `/Users/igors/.cache/checkouts/github.com/rockorager/prise/src/io.zig:10-18` selects mock/io_uring/kqueue backends.
- `/Users/igors/.cache/checkouts/github.com/rockorager/prise/src/io.zig:20-66` defines `Context`, `Completion`, `Result`, and `Task`.
- `/Users/igors/.cache/checkouts/github.com/rockorager/prise/build.zig.zon:5` sets minimum zig version `0.15.2`.

prise's macos backend registers one-shot kqueue events, stores pending ops by id, and invokes callbacks on completion:

- `/Users/igors/.cache/checkouts/github.com/rockorager/prise/src/io/kqueue.zig:148-204` registers accept/read/recv readiness.
- `/Users/igors/.cache/checkouts/github.com/rockorager/prise/src/io/kqueue.zig:347-376` cancels pending events with `EV_DELETE` and removes the pending op.
- `/Users/igors/.cache/checkouts/github.com/rockorager/prise/src/io/kqueue.zig:395-423` runs the event loop and removes pending ops before handling completions.
- `/Users/igors/.cache/checkouts/github.com/rockorager/prise/src/io/kqueue.zig:425-454` maps readiness to result and invokes the callback.

prise's linux backend submits io_uring operations and maps cqes back to pending ops:

- `/Users/igors/.cache/checkouts/github.com/rockorager/prise/src/io/io_uring.zig:59-227` submits socket/connect/accept/read/recv/send/close/timer/waitpid work.
- `/Users/igors/.cache/checkouts/github.com/rockorager/prise/src/io/io_uring.zig:258-266` submits cancellation by operation id.
- `/Users/igors/.cache/checkouts/github.com/rockorager/prise/src/io/io_uring.zig:285-311` submits and drains completion queue entries.
- `/Users/igors/.cache/checkouts/github.com/rockorager/prise/src/io/io_uring.zig:350-356` maps canceled cqes to `error.Canceled`.

prise is useful because it shows clear operation ids, pending tables, explicit cancellation, and deterministic test backends. it is not a direct copy target because zig 0.16 already provides `std.Io.Threaded`, `std.Io.Kqueue`, `std.Io.Uring`, `std.Io.Queue`, `std.Io.Select`, futures, groups, and cancellation points. copying prise would import a zig 0.15 backend layer and callback-first control flow that fights zi's owner-drain rule.

## what to borrow from prise

borrow:

- operation identity for submitted work.
- pending table discipline.
- deterministic mock backend pattern.
- cancel-by-resource for fd-like resources when needed.
- explicit run/drain lifecycle.

avoid:

- raw kqueue/io_uring backend ownership before `std.Io` has been proven insufficient.
- callback-driven product mutation.
- unbounded pending operations.

## why zag is the closest product reference

`zag` is an agent product with a runtime shape closer to zi. its lua async subsystem uses a fixed worker pool plus a bounded completion queue:

```text
workers execute blocking jobs
  -> push completed Job into bounded completion queue
  -> write wake fd
  -> main thread drains completions
  -> main thread resumes coroutine
```

references:

- `/Users/igors/.cache/checkouts/github.com/vtemian/zag/src/lua/AsyncRuntime.zig:1-8` states the ownership relation between worker pool and completion queue.
- `/Users/igors/.cache/checkouts/github.com/vtemian/zag/src/lua/AsyncRuntime.zig:20-47` initializes queue before pool and stops the pool before tearing down the queue.
- `/Users/igors/.cache/checkouts/github.com/vtemian/zag/src/lua/LuaIoPool.zig:1-10` states workers execute blocking primitives and never touch lua state.
- `/Users/igors/.cache/checkouts/github.com/vtemian/zag/src/lua/LuaIoPool.zig:18-90` implements fixed workers, mutex/condition FIFO, shutdown, and submit.
- `/Users/igors/.cache/checkouts/github.com/vtemian/zag/src/lua/LuaIoPool.zig:107-120` executes jobs and pushes completions, counting drops when the ring is full.
- `/Users/igors/.cache/checkouts/github.com/vtemian/zag/src/lua/LuaCompletionQueue.zig:1-10` documents the bounded queue and wake fd behavior.
- `/Users/igors/.cache/checkouts/github.com/vtemian/zag/src/lua/LuaCompletionQueue.zig:17-64` implements the fixed ring, mutex, wake fd, and `QueueFull` return.

zag's `AgentRunner` also gives a useful owner model:

- `/Users/igors/.cache/checkouts/github.com/vtemian/zag/src/AgentRunner.zig:1-13` states the agent thread emits events and the main thread drains them into sinks and persistence.
- `/Users/igors/.cache/checkouts/github.com/vtemian/zag/src/AgentRunner.zig:63-87` owns agent thread, cancel flag, event queue, wake fd, lua engine pointer, and window manager pointer.
- `/Users/igors/.cache/checkouts/github.com/vtemian/zag/src/AgentRunner.zig:154-202` implements shutdown as cancel, unblock pending round trips, join, drain remaining events, free payloads, and deinit queue.
- `/Users/igors/.cache/checkouts/github.com/vtemian/zag/src/agent_events.zig:1-8` states agent events are produced into a bounded queue and drained by the main thread.
- `/Users/igors/.cache/checkouts/github.com/vtemian/zag/src/agent_events.zig:66-118` models main-thread round trips for hooks, lua tools, layout, prompt assembly, compaction, and tool gates.

this is the strongest behavioral reference for zi's eventual session/agent architecture: workers and agent threads can produce requests, but main/session owners drain and mutate.

zag's oauth implementation is less useful for this specific race because it explicitly runs synchronously on the main thread:

- `/Users/igors/.cache/checkouts/github.com/vtemian/zag/src/oauth.zig:1-5` says oauth runs synchronously and is not integrated with the lua async runtime.

## why pz matters

`pz` is the strongest reference for bounds, security posture, and oauth callback hardening.

pz has a small platform readiness loop with explicit bounds:

- `/Users/igors/.cache/checkouts/github.com/joelreymont/pz/src/core/event_loop.zig:1-11` selects kqueue/epoll by platform.
- `/Users/igors/.cache/checkouts/github.com/joelreymont/pz/src/core/event_loop.zig:22-27` defines `max_events`, timer ids, and max timers.
- `/Users/igors/.cache/checkouts/github.com/joelreymont/pz/src/core/event_loop.zig:79-100` bounds handlers and timer handlers.
- `/Users/igors/.cache/checkouts/github.com/joelreymont/pz/src/core/event_loop.zig:102-117` initializes backend and wake pipe.
- `/Users/igors/.cache/checkouts/github.com/joelreymont/pz/src/core/event_loop.zig:182-218` dispatches fd/timer events to handlers.
- `/Users/igors/.cache/checkouts/github.com/joelreymont/pz/src/core/event_loop.zig:370-373` wakes the event loop through a pipe.

pz's oauth callback server has constraints zi should adopt:

- `/Users/igors/.cache/checkouts/github.com/joelreymont/pz/src/core/providers/oauth_callback.zig:4-11` defines bind ip, redirect host, expected path, success redirect, and read deadline.
- `/Users/igors/.cache/checkouts/github.com/joelreymont/pz/src/core/providers/oauth_callback.zig:32-60` binds a local server and builds the redirect URI from the actual port.
- `/Users/igors/.cache/checkouts/github.com/joelreymont/pz/src/core/providers/oauth_callback.zig:75-121` polls with an overall timeout and retries bad/stalled requests.
- `/Users/igors/.cache/checkouts/github.com/joelreymont/pz/src/core/providers/oauth_callback.zig:123-170` accepts one connection, rejects non-loopback peers, sets a read deadline, uses a bounded 8192-byte request buffer, validates path, validates code/state, and responds.

pz also separates oauth stages cleanly:

- `/Users/igors/.cache/checkouts/github.com/joelreymont/pz/src/core/providers/oauth_flow.zig:111-161` begins oauth by creating verifier/state/challenge and authorize URL.
- `/Users/igors/.cache/checkouts/github.com/joelreymont/pz/src/core/providers/oauth_flow.zig:165-195` completes oauth from manual input.
- `/Users/igors/.cache/checkouts/github.com/joelreymont/pz/src/core/providers/oauth_flow.zig:197-242` completes oauth from local callback after state validation.

zi should adopt this stage split so the runtime races only input acquisition; credential exchange and persistence remain a single owner-controlled completion path.

## first target: openai-codex oauth login

current zi oauth code starts the callback server, prints the URL, then serializes manual input before callback accept:

- `src/ai/utils/oauth/openai_codex.zig:184` starts the callback server.
- `src/ai/utils/oauth/openai_codex.zig:187-190` calls `callbacks.onAuth`.
- `src/ai/utils/oauth/openai_codex.zig:192-197` calls `callbacks.onManualCodeInput` before `server.waitForCode`.
- `src/ai/utils/oauth/openai_codex.zig:215-254` accepts and handles one callback request.

this must become a race:

```text
begin oauth flow
start callback server if possible
emit url/prompt and flush

race:
  callback server wait
  manual stdin read

winner:
  parse/validate code and state
  cancel loser
  drain/join loser
  exchange authorization code
  persist credentials in auth owner
```

## implementation plan

### phase 0: isolate current auth cli slice

commit the already working slice that adds:

- `zi auth status <provider>`.
- status reporting stored oauth and env auth through `AuthManager.hasAuth`.
- flushes before blocking manual oauth input.

### phase 1: split oauth flow stages

refactor `src/ai/utils/oauth/openai_codex.zig` without changing behavior first:

```text
beginLogin:
  create flow
  start callback server
  call onAuth

waitForInput:
  current serialized behavior initially

completeLogin:
  parse code
  validate state
  exchange authorization code
```

success criteria:

- existing tests pass.
- no auth/session mutation inside callback server wait.
- manual and callback inputs produce the same owned code representation.

### phase 2: introduce oauth input race

use `std.Io` concurrency support and `std.Io.Select` for required concurrency:

```text
const OAuthInput = union(enum) {
    callback: anyerror![]const u8,
    manual: anyerror![]const u8,
};

var buffer: [2]OAuthInput = undefined;
var select = std.Io.Select(OAuthInput).init(io, &buffer);

try select.concurrent(.callback, waitForCallbackInput, .{ ... });
try select.concurrent(.manual, waitForManualInput, .{ ... });

const winner = try select.await();
while (select.cancel()) |loser| freeLoser(loser);
```

important caveat: cancellation only works at `std.Io` cancellation points. app-level cancellation must use wakeable tokens or explicit resource close behavior; do not claim cancellation completion until the owner has drained the loser.

### phase 3: extract a zi runtime adapter

only after product paths prove the shape, add small helpers to `src/runtime`, such as:

```text
runtime.Race
runtime.sleepUntilCancel
```

required properties:

- bounded max operations.
- explicit init/deinit.
- completion values are data.
- owner drains all completions or cancels and joins.
- no callback path mutates product state.
- tests can drive deterministic completion order.
- concurrency unavailable is an explicit error, not serialized fallback.

### phase 4: apply to other pressure points

known pressure points:

1. provider http/sse streaming in `src/ai/providers/*`.
2. `ai.provider_stream_stepper` producer/consumer boundaries.
3. agent turn lifecycle in `src/agent/Agent.zig` and `src/agent/loop.zig`.
4. parallel tool execution and result collection.
5. `coding_agent.AgentSession` event hooks, persistence, public events, and terminal policy.

apply the same rule each time: producer emits data, owner drains and mutates.

## 2026-06 runtime hardening pass

current `src/runtime` primitives are intentionally small, but they now encode
the ownership rules instead of relying on caller memory:

- `runtime.Race` wraps `std.Io.Select` and makes loser drain mandatory before
  `deinit`.
- `runtime.CancelSource` owns heap-stable wake storage. App-level cancellation
  closes the wake channel with `requestWithWake(io)` so all waiters wake; token
  reuse reopens a fresh generation with `resetAfterDrain()`, and stale tokens
  fail closed instead of observing a later run.
- `runtime.sleepUntilCancel` races real `std.Io.sleep` against a wakeable
  cancel token. There is no sleep-polling cancel path.
- `runtime.EventPipe` has both terminal close and abort close, so producer
  errors cannot leave consumers blocked forever.
- `runtime.OperationIdAllocator` is only an id allocator. It is not a
  scheduler or operation table.
- `runtime.ByteBuilder` supports bounded capacity for stream/parser paths that
  have externally sized input.

do not add a worker pool until a concrete product path proves that `std.Io`
concurrency plus owner-local `std.Io.Group`/`Race` usage is insufficient. The
current blocking-tool path is bounded by tool-call limits and an owner-local
worker group; adding a pool now would introduce scheduling policy before there
is evidence for it.

## consequences

### positive

- preserves zi's one-owner mutation rule.
- gives auth, provider streams, tools, and hooks one shared lifecycle vocabulary.
- avoids importing a custom pre-0.16 backend before stdlib options are tested.
- makes cancellation and shutdown visible instead of magical.
- gives tests deterministic seams.

### negative

- more explicit lifecycle code than node/pi-mono.
- `std.Io.Select.cancel` may not fully stop blocking stdin/accept without explicit wake/close design.
- some code will be temporarily more verbose while zi discovers the right helper shape.
- callback-style external references must be translated into owner-drained completions.

## non-goals

- building a general-purpose async runtime now.
- porting prise's kqueue/io_uring backends.
- adding hidden global runtime state.
- letting workers mutate session/auth/transcript state.
- making cancellation pretend to be completion.

## acceptance criteria for future runtime work

before marking a runtime change done, prove:

- the max number of in-flight operations is bounded.
- every started operation has an explicit shutdown path.
- every loser in a race is cancelled or otherwise joined/drained.
- all product mutation occurs at the owner drain/apply site.
- completions are bounded or backpressure is explicit.
- tests cover both winner orders where practical.
- gates pass:

```bash
zig build test
ziglint src/coding_agent
zig build
zig build run -- "hello"
```
