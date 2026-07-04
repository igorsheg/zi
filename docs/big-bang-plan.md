# Big-bang plan: SessionEngine + ViewModel architecture

Status: not started
Supersedes: the remaining steps 3–4 of `docs/frame-loop-plan.md` (they happen
here as deletions, not as separate work).
Prerequisite reading: `CONTEXT.md`, `AGENTS.md`, `docs/frame-loop-plan.md`.

This plan replaces the delta-event pipeline between `coding_agent` and the TUI
with a versioned, engine-owned view model sampled at frame rate, and moves the
session engine onto its own thread. It is a cutover, not a migration: no
compatibility scaffolding survives, and "done" is defined by deletion.

Every decision in this document is pinned. If the implementer finds a conflict
between this document and the code, stop and surface it; do not improvise a
third design.

---

## 0. The diagnosis this plan answers

Evidence (git history, April–July 2026):

- The same failure class — unbounded or super-linear work reaching the UI
  thread — was re-fixed in three successive architectures (April monolith, May
  runtime split, June Alpha restructure) and is still the subject of HEAD.
- 11 of 21 post-Alpha commits touch both `src/frontends/tui/interactive.zig`
  and `src/coding_agent/session_runtime.zig`. The seam is a fault line: nearly
  every feature crosses it.
- The pacing layer (presentation queue intervals, RenderThrottle priorities,
  wake delays) accreted as constants tuned against other constants; the
  frame-loop plan already concluded it must be deleted.

Root causes, in order:

1. **The TUI is a protocol client of its own process.** The only frontend that
   matters consumes a wire-shaped delta stream (sequenced envelopes, replay,
   gap recovery) designed for a remote client that does not exist. Everything
   between the agent and the render — presentation queue, drain budgets,
   adapter mirrors, seen-flags, chrome events — is impedance-matching between
   push-at-network-rate and pull-at-frame-rate.
2. **The mailbox host runs on the UI thread.** `SessionRuntime.stepTimed` is
   driven cooperatively from the frame loop, so any expensive event blows the
   frame, and the 60fps invariant is enforced by prose plus a debug watchdog
   with a growing exemption list.

The fix: the engine owns and writes a bounded, versioned **ViewModel** on its
own thread; the UI samples it at most once per frame and diffs by revision.
Deltas remain an internal engine concern and (later) a wire concern for remote
frontends. Coalescing becomes what state does for free.

## 1. Target architecture

```text
        engine thread                             UI thread (frame loop)
┌────────────────────────────────┐         ┌─────────────────────────────────┐
│ agent.Agent loop (tasks)       │         │ 1. drain input -> App.apply     │
│   AgentSession (policy spine)  │         │ 2. if vm generation changed:    │
│   Engine: mailbox drain,       │         │      sample -> diff -> commands │
│     op dispatch, VM writes     │         │ 3. tick time                    │
│        │ single writer         │         │ 4. render if dirty (sync flush) │
│        ▼                       │◄─sample─┤ 5. sleep until wake/deadline    │
│ ViewModel (mutex + generation) │         │                                 │
│        │ publish               ├──wake──►│ Effects -> engine commands ─────┼─►
│ jsonl durable truth            │         └─────────────────────────────────┘
│ (wire event stream: rebuilt    │
│  later for rpc; NOT this plan) │
└────────────────────────────────┘
```

Ownership rules (these amend CONTEXT.md at cutover):

- **Engine** (`src/coding_agent/Engine.zig`): the mailbox host and the only
  writer of the ViewModel. Owns one live session slot, the session `std.Io`
  runtime, the operation table, and all coding-agent-side workers. Runs on a
  dedicated thread it owns for its lifetime.
- **ViewModel** (`src/coding_agent/view_model.zig`): bounded, versioned,
  session-scoped presentation state. Facts a frontend renders, nothing a
  frontend must replay. Guarded by one mutex; published by one generation
  counter.
- **Frame loop** (`src/frontends/tui/frame_loop.zig`): the UI thread. Touches
  only: input reader, ViewModel sampling, `tui.Terminal`/`App`, the frontend
  worker. It has no reference to `AgentSession`, `SessionManager`, providers,
  or the session `std.Io` runtime — the 60fps invariant becomes a property of
  what this thread can reach, not a rule.
- **Differ** (`src/frontends/tui/view_diff.zig`): pure translation from
  sampled ViewModel state to `tui.Command` values. Owns per-item cursors.
  No protocol knowledge, no pacing knowledge.

The command direction is unchanged: `tui.App.Effect` values become engine
commands submitted to the bounded mailbox, exactly as today.

The two-runtime conflict is resolved by geography: the session `std.Io`/zio
runtime lives entirely on the engine thread; the UI thread uses only plain
threads, atomics, and kernel fds. No `std.Io` on the UI thread, ever.

Cross-runtime signaling rule (pinned, amended 2026-07-04): no blocking
primitive is ever shared across Io runtimes. Engine→UI wake is a kernel pipe
fd (engine writes one byte on publish; UI polls it). UI→engine wake is the
mailbox wake pipe watched by the engine's zio loop. `runtime.WakeEvent`
(`std.Io.Event`) may only be used between parties sharing one Io instance.
The shared ViewModel is guarded by the io-free `runtime.SharedMutex` (§3.1).
The UI thread blocks only in `std.posix.poll` with a deadline.

## 2. What survives unchanged

Do not redesign these; they are correct:

- `tui.App.apply(Command) -> error{OutOfMemory}!?Effect` — total function,
  single mutation path, time via `Command.tick`, degrade-don't-crash.
