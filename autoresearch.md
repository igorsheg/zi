# Autoresearch: Andrew Kelley Delete Loop

## Objective
Keep deleting, collapsing, and simplifying Zi until the remaining system is obviously necessary.

This is not a performance loop. It is a maintainability loop with a hard correctness gate. Each iteration should remove code, remove concepts, collapse boundaries, or make invalid states unrepresentable while preserving Zi's current behavior and architecture contracts.

The loop's Andrew-style question is:

> Can this code disappear, or become boring direct code, without losing a tested behavior or a real ownership boundary?

Prefer negative work: delete unused seams, collapse speculative abstractions, shrink owner files, replace ambient discipline with types/assertions, and turn runtime surprises into compile-time structure. Do not add a new framework to make deletion easier.

## Metrics
- **Primary**: `complexity_score` (weighted static score, lower is better) — proxy for unnecessary surface area in the current complexity hotspots.
- **Secondary**:
  - `scoped_loc` — total lines in the hotspot files.
  - `large_file_penalty` — pressure from files too large to audit locally.
  - `speculative_name_count` — names that often indicate extra machinery (`Manager`, `Registry`, `Policy`, `Mirror`, `Slot`, `Surface`, etc.). Treat as a prompt to inspect, not an automatic rename target.
  - `panic_like_count` — `catch unreachable`, `@panic`, `std.debug.panic`, and raw `unreachable` sightings.
  - `todo_count` — unfinished or deferred work markers.
  - `test_count` — guardrail; dropping tests is suspicious.
  - `fmt_status` — 0 pass, 1 fail.
  - `boundary_violations` — forbidden import-direction violations; any nonzero value is a hard failure.

The metric is a compass, not the truth. A rename that lowers `speculative_name_count` without reducing machinery is cheating. A deletion that preserves behavior and lowers `scoped_loc` is the ideal win.

## How to Run
`./autoresearch.sh` — fast static scoring. It prints `METRIC name=value` lines.

Full correctness gates live in `./autoresearch.checks.sh` and must pass before keeping any code change.

## Files in Scope
Primary simplification targets:

- `src/coding_agent/AgentSession.zig` — session owner, lifecycle, prompt run, event drain integration, retry/compaction policy. Highest-value shrink target.
- `src/coding_agent/AgentSessionRuntimeHost.zig` — session replacement and host API. Collapse if it is just forwarding without protecting ownership.
- `src/coding_agent/interactive.zig` — TUI/session bridge. Keep as the only bridge, but split/collapse local state if it reduces owner-loop complexity.
- `src/coding_agent/session_manager.zig` — resident history/session state. Keep durable truth separate from runtime context; delete duplicate facts.
- `src/agent/loop.zig` — generic turn loop. Keep product policy out; make state transitions simpler and deterministic.
- `src/agent/Agent.zig` — transcript/runtime context owner. Prefer explicit state over callback protocol.
- `src/agent/tool_runner.zig` — tool execution. Keep bounded parallelism only if tests prove need.
- `src/agent/root.zig` — public agent vocabulary. Move helpers out or delete exported concepts that have one caller and no boundary value.
- `src/runtime/process_runner.zig` — mechanism only. Simplify only when preserving zio/process/cancel behavior.
- `src/tui/product/App.zig` — single TUI product owner. Commands mutate; effects are returned data.
- `src/tui/product/frame.zig` — full-frame renderer. Shrink projection/drawing code without adding retained surfaces or dirty rectangles.
- `src/tui/product/slots.zig`, `src/tui/product/surface.zig`, `src/tui/product/status_area.zig` — likely extension-ish/product machinery. Delete or collapse if current behavior does not require the seam.
- `src/tui/product/loop.zig`, `src/tui/product/terminal_loop.zig` — terminal owner loops. Keep transactionality and bounded drains.

Supporting files may be edited only when required by a simplification:

- Tests next to touched code.
- `CONTEXT.md`, `AGENTS.md`, or ADRs only to remove stale claims after code changes.
- `autoresearch.md`, `autoresearch.sh`, `autoresearch.checks.sh`, `autoresearch.ideas.md`.

