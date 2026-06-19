# Deep audit — `src/coding_agent` + `src/tui`

> Date: 2026-06-19 · Method: 23 per-submodule deep-read agents, each finding
> adversarially re-verified against the code by an independent skeptic
> (43 agents total). Graded against the canonical invariants in `AGENTS.md` /
> `CONTEXT.md`, with `.references/pi-mono` as the behavioral north star and
> Andrew Kelley's Zig mindset as the architectural one.
>
> This file is a living worklist. Per-unit detail is appended in the
> [Per-unit appendix](#per-unit-appendix); update each unit's status as findings
> are fixed. `code wins` — when a finding here disagrees with the code, re-check
> the code and correct this file.

## Verdict

Both modules are already AK-shaped and close to the "small, polished, efficient"
goal. No architectural rot: state is encoded directly (phase-typed operations,
run state machines, single-writer drains), nearly every accumulation point
carries a named bound, and operational input degrades instead of tearing down
owner loops. `tui` is the strongest module in the codebase; `coding_agent` is
strong but carries a small cluster of mechanical correctness bugs worth fixing
before adding features.

**30 confirmed findings** (25 `coding_agent`, 5 `tui`). 14 of 23 units came back
clean. The HIGH items are mostly one shape — an `errdefer` outliving an
ownership transfer — plus a startup-abort and a missing image bound.

## Scorecard

| Unit | Confirmed | Worst | Status |
|---|---|---|---|
| **coding_agent** | | | |
| session_runtime | 2 | HIGH | open |
| session_listing | 2 | HIGH | open |
| tools_read_write | 5 | HIGH | open |
| skills_resources | 2 | HIGH | open |
| event_plumbing | 3 | MEDIUM | open |
| tools_edit | 2 | MEDIUM | open |
| auth | 1 | MEDIUM | open |
| session_manager | 2 | LOW | open |
| agent_session | 1 | LOW | open |
| tools_bash | 1 | LOW | open |
| tools_framework | 3 | LOW | open |
| config_policy | 1 | LOW | open |
| client_protocol | 0 | clean | — |
| paths | 0 | clean | — |
| **tui** | | | |
| markdown_text | 2 | MEDIUM | open |
| app | 1 | LOW | open |
| picker_match | 1 | LOW | open |
| terminal | 1 | LOW | open |
| render | 0 | clean | — |
| transcript | 0 | clean | — |
| composer_input | 0 | clean | — |
| theme_status | 0 | clean | — |
| effects_misc | 0 | clean | — |

## Recommended fix order

1. **Three `errdefer` double-frees** — `session_runtime:1308-1335`,
   `session_listing:226-229`, `read:123-126`. Mechanical, allocator-corrupting.
2. **Skill/context startup abort** — `skills.zig` / `resources.zig` /
   `AgentSession.init:182`. Highest felt-behavior leverage.
3. **Image bounds + degrade** — `read.zig:103-118,164-187`.
4. **Mirror desync + OAuth cross-process lock** (medium) —
   `AgentSession.zig:564-572`, `auth.zig:251-269`.
5. **`text.zig` quadratic UTF-8 re-validation** — the `tui` efficiency fix.
6. **Low-severity minimalism + error-discipline tail.**

---

## Module synthesis — coding_agent

The coding_agent module is in strong, AK-shaped health and largely already meets
the small/minimal/polished/efficient goal. The session host, durable history
layer, agent session, typed protocol, event plumbing, and all four tools encode
state directly, bound every accumulation point with a named reject/evict policy,
and consistently degrade operational input rather than tearing down the owner
loop. No architectural rot was found, and most units have zero high/medium
correctness defects. What keeps it from polished is a recurring, mechanical class
of bug — un-disarmed `errdefer`s that double-free after ownership has already
moved (three high-severity instances) — plus one genuine bounds gap (unbounded
base64 image inflation) and three pi-mono parity regressions. Everything else is
low-severity minimalism noise.

**Themes, ranked:**

1. **`errdefer` outlives ownership transfer → double-free / UAF on the OOM path
   (HIGH).** A standalone `errdefer` frees a buffer whose ownership already moved
   to another owner; a later allocation failure fires the stale errdefer and
   frees the same pointer twice. Units: `session_runtime`, `session_listing`,
   `tools_read_write`. Uniform fix: one owner, one errdefer.
2. **Operational input aborts startup instead of degrading (HIGH).** A
   malformed/oversize skill or context file propagates a hard error through
   `PromptResources.load` into `AgentSession.init`. pi-mono degrades to per-file
   diagnostics and keeps running. Unit: `skills_resources`.
3. **Image read path has no named bound and no degrade (HIGH).** Base64-encodes
   raw content (up to the 1 MB read cap, ~1.33× inflated) into the request with
   no size check or omit/resize path. Unit: `tools_read_write`.
4. **Shared mutable state with two fallible mutation paths / no cross-process
   lock (MEDIUM).** Agent queue vs drain mirror; OAuth refresh vs rotated
   single-use tokens. Units: `event_plumbing`, `auth`.
5. **One-source-of-truth drift and dead/defensive surface (LOW).** A long tail of
   minimalism nits and minor error-discipline inconsistencies.

## Module synthesis — tui

The tui module is in excellent health against the small/polished/efficient goal —
the strongest module in this audit. Every unit is AK-shaped: single-owner state
with one mutation path, named bounds with explicit eviction/reject policies at
every accumulation point, total error discipline over operational input (only
`OutOfMemory` propagates), strict layering (no Zi-owned width/grapheme/ANSI
engine — vaxis owns those), and O(viewport+items) hot paths. The render
transaction, dirty-on-failed-write retry, the single `buildItemRows` producer
with its `assert(count == rows)`-guarded dual path, and clock-free projection are
all correct. No high-severity violations exist.

**Themes, ranked:**

1. **Quadratic UTF-8 re-validation on the hot wrap/render path (MEDIUM).**
   `nextGrapheme` re-validates the whole remaining tail, called per grapheme →
   O(N²) per physical line, twice per frame. The one real efficiency gap. Unit:
   `markdown_text`.
2. **Minimalism: speculative capacity and write-only state (LOW).** 8-wide
   slash-arg array with two callers; `Picker.dropped_items` nobody reads. Units:
   `app`, `picker_match`.
3. **Honesty/robustness nits (LOW).** Over-promising `utf8Prefix` doc; OSC-52
   panic vector via `paste_allocator.?` in vendored vaxis. Units:
   `markdown_text`, `terminal`.

---

## Per-unit appendix

Format per finding: **severity · category · `file:line`** — problem. _Fix:_ … ·
_Verifier:_ … Append fix notes / status under each unit as work proceeds.

### coding_agent / session_runtime — 2 confirmed (HIGH)

Well-shaped mailbox host: one live session slot, phase-typed active operation
making concurrent run/summary/retry unrepresentable, build-then-swap session
replacement through the owner path, backpressured event queue, bounded
retained-event ledger with observable-gap eviction.

- **HIGH · ownership · `session_runtime.zig:1308-1335`** — `errdefer
  resume_sessions.deinit` stays armed after the value is moved into `snapshot`;
  the non-`EventQueueFull` arm calls `snapshot.deinit` then `return err`,
  re-firing the stale errdefer → double-free. Reachable: `enqueueEvent` →
  `retained_events.append` dupes JSON and can OOM. _Fix:_ build the snapshot
  first, cover both lists with one `errdefer snapshot.deinit`, drop the
  standalone errdefer and the `else` deinit. _Verifier:_ confirmed; `snapshot.resume_sessions = resume_sessions` is a struct copy aliasing the same backing alloc and does not disarm the errdefer.
- **MEDIUM · ownership · `session_runtime.zig:1325-1334`** — dead `EventQueueFull`
  arm encodes a contradictory ownership assumption (all four callers gate on
  `hasEventCapacity()`, so `pushOrDrop` never returns full here); harbors a
  latent UAF if gating ever weakens. _Fix:_ delete the bespoke switch; let one
  `try` + the unified errdefer cover it. Collapses once finding #1 is fixed.

### coding_agent / session_manager — 2 confirmed (LOW)

Durable session-history layer (in-memory view + append-only jsonl store +
parser). Clean: every accumulation point bounded, single-owner memory with
disciplined errdefer, sharp torn-tail-repair vs interior-corruption split,
prepare/commit lets jsonl reach disk before an entry is visible in memory.

- **LOW · minimalism · `session_manager.zig:724`** — entry-count cap in
  `nextBase` is unreachable; `ensureAppendCapacity(1)` already rejects one frame
  up. _Fix:_ drop the count check, keep only the `next_id == maxInt(u64)`
  id-exhaustion guard.
- **LOW · ownership · `session_manager.zig:412-417`** — prepare reads `next_id`,
  commit increments it; two outstanding prepared entries would duplicate an id
  (latent — all callers are strictly sequential). _Fix:_ assert prepared id ==
  `next_id` at commit, or document the single-outstanding invariant.

### coding_agent / agent_session — 1 confirmed (LOW)

Strong: one long-lived agent, fully laddered errdefer init, named bounds at every
accumulation point, settle-as-verdict so the session never blocks. Documented
event order holds.

- **LOW · pi-mono-parity · `AgentSession.zig:859-868`** — overflow-retry sets
  `max_attempts = attempt` (a shared counter), so the UI always renders "N of N"
  for overflow retries; the provider-error path at :605 correctly uses
  `retry_settings.max_attempts`. Overflow resubmit is single-shot (gated by
  `overflow_retry_used`), so the ceiling is meaningless. _Fix:_ use a dedicated
  single-shot reason/payload so the frontend doesn't render a misleading counter.

### coding_agent / event_plumbing — 3 confirmed (MEDIUM)

Genuinely clean. The event drain is a real single-writer on the cooperative
consumer task; documented order (mirror → bounded public event → persistence →
terminal policy) is implemented exactly; bounded public queue uses drop +
single-deferred `event_overflow`.

- **MEDIUM · ownership · `AgentSession.zig:564-572` (+ `event_drain.zig:142-150`)**
  — `agent.steer` then `appendSteering` are two fallible writes for one fact; OOM
  between them leaves the mirror permanently undercounted with no rollback, and
  later delivery's content-match `removeUserText` finds nothing. _Fix:_ append to
  the cheap mirror first (or errdefer-remove on steer failure) so both commit
  together.
- **LOW · error-discipline · `event_drain.zig:103-113`** — `failRetry` resets
  `retry_attempt = 0` then `EventText.init ... catch return`, dropping the
  terminal `auto_retry_end` on OOM; the client that saw `auto_retry_start` shows
  an unresolved retry. _Fix:_ still emit `auto_retry_end{ success=false,
  final_error=null }` (the field is already optional).
- **LOW · minimalism · `event_drain.zig:181-183`** — `droppedPublicEventCount`
  has only a test caller; production overflow signalling goes through the
  `event_overflow` event. _Fix:_ drop the accessor (test can read
  `public_events.dropped()`).

### coding_agent / tools_edit — 2 confirmed (MEDIUM)

Well-tested edit tool: exact/unique-or-fail matching, BOM+CRLF restore, no-op
rejection, output and diff byte caps, fail-before-mutate structurally enforced
through the single FileMutationQueue path.

- **MEDIUM · ownership · `edit.zig:339-350`** — in-loop `errdefer`s discharge per
  iteration and the cleanup `defer` registers only after the loop, so normalized
  edits from completed iterations leak when `normalizeLineEndings` OOMs mid-loop
  (up to 64 edits). _Fix:_ track an `initialized` count and free
  `normalized_edits[0..i]` in one pre-loop errdefer — mirror the `parseArgs`
  pattern at :254-261.
- **LOW · error-discipline · `edit.zig:708`** — over-limit diff returns raw
  `error.EditTooLarge` (not caught by the switch at :211-220) → "tool execution
  failed: EditTooLarge" instead of the clean `editTooLargeResult` used by the
  output-bytes path at :218. _Fix:_ return the operational too-large tool result
  so both size limits degrade identically.

### coding_agent / tools_bash — 1 confirmed (LOW)

Strong, well-bounded: output capture bounded at three independent layers with
named policies (reject-and-kill, backpressure channel, tail eviction); timeout /
cancel / output-limit degrade into bounded result data; UTF-8 sanitized at the
boundary.

- **LOW · minimalism · `bash.zig:503`** — `firstLineExceedsLimit = false` emitted
  unconditionally; the bash TUI consumer (`tool_view.zig:466-483`) never reads it
  (only `readMetadata` does). Dead in the bash path. _Fix:_ drop the field from
  bash's `resultDetails`, or compute it from `last_line_partial`.

### coding_agent / tools_read_write — 5 confirmed (HIGH)

Mostly AK-shaped: bounded reads (1 MB cap + 50 KB/2000-line truncation with
continuation metadata), atomic write via temp+rename behind one FileMutationQueue,
strong path-containment tests.

- **HIGH · bounds · `read.zig:103-118,164-187`** — image branch returns before
  text caps apply and base64-encodes the entire raw content (up to 1 MB, ~1.33×
  inflated) into the request with no size check or degrade. The only true BOUNDS
  gap. _Fix:_ add `max_image_bytes` with an omit-and-note degrade (or downscale).
  _Verifier:_ confirmed; would accept medium since the request is bounded by 1
  MB×1.33, but no named image policy and no degrade path.
- **MEDIUM · pi-mono-parity · `read.zig:116-118,164-187`** — pi-mono `read.ts`
  resizes images then omits with "[Image omitted: could not be resized below the
  inline image size limit.]"; zi has no resize and no inline-size limit, so an
  oversize screenshot bloats the request or trips a hard provider error. _Fix:_
  match the felt behavior (bounded `max_image_bytes` + omit-and-note), not the TS
  architecture.