- `src/tui/render.zig` economics: layout memoization keyed by
  `(version, width, expanded)`, O(items) counting, O(viewport) drawing,
  stable-prefix markdown cache, vaxis cell diff.
- `src/frontends/tui/input_reader.zig`: dedicated stdin thread, bounded byte
  queue, wake event. Keep as-is.
- `src/frontends/tui/tool_view.zig`: stateless projection functions. Keep;
  callers change.
- `agent` package: loop, steering/follow-up queues, `tool_runner` parallel
  fan-in, `CancelSource` two-phase cancel. (Run-handle unification in Phase 5
  is a re-plumbing of `AgentSession`/Engine dispatch, not of `agent`.)
- `session_manager.zig` jsonl store: durable truth, prepare/commit ordering.
- `event_drain.zig`'s single-writer discipline — the *pattern* survives; the
  file is refitted to write the ViewModel instead of a ClientEvent queue.
- All named bounds keep their values unless this plan states otherwise.

## 3. ViewModel specification

File: `src/coding_agent/view_model.zig`. New. Imports: `std`,
`runtime` (for `ByteBuilder` if reused), `tool_metadata` types only. It must
not import `agent`, `ai`, `session_manager`, or anything above itself; it is a
leaf data structure with methods.

### 3.1 Top-level shape

```zig
pub const ViewModel = struct {
    mutex: runtime.SharedMutex = .{},
    /// Bumped exactly once per publish batch. Never per field.
    generation: u64 = 0,
    /// Bumped when the live session identity changes (new/resume/switch).
    /// A reader observing a new epoch discards ALL local state and cursors.
    session_epoch: u32 = 0,

    chrome: Chrome,            // chrome.rev: u32
    op: OperationStatus,       // op.rev: u32
    queue: QueueEcho,          // queue.rev: u32
    transcript: ItemStore,
    history: HistoryWindow,    // history.rev: u32
    completion: CompletionSlot,// completion.rev: u32
    notices: NoticeRing,
};
```

Writer protocol (engine thread only):

1. `vm.mutex.lock()`
2. mutate any number of sections; bump each touched section's `rev` and each
   touched item's `rev`
3. `vm.generation += 1` (once)
4. `vm.mutex.unlock()`
5. `ui_wake.set()`

Reader protocol (UI thread, at most once per frame):

1. `vm.mutex.lock()`; if `generation == last_seen_generation`, unlock, done.
2. If `session_epoch != last_seen_epoch`: record "epoch reset" and copy
   everything fresh (do not diff).
3. Copy out only what changed, into the reader's frame arena (pinned, amended
   2026-07-04): the POD sections (chrome/op/queue) are copied by value always
   (no allocation); the allocating sections (history, completion) are copied
   ONLY when their `rev` differs from the cursor's recorded value and are
   `null` in the sample otherwise. For transcript items, the sample delivers
   per-item DELTAS, not whole items: for each item whose `rev` differs from
   the cursor's, copy metadata plus `text[cursor.consumed_len..]` up to the
   remaining byte budget, advance `cursor.consumed_len` by exactly the bytes
   copied, and record the item's new `rev` in the cursor only when its suffix
   was fully copied. If `text_replaced_at_rev` is newer than the cursor's
   recorded rev for that item, reset `consumed_len` to 0 first and mark the
   delta as a replace. A sample never re-copies bytes it already delivered:
   steady-state streaming cost is O(new bytes since last frame), never
   O(message).
4. `vm.mutex.unlock()`. All translation to `tui.Command` happens after unlock.

**Locking primitive (pinned, amended 2026-07-04):** Zig 0.16 has no
`std.Thread.Mutex`; blocking primitives live under `std.Io` and are
io-parameterized. zio's futex backend is a user-mode, coroutine-only wait
queue (`vendor/zio/src/sync/Futex.zig`), so any io-parameterized primitive on
memory shared between the engine thread (zio io) and the UI thread loses
wakes across runtimes. Therefore: `runtime.SharedMutex` (new file
`src/runtime/shared_mutex.zig`) — pure `std.atomic.Value` state, `tryLock`
plus bounded spin (`std.atomic.spinLoopHint`) then `std.Thread.yield()` loop;
no `std.Io` anywhere in its API. This is sound because VM critical sections
are bounded (64KiB copy cap, 2ms debug assert) and contention is
writer-once-per-batch vs reader-at-most-60Hz. The ViewModel public API takes
allocators but never `std.Io`.

Lock-hold bound: the reader copies at most `sample_bytes_per_frame_max =
64 * 1024` bytes per sample; if dirty payload exceeds this, the sample is
partial: `generation` is not consumed (do not update `last_seen_generation`),
but per-item cursor progress made during the partial sample (consumed_len
advances, revs of fully-copied items) IS retained, so successive frames make
monotone progress and convergence is guaranteed even when the backlog exceeds
the cap. A sample never re-copies bytes it already delivered. This is the
bounded policy: backpressure by frame, never a long lock hold, never a
livelock. Debug-assert lock hold < 10ms in both reader and writer (amended
2026-07-04: generous because debug allocators inflate bounded work 10-50x;
the assert catches category errors — I/O or O(session) scans under the lock —
while the byte caps are the real bound).

Memory: the ViewModel owns all its payload bytes via the gpa passed at init.
Readers copy; readers never retain pointers into the ViewModel. Section
payloads are bounded (caps below); `OutOfMemory` on a writer mutation is
propagated to the engine, which fails the operation (existing failure
handling), never a partial write: use the mutate-into-scratch-then-swap
pattern or reserve-before-write for multi-field updates.

