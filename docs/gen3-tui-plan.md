# gen-3 TUI plan — single-loop, alt-screen, vaxis-rendered

Status: **approved for implementation**. Written 2026-07-06 against commit `b5b2ef9`
(branch `interactive`, working tree with `src/tui/`, `src/frontends/`, and the
Engine/view_model/wire_protocol/client_protocol/engine_drain layer deleted).

This document supersedes `docs/big-bang-plan.md`, `docs/frame-loop-plan.md`,
`docs/parity-audit.md`, and `docs/parity-burndown.md` for all frontend work. Those
documents are historical records of generations 1 and 2 and must not be used as
design input, only as evidence for the trap list in §1.2.

Every file:line citation in this plan was verified against the working tree (or
`git show HEAD:` for deleted files) on the date above. **If any cited API does not
match the code when you implement, stop and report the mismatch — do not improvise
around it.**

---

## 0. Ground rules for the implementing agent

- **G1** Toolchain: Zig **0.16.0** exactly (`build.zig.zon` `minimum_zig_version`).
  Commands: `zig build` (binary), `zig build test` (all tests, includes the
  zio-import check step, `build.zig:69-78`).
- **G2** Dependencies: **no new dependencies.** `zio` and `vaxis` are vendored and
  already wired as module imports named `"zio"` and `"vaxis"` (`build.zig:23,29,37-38`).
  `zio` may only be imported by `src/runtime/zio_backend.zig` — enforced by build
  (`build.zig:69-75`). `vaxis` may be imported **only** by files under `src/tui/`.
- **G3** Work in phases P0–P5 (§5–§10), in order. A phase is done only when its
  acceptance gate passes. Do not start phase N+1 with phase N's gate red.
- **G4** Do not modify `src/agent/`, `src/ai/`, or `src/runtime/` except for the
  exact edits listed in P0 (§5). If you believe another edit is needed, stop and report.
- **G5** Every behavior in this plan is normative. Where the plan says "decide X = Y",
  Y is the decision — there are no open choices. Anything not covered: pick the
  smallest implementation consistent with §1.2's trap list and note it in the PR
  description.
- **G6** Every new module ships with tests in the same file (repo convention).
  Timing-sensitive tests must be run serialized and 3× before declaring green
  (§13.4). No test may inject `Options.stream` to bypass provider resolution (§13.3).
- **G7** All user-facing strings come from Appendix C verbatim.
- **G8** All numeric constants come from Appendix A. Introducing a new time constant
  anywhere outside `src/tui/Loop.zig` is a plan violation (trap T4).

---

## 1. Context and binding constraints

### 1.1 What was deleted and why

~22.6k LoC of frontend: `src/tui/*` (11.1k), `src/frontends/*` (5.4k incl. print
mode), and the in-process protocol tier `src/coding_agent/{Engine, engine_drain,
view_model, client_protocol, wire_protocol}.zig` (6.4k). Two generations of frontend
died of the same disease: a **translation corridor** moving presentation facts
between an "engine side" and a "UI side" of one process (gen-1: wire-shaped events;
gen-2: Engine→engine_drain→view_model→view_diff→tool_view, ~5,400 LoC of pure
translation). The surviving core (`src/runtime/`, `src/agent/`, `src/ai/`,
`src/coding_agent/` minus the protocol tier) is healthy and is **not** being rewritten.

The build is currently broken: `src/root.zig`, `src/coding_agent/root.zig`,
`src/coding_agent/AgentSession.zig`, `src/coding_agent/file_completion.zig`, and
`src/cli/root.zig` still import deleted files. P0 fixes this.

### 1.2 The trap list (binding)

Distilled from the gen-1/gen-2 post-mortem. Each is a hard constraint; PR review
rejects violations.

- **T1** No protocol between the agent and the screen inside one process. The seam
  is a Zig function call (`Transcript.apply(AgentEvent)`), not typed envelopes.
- **T2** "What to show" and "how to show" live in the same place, on the same
  execution context. One file owns each pixel behavior (tool presentation lives
  only in `blocks.zig`).
- **T3** A transcript item exists in exactly one place plus derived caches guarded
  by a `dirty` flag. No per-layer mirrors, no cursor/rev protocols.
- **T4** Exactly one time constant in the data path's vicinity: the 16 ms frame
  coalesce in `Loop.zig`. No producer-side throttles, pacing, or reveal queues. If
  you feel you need one, the data model is wrong — stop and report.
- **T5** One Io runtime (the zio runtime behind `src/runtime`). The only primitive
  crossed by foreign threads is `WakeEvent.set` (proven foreign-thread-safe:
  `src/runtime/wake_event.zig:67-94`). No `SharedMutex`, no wake-pipe zoo.
- **T6** No dead protocol kept "for a future rpc client". The rpc mode stays the
  stub it already is (`cli/root.zig:272-285`).
- **T7** No opaque ids used as discriminators. Pickers and completions are direct
  calls returning typed results; there are no query ids.
- **T8** User-facing copy is composed at the site that knows the cause (Appendix C),
  never laundered through semantic enums across layers.
- **T9** No generic worker slots on the hot path. Prompt submit is a direct call.
- **T10** "Done" is the behavior catalog (§2.2), not mechanism gates. The perf gates
  are necessary, not sufficient.
- **T11** End-to-end tests drive the real provider-resolution path via the
  env-gated faux provider (`ZI_ENABLE_FAUX_PROVIDER=1`,
  `src/coding_agent/runtime_services.zig:62-77,203-225`). Never inject
  `Options.stream` in an e2e test.
- **T12** No revision taxonomy. UI state bookkeeping is `dirty: bool` per item plus
  the viewport anchor. Single-threaded mutation needs nothing else.
- **T13** One copy of each streamed byte into the model (at `Transcript.apply`),
  bounded by Appendix A caps. Frames move pointers.
- **T14** The painter (`screen.zig`) holds zero application state.
- **T15** Known-good specs from the old code are re-implemented as written specs
  (bounds policy, `utf8Prefix` truncation, input drain cap, test-serialization lore)
  — never by resurrecting old files.

### 1.3 Invariants

- **I1 Alt-screen.** The TUI runs full-screen in the alternate screen buffer.
  Scrollback is virtual (owned by the app, §8). On any exit path — clean, error,
  panic — the terminal is restored (§6.2.4).
- **I2 Always responsive.** Input echo and UI feedback never wait on network, tool
  output, or transcript size. Perceived 60 fps: p99 key-echo < 16 ms under flood
  (§12 gates).
- **I3 Streaming-first.** Assistant text, thinking, and tool output render live as
  they stream. Backpressure is the bounded `EventPipe` blocking the producer
  coroutine (TCP flow control) — nothing is dropped, nothing is throttled.
- **I4 Minimal.** Total new code budget ≈ 6.5k LoC (§4). This is a minimal coding
  agent, not a framework.

---

## 2. Product spec

### 2.1 Screen layout (alt-screen, full size W×H)

```
row 0        header:    zi <version> · <session title> · <model id> · thinking:<level>
row 1..T     transcript viewport (T = H - 1 - Q - S - E - 1)
             ┌ user message block
             ├ assistant markdown (streaming)
             ├ tool block: status glyph + title, tail/body
             ├ notices, compaction summaries
row ..Q      queue lines (0..3 dim lines: "steering: …" / "follow-up: …", + hint)
row ..S      status line (spinner "Working…", retry countdown, notices — 1 row,
             blank when idle and no notice)
row ..E      editor (bordered, 3..max(5, 30% of H) rows incl. border)
row H-1      footer: <cwd, ~-relative>            <ctx NN.N%> ↑<in> ↓<out> tokens
```

The hardware cursor is shown at the editor's logical cursor position (or the
picker's filter field). Everything else renders styled cells.

### 2.2 Behavior catalog (the definition of done)

Numbered; P-column = phase that delivers it.