- **MEDIUM · ownership · `read.zig:123-126`** — success path arms
  `formatted.deinit` (frees `formatted.text`) after `ownedTextResult` already
  took `formatted.text`; on `ownedTextResult`'s OOM the same pointer is freed
  twice and `details` leaks. _Fix:_ drop the line-124 errdefer, add `errdefer
  freeJsonValue(details)` before the return.
- **LOW · zig-idiom · `write.zig:148-156`** — `message` (from `allocPrint`) has no
  errdefer; the inline `try jsonDetails(...)` arg can OOM before `ownedTextResult`
  is called, leaking `message`. _Fix:_ `errdefer allocator.free(message)` after
  the allocPrint, or hoist details to its own statement.
- **LOW · minimalism · `write.zig:31` vs `read.zig:34`** — `allow_paths_outside_cwd`
  defaults diverge (true vs false) and are dead (registry always sets them
  explicitly at `tool_registry.zig:83-101`). _Fix:_ make the defaults agree or
  drop them.

### coding_agent / tools_framework — 3 confirmed (LOW)

Already AK-shaped: definition-first tools, bounded fixed-array registry handing
borrowed `agent.AgentTool` views, heap-pinned `BuiltinTools`, single
`tool_output_policy` source of truth. No speculative central table.

- **LOW · layering · `bash.zig:110`** — truncation message hardcodes "2000 lines
  or 50KB", a second copy of `tool_output_policy` (every numeric cap elsewhere
  derives from the policy). _Fix:_ build the string from the constants via
  `std.fmt.comptimePrint` (line 110 is a comptime concat).