### 3.2 Chrome

```zig
pub const Chrome = struct {
    rev: u32,
    cwd: BoundedText(cwd_bytes_max),            // 1024
    model_id: BoundedText(128),
    model_label: BoundedText(128),
    provider_label: BoundedText(64),
    thinking_level: ThinkingLevel,               // reuse existing enum
    hide_thinking: bool,
    context_used_pct: ?u8,                       // null until known
    session_title: BoundedText(256),
};
```

`BoundedText(cap)` is a fixed-capacity inline byte array + len (no heap),
truncated at a UTF-8 boundary via the existing `utf8Prefix` logic — move
`utf8Prefix` from `client_protocol.zig` into `view_model.zig` (or a shared
`text_bounds.zig`) and have `client_protocol` import it from there.

This kills the `session_chrome` ClientEvent and its `session_chrome_dirty`
bookkeeping: chrome is state; the differ re-renders the status line when
`chrome.rev` changes.

### 3.3 OperationStatus

```zig
pub const OperationStatus = struct {
    rev: u32,
    phase: Phase,
    cancel_requested: bool,

    pub const Phase = union(enum) {
        idle,
        running: struct { op_id: u64, started_ms: i64 },
        compacting: struct { op_id: u64, started_ms: i64, trigger: CompactionTrigger },
        retry_wait: struct { until_ms: i64, attempt: u32, reason: BoundedText(256) },
        shutting_down,
        stopped,
    };
};
```

One phase at a time — same "unrepresentable combinations" property as today's
`ActiveOperation`, now client-visible as plain state. The differ derives the
spinner/status-line and whether Esc shows "cancel requested" from this alone;
the adapter fields `operation_active` and `cancel_requested` die.

### 3.4 QueueEcho

```zig
pub const QueueEcho = struct {
    rev: u32,
    steering: BoundedArray(QueuedPrompt, 8),
    follow_up: BoundedArray(QueuedPrompt, 8),
    dropped: u8, // count of echoes not shown because a bound was hit
};
pub const QueuedPrompt = struct { id: u64, text: BoundedText(256) };
```

Written by the engine at the same points `queue_mirror.zig` writes today.
`QueuedPrompt.id` is assigned at enqueue time and carried through the real
`agent` queues (add an id field to the queued message), so consumption removes
by id, not by string match — this deletes the string-equality removal hazard
in `event_drain.zig`. `queue_mirror.zig` is deleted; the ViewModel section is
the mirror.

### 3.5 ItemStore (the transcript tail)

```zig
pub const ItemStore = struct {
    /// Resident tail items, oldest first. Bounded; eviction below.
    items: std.ArrayList(Item),
    /// All items with id <= evicted_through_id were evicted from residency.
    evicted_through_id: u64,
    next_item_id: u64,
};

pub const Item = struct {
    id: u64,                 // monotonic per session epoch, engine-assigned
    rev: u32,                // bumped on ANY field change of this item
    kind: Kind,
    state: State,            // .streaming, .final, .canceled
    /// Durable session entry id once committed to jsonl; null while streaming.
    entry_id: ?u64,
    /// Append-only while state == .streaming (see invariant below).
    text: std.ArrayList(u8),
    /// Set when a final normalization replaced `text` wholesale; readers must
    /// discard their append cursor and re-copy from offset 0. Cleared by the
    /// reader protocol implicitly (it is a rev-observed fact, engine keeps it
    /// set from the moment of replacement onward for that rev).
    text_replaced_at_rev: ?u32,
    footer: BoundedText(footer_bytes_max),       // 256
    tool: ?ToolMeta,

    pub const Kind = enum {
        user, assistant, thinking, tool, banner, compaction_summary, system_notice,
    };
    pub const State = enum { streaming, final, canceled };
};

pub const ToolMeta = struct {
    tool_call_id: BoundedText(128),
    name: BoundedText(64),
    title: BoundedText(256),        // from tool_view-style projection
    display: tool_metadata.Display, // body_mode, collapse, shows_duration
    streams_output: bool,           // moved from hardcoded switch into tool_metadata
    started_ms: ?i64,               // set at execution start; UI renders elapsed
    duration_ms: ?u64,              // set at end; replaces live elapsed
    exit_meta: BoundedText(128),    // e.g. truncation chip text
};
```

**Append-only invariant (the load-bearing one):** while `state == .streaming`,
`text` may only grow; `text.items.len` is monotone under a fixed `rev` history
and every append bumps `rev`. A reader keeps `consumed_len` per item and, on
observing `rev` change with `text_replaced_at_rev == null` (or one it has
already processed), copies exactly `text[consumed_len..]` and appends it via
the existing delta command path (`tool_output_delta` / transcript append).
When `text_replaced_at_rev` is newer than the reader's last processed rev, the
reader resets `consumed_len = 0` and issues a full replace
(`replace_tool_output` / re-append). Unit-test this invariant directly.

Per-kind text caps (bounded policy: evict-with-notice, matching today's
truncation behavior): assistant/thinking text cap and tool output cap reuse
the existing `client_protocol.zig` `..._bytes_max` constants — move them to
`view_model.zig` and re-export from `client_protocol` for the wire types.
When a cap is hit, the engine truncates at a UTF-8 boundary, sets
`exit_meta`/footer truncation text exactly as the current bounded-copy path
does, and stops appending.

Residency: `resident_items_max = 256`. When exceeded, evict oldest items
(whole items), advance `evicted_through_id`, bump no per-item revs (they are
gone), bump `generation`. The differ, on seeing `evicted_through_id` advance,
issues nothing — `tui.Transcript` has its own residency policy and already
evicts; the ids simply stop being referenced. History paging (3.6) is the way
older content returns.