## Off Limits
- Do not break import boundaries:
  - `tui` must not import `runtime`, `ai`, `agent`, or `coding_agent`.
  - `agent` must not import `coding_agent` or `tui`.
  - `ai` must not import `agent`, `coding_agent`, or `tui`.
  - `runtime` must not import product modules.
- Do not replace one abstraction with two smaller abstractions unless the code becomes easier to audit.
- Do not remove tests to improve the metric.
- Do not weaken bounds, cancellation, shutdown, path policy, or durable session history.
- Do not add new dependencies.
- Do not port pi-mono shapes.
- Do not introduce global state, callback mutation paths, unbounded queues, or ambient I/O.
- Do not change public behavior unless the old behavior is demonstrably wrong and tests/docs are updated.

## Constraints
- Before logging `keep`, run `./autoresearch.checks.sh` successfully.
- Every kept change must either:
  1. delete code/concepts,
  2. collapse duplicate state/mutation paths,
  3. make an invariant compile-time/state-machine enforced, or
  4. replace crash/silent corruption with a clear programmer assertion or operational error.
- If `complexity_score` improves but code becomes cleverer, discard.
- If `complexity_score` is equal but code is smaller and more obvious, keeping is allowed; explain why in ASI.
- If a change increases `complexity_score`, keep only when it deletes a real bug class and the ASI names the invariant now enforced.
- Keep changes small. One deletion/refactor idea per iteration.
- Update this file's "What's Been Tried" after meaningful discoveries.

## Loop Method
For every iteration:

1. Read one hotspot deeply. Identify the owner, mutation path, bounds, and failure modes.
2. Ask: "What can be deleted without changing behavior?"
3. Make the smallest deletion/collapse.
4. Add or keep behavior tests if the simplification touches behavior.
5. Run `./autoresearch.sh`.
6. If the primary metric improved, run `./autoresearch.checks.sh`.
7. Log with ASI that captures what was learned, especially why the removed concept was unnecessary.

Useful first probes:

- Find fields in `AgentSession` that mirror another owner and can become derived snapshots.
- Find `interactive.zig` branches that duplicate session policy instead of translating events/effects.
- Inspect TUI slots/surfaces: are they current product needs or future extension seams?
- Audit non-test `catch unreachable`; either prove locally with type/state or handle explicitly.
- Collapse one-caller helper types that obscure ownership.
- Split giant files only if the split removes coupling. Moving code without simplifying is not a win.

## What's Been Tried
- Replaced internal agent state-machine panics/unreachable prompt-token unwraps with `std.debug.assert` preconditions where the failure is programmer misuse, not operational input.
- Deleted a one-caller `SlotStore.hasSlot` helper; status row visibility now uses the existing slot count directly.
- Collapsed the single-variant TUI modal wrapper into direct `Confirm` ownership, then removed duplicate focus state derived from modal presence.
- Simplified confirm modal state: fixed Yes/No labels are current behavior, and selection is a direct `selected_yes` field.
- Found `shuffle_text` status effect had no current setter. First deletion attempt failed checks because `hasAnimated` kept an unused tick parameter; retry removed the parameter too.
- Removed unused session-host surfaces: ready-poll prompt draining, public-event presence probe, runtime accessor, replacement callbacks, host continue forwarding, and session-level continue API. The continue API deletion removed one test that only covered the deleted method; `autoresearch.sh` baseline test count is now 617.
- Collapsed composer slot surface to the one current product label (`composer_top_right`) plus `status_area`; bottom and top-left composer slots, owner namespaces, and bulk owner clearing were test-only/future seams.
- Removed explicit modal command surface; confirm modals now accept terminal input directly. Also collapsed fixed confirm button rendering and one-use validation helpers.
- AgentSession prompt startup now uses one path (`startPromptRun`) with inline preconditions/retry flags instead of wrapper/helper policy structs.
- Eliminated the remaining scoped panic-like sites by replacing test/helper `catch unreachable` with assertions for infallible buffered stream/event drain invariants.