- **LOW · minimalism · `tool_registry.zig:18,28,40-42`** — optional
  `prompt_snippets` and its `orelse continue` are never exercised (all four
  appends pass non-null). _Fix:_ store `[]const u8`, or note it as an explicit
  extension seam.
- **LOW · minimalism · `AgentSession.zig:682`** — magic `+57` headroom on the
  snippet scratch buffer with no derivation; real bound is
  `default_active_tool_names.len` (4). _Fix:_ size to that (or `max_tool_snippets`).

### coding_agent / auth — 1 confirmed (MEDIUM)

Genuinely AK-shaped: credential file treated as operational input (missing/
malformed → empty store, only OOM propagates), secrets never reach logs/events,
bounded accumulation, build-next/save/swap mutation with atomic tmp+rename.

- **MEDIUM · pi-mono-parity · `auth.zig:251-269`** — `refreshIfExpired` does
  read→refresh→write with no cross-process lock while the openai-codex provider
  rotates single-use refresh tokens (`openai_codex.zig:564`), so two concurrent
  zi processes can each consume the same token; the loser breaks auth until
  `/login`. pi-mono wraps this in `withLockAsync` + re-read + expiry re-check.
  _Fix:_ refresh under a lockfile + reload, re-check expiry inside the critical
  section, or assert/document single-process. Keep it zig-shaped.