Duration timers: the differ renders elapsed time for any resident tool item
with `started_ms != null and duration_ms == null` on each `Command.tick`
frame. This deletes the 8-slot `ToolTimer` table and its silent degradation.

### 3.6 HistoryWindow

```zig
pub const HistoryWindow = struct {
    rev: u32,
    state: enum { closed, loading, open },
    /// Windowed items, oldest first, same Item shape but always .final.
    items: std.ArrayList(Item),
    has_more_before: bool,
    has_more_after: bool,
    /// entry_id anchors for paging continuation.
    oldest_entry_id: ?u64,
    newest_entry_id: ?u64,
};
```

Contract: paging is request/response through the mailbox
(`Command.history_page{ before_entry_id, limit }` — keep the existing command
shape and page size). The engine builds the whole window on its thread from
`SessionManager` entries via the single projection (Phase 5) and publishes it
atomically; there is no interleaving with live-tail items because the reader
samples consistent snapshots. Any `history.rev` change is treated by the
differ as a whole-window replace (it re-issues `prepend_transcript` content
per the existing prepend command). While `state == .open` and
`has_more_after == true`, the differ shows the existing "newer messages below"
notice and suppresses live-tail rendering exactly as today; `Effect.
request_transcript_tail` closes the window (engine sets `state = .closed`,
differ resumes tail from ItemStore). The five adapter paging booleans and the
tail-race drop logic die; the state machine is these enum fields.

### 3.7 CompletionSlot

```zig
pub const CompletionSlot = struct {
    rev: u32,
    query_id: u64,              // echoes the requesting command's query_id
    kind: enum { none, file, model, resume_session, slash_arg, settings },
    items: std.ArrayList(CompletionItem), // bounded: completion_items_max = 64
};
pub const CompletionItem = struct {
    id: BoundedText(256),
    label: BoundedText(256),
    detail: BoundedText(256),   // e.g. model cost/token columns, preformatted
};
```

The frontend submits `Command.completion_query{ query_id, kind, text }` with a
monotonically increasing `query_id` it allocates; the engine answers by
publishing the slot. The differ ignores any slot whose `query_id` is not the
latest one the frontend issued (stale answers are dropped by comparison, not
by protocol). Column formatting (`formatModelTokenCount`, `formatModelCost`,
picker column layout) moves out of the engine: the engine publishes raw
labels/details; a frontend module formats (5.4). The file-index worker and
one-in-flight/reject-busy load policy carry over from today unchanged.

### 3.8 NoticeRing (the only event-shaped thing left)

Some facts are genuinely one-shot (operational failures, retry announcements,
"queue full" warnings, terminal bell requests). They get a bounded ring, not a
return to event plumbing:

```zig
pub const NoticeRing = struct {
    next_id: u64,
    /// Ring of the last notices; overwrite-oldest on overflow.
    entries: [notice_ring_len]Notice,   // notice_ring_len = 32
    evicted_through_id: u64,
};
pub const Notice = struct {
    id: u64,
    severity: enum { info, warn, err },
    semantic: NoticeSemantic,           // enum consumed by frontend copy tables
    text: BoundedText(512),
};
```

Reader keeps `last_seen_notice_id`; on sample it copies notices with
`id > last_seen_notice_id`. If `evicted_through_id > last_seen_notice_id`,
the differ emits one "some notices were dropped" warn notice first (the
replay-gap pattern, reused). Overflow policy: evict oldest, report the gap.

### 3.9 What the ViewModel deliberately does not contain

- No sequence numbers, no replay, no snapshots-vs-events distinction: sampling
  a consistent state IS the snapshot, every frame.
- No pacing metadata (`queued_ns`, reveal intervals). Sampling cadence is the
  reveal cadence: at 60fps, appends land every ~16ms, which is the value the
  frame-loop plan already concluded was correct. The 12ms constant and the
  concept behind it are deleted, not ported.
- No per-frontend cursors: cursors (consumed_len, last revs, notice ids) are
  reader-owned. A second frontend is just a second reader struct.

## 4. Engine specification

File: `src/coding_agent/Engine.zig`. Replaces `session_runtime.zig` (which is
deleted in Phase 3). `pub const Engine`.

### 4.1 Responsibilities (exactly these, nothing else)

1. Own the dedicated engine thread and the session `std.Io` runtime on it.
2. Own the bounded command mailbox (keep the existing `CommandQueue` type and
   bound) and drain it.
3. Own one live session slot (`AgentSession`) + `RuntimeServices`, with the
   existing build-next-slot-completely-then-swap rule; the slot build runs on
   the engine's existing completion-load worker path, not on the UI thread —
   this carries over from frame-loop-plan step 2a unchanged.
4. Own the operation table (one active operation; `.busy` reject policy as
   today) and drive `AgentSession` run progress.
5. Be the single writer of the ViewModel (via the refitted `event_drain`).
6. Own coding-agent-side workers: file index (existing raw-thread worker),
   completion loads, session opens. Their results land on the engine thread
   and are applied there.

Explicitly evicted from the engine (new homes in Phase 5, but the Engine file
is born without them): slash-command interpretation (`slash_commands.zig` +
`AgentSession` methods), model/thinking/settings mutation
(`AgentSession.setModel` / `.setThinkingLevel` / `.setHideThinking`),
picker/completion presentation formatting (frontend).

### 4.2 Thread and loop

