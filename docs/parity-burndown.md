# Parity burn-down: restore pre-cutover UX on the new architecture

Status: batches 1a/1b done; batches 2-4 implemented in working tree; verification sweep open.
This document is a self-contained handoff. An implementing agent should be
able to work from it with no other conversation context.

## Goal and standing acceptance criterion

zi was cut over to a new architecture (the "big bang", `docs/big-bang-plan.md`)
to make the TUI structurally smooth: engine thread owns the session and writes
a versioned ViewModel; the UI thread samples per frame and renders under one
pacing rule. The performance goal is achieved and gated (17ms debug watchdog,
flood/echo tests, pty baselines in `docs/baselines/`).

The cutover under-ported the presentation layer. The owner's standing
criterion: **end-user UX and product behavior must equal the pre-cutover TUI,
then improve.** The contract for "equal" is `docs/parity-audit.md` — a
pixel-altitude table of 114 rows extracted from the deleted adapter at commit
`46b6276~1`. Nothing is done by mechanism-level reasoning; a row is done when
the visible behavior matches.

Read before working: `CONTEXT.md` (vocabulary/owners), `AGENTS.md` (workflow
and layer rules), `docs/big-bang-plan.md` §1-§6 (architecture and pinned
invariants), `docs/parity-audit.md` (the row contract).

## Architecture invariants you must not break