### coding_agent / paths — 0 confirmed (CLEAN)

Single source of truth for path constants and tool-operand resolution. Careful
error paths (manual frees before errdefer scope opens, per-variant errdefers, no
double-free/leak found), exact overflow-guarded bounds, symlink-escape
containment with separator boundary. The macOS filename-repair machinery earns
its keep and is tested. (One LOW nit on two divergent in-file tilde expanders was
raised but not confirmed as a defensible violation.)

### coding_agent / session_listing — 2 confirmed (HIGH)

Clean, well-bounded enumeration: never loads session totals wholesale (64 KB
prefix per file), bounded resident view with explicit evict-and-report-truncated
policy, reuses `paths.zig` for the leaf-name scheme.

- **HIGH · ownership · `session_listing.zig:226-229`** — exact-id branch frees
  `match` without resetting it to null; a failing `allocator.dupe` re-fires the
  errdefer at :218 → double-free. The normal return at :236 correctly nulls it
  first — proof of the omission. _Fix:_ `match = null;` immediately after the free.
- **LOW · bounds · `session_listing.zig:89-94,165`** — `max_directory_entries`
  counts raw directory entries (incl. non-session files), so a noisy directory
  truncates before reaching real sessions and `--resume` hard-fails via
  `error.SessionListTruncated`. _Fix:_ count the cap after the
  `isSessionFileLeafName` filter, or document it as a raw-scan safety valve.