```zig
pub fn start(gpa, process_runtime, options) !*Engine   // spawns thread, returns after ready
pub fn submit(self, command) SubmitError!void          // any thread; bounded; reject-on-full
pub fn viewModel(self) *ViewModel                      // stable pointer for readers
pub fn attachReaderWakeFd(self, fd) void               // engine writes 1 byte on publish; bounded list, len 4, reject beyond
pub fn requestShutdown(self) void
pub fn join(self) void                                 // blocks until stopped; then deinit is safe
```

Engine loop iteration: wait on {mailbox non-empty, run-progress wake, worker
completion wake, retry deadline} → drain commands (bounded per turn: keep
existing per-turn command bound) → apply run progress (bounded by events per
turn as today, but the budget's purpose is now cancel-latency, not frame
protection) → apply worker results → publish ViewModel batch (one generation
bump) → wake readers. The engine may hold the VM lock only inside the publish
step.

Shutdown order (pinned): `requestShutdown` → engine stops accepting commands
(submit returns `error.ShuttingDown`) → cancel active operation (two-phase,
observe terminal outcome) → join workers → final publish
(`op.phase = .stopped`, generation bump, wake) → thread exits → `join`
returns → caller deinits. The UI thread never calls `deinit` before `join`
returns. `deinit` poisons the struct.

### 4.3 The refitted drain

`event_drain.zig` keeps its name, single-writer role, and drain order, but its
output changes: instead of enqueueing ClientEvents it applies agent events to
the ViewModel:

```text
agent event -> ViewModel mutation (items/op/queue) -> jsonl persistence on
message_end (persist BEFORE setting entry_id/state=.final on the item)
-> terminal policy
```

The persist-before-commit ordering rule survives verbatim: an item only gets
`entry_id` and `.final` after the jsonl append succeeds. The
`message_committed` protocol event dies; `entry_id` appearing on the item is
the committed fact, and it is what history paging anchors on.

Streaming apply is O(delta): the frame-loop-plan 2e compact-delta work is a
prerequisite and is kept; the engine appends deltas into `Item.text` in place.

### 4.4 What is deleted with session_runtime.zig

`EventQueue`, `pending_event` holdback, `RetainedEventLedger`, `EventSeq`
assignment, `enqueueEvent`/`drainEvent`/`flushPendingEvent`, replay/gap
building, `eventRefreshesSessionChrome` + `session_chrome_dirty`,
`shouldRetainClientEvent`, the `waitAndApplyWake`/`stepTimed` cooperative
scheduler and its per-phase frame budgets, `buildModelCompletionList`
formatting. The `ClientEvent` union and envelope types in
`client_protocol.zig` are retained but orphaned (no producer) until the rpc
rebuild; mark the file top with a comment saying exactly that.

## 5. Core consolidations (engine-side, Phase 5)

### 5.1 One run-handle shape

In `AgentSession`, prompt runs and compaction runs (and future subagent runs)
expose one interface:

```zig
pub const RunHandle = struct {
    kind: enum { prompt, compaction },
    pub fn poll(...)   // drive stream progress, bounded
    pub fn settle(...) // exactly-once terminal handling -> SettleVerdict
    pub fn cancelRequest(...)
    pub fn deinitAfterSettled(...)
};
```

The Engine's operation table stores `?RunHandle` plus the retry-wait deadline;
`applyActiveProgressTimed` / `applyVerdict` / `cancelAndDestroyActivePhase` /
shutdown handling collapse from per-kind switch arms threaded through six
functions into one code path calling the interface. `PromptRun.State`'s
settle-once guard becomes the shared `settled: bool` inside `RunHandle`;
`Agent.cancel_source` remains the only transport-level cancel primitive;
`CompactionRun` keeps its dedicated `CancelSource` behind its handle. Net: the
five overlapping lifecycle FSMs reduce to three with distinct jobs
(agent status / RunHandle settle-guard / engine phase), and adding an
operation kind is one union arm + one handle implementation.

### 5.2 One transcript projection

`session_manager.zig`: `contextMessages` and `reconstructSession` currently
compute the compaction boundary independently. Extract one
`projectSession(entries) -> ProjectionIterator` that yields post-boundary
entries; `contextMessages` maps them to `AgentMessage`, the history-window
builder maps them to `view_model.Item`. Delete the duplicated boundary logic.

### 5.3 Ownership repairs

- `AgentSession.setModel`, `.setThinkingLevel`, `.setHideThinking` become
  owned methods; they persist the durable session fact first (existing rule),
  then mutate the live agent, then the engine publishes chrome.
- Slash-command dispatch moves into `slash_commands.zig` (module exists):
  parse there, call `AgentSession`/Engine methods, return a
  `NoticeSemantic`-or-transcript-reply result the engine publishes. The
  `prompt_command` presentation split (status vs transcript) is preserved by
  that return type.

### 5.4 Frontend product-policy modules

New files, extracted (not rewritten) from `interactive.zig`:

- `src/frontends/tui/pickers.zig` — picker opening/wiring, the bare
  `/model` `/resume` `/settings` shortcuts, completion-column formatting
  (receives raw `CompletionItem`s).
- `src/frontends/tui/failure_text.zig` — the operational-failure /
  retry / rejection copy tables keyed by `NoticeSemantic`.
- `src/frontends/tui/worker.zig` — ONE generic background-task primitive
  replacing the three copy-pasted thread+slot implementations: 
  `Worker.spawn(kind, input) -> error{Busy}`, one in flight, result drained on
  the UI thread after a wake, kinds: `clipboard_copy`, `clipboard_image_paste`,
  `prompt_attachments`. Same reject-busy policy as today.

## 6. Frame loop specification