- `Engine` (engine thread) is the only writer of `view_model.ViewModel`;
  frontends sample. Never add a second writer or block across the boundary
  (pipes + atomics only; UI thread never touches the engine's zio io).
- Sampling is O(new bytes): items stream as suffix deltas via reader cursors.
  Never make the engine or differ redeliver full accumulated text per event.
- `coding_agent` never imports `frontends/`. Presentation *data* lives in the
  ViewModel (bounded); presentation *formatting* lives frontend-side
  (`view_diff.zig`, `tool_view.zig`, `failure_text.zig`, `pickers.zig`).
  Small per-tool rules that select WHAT to publish (bodies, previews, titles)
  are drain policy in `engine_drain.zig`.
- Everything bounded, with a named policy (`view_model.zig` caps; the
  Transcript caps one append at 8KiB — `view_diff` must chunk, already built:
  `appendDeltaCommand`).
- Zig lifetime discipline: never `.slice()` a `BoundedText` reached through a
  by-value copy or a bare `.?` unwrap — capture `&item.tool.?` / `|*tool|`.
  A dangling-slice UAF class already shipped once (fixed in `e4daf99`).
- jsonl persistence order: an item gains `entry_id`/`.final` only after the
  append succeeded.

## State (as of commit c760df0)

Done and committed since the cutover, beyond the original plan:
model/settings resolution at startup (`6b31def`); composer chrome chips +
context wiring (`0c3b879`); tool details pipeline + UAF fix (`e4daf99`);
preview throttle + write line-cap (`15f6dc4`); rich titles from args
(`dedd546`); title polish, no-JSON previews, output normalization (batch 1a);
settled bodies, error status, transcript chunking, serialized test binaries
(batch 1b, `c760df0`). Hermetic e2e exists: faux provider behind
`ZI_ENABLE_FAUX_PROVIDER=1`, pty scenarios in `scripts/capture_baselines.sh`.

Audit rows: the tool-title/body/preview groups (rows 1-32, 43-52) are
implemented; update their Status cells to RESTORED as you verify each.
Remaining work is batches 2-4 below, then the verification sweep.

## Batch 2 — history window and session lifecycle (rows 9, 10, 92-108, 113)

The largest gap: `view_diff.diff` stores `history_rev` but renders nothing —
history paging is nonfunctional, not just unpolished.

1. History rendering (rows 94, 96, 97): when `sample.history` is non-null and
   `state == .open`, translate the window items into `prepend_transcript`
   commands (older pages prepend in reverse page order, exactly the old
   `applyHistoryPage` behavior). Chunk text at 8KiB like live items. Hidden
   thinking rows get the empty hidden placeholder (row 96). Window replace on
   `history.rev` change per `docs/big-bang-plan.md` §3.6.
2. Tail notice (rows 92, 93): while the window is open and
   `history.has_more_after`, show the `new output below; ctrl+end reloads
   tail` notice; `Effect.request_transcript_tail` (already wired to the
   `history_tail` command) closes the window and clears the notice.
3. Live-tail suppression (row 95): while a window is open, the differ skips
   live tail item deltas (plan §3.6 contract) instead of interleaving them.
4. History tool rows (rows 9, 10, 98): the engine's history-window builder
   must fill `ToolMeta` for tool items including `arguments_json` (add a
   bounded field, 2KiB, mirroring `details_json`) so the frontend can derive
   titles via the same rules; settled bodies/footers via
   `tool_view.historyFinish` semantics on the frontend side.
5. `/session` and prompt-command output (rows 99-102, 113): slash-command
   replies with `presentation == .transcript` must appear as transcript items
   again. Give `vm.Item` an optional `title: BoundedText(256)` +
   `markdown: bool` used by `.banner`/custom kinds; the drain publishes
   `/session` output (`Session Info` title, `File:`/`ID`/`**Messages**`/
   `**Tokens**`/`**Cost**` sections — port `formatSessionInfo` from
   `46b6276~1:src/frontends/tui/interactive.zig`) and generic command output
   (`Command` title, markdown).
6. Session change notices (row 104): `started new session` / `resumed
   session` notice on epoch bump, chosen by open kind.
7. Compaction (rows 106, 107, 108): status copy `compacting context`; on
   compaction end, publish a `.compaction_summary` item titled
   `Context Compacted ({reason}, {tokens_before} tokens before)` with the
   markdown summary body — the engine must pass reason/tokens/summary into
   `drain.compactionEnd`; aborted compaction keeps the warning notice and
   restores the working status per row 108.
8. Epoch-reset sweep (rows 103, 105): on epoch change the differ must also
   clear working/queue/completion statuses and notifications, not only the
   transcript. Verify against `applySessionChanged` in the old adapter.

## Batch 3 — failure copy and notify semantics (rows 75-91)

Port the copy/semantic tables from `46b6276~1:src/frontends/tui/interactive.zig`
(`formatOperationalFailureMessage`, `operationalFailureNotifySemantic`,
`notifyAnnote`, `formatRetryStatus`, `formatRejectionMessage`).

1. Extend `vm.NoticeSemantic` with the old categories (auth, rate, context,
   provider, network, cancel, retry, queue_full, ...). The drain maps
   `ai.OperationalFailure.Category` and rejection kinds onto them; fallback
   message table lives in `failure_text.zig` (frontend owns the words).
2. `view_diff.emitNotices` passes annote and per-category TTL (3s-15s table)
   into the notify command; check `tui.notify`'s Set fields for both.
3. Retry: status `retry A/B in Dms[: reason]` (row 80); retry-start notify
   annote `retry`/warn/5s (row 81); retry-end failure annote `retry`/err/10s
   (row 82).
4. Queue-full copies: `prompt queue full ({max})` and `command queue full`
   (rows 85, 86) — surface engine `.busy`/`error.Full` through these strings.
5. Keyed cancel notifies (rows 87, 88): `cancel requested` and `canceled`
   with the old tones/keys.
6. Row 90/91 sweep: diff the copy strings in `frame_loop.zig` (selection
   copy, clipboard errors, input warnings) against the old adapter's exact
   strings; align.

## Batch 4 — chrome and polish (rows 39, 40, 67, 69, 70, 73, 74)

1. Context chip format `12.3%/200k` (row 69): add `context_percent_tenths:
   ?u32` and `context_window: u64` to `vm.Chrome`; `AgentSession.chrome`
   fills from `clientContextUsage`; `formatChromeRight` renders the old
   format (`formatContextUsage` in the old adapter is the reference).
2. Cwd `.` resolution (row 67): resolve to real path engine-side before
   publishing chrome.
3. `no authenticated model` only when provider AND model are unknown (row 70).
4. `loading completions` shimmer while a completion load is in flight
   (row 73): add an in-flight flag to `vm.CompletionSlot` set by the engine
   worker lifecycle; differ emits/clears the shimmer status.
5. Duration chip labels `Elapsed 1.2s` / `Took 1.2s` capitalization (rows
   39, 40) and queue-status priority/tone (row 74) to match old exactly.

## Verification sweep (after batch 4)

1. Walk `docs/parity-audit.md` top to bottom; for each row mark RESTORED (with
   new home) or justify CHANGED/OBSOLETE in the table. CHANGED rows accepted
   by design so far: 42 (per-item duration cursor replaces the 8-slot table),
   47 (engine throttle replaces UI reveal queue), 53-63 (presentation-queue
   mechanics superseded by sampling; UX-visible effects must still hold), 68,
   72. Update the summary counts.
2. Re-run all pty scenarios: `bash scripts/capture_baselines.sh` (includes the
   front-door streaming assertion).
3. Full gates, three consecutive runs (timing tests):
   `set -o pipefail; zig build test && zig build && zig fmt --check src`.
4. Owner acceptance: manual feel pass in a real terminal + tmux/ssh — type and
   scroll mid-stream, run bash/read/write/edit tools, page history, cancel
   mid-tool, paste 17KB, external editor round trip, `/session`, `/model`,
   resume a large session. The owner compares against pre-cutover screenshots.

## Known-cost and backlog (not parity blockers)

- Row 114: unbroken single-line items re-wrap O(len) per append in the
  apply-side scroll math (~84ms for a 64KiB one-liner in Debug). Pre-existing
  before the cutover. Candidate fix: incremental wrap cache for unbroken
  lines in `src/tui` layout.
- `client_protocol.zig` trim (orphaned ClientEvent machinery) and the rpc
  frontend rebuild as a wire adapter deriving events from the ViewModel.
- `scripts/live_smoke.sh`: one real-provider round trip per authed provider,
  one tool call, one cancel; run before releases, never in CI.
- Faux provider cannot script tool calls; `chatty-bash-tool` baseline stays
  manual until it can.
- AgentSession still carries a small caller-drained public event queue for
  its own tests; remove once tests migrate to the ViewModel.

## Process rules (hard-won; follow them)

- Gates always with `set -o pipefail`; a piped `zig build test` swallows
  failures otherwise. Test binaries run serialized (build.zig) because
  wall-clock frame tests flake under concurrent sibling suites; run timing
  tests 3x before trusting a pass or a fail.
- Commit per coherent batch, conventional commits, no emojis, no generated-by
  footers. Update audit row statuses in the same commit as the code.
- When porting from the old adapter, `git show 46b6276~1:<path>` is the
  source of truth for exact strings and behaviors; `tool_view.zig` tests
  encode many expected strings verbatim.
- If delegating to a subagent/LLM implementer: single-file scope per task,
  name the exact reference functions, require first edit within 10 minutes,
  and never let it copy `BoundedText` by value before slicing.