### coding_agent / skills_resources — 2 confirmed (HIGH)

Clean, leak-free ownership; correct errdefer; explicit dedup/override; named
per-skill/file/depth/count limits.

- **HIGH · error-discipline · `skills.zig:139-150,271-273`;
  `resources.zig:199-210,224-239`; `AgentSession.zig:182-187`** — malformed/
  oversize/limit-exceeded skill or context files throw hard errors
  (`InvalidSkillFrontmatter`, `SkillNameTooLong`, `StreamTooLong`,
  `SkillLimitExceeded`) that propagate through `PromptResources.load` into
  `AgentSession.init`, so one bad `SKILL.md` or oversize `AGENTS.md` aborts
  session startup. pi-mono skips with a diagnostic and keeps loading. _Fix:_ make
  per-file loading total (drop-with-diagnostic); treat limits as stop-collecting;
  reserve hard errors for OOM/IO faults.
- **LOW · bounds · `skills.zig:75-108`** — per-directory `root_files`/`child_dirs`
  accumulate one dupe per entry with no cap (transient — freed per directory; the
  named bounds gate output skills and recursion, not these intermediates). _Fix:_
  bound per-directory entries against `max_skills`, or stream-insert.

### coding_agent / config_policy — 1 confirmed (LOW)

Small, explicit, well-bounded (settings / system_prompt / message_policy /
slash_commands / runtime_services / root). Every accumulation point capped;
settings degrade malformed input to defaults, only OOM propagates;
`command_count_max` genuinely sizes TUI stack arrays.