File: `src/frontends/tui/frame_loop.zig`. Replaces the loop half of
`interactive.zig`.

```text
loop:
    deadline = min(app.nextDeadlineMs(), now + idle_wait_ms)      // idle_wait_ms = 30_000
    wake = std.posix.poll([input_wake_fd, engine_wake_fd, worker_wake_fd], deadline)
    drain input bytes -> Terminal.applyInputBytes -> effects
    dispatch effects (engine commands / worker spawns / local commands)
    drain one ready worker result -> App.apply
    if vm.generation != last_seen: sample + diff -> App.apply commands
    apply Command.tick
    if app dirty and now >= render_due:
        render (draw -> sync flush -> clear dirty)
        render_due = now + max(frame_interval_ms, 3 * last_render_cost_ms)
    drain pending resize
```

Pinned decisions:

- `frame_interval_ms = 16`. One render pacing rule: the `render_due` line
  above. `RenderThrottle`, `FramePriority`, `BackgroundRenderReason`,
  `requested_background_interval_ms`, and both `renderIfDue` call sites are
  deleted. Typed input and resize set `render_due = now` (render this frame);
  nothing else has priority semantics.
- Foreground rule: input is drained before sampling every iteration; a full
  input drain plus its App.applies must never be skipped for VM work.
- The 64KiB sample cap (3.1) is the only VM-side budget; there are no drain
  count/time budget constants on the UI side anymore.
- Watchdog: keep `FrameWatchdog` in debug builds, budget starts at 33ms,
  ratchet to 17ms once Phase 3 lands. Delete the `WatchdogExemption` enum;
  the only remaining exemption is the external-editor suspend, expressed by
  the loop being suspended (not exempted) around
  `Terminal` suspend/resume. Post-resume repaint becomes a new
  `Command.force_redraw` (added to `tui.App`), deleting the
  `app.dirty = true` write in `Terminal.resumeAfterExternalProgram`.
- The frame loop file must not import `coding_agent` internals beyond
  `Engine`'s public surface and `view_model` types.
- Wake plumbing per the §1 cross-runtime rule: `input_reader` and the
  frontend worker signal the frame loop through pipe fds (input_reader
  already owns the self-pipe pattern); the frame loop's only blocking call is
  `std.posix.poll` over {input wake fd, engine wake fd, worker wake fd} with
  the frame deadline as timeout. No `std.Io` and no `runtime.WakeEvent` on
  this thread.

### 6.1 Differ (`src/frontends/tui/view_diff.zig`)

Owns the reader-side state, all of it in one struct created per session epoch:

```zig
pub const ViewCursor = struct {
    epoch: u32,
    generation: u64,
    chrome_rev, op_rev, queue_rev, history_rev, completion_rev: u32,
    last_notice_id: u64,
    items: /* bounded map item.id -> struct { rev: u32, consumed_len: usize } */,
    latest_query_id: u64,
};
```

Rules:

- Epoch change (new/resume/switch session): drop `ViewCursor`, create fresh,
  issue `Command.clear_transcript`, re-render everything from the sampled
  state. This replaces both hand-maintained reset checklists
  (`applySessionChanged` / `applySnapshot`) with one code path.
- Item diffing: new id → `append_transcript`; rev change on streaming item →
  append `text[consumed_len..]` via the delta commands; `text_replaced` →
  replace commands; state → `.canceled` participates in
  `mark_pending_tools_canceled` semantics as today; footer rev change →
  `replace_tool_footer`.
- The sample already delivers per-item text SUFFIXES (§3.1 reader protocol);
  the differ appends them via the delta commands and issues replaces when the
  delta is marked replaced. The differ never re-slices full item texts; the
  per-item `{rev, consumed_len}` bookkeeping lives in the reader cursor shared
  with `ViewModel.sample`.
- The differ is a pure function of (sampled copy, cursor) → (commands, next
  cursor). Unit-test it with hand-built ViewModel fixtures and golden command
  sequences; no engine, no terminal.

## 7. Behavior inventory — every special case and its new home

The implementer must account for every row; none may be silently dropped.