| #   | P  | Behavior |
|-----|----|----------|
| B1  | P2 | Assistant text streams as live markdown; the streaming item repaints in place each frame; earlier items never repaint during streaming. |
| B2  | P2 | Thinking parts render italic + dim when `hide_thinking == false`; when hidden, a single dim "Thinking…" line shows while thinking streams. Toggling (B22) relayouts the whole transcript, preserving the viewport anchor. |
| B3  | P2 | A tool block appears the moment its toolcall id streams (from `message_update`/`toolcall_start`), title updates live as args stream, before execution starts. |
| B4  | P2 | Tool block status tint: pending (dim) → running (accent) → success (ok tint) / error (error tint). |
| B5  | P2 | Running tools show a live tail preview of the last 5 output lines (`tool_execution_update`) plus an elapsed timer ("Elapsed 3s" → "Took 3s" on completion). |
| B6  | P2 | ESC during a run aborts it; all in-flight tool blocks flip to aborted tint with "aborted" text; run settles as failure notice. |
| B7  | P3 | Ctrl+O toggles expanded/collapsed on all tool bodies globally (collapsed = 5-line preview + "… N more lines"; expanded = full bounded body). |
| B8  | P2 | Typing is never blocked. The editor keeps focus and echoes during streaming. Enter while streaming = steer; Alt+Enter = follow-up. |
| B9  | P2 | Queued messages render as dim "steering:"/"follow-up:" lines above the status row with the dequeue hint; Alt+Q moves all queued text back into an empty editor and clears the queue. |
| B10 | P2 | ESC cascade, in priority order: picker open → close picker; completion popup → dismiss; retry countdown → cancel retry (run fails with notice); compacting → cancel compaction; streaming → abort run and (if editor empty) restore queued text into editor; idle → no-op. |
| B11 | P1 | Ctrl+C: first press clears the editor (shows exit hint); second press within 500 ms exits. Ctrl+D on empty editor exits. |
| B12 | P3 | Virtual scrollback: wheel (3 lines/tick), PgUp/PgDn (viewport−2 lines). Scrolled-up view is anchored — streaming appends below do not move it; chrome shows "↓ N new lines"; PgDn at bottom (or any submit) re-pins to follow-tail. |
| B13 | P2 | Enter on `/command` input dispatches slash commands (§9.4): /help /session /model /resume /new /compact /settings. Unknown → notice with the catalog. |
| B14 | P4 | Slash-command autocomplete popup when the editor starts with `/`; `@`-token file completion via `file_completion.Index` (Tab forces). Popup replaces nothing — it overlays above the editor inside the chrome region. |
| B15 | P4 | Pickers (model, session, settings) render in a fixed-height panel below the composer, pushing the composer upward. The composer remains the focused omni input and supplies filter text; picker rows overflow inside the panel by selection-windowing. Up/Down moves selection, Enter/Tab selects or pushes a child frame, ESC pops a child frame or hides the root without changing editor text. |
| B16 | P4 | Session restore renders the full transcript (user/assistant/tools matched to results by call_id/compaction summaries) through the same `Transcript.apply` fold as live events; user messages seed editor history; header shows "compacted N times" when applicable. |
| B17 | P2 | Compaction: cancellable status spinner "Compacting context… (esc to cancel)"; on success a compaction-summary block is appended and the run resubmits when `will_retry`. Threshold compaction auto-runs after a completed run when `shouldRunThresholdCompaction()` (`AgentSession.zig:973-982`). |
| B18 | P2 | Auto-retry: status line "Retrying (n/max) in Ns… (esc to cancel)" with a live countdown ticking from the loop clock; error notice only on final failure. |
| B19 | P2 | "Working…" spinner in the status row for the whole run (`agent_start`→`agent_end`). |
| B20 | P4 | Footer: ~-relative cwd left; context % (colored per Appendix A thresholds) and session token ↑/↓ counts right, from `contextUsage()` and `agent.state`. |
| B21 | P2 | Editor border color encodes thinking level (Appendix A palette). |
| B22 | P4 | `/settings thinking:<level|shown|hidden>` applies immediately (B2) and persists via `SettingsManager` (`settings.zig:120-131`). |
| B23 | P4 | Terminal title: OSC 0 `zi - <session title> - <cwd basename>` on startup and session switch (`vaxis.Vaxis.setTitle`, `Vaxis.zig:863`). |
| B24 | P1 | Resize: width change relayouts everything and repaints; height change repaints; no crash, viewport anchor preserved by item. Worst-case resize latency 100 ms (legacy path §6.3), instant with in-band resize. |
| B25 | P1 | Exit hygiene: alt-screen left, kitty keyboard popped, bracketed paste and mouse off, termios restored — on clean exit, error return, **and panic** (§6.2.4). Kill -9 leaves at most a recoverable terminal (`reset` fixes it) — nothing we can do there. |
| B26 | P2 | Large paste (>1000 chars or >10 lines) collapses to an atomic `[paste #N +M lines]` marker (cursor treats it as one unit; expanded on submit). Bracketed paste arrives as one event. |
| B27 | P2 | Editor: multi-line (Shift+Enter via kitty, `\` + Enter fallback), grapheme-aware cursor motion, Emacs kill ring (Ctrl+K/U/W, Ctrl+Y), word-coalesced undo (Ctrl+_ / Ctrl+Z is NOT suspend, see B28), 100-entry prompt history on Up/Down at first/last visual line. |
| B28 | —  | Out of scope v1 (explicit): user `!cmd` bash, tree/fork navigation, inline images, image paste, external `$EDITOR` round-trip, terminal suspend (Ctrl+Z), mouse click/drag (wheel only), OSC 9;4 progress, OSC 8 hyperlinks, `/model` set-as-default persistence, queuing submits during compaction (rejected with notice instead). Each is a named follow-up, not an accident. |

### 2.3 Alt-screen consequences (accepted, do not "fix")

Native terminal scrollback/search/selection do not see transcript history; the
virtual viewport (B12) is the only history view. Retention bounds (Appendix A) are
therefore generous (2000 items / 8 MiB). A copy-mode / export command is a named
follow-up, not in v1.

---

## 3. Architecture

### 3.1 Concurrency model

**Two threads. One runtime. One wait point.**

1. **Main thread** — creates one `runtime.Runtime` (zio; `executors` defaults to
   `.exact(1)`, i.e. single-threaded, `vendor/zio/src/runtime.zig:61-70`) and runs
   the TUI owner loop **directly on the main thread**, calling blocking operations
   through `task_runtime.io()`. This is the proven in-tree pattern: `auth_mode.login`
   drives OAuth HTTP through the runtime from the plain main thread
   (`cli/root.zig:108-120`), and every `AgentSession` test polls runs from the test
   thread. While the loop is parked in `wake.waitTimeout`, the runtime's executor
   advances the agent's producer coroutines (SSE reader, tool workers) — cooperative
   single-executor scheduling is exactly the design.
2. **InputPump thread** (`std.Thread`) — owns nothing but stdin bytes. Reads with a
   100 ms `poll(2)` timeout loop (reusing `src/runtime/fd_readiness.zig`), pushes
   into an SPSC byte ring, calls `wake.set(io)` (foreign-thread-safe,
   `wake_event.zig:67-94`), checks a stop flag each iteration. §6.3.

**The one wait point** (the only place the loop blocks):

```zig
loop.wake.waitTimeout(io, timeout) catch |err| switch (err) {
    error.Timeout => {},
    error.Canceled => return,
};
loop.wake.reset();
```

(`WakeEvent.waitTimeout(io, std.Io.Timeout)`, `wake_event.zig:24-26`; timeout built
as `.{ .duration = .{ .raw = .fromMilliseconds(n), .clock = .awake } }`.)

Everything sets this one event:

- the run stream, via `RunHandle.setWake(io, &loop.wake)` (`AgentSession.zig:292-297`)
  — every pipe emit/end/abort fires it (`event_pipe.zig:52-54`);
- the InputPump after each byte batch and on resize-flag observation;
- `spawnBlocking` completions are observed via `Task.hasResult()` polling at loop
  iterations (no extra wake needed; the completing op is always paired with a
  deadline or an existing wake source).

**Backpressure:** the run stream's `EventPipe` buffer is 64 events
(`AgentSession.zig:26,234`). When the loop drains slower than tokens arrive, the
producer coroutine blocks in `emit`, which stops reading the HTTP socket — TCP flow
control to the provider. Nothing is dropped. The lossy 256-cap public-event tier is
**deleted** in P0, not replaced.

**Cancellation:** ESC → `handle.cancelRequest(session)` (same coroutine;
`AgentSession.zig:324-329` → `cancelPromptRun`: `agent.abort()` +
`stream.cancelProducer()`, `AgentSession.zig:560-571`). The producer observes cancel
at its next suspension point. No polling floor.

**Large-payload rule:** any single CPU-bound step that can exceed ~2 ms on the
owner loop must go through `task_runtime.spawnBlocking` with a typed `Task(T)`
result (`Runtime.zig:87-93`). Concretely in v1: `file_completion.Index.build` at
startup, and nothing else — `Transcript.apply` is delta-bounded by construction
(§7.3). If profiling (§12) shows another >2 ms step, move it the same way.

### 3.2 Dataflow

```
                    ┌────────────────────── main thread (zio exact(1)) ───────────────────┐
 stdin ─► InputPump │ ring ─► input.zig ─► keymap ─► Loop.dispatch ──► Editor / Viewport   │
 (thread)  wake.set │                                    │  direct calls                   │
                    │                                    ▼                                 │
                    │                          AgentSession (startPromptHandle, queue-     │
                    │                          Prompt, cancel, setModel, …)                │
                    │  SSE producer coroutine ─► EventPipe(64) ─► RunHandle.poll ──┐       │
                    │                                     (fires listeners in-thread)      │
                    │                                    ▼                                 │
                    │                    Transcript.apply(AgentEvent)  [the only seam]     │
                    │                                    ▼ dirty flags                     │
                    │   frame due? ─► layout dirty items ─► viewport slice ─► chrome ─►    │
                    │   screen.paint (vaxis cells) ─► vx.render(tty) ─► one write+flush    │
                    └──────────────────────────────────────────────────────────────────────┘
```

### 3.3 The five load-bearing interfaces

1. `Transcript.apply(self: *Transcript, event: agent_mod.AgentEvent) !void` —
   registered as an `Agent.Listener` (`Agent.zig:55-57,217-227`), fired inside
   `RunHandle.poll`. Event is **borrowed**: its arena dies when
   `applyPromptRunProgress` returns (`loop.zig:11-19`, `AgentSession.zig:538-558`);
   `apply` copies what it keeps. §7.3.
2. `RunDriver.pump(self, session: *AgentSession, io: std.Io) !void` — the
   poll → settle → verdict state machine. §7.5.
3. `layout.itemLines(item: *Item, width: u16, th: *const Theme, epoch: LayoutEpoch)
   []const Line` — memoized per item. §7.6.
4. `viewport.slice(vp: *Viewport, total_lines: usize, height: u16) LineRange` +
   anchor maintenance. §8.2.
5. `screen.paint(s: *Screen, frame: Frame) !void` — writes cells into the vaxis
   window, calls `vx.render(tty.writer())`, flushes. Holds zero app state. §6.5.

### 3.4 Mutable state inventory (complete)

| State | Owner | Notes |
|---|---|---|
| `Transcript` (items + caches) | Loop coroutine | T3: sole item store |
| `Editor` (lines, cursor, undo, kill ring, history) | Loop | |
| `Viewport` (mode: follow / anchored{item_seq, line_off}) | Loop | T12 |
| `RunDriver` (idle/running/retry_wait/compacting + saved prompt) | Loop | |
| `Focus` (`union(enum){ editor, picker: *Picker }`) | Loop | |
| Chrome scratch (spinner phase, notice, last_flush) | Loop | frame arena |
| `AgentSession` internals | AgentSession (same coroutine) | untouched core |
| SPSC ring + stop flag + resize flag | InputPump ↔ Loop | atomics only |
| Trace ring + latency histogram | Loop | §12 |

Nothing else. There is no other mutable state.

---

## 4. Module map and budgets

New code under `src/tui/` (all files new; the directory is empty):

| File | Responsibility | LoC budget |
|---|---|---|
| `root.zig` | `run(...)` bootstrap: services, session open, wiring, teardown order | 150 |
| `Loop.zig` | wake mux, deadlines, dispatch, RunDriver, ESC cascade, slash effects | 550 |
| `InputPump.zig` | stdin thread, SPSC ring, resize flag, timestamps | 130 |
| `Terminal.zig` | tty + vaxis lifecycle, alt-screen, caps, panic restore, title | 300 |
| `input.zig` | Parser feed, lone-ESC deadline, keymap tables, release filtering | 280 |
| `Editor.zig` | composer per B26/B27 | 1000 |
| `Transcript.zig` | item store, `apply`, bounds/eviction, restore fold | 700 |
| `blocks.zig` | ALL tool presentation: titles from args, tint, tail, body, expand | 450 |
| `markdown.zig` | line-oriented markdown → spans (§7.7 subset), MdState | 500 |
| `layout.zig` | item → wrapped `Line`s, memo, incremental tail wrap | 450 |
| `viewport.zig` | scroll state, follow/anchor, new-lines hint | 250 |
| `chrome.zig` | header/footer/status/queue rows, editor region composition, popup | 350 |
| `screen.zig` | frame → vaxis window → render/flush; zero app state | 200 |
| `pickers.zig` | model + session pickers (filter/list/select) | 350 |
| `theme.zig` | palette, ColorLevel detection (moved from old cli helpers) | 180 |
| `trace.zig` | frame ring, latency histogram, exit report | 200 |
| **total** | | **≈ 6,040** |

Plus: `src/coding_agent/session_bootstrap.zig` (~180, §5.3),
`src/frontends/print/print_mode.zig` rebuilt in P5 (~220, §10.1).

Vaxis usage — allowed surface: `Tty` (`tty.zig:57-124,143,174`), `Vaxis`
(`init/deinit/resize/window/enterAltScreen/exitAltScreen/queryTerminal/
enableDetectedFeatures/render/queueRefresh/setTitle/setBracketedPaste/setMouseMode`,
`Vaxis.zig:108-906`), `Parser.parse` (`Parser.zig:53`), `Key`, `Cell`, `Segment`,
`Style`, `Window.print/printSegment/writeCell/clear/fill/showCursor/hideCursor/child/gwidth`
(`Window.zig:104-473`), `gwidth`, `ctlseqs`, `Winsize`, `Mouse`, `Panic`. Forbidden:
`vaxis.Loop`, `vxfw`, `widgets/`, `Image`/zigimg paths.

---

## 5. Phase P0 — build repair (net-negative diff, no new features)

Goal: `zig build` and `zig build test` green with the deletion applied. The binary's
`--mode text|json|rpc` and interactive modes print a stub and exit 2; `zi auth …`
still fully works.

### 5.1 `src/coding_agent/AgentSession.zig` surgery

Remove imports `engine_drain`, `client_protocol`, `view_model` (lines 13, 16, 20).
Then, precisely:

1. **Delete the public-event tier**: `public_event_capacity_default` (24),
   `Options.public_event_capacity` and `Options.view_sink` (157-158), `ViewSink`
   (1412), `PublicEventQueue` (1414), `DummyQueueMirror` (1416-1424), and in
   `SessionEvents`: fields `view_sink`, `public_event_buffer`, `public_events`,
   `queue_mirror`, `public_event_wake`, `pending_public_event_overflow_count`;
   methods `emitQueueUpdate`, `enqueuePublicEvent`, `enqueueClientEvent`,
   `queueSnapshot`, `drainPublicEvent`, `publicEventWake`, `publicEventCount`,
   `droppedPublicEventCount`, `publicEventsEmpty` (1570-1681). Delete the
   session-level forwarders `drainPublicEvent/publicEventWake/publicEventsEmpty`
   (791-801). In `shutdownComplete` (617-622) drop the `publicEventsEmpty()`
   conjunct. In `SessionEvents.handle` (1482-1528) delete every
   `view_sink`/`enqueuePublicEvent` branch — what remains is: queued-echo removal on
   user `message_start`, `persistMessage` on `message_end`, overflow counting, and
   retry-attempt reset. In `failRetry` (1536-1555) and `settlePromptRun` (856-869)
   delete event construction; retry facts flow to the owner via `SettleVerdict.retry`
   and the getters below.
2. **Local types replacing client_protocol** (define in AgentSession.zig):
   ```zig
   pub const CompactionReason = enum { manual, threshold, overflow };   // was client_protocol.zig:605
   pub const ContextUsage = struct { tokens: ?u64 = null, window: u64 = 0, percent_tenths: ?u32 = null };
   ```
   Retype `CompactionRun.reason` (218), `startCompactionHandle` (484),
   `startCompactionRun` (986). Rename `clientContextUsage` →
   `pub fn contextUsage(self: *const AgentSession) ContextUsage` (668-698), keeping
   the math byte-for-byte; update `shouldRunThresholdCompaction` (978).
3. **Delete snapshot surface**: `clientSnapshot` (624-652), `clientChromeSnapshot`
   (654-666), `clientHistoryPage` (728-734), `chrome` (770-789). The underlying data
   stays reachable: `manager.header`, `agent.state.model`,
   `agent.state.thinking_level`, `hide_thinking`, `contextUsage()`.
4. **Expose the queue echoes** (chrome reads them each frame — one owner, T3):
   make `QueuedEcho` and its `Kind` `pub` (1426-1432) and add
   `pub fn queuedEchoes(self: *const AgentSession) []const QueuedEcho
   { return self.events.queued_echoes.items; }`.
5. **Expose retry/failure facts as getters** (replacing auto_retry events):
   `pub fn retryAttempt(self: *const AgentSession) u8`,
   and keep `latestAssistantError`/`latestOperationalFailure` (already session
   methods; retype the latter to return `?ai.OperationalFailure` if it does not
   already).
6. **Fix tests** at 1861/1898 (and any other `client_protocol.` references in
   tests): assert on `ai.OperationalFailure.Category` via
   `latestOperationalFailure()` and on `retryAttempt()`/`SettleVerdict` instead of
   drained events.
7. Everything else in the file — `RunHandle`, `SettleVerdict`, `PromptRun`,
   `CompactionRun` mechanics, persistence, compaction, retry policy — is untouched.

### 5.2 Other file repairs

- **`src/coding_agent/file_completion.zig`**: replace the `client_protocol` import
  (line 10) with local constants (values from deleted `client_protocol.zig:36-38,202`):
  ```zig
  pub const completion_id_bytes_max = 256;
  pub const completion_label_bytes_max = 160;
  pub const completion_detail_bytes_max = 160;
  pub const file_completion_query_bytes_max = 256;
  ```
  Replace `Item.source()`'s `client_protocol.CompletionItem.Source` return type
  (35-41) with a local `pub const Source = struct { id: []const u8, label: []const u8, detail: []const u8 };`.
- **`src/coding_agent/session_manager.zig`**: move `SessionStamp` here verbatim
  from deleted `Engine.zig:93-125` (`pub const SessionStamp = struct { text: [20]u8,
  nanoseconds: i96, pub fn now(io) …, date(), timestamp() }`).
- **`src/coding_agent/root.zig`**: drop exports/imports of `Engine`,
  `client_protocol`, `view_model`, `wire_protocol`, `engine_drain` (6, 8, 12, 13, 17
  and test block). Add `pub const AgentSession = @import("AgentSession.zig");`,
  `pub const runtime_services = @import("runtime_services.zig");`,
  `pub const session_manager = @import("session_manager.zig");`,
  `pub const settings = @import("settings.zig");`,
  `pub const file_completion = @import("file_completion.zig");`,
  `pub const session_bootstrap = @import("session_bootstrap.zig");` (created below).
- **`src/root.zig`**: remove the six deleted-frontend imports (print, tui/*,
  frontends/*); add `_ = @import("tui/root.zig");` once P1 creates it (P0: leave
  out).
- **`src/cli/root.zig`**: remove imports of `Engine`, `print_mode`, `frame_loop`,
  `trace`, `input_reader`, `pickers`, `worker`, `tui/root.zig` (7-15). Replace
  `runTui`, `runPrompt`, `runRpc` bodies with the Appendix C "being rebuilt" stub +
  `error.UnsupportedCliFeature` (keep `runRpc` that way permanently, T6). Delete
  `openEngineRuntime`, `writeTracePath`, `resolveTerminalInfo`, `resolveColorLevel`
  (the last two move into `src/tui/theme.zig` in P1). Keep `selectResumeSession`
  (session_listing is intact) and all auth paths. Rewrite the Engine-based tests
  (373-600) to target `session_bootstrap.openSession` + `selectResumeSession`.
- **`src/coding_agent/session_bootstrap.zig`** (new): recreate the deleted Engine's
  startup resolution as a pure function library (semantics verified from
  `git show HEAD:src/coding_agent/Engine.zig:819-880,385`):
  ```zig
  pub const OpenSpec = union(enum) {
      create: struct { session_id: []const u8, timestamp: []const u8 },
      resume_existing: struct { session_file_name: []const u8 },
  };
  pub const Overrides = struct {
      model: ?ai.Model = null,
      thinking_level: ?agent_mod.ThinkingLevel = null,
      stream: ?ai.StreamFunction = null,
  };
  pub fn openSession(allocator: std.mem.Allocator, services: *RuntimeServices,
      current_date: []const u8, spec: OpenSpec, overrides: Overrides) !AgentSession;
  pub fn streamFor(services: *const RuntimeServices, model: ai.Model) ?ai.StreamFunction;
      // = services.provider_registry.get(model.api).?.stream_simple  (Engine:385,879)
  ```
  Resolution rules (normative, R1–R6):
  - **R1** Settings pair: if `project.default_provider != null or project.default_model != null`
    use project, else global (`settingsValue` over `services.settings_manager.current()`).
  - **R2** Model: `overrides.model` → settings pair's `default_model` resolved via
    `ai.getModel(provider, model_id)` if `auth_manager.hasAuth(model.provider)` and
    `provider_registry.get(model.api) != null` → first model in `ai.models` passing
    the same two checks → `agent_mod.Agent.defaultModel()`.
  - **R3** Stream: `overrides.stream` → `streamFor(model)`; leave
    `Options.stream = null` only if the registry has no provider (then the first
    run fails with the provider notice — never silently).
  - **R4** `get_api_key = services.auth_manager.hook()` (`auth.zig:216`).
  - **R5** Retry/compaction settings: project → global → defaults
    (`Settings.Retry/Compaction`, `settings.zig:15-26`); map onto
    `AgentSession.RetrySettings` / `session_manager.CompactionSettings`.
  - **R6** `hide_thinking`: project → global `hide_thinking_block` → `true`.
  - Store: `.create` → `StoreOptions{ .create = SessionStore.create(...) }`;
    `.resume_existing` → `.{ .restore = ... }` (signatures at
    `session_manager.zig:891-976`); `thinking_level` from overrides else `.off`.
  Unit tests: R1–R6 against a tmp-dir settings/auth fixture (pattern:
  `runtime_services.zig:179-245`).

### 5.3 P0 acceptance gate

`zig build` green; `zig build test` green (includes check-zio-imports);
`zig-out/bin/zi --version` works; `zi "hi" --mode text` and bare `zi` print the
stub and exit 2; `zi auth status openai-codex` works. `grep -R "client_protocol\|view_model\|engine_drain\|wire_protocol" src/` → no hits.

---

## 6. Phase P1 — terminal skeleton

Deliverables: `theme.zig`, `Terminal.zig`, `InputPump.zig`, `input.zig`,
`screen.zig`, `trace.zig`, `Loop.zig` (shell: wake mux + deadlines + dispatch, no
agent), minimal `chrome.zig`, `Editor.zig` v0 (single-line echo + cursor motion +
Ctrl+C/D), plus a synthetic streaming generator for the flood harness. `cli/root.zig
runTui` now enters the real TUI.

### 6.1 Bootstrap (`src/tui/root.zig`)

```zig
pub const Options = struct {
    initial_prompt: ?[]const u8,      // from CLI positional
    open: coding_agent.session_bootstrap.OpenSpec,
    resume_picker: bool,              // open session picker on start (P4)
};
pub fn run(process: runtime.Process, options: Options) !void;
```

Order (init): `runtime.Runtime.init(process.gpa, .{})` → `RuntimeServices.init`
(cwd/agent_dir resolution copied from the old CLI call sites) →
`session_bootstrap.openSession` → `Terminal.init` → `InputPump.start` → `Loop.run`.
Teardown (reverse, always): pump stop+join → terminal restore → session shutdown
(§9.7) → services/runtime deinit. `cli/root.zig` keeps ownership of arg parsing and
resume selection (`selectResumeSession`), passing an `OpenSpec`.

### 6.2 `Terminal.zig`

Wraps `vaxis.Tty` + `vaxis.Vaxis`.

1. **Init**: `Tty.init(io, &read_buffer)` (opens `/dev/tty`, raw mode;
   `tty.zig:57-91`) — but **reads come from the InputPump on fd 0**, never from
   `Tty.read`; the Tty is used for its writer, termios, and winsize
   (`getWinsize`, `tty.zig:174`). `Vaxis.init(io, gpa, env_map, .{})` →
   `enterAltScreen(w)` → `queryTerminalSend` + wait ≤ `query_timeout_ms` →
   `enableDetectedFeatures(w)` → `setBracketedPaste(w, true)` → `setMouseMode(w,
   true)` → initial `vx.resize(gpa, w, winsize)`.
2. **Kitty keyboard** is entered by `enableDetectedFeatures` when supported; legacy
   fallback is automatic. Key-release events are filtered in `input.zig` (kitty
   sends them; we drop all `.release`).
3. **Restore** (`deinit`, idempotent): `vx.deinit(gpa, w)` — vaxis resetState exits
   alt screen, pops kitty kbd, disables paste/mouse (`Vaxis.zig:122-165`) — then
   Tty deinit restores termios (`tty.zig:91-98`).
4. **Panic**: set `pub const panic = vaxis.Panic;` in `src/main.zig`
   (`vendor/libvaxis/src/main.zig:50-52` provides the handler; it restores the tty
   before printing the panic). Additionally `Terminal.deinit` must be tolerant of
   partial init (nullable stages).
5. **Title**: `setTitle` per B23.

### 6.3 `InputPump.zig`

```zig
pub const InputPump = struct {
    ring: SpscRing(u8, 32768),                   // power-of-two byte ring, atomics
    stamps: SpscRing(BatchStamp, 64),            // {ring_pos: u32, read_ns: u64} per read() batch
    stop: std.atomic.Value(bool),
    resize_seen: std.atomic.Value(bool),
    thread: std.Thread,
};
```

Thread body: loop { if stop → return; `fd_readiness.poll(stdin_fd, 100ms)`
(`src/runtime/fd_readiness.zig`); if readable → `posix.read` into a 4096-byte stack
buffer → push bytes (on ring full: drop the batch, increment a dropped counter —
never block; assert-log in debug) → push a `BatchStamp` with `std.time.Instant`
nanos → `wake.set(io)`; if `resize_flag` atomic (set by the SIGWINCH handler
installed via `Tty.notifyWinsize`, `tty.zig:124` — the handler does **only**
`resize_flag.store(true)`, async-signal-safe) → `resize_seen.store(true)` +
`wake.set(io)` }. Stop: `stop.store(true)` then `thread.join()` (≤100 ms).
Additionally vaxis in-band resize (mode 2048), when the terminal supports it,
arrives through the Parser as a resize event — handle both paths; dedupe by
comparing against current winsize.

SpscRing spec: single producer/single consumer, `head`/`tail`
`std.atomic.Value(u32)`, `.acquire`/`.release` orderings, capacity power of two,
`push(item) error{Full}`, `popSlice(buf) usize`. Unit tests: wraparound, full,
cross-thread smoke (pattern of `wake_event.zig:67-94`).

### 6.4 `input.zig`

- Loop drains ≤ 4096 bytes/iteration (T15 spec) into a carry buffer (max 64 bytes
  carry for split escapes). Feed `vaxis.Parser.parse(buf, paste_allocator)`
  (`Parser.zig:53`): returns `{event, n}`; `n == 0` with nonempty buffer ⇒
  incomplete sequence: arm a **10 ms** loop deadline; if it expires and the buffer
  still starts with `0x1b`, emit `Key{ .codepoint = Key.escape }` and consume 1
  byte. Paste events use a per-frame arena as `paste_allocator`.
- Filter: drop key-release events; intercept capability/color events (feed to
  `Terminal`); translate `Mouse` wheel to `Action.scroll{±3}` and drop all other
  mouse events.
- Keymap: comptime table `[]const Binding{ .{ .key, .mods, .action } }` per focus
  context (editor / picker), resolved with `vaxis.Key.matches`. Bindings: Appendix B.
  Output: `pub const Action = union(enum) { insert: []const u8, key_editor: EditorOp,
  submit, newline, steer_submit, follow_up_submit, cancel, clear_or_quit, quit_eof,
  expand_toggle, dequeue_all, scroll: i32, page_up, page_down, force_redraw, none };`

### 6.5 `screen.zig` + frame composition

```zig
pub const Span = struct { text: []const u8, style: vaxis.Style };
pub const Line = struct { spans: []const Span };   // pre-wrapped: total gwidth ≤ width
pub const Frame = struct {
    rows: []const Line,          // exactly H rows, top to bottom (frame arena)
    cursor: ?struct { col: u16, row: u16 },
};
pub fn paint(self: *Screen, vx: *vaxis.Vaxis, tty_writer: *std.Io.Writer, frame: Frame) !void;
```

`paint`: `win = vx.window()`; `win.clear()`; for each row r, col=0: for each span
`win.printSegment(.{ .text, .style }, .{ .row_offset = r, .col_offset = col,
.wrap = .none })`, advancing col from the returned `PrintResult`; cursor →
`win.showCursor(col,row)` else `win.hideCursor()`; `vx.render(tty_writer)`
(cell-diff, synchronized output, relative moves — `Vaxis.zig:375-845`); flush the
writer. Zero fields besides scratch (T14). **Width invariant**: layout emits lines
with visible width ≤ W; debug builds assert via `win.gwidth`, release truncates with
`agent_mod.utf8Prefix` (`src/agent/root.zig:726-729`) — pi's crash-on-overflow
contract, softened to assert.

### 6.6 `Loop.zig` shell — iteration contract (normative order)

1. `waitTimeout(deadline)`; `wake.reset()`.
2. Drain input ring → actions → dispatch (mutates editor/viewport/etc., sets
   `dirty`). **Input is always processed before rendering in the same iteration.**
3. `driver.pump(session, io)` (P2+; no-op in P1's synthetic mode).
4. Tick timers: spinner phase (80 ms), elapsed-timer seconds, retry countdown,
   Ctrl+C/ESC 500 ms windows expiring → set `dirty` when a visible value changed.
5. If `dirty` and `now - last_flush ≥ 16 ms`: layout dirty items → compose Frame →
   `screen.paint` → record trace → `last_flush = now`, `dirty = false`.
6. Next deadline = min(frame-due-if-dirty, next timer, lone-ESC deadline); no
   deadlines and not dirty → wait `.none` (infinite).

Resize handling: on resize event/flag → `vx.resize(gpa, w, new_winsize)`, bump
`layout_epoch` on width change (invalidates every item memo), `dirty = true`.
Full-clear is vaxis's `queueRefresh` — never manual escapes.

### 6.7 `theme.zig`

`ColorLevel` detection moved verbatim from `cli/root.zig:224-240`
(COLORTERM/TERM/`ZI_THEME_LIGHT`). Palette: named `vaxis.Style` constants (Appendix
A table) with truecolor RGB and 256-color fallbacks chosen by ColorLevel.
`LayoutEpoch = struct { width: u16, expanded: bool, hide_thinking: bool, n: u32 }`.

### 6.8 P1 acceptance gate

- Manual matrix: Terminal.app, iTerm2, kitty, Ghostty, tmux — alt-screen up/down
  clean (B25), typing echoes, resize storms don't corrupt (B24), Ctrl+C×2 exits.
- Synthetic flood: a loop-internal generator coroutine appends 50 KB/s of text to a
  scratch transcript item for 60 s while the editor is typed into. Trace report
  (§12): p99 iteration-to-flush < 16 ms, no frame > 33 ms, Debug build, 3×
  serialized.
- Panic path: a debug-only `--panic-test` flag panics after 1 s; terminal restored.
- Kill criterion (pre-named): if `vx.render` cell-diff cost exceeds the frame
  budget at 250×80 (it should not — it is O(W×H) with cheap cell equality), the
  fallback is damage-tracking per transcript row before paint. Do not build that
  speculatively.

---

## 7. Phase P2 — the agent seam

Deliverables: `Transcript.zig`, `blocks.zig`, `markdown.zig`, `layout.zig`,
`RunDriver` in `Loop.zig`, full `Editor.zig`, queue/status chrome; behaviors
B1–B6, B8–B11, B13, B17–B19, B21, B26, B27.

### 7.1 Transcript model

```zig
pub const Transcript = struct {
    gpa: std.mem.Allocator,
    items: std.ArrayList(*Item),
    live_tools: std.StringArrayHashMap(*Item),   // call_id → tool item, cleared on run settle
    streaming_item: ?*Item,                       // current assistant item
    total_bytes: usize,
    next_seq: u64,
    evicted_seqs: u64,                            // count, for viewport anchor math
};
pub const Item = struct {
    arena: std.heap.ArenaAllocator,   // owns ALL bytes of this item incl. layout cache
    seq: u64,
    dirty: bool = true,
    cached_width: u16 = 0,
    cached_epoch: u32 = 0,
    lines: []layout.Line = &.{},      // memoized layout, arena-backed
    wrap: layout.WrapState = .{},     // incremental tail wrap (§7.6)
    kind: Kind,
};
pub const Kind = union(enum) {
    user: struct { text: std.ArrayList(u8) },
    assistant: struct {
        parts: std.ArrayList(Part),   // Part = union(enum){ text: std.ArrayList(u8), thinking: std.ArrayList(u8) }
        streaming: bool,
        stop: enum { ok, aborted, errored } = .ok,
        error_text: ?[]const u8 = null,
    },
    tool: struct {
        call_id: []const u8, name: []const u8,
        title: []const u8,            // built by blocks.zig, rebuilt as args stream
        args_preview: std.ArrayList(u8),          // ≤ 2 KiB
        status: enum { pending, running, done, failed, aborted },
        started_ns: ?u64 = null, duration_ms: ?u64 = null,
        tail: TailBuffer,             // last 5 lines while running (blocks.zig)
        body: std.ArrayList(u8),      // final output, ≤ 64 KiB + truncation notice
        body_truncated: bool = false,
    },
    notice: struct { level: enum { info, warn, err }, text: []const u8 },
    compaction: struct { summary_first_line: []const u8, tokens_before: u64 },
};
```

Bounds and eviction (T15, values in Appendix A): appends are chunked to ≤ 8 KiB per
event application with `utf8Prefix`; per-item text cap 256 KiB (further appends
dropped with a one-time `[output truncated]` marker); transcript caps 2000 items
and 8 MiB total — evict oldest items (arena freed whole; `evicted_seqs += 1`;
viewport anchor clamps, §8.2). A running tool's tail buffer is fixed-size (5 × 200
bytes) and never counts toward totals.

### 7.2 Listener registration and lifetime

In `root.zig` after session init:
`_ = try session.agent.subscribe(.{ .context = transcript, .call_fn = Transcript.applyListener });`
(`Agent.zig:217-227`; the session's own persistence listener is registered first in
`AgentSession.init`, `AgentSession.zig:432`). `applyListener` signature must match
`Agent.Listener.call_fn`: `fn (std.Io, ?*anyopaque, agent_mod.AgentEvent,
runtime.CancelToken) anyerror!void` (`Agent.zig:55-57`).

**Lifetime contract (memorize):** the event and everything it references live in a
per-event arena freed when `applyPromptRunProgress` returns
(`loop.zig:11-19`, `AgentSession.zig:544-555` — `defer event.deinit()` runs after
`emitEvent` fans out to listeners). `apply` must copy every byte it keeps into the
target item's arena. It must not stash pointers, must not call session methods, and
must not render.

### 7.3 The apply table (exhaustive; `AgentEvent` per `src/agent/root.zig:635-673`)

| Event | Mutation |
|---|---|
| `agent_start` | chrome status → working spinner on (loop reads a `run_active` flag; set it) |
| `agent_end` | spinner off; `live_tools.clearRetainingCapacity()` |
| `turn_start` / `turn_end` | no-op |
| `message_start` (`.user`) | append `user` item with copied text (`message_policy.userText` shape); dirty |
| `message_start` (`.assistant`) | append `assistant` item, `streaming = true`, set `streaming_item` |
| `message_start` (`.tool_result`, `.custom`) | no-op (tool results arrive via tool_execution events; customs render on restore only) |
| `message_update` → inner `ai.AssistantMessageEvent` (`protocol.zig:462-511`): | |
| — `.start` | no-op (item exists from message_start) |
| — `.text_start` / `.thinking_start` | ensure part at `content_index` exists with matching tag |
| — `.text_delta` / `.thinking_delta` | append `payload.delta` (chunked/utf8Prefix) to part; `dirty = true`. **Never touch `payload.partial`** — delta-only is what makes apply O(delta) (T13) |
| — `.text_end` / `.thinking_end` | replace part content with `payload.content` if it differs in length (authoritative final) |
| — `.toolcall_start` | create tool item (status `.pending`, placeholder title from `blocks.titleFor(name, "")`); register in `live_tools` by the id found in `payload.partial`'s toolcall content at `content_index` |
| — `.toolcall_delta` | append delta to `args_preview` (≤2 KiB); `title = blocks.titleFor(name, args_preview)`; dirty |
| — `.toolcall_end` | finalize title from `payload.tool_call`; dirty |
| — `.done`, `.@"error"` | no-op (message_end is authoritative) |
| `message_end` (`.assistant`) | `streaming = false`, `streaming_item = null`; reconcile parts against `payload.message` content (replace text/thinking bytes if they differ); if `stop_reason == .aborted` or `.error_`: set `stop`, copy the error text, and flip every `live_tools` item with status `.pending`/`.running` to `.aborted` (B6); dirty |
| `message_end` (`.user`/`.tool_result`/`.custom`) | no-op |
| `tool_execution_start` | lookup `live_tools[tool_call_id]` (create the item if a provider skipped toolcall_start); status `.running`, `started_ns = now`; dirty |
| `tool_execution_update` | extract text from `partial_result.content` (`AgentToolResult`, `root.zig:156-160`; text items only) → `blocks.updateTail`; dirty |
| `tool_execution_end` | status = `is_error ? .failed : .done`; `duration_ms` from `started_ns`; copy result text content into `body` (cap + truncation marker); drop from `live_tools`; dirty |

`apply` is a pure state fold — unit-testable headless with hand-built events
(§13.1). Coalescing is unnecessary by construction: per-event work is O(delta).

### 7.4 `blocks.zig` — the ONE owner of tool presentation (T2)

- `titleFor(name, args_json_prefix) []const u8` — per-tool title synthesis from
  streamed args (partial JSON tolerated: extract the first string value of the
  known key). Rules: `read`/`write`/`edit` → `<name> <path>`; `bash` → `$ <command
  first line, ≤ 60 cols>`; unknown tool → `<name>`. Uses
  `src/ai/utils/partial_json.zig` for tolerant extraction.
- `TailBuffer`: fixed 5 × 200-byte lines, `\r`-normalized, tab→2 spaces;
  `updateTail(partial_text)` keeps the last 5 visual lines.
- `bodyLines(tool, expanded) []const []const u8` — collapsed = first 5 lines +
  Appendix C "more lines" marker; expanded = full body.
- Status glyphs and tints (Appendix A).
- Elapsed text: "Elapsed Ns" while running (ticked by the loop's 1 s timer marking
  running tool items dirty), "Took Ns" when done.

### 7.5 RunDriver (in `Loop.zig`)

```zig
pub const RunDriver = struct {
    state: State = .idle,
    saved_prompt: ?SavedPrompt = null,   // owned copy: text + images; freed on final settle
    overflow_count_before: usize = 0,
    overflow_retry_used: bool = false,
    retry: ?struct { deadline_ns: u64, attempt: u8, max: u8 } = null,
    pub const State = union(enum) {
        idle,
        running: AgentSession.RunHandle,
        retry_wait: AgentSession.SettleVerdict.Retry,   // + retry field above for display
        compacting: struct { handle: AgentSession.RunHandle, will_retry: bool },
    };
};
```

Transition table (normative):

| From | Trigger | Action → To |
|---|---|---|
| idle | submit(text, images) | save prompt copy; `overflow_count_before = session.contextOverflowCount()`; `handle = try session.startPromptHandle(text, images)` (`AgentSession.zig:470-476`); `handle.setWake(io, &wake)` → **running**. Errors: map per Appendix C (`SessionBusy` etc. from `ensureCanStartRun`, 921-929) |
| running | loop iteration | `while true: switch (try handle.poll(session))` (`271-313`): `.live` → continue; `.empty` → break; `.settled` → settle below |
| running | settled | `verdict = try handle.settle(session, .{ .overflow_count_before, .overflow_retry_used })`; `handle.deinitAfterSettled(session)`; then: `.completed` → maybe threshold-compaction (B17) else free saved prompt → **idle**; `.failed` → failure notice from `latestAssistantError()` → **idle**; `.retry = r` → record deadline `now + r.delay_ms`, attempt = `session.retryAttempt()` → **retry_wait**; `.compact = run` → `RunHandle.compaction(run)` + setWake → **compacting** (will_retry = run.will_retry) |
| retry_wait | deadline reached (loop timer) | `.resubmit_prompt` → startPromptHandle(saved prompt); `.continue_run` → `session.startContinueHandle()` (478-480) → **running** |
| retry_wait | ESC | `session.cancelRetryWait()` (879-887); failure notice → **idle** |
| compacting | poll/settle like running | verdict `.completed`: append compaction item; if `will_retry` → resubmit saved prompt → **running**, else notice "compacted" → **idle**. verdict `.failed`/`.retry`: treat `.retry` as failed (compaction retry not supported v1); notice → **idle** |
| compacting | ESC | `handle.cancelRequest(session)`; poll to settled; settle; notice → **idle** |
| any | Ctrl+C×2 / Ctrl+D / quit | shutdown procedure §9.7 |

While **running**: Enter → `session.queuePrompt(text, &.{}, .steer)`; Alt+Enter →
`.follow_up` (`803-828`; errors per Appendix C). While **retry_wait** or
**compacting**: submits rejected with Appendix C notice (B28 divergence). Manual
`/compact`: only from idle; `startCompactionHandle(.manual, false, null)`
(482-490); `null` → "nothing to compact" notice.

### 7.6 Layout and incremental wrap

```zig
pub const WrapState = struct {
    committed_bytes: usize = 0,      // source offset up to which lines are final
    committed_lines: usize = 0,
    md: markdown.MdState = .{},      // carried fence/list/quote state at the commit point
};
pub fn itemLines(item: *Item, width: u16, th: *const Theme, epoch: LayoutEpoch) []const layout.Line;
```

- Cache hit iff `!item.dirty and item.cached_width == width and item.cached_epoch == epoch.n`.
- Full relayout (epoch/width change): reset WrapState, wrap everything.
- Streaming append (dirty, same width/epoch): re-wrap **only** from
  `committed_bytes`; after wrapping, advance the commit point to the end of the
  last **markdown-block boundary** (blank line, or fence open/close line) that is
  followed by at least one more byte — never mid-block, so late tokens can restyle
  the open block but committed lines are physically final. This bounds per-frame
  work to O(new bytes + open block) and kills the historical 84 ms
  single-line-rewrap trap by construction. A pathological single block (e.g. one
  64 KiB line) is bounded by the 8 KiB append chunking: each chunk becomes its own
  wrappable region.
- Wrapping: grapheme-aware via `vaxis.gwidth` + `vaxis.unicode` word wrap; break at
  spaces, fall back to hard break; every produced `Line` satisfies the ≤ width
  invariant (§6.5).

### 7.7 `markdown.zig` (normative subset)

Line-oriented, `MdState`-carrying. Supported: `#`–`######` headings; fenced code
blocks (``` with optional info string; content styled mono/dim, no highlighting);
`>` quotes; `-`/`*`/`1.` list bullets (2-space nesting); inline `code`,
`**bold**`, `*italic*`; `[text](url)` renders text underlined, url dropped; `---`
rule. **Inline styles terminate at end of line** (documented divergence from pi,
same as gen-2's spec). Tables render as plain text. No HTML. `MdState = { fence:
?struct{ char: u8, len: u8 }, quote_depth: u8, list_stack: … }` — exactly what the
commit-point carry needs.

### 7.8 Editor (B26/B27) — key specs

State: `lines: std.ArrayList(std.ArrayList(u8))`, cursor {line, byte_col};
grapheme motion via `vaxis.unicode.GraphemeIterator`. Soft wrap at editor width;
height = clamp(content, 1, max(5, H*3/10)) content rows + border. Undo: ring of 32
full snapshots, coalesced while consecutive inserts stay within one word. Kill
ring: 8 entries, consecutive kills append, `Ctrl+Y` yank (no yank-pop v1). History:
100 entries, deduped consecutive, navigated at first/last visual line; current
draft stashed. Paste markers per B26 with a side map `markers: id → text`,
expanded on submit in order. Slash/`@` completion hooks land in P4 (the editor
exposes `currentToken()` for them).

### 7.9 P2 acceptance gate

- Headless: `Transcript.apply` unit suite covering every row of §7.3's table,
  including out-of-order tool events (execution_start before toolcall_start),
  abort mid-tool, 8 KiB chunking, caps/eviction.
- E2E (T11): `ZI_ENABLE_FAUX_PROVIDER=1 ZI_FAUX_SCRIPT=<fixture> zi` in a pty
  harness (`std.posix.openpty` + fork/exec of `zig-out/bin/zi`, harness lives in
  `src/tui/testing/pty_harness.zig`, test-only): prompt → streamed markdown
  renders; ESC aborts; Ctrl+C×2 exits clean; terminal restored (termios compared
  before/after).
- Flood: faux provider with `ZI_FAUX_DELAY_MS=0` and max script (16 KiB,
  `runtime_services.zig:116`) for correctness; sustained-rate flood via the P1
  synthetic generator now feeding real `AgentEvent`s (`message_update` deltas at
  1 MB/s for 30 s, plus one synthetic 4 MiB `tool_execution_end`) — gate: p99
  input-to-flush < 16 ms, no frame > 33 ms, RSS flat after caps reached, zero
  drops; Debug, 3×, serialized.

---

## 8. Phase P3 — viewport, rebuild ops, resize hardening

Delivers B7, B12, B24 fully, B2's toggle path.

### 8.1 Line index

Frame composition needs `total transcript lines` and `line → (item, offset)`
mapping. With ≤ 2000 items, keep it simple: each frame, walk items summing
`lines.len` into a scratch prefix-sum array (frame arena; 2000 × usize — trivial).
No incremental index, no cleverness (T12).

### 8.2 Viewport

```zig
pub const Viewport = union(enum) {
    follow,                                        // pinned to bottom
    anchored: struct { item_seq: u64, line_in_item: u32, lines_below_seen: u32 },
};
```

- `follow`: viewport bottom = last transcript line.
- Scroll up from follow → anchored at the first fully-visible line's (item_seq,
  line). While anchored: appends don't move the view; chrome shows Appendix C
  "new lines" hint with a live count.
- Re-pin (→ follow): PgDn/wheel-down reaching bottom, any submit, or session switch.
- Eviction/rebuild: if the anchored item was evicted, anchor to the oldest live
  item at line 0. Width/epoch change: recompute `line_in_item` clamped to the
  item's new line count (anchor by item, not by absolute line — no teleporting).

### 8.3 Rebuild ops (the only whole-transcript relayouts, T4-adjacent)

`Ctrl+O` (expanded), `/settings thinking:shown|hidden` (hide_thinking), width
resize, compaction rebuild, session switch: bump `layout_epoch.n`, set every item
dirty, preserve viewport per §8.2. These are user-initiated and allowed to cost
≤ 10 ms at the cap (measure in the trace; assert < 50 ms in the pty test).

### 8.4 P3 acceptance gate

Headless viewport unit tests (anchor math across append/evict/resize/toggle).
Pty test: 3000-item session (forces eviction), scroll up during flood — anchored
view byte-stable across 100 frames (compare pty snapshots); Ctrl+O with 500 tools
< 50 ms relayout; resize storm (20 SIGWINCH/s for 5 s) never corrupts; hint counter
accurate.

---

## 9. Phase P4 — chrome, pickers, slash effects, completion, restore/switch

Delivers B14–B16, B20, B22, B23; full slash catalog behavior.

### 9.1 Footer/header (B20)

From `session.manager.header` (title/cwd), `session.agent.state.model.id`,
`state.thinking_level`, `session.contextUsage()` (P0 getter). Context % =
`percent_tenths` colored per Appendix A. Token counts summed from
`manager.entries` assistant usage — compute once per `message_end` (cache in Loop,
not in AgentSession).

### 9.2 Completion popup (B14)

- Trigger: editor's current token starts with `/` (slash catalog:
  `slash_commands.builtins`, filtered by prefix; plus `/settings thinking:*`
  argument completions) or with `@` (file completion), or Tab forces file mode.
- `file_completion.Index.build(gpa, root_dir)` runs once at startup via
  `spawnBlocking` (Task polled at loop iterations; popup shows "indexing…" until
  ready); the Index is immutable afterwards; `index.query(alloc, raw)` per
  keystroke (bounded: `item_count_max = 64`, `file_completion.zig:12`) with results
  copied into the frame arena.
- Popup renders ≤ 8 rows above the editor inside the chrome region; Up/Down cycle,
  Enter/Tab accept (replaces the token), ESC dismisses. Focus stays `editor`
  (popup is not a focus target — T7-adjacent simplicity).

### 9.3 Pickers (B15)

Picker/listbox state is a bounded stack of typed frames. Stack entries carry
frame kind + selected row metadata; Loop owns the bounded row buffer for the
active top frame. The picker does **not** own text input or focus. The composer
is the omni input: the current slash-argument token supplies filter text,
printable keys edit the composer, Up/Down moves the top frame selection,
Enter/Tab selects the row, and ESC pops one child frame or hides the root frame
without restoring or rewriting editor text. Chrome renders the active frame in a
fixed-height panel below the composer; row overflow is handled by Loop windowing
around the selected row.
Model picker rows: `ai.models` filtered to `provider_registry.get(model.api) !=
null`, authed providers (`auth_manager.hasAuth`) sorted first, label =
`provider/model_id`. Session picker rows:
`session_listing.listRuntimeSessionSummaries` (`session_listing.zig:133`, fields
title/detail/meta/aux/file_name, 36-51). Settings root rows push child frames such
as thinking effort and thinking visibility; child selections emit direct typed
setting actions in Loop. Selection → typed callback in Loop. The picker never
replaces the editor region.

### 9.4 Slash-command effects (owner: `Loop.dispatchSlash`, catalog:
`slash_commands.zig:39-129`)

| Action | Effect |
|---|---|
| `.help` | notice: `formatAvailable` (131-140) |
| `.session` | notice block: session file name, title, cwd, model, thinking level, context tokens/window/%, entry count |
| `.model` (empty args) | open model picker; select → `session.setModel(model, session_bootstrap.streamFor(services, model))` (`AgentSession.zig:741-751`) + notice |
| `.model` (args) | parse `provider/model-id` or bare model-id searched across registered providers via `ai.getModel`; found → as above; not found → Appendix C notice |
| `.resume_session` (empty) | open session picker; select → switch §9.6 |
| `.resume_session` (args) | switch §9.6 with `.resume_existing{ .session_file_name = args }` |
| `.new_session` | switch §9.6 with `.create` (fresh SessionStamp id `tui-<ns>`) |
| `.compact` | manual compaction per §7.5 |
| `.settings` bare | open settings root frame with `/settings ` kept in the composer; category rows can push child frames such as thinking effort/visibility |
| `.thinking_level` | `session.setThinkingLevel(level)` (753-762) + notice |
| `.hide_thinking` | `session.setHideThinking(v)` (766-768) + `services.settings_manager.setHideThinkingBlock(v)` (`settings.zig:131`) + epoch bump (B2) |
| `.unknown` | Appendix C unknown-command notice |

### 9.5 Session restore fold (B16)

On open of a restored session, before entering the loop: iterate
`session.manager.entries` (`SessionEntry`, `session_manager.zig:67-107`):
`.message{.user}` → user item + editor history push; `.message{.assistant}` →
assistant item from final message content (text/thinking parts; toolCall content
parts create tool items registered by call_id); `.message{.tool_result}` → attach
to the pending tool item by `tool_call_id` (status done/failed via `is_error`);
`.message{.custom}` → skip; `.compaction` → compaction item; `.model_change` /
`.thinking_level_change` → info notices. Then one layout pass. This reuses the same
item constructors as `apply` — restore and live rendering share one code path.

### 9.6 Session switch (adapted from deleted Engine 525-565; divergence: reuse the
same `RuntimeServices` — settings changes require restart, documented)

Preconditions: driver idle (else Appendix C busy notice). Steps: build
`SessionStamp.now(io)`; `openSession(gpa, services, stamp.date(), spec, .{ .model =
current model, .thinking_level = current, .stream = current loopConfig().stream })`;
on success: shutdown old session (§9.7 without process exit), swap, clear
transcript + `live_tools`, restore-fold the new session (§9.5), re-pin viewport,
set title (B23), notice "started new session"/"resumed session". On failure: keep
old session, error notice.

### 9.7 Shutdown procedure (normative order)

1. If driver not idle: `handle.cancelRequest(session)`, then poll→settle→
   `deinitAfterSettled` (bounded: ≤ 5 s wall; after that proceed anyway and log).
2. `session.requestShutdown()` (`AgentSession.zig:599-615`).
3. `while (!session.shutdownComplete())` wait on wake with 100 ms timeout (≤ 5 s).
4. `session.deinit()` (asserts complete, 451-468).
Process exit path additionally: pump stop/join **before** terminal restore, then
Terminal.deinit, then services/runtime deinit (§6.1 order).

### 9.8 P4 acceptance gate

Pty script: `/model` picker selects faux model and a prompt streams with it;
`/resume` into a fixture session renders the restored transcript identical to a
golden snapshot (`docs/baselines/`, captured via `scripts/capture_baselines.sh`
pattern); `/new` mid-scroll re-pins and retitles; footer % matches
`contextUsage()` fixture; completion popup filters and inserts. All headless unit
suites green.

---

## 10. Phase P5 — print mode, hardening, parity audit

### 10.1 Print mode rebuild (`src/frontends/print/print_mode.zig`, ~220 LoC)

`pub fn run(gpa, services, session: *AgentSession, io, stdout, stderr, opts:
struct{ prompt: []const u8, output: enum{text,json} }) !u8` — headless RunDriver:
start prompt, wake-wait loop, poll; per event in `.text` mode print assistant
`text_delta`s; in `.json` mode print each `AgentEvent` as one JSON line (the
`jsonStringify` impls exist, `root.zig:675-716`); honor retry verdicts (sleep via
`io`), compaction, exit 0/1 per final verdict. Wire back into `cli/root.zig`
`runPrompt`. This is also the T11 e2e carrier: `ZI_ENABLE_FAUX_PROVIDER=1 zi -p
"hi" --mode json` asserted in tests.

### 10.2 Hardening checklist

- 5-terminal manual matrix re-run of B24/B25 + tmux inside ssh.
- `NO_COLOR`/`ZI_THEME_LIGHT`/`TERM=dumb` (dumb → refuse TUI with stub message,
  run print mode hint).
- Fuzz `input.zig` with random byte streams (must never panic; carry buffer bounded).
- Leak check: GPA leak assertions in pty tests' child exit.

### 10.3 Definition of done

Every B-row in §2.2 demonstrated (checklist in PR description, one line each with
evidence: test name or pty snapshot path). Trace gates (§12) green 3×. Update
`CONTEXT.md` and `AGENTS.md` to describe the gen-3 architecture (they are the
living docs; this plan then becomes historical like its predecessors).

---

## 11. Memory & ownership rules (M-rules, binding)

- **M1** `process.gpa` (from `std.process.Init`) is the root; `Transcript`,
  `Editor`, caches, rings allocate from it.
- **M2** One arena per transcript item owns the item's bytes AND its layout cache;
  freed whole on eviction. No item byte is ever referenced from outside the item
  except within a single frame's composition (frame arena copies nothing — it
  holds span slices pointing into item arenas, valid because eviction only happens
  during `apply`, never between layout and paint of the same iteration).
- **M3** Frame arena (`std.heap.ArenaAllocator`, reset with retain_capacity each
  frame): prefix sums, chrome lines' formatted text, paste parse scratch, popup rows.
- **M4** Event data is borrowed during `apply` (§7.2); copy-on-keep, chunked.
- **M5** Editor lines/undo/kill/history: gpa, bounded (Appendix A).
- **M6** `SavedPrompt` (RunDriver) is a gpa copy freed on final settle (all verdict
  paths — audit each).
- **M7** No `[N]u8`-by-value structs holding text that is later sliced
  (the gen-2 `BoundedText` UAF class). Owned slices or arena bytes only.
- **M8** Cross-thread: only `u8`/POD through the SPSC rings; no allocator use on
  the pump thread.
- **M9** `self.* = undefined` poisoning on every deinit (repo convention).
- **M10** Debug builds: GPA with `.safety = true` in the pty harness child.

---

## 12. Instrumentation (built in P1, permanent)

`trace.zig`:

- `FrameRecord { wake_ns, input_bytes, events_applied, apply_us, layout_us,
  paint_us, flush_us, flush_bytes }` in a fixed ring of 512 (overwrite oldest).
- Input latency histogram: per InputPump `BatchStamp`, latency = flush-complete
  time of the frame that consumed the batch minus `read_ns`; log2 buckets 1 ms →
  1024 ms + overflow.
- Rebuild-op timings (epoch bumps) recorded separately.
- Report: `ZI_TUI_TRACE=1` env → on exit write
  `$TMPDIR/zi-tui-trace-<ns>.log` (reuse the old cli pattern) with: p50/p90/p99
  frame totals and per-phase, histogram table, max frame, dropped-input count,
  eviction count. The pty gates parse this file.

**The perf gates** (P2 §7.9, rechecked in P5): Debug build, serialized, 3 runs
each: p99 input-to-flush < 16 ms; zero frames > 33 ms; sustained 1 MB/s
`message_update` flood for 30 s with 30 cps typing; one 4 MiB synthetic
`tool_execution_end` during flood; RSS flat after caps.

---

## 13. Testing policy & process lore

- **13.1 Headless-first**: `Transcript`, `layout`, `markdown`, `viewport`,
  `Editor`, `RunDriver` (with a faux-provider session), `blocks` all test without a
  terminal. The pty harness is only for terminal-lifecycle, rendering-snapshot, and
  latency gates.
- **13.2 Pty harness**: `src/tui/testing/pty_harness.zig` — `openpty`, fork/exec
  `zig-out/bin/zi` with a controlled env, scripted writes with per-key delays,
  reads with timeouts, snapshot = raw byte capture normalized (cursor-park
  stripped). Golden files under `docs/baselines/gen3/`.
- **13.3** T11: e2e always through real provider resolution with
  `ZI_ENABLE_FAUX_PROVIDER=1` (+ `ZI_FAUX_SCRIPT`, `ZI_FAUX_DELAY_MS`,
  `runtime_services.zig:143-165`). `Options.stream` injection is allowed **only**
  in unit tests below the session layer.
- **13.4** Lore (paid for in gen-2, keep): don't pipe `zig build test` through
  filters that swallow failures; run timing-sensitive tests serialized and 3×;
  wall-clock assertions belong in the pty gates, not unit tests.

---

## Appendix A — constants (single source of truth)

| Name | Value | Home |
|---|---|---|
| `frame_interval_ms` | 16 | Loop.zig (the ONE pacing constant, T4) |
| `lone_esc_flush_ms` | 10 | input.zig (parser disambiguation, not pacing) |
| `double_key_window_ms` (Ctrl+C, ESC-idle) | 500 | Loop.zig |
| `spinner_interval_ms` | 80 | Loop.zig timer table |
| `elapsed_tick_ms` / retry countdown tick | 1000 | Loop.zig timer table |
| `pump_poll_ms` | 100 | InputPump.zig |
| `query_timeout_ms` (terminal caps) | 500 | Terminal.zig |
| input drain per iteration | 4096 B | input.zig |
| SPSC ring | 32768 B / 64 stamps | InputPump.zig |
| append chunk (utf8Prefix) | 8192 B | Transcript |
| per-item text cap | 256 KiB | Transcript |
| tool body cap | 64 KiB | Transcript |
| tool args preview cap | 2 KiB | Transcript |
| tool tail | 5 lines × 200 B | blocks.zig |
| transcript caps | 2000 items / 8 MiB | Transcript |
| editor: history/undo/kill ring | 100 / 32 / 8 | Editor.zig |
| editor height | max(5, H·3/10) content rows | Editor.zig |
| paste marker threshold | >1000 chars or >10 lines | Editor.zig |
| completion rows / popup rows | 64 / 8 | file_completion (existing) / chrome |
| wheel scroll / page scroll | 3 / viewport−2 lines | viewport.zig |
| context % colors | <70 ok, 70–90 warn, >90 error | theme.zig |
| shutdown bounds | 5 s cancel-settle, 5 s drain | Loop.zig |
| Palette (truecolor / 256 idx): text #C8C8C8/252 · dim #808080/244 · accent #7AA2F7/111 · ok #9ECE6A/149 · warn #E0AF68/179 · error #F7768E/210 · thinking-level border: off dim, minimal/low accent, medium warn, high/xhigh error | theme.zig |

## Appendix B — keymap (editor focus unless noted)

| Key | Action |
|---|---|
| printable / paste | insert (paste per B26) |
| Enter | submit; while streaming → steer (B8); on `/…` → slash dispatch |
| Alt+Enter | follow-up submit |
| Shift+Enter, or trailing `\` + Enter | newline |
| ESC | cascade B10 |
| Ctrl+C | clear editor / exit on 2nd within 500 ms (B11) |
| Ctrl+D | exit if editor empty, else delete-forward |
| Ctrl+O | expand toggle (B7) |
| Alt+Q | dequeue-all (B9) |
| Up / Down | cursor line; at first/last visual line → history |
| Left/Right, Alt+B/F, Home(Ctrl+A)/End(Ctrl+E) | grapheme/word/line motion |
| Backspace / Ctrl+W / Ctrl+K / Ctrl+U | delete grapheme / word-back / to-EOL / to-BOL (kills fill ring) |
| Ctrl+Y | yank |
| Ctrl+_ | undo |
| Tab | accept completion / force file completion |
| PgUp / PgDn | viewport page (B12) |
| Mouse wheel | viewport ±3 |
| Ctrl+L | force full repaint (`vx.queueRefresh`) |
| Picker focus: type=filter, Up/Down=move, Enter=select, ESC=close | |

## Appendix C — user-facing copy (verbatim)

| Situation | Text |
|---|---|
| CLI stub (P0) | `this frontend is being rebuilt; try a newer build` |
| queue full | `queue is full ({d} queued)` |
| submit while idle got steer path | (unreachable; assert) |
| submit during retry/compaction | `busy: waiting to retry — esc to cancel` / `busy: compacting — esc to cancel` |
| run aborted | `aborted` |
| run failed | `error: {s}` (latestAssistantError) |
| retry status | `Retrying ({d}/{d}) in {d}s… (esc to cancel)` |
| compacting status | `Compacting context… (esc to cancel)` / `Auto-compacting… (esc to cancel)` |
| compacted | `context compacted` |
| nothing to compact | `nothing to compact` |
| working | `Working…` |
| queued lines | `steering: {s}` / `follow-up: {s}` / hint `alt+q edits queued messages` |
| new-lines hint | `↓ {d} new lines` |
| tool collapsed marker | `… {d} more lines (ctrl+o)` |
| output truncated | `[output truncated]` |
| paste marker | `[paste #{d} +{d} lines]` |
| exit hint after Ctrl+C | `press ctrl+c again to exit` |
| unknown command | `unknown command /{s} — {s}` (formatAvailable) |
| unknown model | `unknown or unauthenticated model: {s}` |
| session switch | `started new session` / `resumed session` |
| switch while busy | `finish or cancel the current run first` |
| settings usage | `usage: /settings thinking:<off|minimal|low|medium|high|xhigh|shown|hidden>` |
| indexing files | `indexing files…` |

## Appendix D — verified API quick-reference

- `runtime.Runtime.init(gpa, .{})` → `*Runtime`; `.io()`; `.spawn/.spawnBlocking`
  → `Task(T){ join, cancel, hasResult, getResult }` (`Runtime.zig:52-98`). zio
  executors default `.exact(1)` (`vendor/zio/src/runtime.zig:61-70`).
- `runtime.WakeEvent`: `.init`, `set(io)` (foreign-thread-safe), `reset()`,
  `wait(io)`, `waitTimeout(io, std.Io.Timeout)` (`wake_event.zig`).
- `AgentSession`: `init(gpa, io, Options)`, `deinit` (asserts shutdownComplete);
  `startPromptHandle(text, images) !RunHandle` (470), `startContinueHandle` (478),
  `startCompactionHandle(reason, will_retry, custom) !?RunHandle` (482);
  `queuePrompt(text, images, .steer|.follow_up)` — errors `SessionNotRunning`,
  `QueueFull` (803-828); `clearQueue` (736); `setModel(model, ?stream)` (741),
  `setThinkingLevel` (753), `setHideThinking` (766); `cancelRetryWait` (879);
  `requestShutdown` (599), `shutdownComplete` (617);
  `contextOverflowCount` (895), `shouldRunThresholdCompaction` (973). Post-P0:
  `contextUsage()`, `queuedEchoes()`, `retryAttempt()`.
- `RunHandle`: `setWake(io, *WakeEvent)` (292), `poll(session) !enum{live,empty,settled}`
  (299), `settle(session, SettleContext) !SettleVerdict` (315),
  `cancelRequest(session)` (324), `deinitAfterSettled(session)` (331).
- `SettleVerdict = union(enum){ completed, failed, retry: .{kind: enum{resubmit_prompt,
  continue_run}, delay_ms: u64}, compact: *CompactionRun }` (185-202).
- `Agent.subscribe(Listener{context, call_fn: fn(std.Io, ?*anyopaque, AgentEvent,
  CancelToken) anyerror!void }) !usize` (`Agent.zig:55-57,217`).
- `AgentEvent` union (`agent/root.zig:635-673`); `ai.AssistantMessageEvent`
  (`ai/protocol.zig:462-511`); `AgentToolResult{ content: []ai.ToolResultContent,
  details, terminate }` (`agent/root.zig:156-160`); `utf8Prefix`
  (`agent/root.zig:726`).
- `session_listing`: `listRuntimeSessionSummaries` (133), `selectRuntimeSession`
  (163); `SessionSummary{file_name,title,detail,meta,aux}` (36-51).
- `slash_commands`: `dispatch(text) ?Action` (104), `Action` (39-50),
  `formatAvailable` (131).
- `file_completion`: `Index.build`, `index.query`; caps at top of file (post-P0).
- vaxis: `Tty.init(io, buf)` / `.writer()` / `.getWinsize()` / `.notifyWinsize`
  (`tty.zig:57,114,174,124`); `Vaxis.init(io, alloc, env_map, Options)` (108),
  `enterAltScreen` (238), `queryTerminal(w, Duration)` (257),
  `enableDetectedFeatures` (329), `resize(alloc, w, Winsize)` (194), `window()`
  (224), `render(w)` (375), `queueRefresh` (370), `setTitle` (863),
  `setBracketedPaste` (871), `setMouseMode` (887), `deinit(alloc, w)` (122);
  `Parser.parse(input, ?alloc) !{event, n}` (`Parser.zig:53`);
  `Window.printSegment(Segment, PrintOptions) PrintResult` (447), `showCursor`
  (244), `clear` (202), `gwidth` (207); `vaxis.Panic` (`main.zig:50`).