- **LOW · ownership · `settings.zig:7-12` (consumed at
  `session_runtime.zig:235-252`)** — a project scope with only `defaultModel` (no
  provider) selects the project pair, finds provider null, skips the block, and
  falls through to auto-selection with no scope-atomic diagnostic — contrary to
  the documented "reject and record a diagnostic." No diagnostic mechanism exists
  anywhere in `coding_agent`. _Fix:_ model the provider/model pair as one optional
  struct (make the partial state unrepresentable), or record a diagnostic when
  exactly one is set. Note: the resolver lives in `session_runtime`, outside this
  unit.

### coding_agent / client_protocol — 0 confirmed (CLEAN)

Disciplined data-oriented typed protocol: commands in, owned event payloads out.
Every payload's `deinit` takes its creating allocator; init paths use correct
errdefer with an `initialized` counter. All accumulation points (completion
lists, history snapshots/pages, replay batches, per-field text) bounded by named
caps with utf8-boundary truncation and counted drops. Overflow policy correctly
lives in the drain, not here. No defensible violation found.

### tui / render — 0 confirmed (CLEAN)

Disciplined frame painter. Render transaction exactly as specified:
`render.draw` paints infallibly into the Vaxis window via a thin Painter adapter,
the fallible write lives in `Terminal.renderIfDirty`, product state stays dirty
until the write succeeds. `buildItemRows` is the single row producer consumed by
both scroll-counting and drawing, with `assert(count == rows)` guarding the dual
path; per-item layout memoization keeps scroll O(items), drawing O(viewport). No
local ANSI/cell/diff/width substrate reintroduced. Every accumulation point has
an explicit reject/drop policy. No real violations.

### tui / app — 1 confirmed (LOW)

Single owner of TUI product state, one mutation path (`apply(Command) → ?Effect`),
no I/O, time only via `Command.tick`, genuinely agent-agnostic. `apply` total
over operational input.

- **LOW · minimalism · `App.zig:164,199`** — `slash_arg_completion_count_max = 8`
  backs an 8-wide slot array but only two production installers exist (`model`,
  `resume` at `interactive.zig:348,360`) — ~4× speculative capacity. The
  keyed-slot machinery itself is justified by two callers; only the capacity is
  headroom. _Fix:_ size the array to the concrete need; defer extra slots until a
  third caller proves the seam.

### tui / transcript — 0 confirmed (CLEAN)

Exemplary bounded resident view. Every accumulation point has an explicit named
policy (item_count_max=200, total_size_bytes_max=256 KB, per-append cap 8 KB,
per-tool preview cap = total/8) with oldest-first / newest-first eviction.
Single-path ownership through `noteItemMutation`; total over operational input
(unknown ids no-op, oversize truncates+reports, invalid/split UTF-8 sanitized).
Layout memoized keyed by (version,width,expanded) via the shared
`render.buildItemRows` producer. No defensible violation.

### tui / composer_input — 0 confirmed (CLEAN)

Tight and disciplined. Composer is a single flat UTF-8 buffer with a hard 16 KB
reject cap, one owner, one mutation path (every edit funnels through
`noteEdit`/`bumpRevision`), cleanly invalidated projection cache. `input.zig` is
pure: reduces vaxis events to a small product vocabulary with no allocation, no
clock, no agent/session naming. Valid-UTF-8 asserted as a precondition and upheld
by App-boundary sanitization. Zero defensible violations.

### tui / picker_match — 1 confirmed (LOW)