| # | Current behavior (where) | New home |
|---|---|---|
| 1 | Write-tool call preview shown before execution, cleared at execution start (`applyToolCall`/`clearsCallPreviewOnStart`) | Engine publishes the item at tool-call time with preview text; at execution start sets `text_replaced` with empty/real output. Ordering is by item rev, not event choreography. |
| 2 | Bash output streams; `tool_execution_end` does not replay full body (`streamsOutput`) | `ToolMeta.streams_output` from `tool_metadata` table (add the field there; delete the hardcoded `kind(name)` switch). Engine appends stream deltas; at end only footer/duration change. |
| 3 | Tool display modes: body_mode, collapse default, shows_duration | `ToolMeta.display` copied from `tool_metadata.displayForTool`, unchanged. |
| 4 | Tool duration footer, 8-tool cap, silent degradation | `started_ms`/`duration_ms` on ToolMeta + differ tick rendering. Cap deleted. |
| 5 | Assistant/thinking double-render avoidance (`assistant_text_delta_seen`, `assistant_thinking_seen`) | Deleted. Engine guarantees final item text equals accumulated text or sets `text_replaced`. |
| 6 | Thinking visibility: `hide_thinking` hides new thinking blocks | Differ filters `.thinking` items at first-append time by `chrome.hide_thinking`; toggling affects subsequently appended items only (matches today). |
| 7 | History paging: cursors, in-flight flags, tail notice, live-tail suppression/drop | `HistoryWindow` state machine (3.6). Tail-race handling is structural (atomic sampling). |
| 8 | Sequence-gap recovery, snapshot-on-gap, replay handling | Deleted from TUI. In-process sampling cannot gap. (Wire clients re-gain this when rpc is rebuilt.) |
| 9 | `session_chrome` refresh event + dirty tracking | `Chrome` section (3.2). |
| 10 | Queue echo chips, string-match removal | `QueueEcho` + id-based removal (3.4). |
| 11 | Event-overflow banner | NoticeRing eviction gap notice (3.8). |
| 12 | Operational failure / auto-retry copy (`formatOperationalFailureMessage` etc.) | `failure_text.zig` keyed by `NoticeSemantic`; engine publishes semantic + bounded detail text, frontend owns the words. |
| 13 | Bare `/model` `/resume` `/settings` open pickers | `pickers.zig` (5.4), driven by `CompletionSlot`. |
| 14 | Completion snapshot / file completion round-trip dedupe flags | `query_id` comparison (3.7); flags deleted. |
| 15 | Session switch/new/resume resets (two manual checklists) | Epoch reset (6.1). |
| 16 | Cancel semantics: Esc requests cancel once, second Esc no-ops until settled | `op.cancel_requested` (3.3). |
| 17 | Composer-full paste coalescing (`composer_full_noticed`) | Stays in `tui.App` unchanged (it is a UI-local concern). |
| 18 | Composer scroll hint via sentinel status id | Stays as-is in this plan (tui-internal; see Phase 6 note). |
| 19 | Clipboard copy (OSC52/native), image paste, prompt attachment reads off-thread | `worker.zig` single primitive (5.4). |
| 20 | External editor suspend/resume + repaint | Loop suspension + `Command.force_redraw` (6). |
| 21 | Greeter, keybindings, prompt history, selection/copy, shimmer | Untouched (`tui` package). |
| 22 | `/resume` picker bootstrap before first session | Startup sequence: frame loop starts with Engine in `op.phase = .idle`, no session epoch yet; resume listing arrives via `CompletionSlot` like any picker. Engine.start does not require a session to exist. |
| 23 | Print mode streaming output | Phase 4: print frontend samples the VM at a 30ms cadence with its own `ViewCursor`, writes appended text to stdout. Proves the multi-reader design. |
| 24 | RPC stdio frontend | Parked: `cli` rpc mode prints "rpc frontend is being rebuilt; use --print" to stderr and exits code 2. `src/frontends/rpc/stdio.zig` is deleted (git history keeps it). Rebuild against a VM-derived wire stream is explicitly out of scope of this plan. |
| 25 | Latency tracing (`trace.zig`, 60 phases) | Shrunk in Phase 6 to: wait, input_drain, sample, diff_apply, tick, draw, flush, watchdog. Delete queue-wait/accept-apply chain phases with the queue. |

## 8. Phases and gates