Genuinely clean. Candidate set bounded (item_count_max=384), per-keystroke match
loop fully allocation-free (stack scores array + allocation-free `match.zig`),
the only heap alloc is the deliberate `gpa.dupe` of the selected id on Enter.
Scoring math total (no underflow reachable).

- **LOW · minimalism · `Picker.zig:80,92`** — `dropped_items` is set on
  truncation but read nowhere; the `@min(.., item_count_max)` bound at :89 already
  enforces the policy. (Distinct from the history `dropped_items` in
  `client_protocol`, which IS read.) _Fix:_ delete the field, or surface "N more
  not shown" if a picker genuinely exceeds 384.

### tui / markdown_text — 2 confirmed (MEDIUM)

Two tightly-scoped, allocation-disciplined modules. `markdown.zig` is a bounded
non-allocating classifier returning borrowed slices; `text.zig` delegates all
width/grapheme work to vaxis (no local engine) and centralizes UTF-8 sanitation.

- **MEDIUM · performance · `text.zig:27-34` (loop at :73-89)** — `nextGrapheme`
  runs `utf8ValidateSlice` over the whole passed slice; `nextVisualLineBreak`
  calls it per grapheme → O(N²) wrapping per unbroken physical line, run twice per
  frame every animation tick. Stable-row caching (`render.zig:185-195`) and
  newline-splitting (:189) bound practical impact, but the pre-scan is redundant
  given the module's own "product-state text is always valid UTF-8" invariant
  (`text.zig:5-8`). _Fix:_ validate once per call (thread `valid: bool` into a
  private stepper), or drop the per-grapheme validation and validate only at the
  sanitizer entry points.
- **LOW · correctness · `text.zig:188-194`** — `utf8Prefix` doc claims "Longest
  valid-UTF-8 prefix" but the body only strips trailing continuation bytes and
  never validates; no live bug (callers want codepoint-boundary length-bounding,
  not validity). _Fix:_ retarget the comment to "longest prefix no longer than
  `max_bytes` ending on a codepoint boundary."

### tui / terminal — 1 confirmed (LOW)

Disciplined single-owner terminal authority: heap-pins itself (vaxis `Tty`/`Vaxis`
store self-pointers), names every accumulation bound, degrades all operational
input, runs the render transaction so a failed write keeps state dirty. `ansi.zig`
and `glyphs.zig` are thin justified naming layers, no Zi-owned encoder.

- **LOW · error-discipline · `Terminal.zig:163`** — passes `null` as
  `paste_allocator` to `vaxis.Parser.parse`; an unsolicited OSC 52 `c` clipboard
  report reaches `Parser.zig:316`'s `paste_allocator.?.alloc` and panics the
  synchronous owner loop in safe builds (the `catch {}` only catches the error
  union, not the null-unwrap). Trigger needs a hostile/buggy terminal; zi never
  solicits OSC 52, so `null` is the right policy. _Fix:_ ignore-and-free a bounded
  paste from an OSC source, or fix `parseOsc` upstream to return `null_event` when
  `paste_allocator` is null. Do not add clipboard machinery.

### tui / theme_status — 0 confirmed (CLEAN)

Both tight and AK-shaped. `theme.zig` is the deliberate vaxis Style/Color seam
(single honest theme, no premature multi-theme registry). `status.zig` is a fully
inline, allocation-free, fixed-capacity store with one explicit reject bound and
a byte cap, correct sanitization of operational text. No dead public API. (Two
LOW layering/minimalism nits were raised but not confirmed.)

### tui / effects_misc — 0 confirmed (CLEAN)

Clean and disciplined. `shimmer.zig` / `shuffle_text.zig` are pure, allocation-
free, deterministic functions of (config, time, position) with animation-gating
enforced upstream (idle zi drops to the slow heartbeat, does not spin). `Greeter`
and `PromptHistory` encode hard resident bounds (inline buffers / ring buffer
with byte + entry caps), oversize input degraded. No speculative effects
machinery. No defensible violation.