Zi must build and run at every commit ("no scaffolding" ≠ "no runnable
states"). Each phase ends with:

```sh
zig build test && zig build && zig fmt --check src
```

plus the phase's own gate. Work on one branch (`big-bang`); merge to main only
after Phase 4's gate.

### Phase 0 — Baselines and rules of evidence

- Capture `ZI_TUI_TRACE` baselines on the current build for: 1MB assistant
  flood, chatty bash tool, `/resume` of a multi-MB session, 17KB paste,
  scroll-during-stream. Store the trace files under `docs/baselines/` with a
  README naming the scenario for each.
- Confirm the flood test + debug watchdog from frame-loop-plan step 1 pass at
  50ms; do not ratchet yet.
- Freeze the behavior inventory: §7 of this document is the contract. Any
  behavior discovered during implementation that is not in the table gets
  added to the table (with its new home) before its old implementation is
  deleted.

Done when: baselines exist, table reviewed.

### Phase 1 — ViewModel (pure addition)

- Implement `view_model.zig` exactly per §3, with unit tests: append-only
  invariant, text_replaced protocol, per-kind caps + truncation text,
  residency eviction, notice-ring overflow gap, epoch reset, generation
  batching (N mutations → 1 bump), reader byte-cap partial sample
  (generation not consumed), lock-hold debug asserts.
- Implement `view_diff.zig` `ViewCursor` + differ per §6.1 with golden-command
  fixture tests (no engine, no terminal).

Done when: both modules fully tested standalone; `zi` binary unchanged.

### Phase 2 — Engine (addition, wired to nothing)

- Implement `Engine.zig` per §4: thread, mailbox, refitted `event_drain`
  writing the ViewModel, worker ownership, shutdown order. Reuse
  `AgentSession`, `session_manager`, `RuntimeServices` as-is; do not do the
  §5 consolidations yet.
- Integration tests using the faux provider (`src/ai/providers/faux.zig`):
  submit prompt → poll VM until item reaches `.final` with `entry_id` set;
  cancel mid-stream → `.canceled` + op idle; compaction path; retry-wait
  phase visible; session open off-thread with `.busy` reject for a second
  open; shutdown order (submit after shutdown returns `ShuttingDown`).
- Cross-thread stress test: engine floods 1MB in 64-byte deltas while a test
  reader thread samples at 1ms cadence with the 64KiB cap; assert no
  invariant violations and monotone delivery (amended 2026-07-04: the
  reconstructed text must be exactly the sent text up to the per-item cap —
  no gaps, duplicates, or reordering — the item must end `.final` with the
  truncation chip at exactly the cap, and generation must converge after the
  flood; full-1MB retention is not expected because live items are capped at
  256KiB by design).

Done when: engine tests green; old `session_runtime` path still ships; the
binary still runs on the old path.

### Phase 3 — The cutover

Commit sequence (each commit builds and runs):

1. Add `frame_loop.zig`, `worker.zig`, `pickers.zig`, `failure_text.zig`
   (compiled, unused by cli).
2. Flip `cli/root.zig` TUI mode to: build `Engine.start` + `frame_loop.run`.
   The old interactive path is now dead code.
3. Delete the corpse in one commit: `interactive.zig`,
   `presentation_queue.zig`, `session_runtime.zig` (engine already replaced
   it), `queue_mirror.zig`; strip orphaned ClientEvent producers; delete
   `RenderThrottle`/watchdog exemptions per §6. `zig build` must prove
   nothing references them.
4. Update `CONTEXT.md` and `AGENTS.md`: replace SessionRuntime/mailbox-drain
   language with Engine/ViewModel/sampling language; rewrite the "tui changes"
   checklist rules that referenced drain budgets; keep the owner/bounded
   doctrine text.

Gate (all must pass before Phase 3 is done):

- Flood test at 33ms watchdog, then ratchet to 17ms and keep it green.
- Input-echo test: keystrokes injected during the 1MB flood are echoed within
  2 frames (fake-clock or wall-threshold, same style as existing flood test).
- Re-run every Phase 0 scenario; compare traces against baselines: no
  scenario regresses in max frame time; `/resume` and paste show no UI-thread
  stall.
- Manual feel checklist (run in a real terminal, tmux, and ssh): type during
  streaming; scroll during streaming; open history and page; cancel
  mid-tool; paste 17KB; external editor round-trip; resume multi-MB session.
- Deletion grep is clean:
  `grep -rn "presentation_queue\|RenderThrottle\|FramePriority\|RetainedEventLedger\|EventCursor\|session_chrome\|stepTimed" src` returns nothing.

### Phase 4 — Other frontends

- Print mode: rewrite `print_mode.zig` as a VM sampler (inventory #23).
- RPC: park per inventory #24.
- Delete now-unproduced `ClientEvent` machinery from `client_protocol.zig`
  (keep `Command` types and any structs the mailbox still uses; header-comment
  the file as "mailbox commands + future wire protocol").

Done when: `zi --print` output is byte-comparable to before for a faux-provider
scripted session (allowing timing-dependent chunk boundaries); rpc exits 2
with the message.

### Phase 5 — Core consolidations

In order, each independently shippable: 5.1 RunHandle; 5.2 single projection;
5.3 ownership repairs (AgentSession setters, slash dispatch). Engine LoC must
go down in 5.1 and 5.3; if it goes up, the consolidation is wrong — stop.

Done when: `Engine.zig` contains no per-operation-kind switch bodies beyond
constructing handles, no settings/model mutation logic, no slash parsing; the
compaction-boundary logic exists in exactly one function.

### Phase 6 — TUI hygiene (contained, optional-order)

- Derived dirty: `App` computes dirty from subsystem revision counters at the
  end of `apply` (Transcript/Composer revisions exist; add small counters to
  status/notify/picker/viewport). Delete the 56 manual `dirty = true` writes.
- Region-list layout in `render.zig`: ordered array of
  `{ rows(app), draw(app, painter, rect) }`, bottom-anchored stack; update
  `mouseSelectionPoint` to use the same region offsets. This is an array
  literal, not a framework.
- Shrink `trace.zig` per inventory #25.
- Optional backlog (do NOT do in this plan): unify the three row-window
  mechanisms; revisit the composer-scroll-hint sentinel id.

Done when: net-negative diff in `src/tui` + `trace.zig`; flood/feel gates
still green.

## 9. Constants table (single source once implemented: `view_model.zig` / `frame_loop.zig`)

| name | value | policy |
|---|---|---|
| `frame_interval_ms` | 16 | render pacing floor |
| `idle_wait_ms` | 30_000 | max sleep with no deadline |
| `sample_bytes_per_frame_max` | 65_536 | reader copy cap; backpressure-by-frame |
| `resident_items_max` | 256 | ItemStore eviction (evict oldest, advance watermark) |
| `notice_ring_len` | 32 | overwrite-oldest, gap-notice on missed |
| `completion_items_max` | 64 | matches existing cap |
| queue echo caps | 8 + 8 | reject beyond, `dropped` counter |
| assistant/thinking item text cap | 262_144 (256KiB) | truncate-with-chip (amended 2026-07-04: live items mirror `tui.Transcript.total_size_bytes_max` — the UI retains at most 256KiB total, so the VM must never be the binding constraint below it; the old 16KiB values are HISTORY-snapshot caps and apply only to `HistoryWindow` items) |
| tool item text cap | 65_536 (64KiB) | truncate-with-chip (≥ `tui.Transcript.tool_preview_bytes_max`) |
| ItemStore total resident text bytes | 524_288 (512KiB) | evict oldest whole items, advance `evicted_through_id` (2x TUI retention; bounds worst-case VM memory independently of per-item caps) |
| watchdog budget | 33ms → 17ms after Phase 3 gate | debug assert |
| reader wake list | 4 | reject beyond |

## 10. Explicitly not doing

- No general-purpose TUI framework, layout tree, or widget system.
- No render thread / double-buffered flush (frame-loop-plan 2c measured
  no-go stands).
- No rpc wire protocol design in this plan; only the parking note.
- No multi-session tabs; but every new structure (ViewModel epoch,
  ViewCursor, reader list) must be per-session-shaped so tabs are additive
  later, and any deviation from that must be flagged, not assumed.
- No changes to tool semantics, providers, `ai`, or persistence format. The
  jsonl format is frozen through this plan.
