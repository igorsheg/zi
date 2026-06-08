# Autoresearch: Andrew Pi-Mono in Zig

## Objective
Reimagine Zi as: **pi-mono product behavior, implemented in Zig as if Andrew Kelley designed and wrote it.**

This loop is allowed to make large refactors and break Zi's current public API. The desired shape is an executable-first coding agent with boring direct ownership, explicit bounds, and minimal abstraction. Pi-mono is a behavioral reference, not an architecture to port. We keep the user-visible product promises that matter today: model/auth/settings resolution, sessions and resume, prompt resources, tools, print/json/interactive modes, bounded TUI rendering, observable cancellation, and durable history.

The Andrew-style question is now larger than helper deletion:

> If this were written from scratch in Zig for this product, would this boundary/type/API exist?

Prefer deleting or collapsing whole seams over shaving names. Breaking library/sdk API is acceptable when it removes a compatibility-shaped layer that the executable does not need.

## Metrics
- **Primary**: `andrew_score` (weighted static architecture score, lower is better) — combines resident code size, large-file pressure, public/API surface, indirection vocabulary, one-caller helper pressure, and boundary violations.
- **Secondary**:
  - `scoped_loc` — Zig lines in the main app/agent/TUI/product runtime scope.
  - `large_file_penalty` — pressure from files too large to audit locally.
  - `public_api_count` — exported declarations in scoped code. Public surface is now suspicious unless it is a real package boundary.
  - `sdk_host_loc` — lines in `sdk.zig` and `AgentSessionRuntimeHost.zig`; this is compatibility/host pressure, not sacred API.
  - `indirection_name_count` — architecture smell words (`Host`, `Manager`, `Registry`, `Mirror`, `Surface`, `Slot`, `Policy`, `Adapter`, etc.). This is a prompt to inspect, not a rename target.
  - `one_caller_fn_count` — local functions whose names appear only at definition + one call in the same file. Useful for finding wrappers, but do not blindly inline when readability worsens.
  - `test_count` — guardrail. Deleting tests is suspicious unless they cover deleted dead code or deleted API only.
  - `fmt_status` — 0 pass, 1 fail.
  - `boundary_violations` — forbidden import-direction violations; any nonzero value is a hard failure.

The metric is a compass. Do not cheat it with renames, hiding code outside scope, or deleting behavior. A good kept change should remove a real concept, ownership seam, mutation path, compatibility layer, or invalid state.

## How to Run
`./autoresearch.sh` — fast static architecture scoring. It prints `METRIC name=value` lines.

Full correctness gates live in `./autoresearch.checks.sh` and must pass before logging `keep`.

## Files in Scope
Broad refactors are allowed in these areas:

- `src/coding_agent/` — product/session/CLI policy. Highest-value target. Break SDK/API if it lets the executable become direct.
- `src/agent/` — generic turn loop and transcript/tool execution owner. Collapse callback protocols and duplicate event shapes when current behavior can be direct.
- `src/tui/product/` — current Zi TUI product. Delete extension/framework seams until a current product owner needs them.
- `src/runtime/process_runner.zig`, `src/runtime/cancel.zig`, `src/runtime/event_pipe.zig`, `src/runtime/bounded_queue.zig` — mechanism only; simplify without weakening cancellation, deadlines, or bounded queues.
- `src/main.zig`, `src/root.zig`, `build.zig` — only when needed to remove public/API pressure or wire a new direct executable shape.
- `CONTEXT.md`, `AGENTS.md`, ADR/docs — update only to remove stale architecture claims after code changes.
- `.references/pi-mono/` — read-only behavioral reference.

## Off Limits
- Do not port pi-mono's TypeScript architecture. Preserve product behavior, not package shapes.
- Do not break import direction:
  - `tui` must not import `runtime`, `ai`, `agent`, or `coding_agent`.
  - `agent` must not import `coding_agent` or `tui`.
  - `ai` must not import `agent`, `coding_agent`, or `tui`.
  - `runtime` must not import product modules.
- Do not remove durable session history, path policy, auth/settings/model behavior, tool output bounds, cancellation observability, or render transactionality.
- Do not introduce global state, ambient I/O, unbounded queues, new dependencies, callback mutation paths, or hidden lifecycle hooks.
- Do not move code out of metric scope to improve the number.
- Do not rename concepts just to lower `indirection_name_count`.

## Constraints
- Breaking public API is allowed. Breaking current executable behavior is not.
- Before logging `keep`, `./autoresearch.checks.sh` must pass.
- Every kept change must do at least one of:
  1. delete/collapse a compatibility layer, framework seam, or duplicate owner;
  2. make one mutation owner obvious;
  3. make an invariant explicit in type/state instead of discipline;
  4. replace callback/protocol indirection with direct state-machine code;
  5. delete dead behavior with the tests/docs that only covered that behavior.
- If `andrew_score` improves but code becomes cleverer or less bounded, discard.
- If `andrew_score` is equal but a real concept disappears, keeping is allowed; explain why in ASI.
- Large refactors are allowed, but land them as understandable steps with checks passing.

## Starting Hypotheses
- `AgentSessionRuntimeHost` and `sdk.zig` likely contain executable-unnecessary compatibility surface. Collapse host/session construction into CLI modes where possible.
- `AgentSession` may own too many mirrors (`queue_mirror`, event drain, public event queue, manager). Seek one event/log owner and derived projections.
- `tool_registry` may be dynamic machinery for a static built-in tool set. Prefer a compile-time table until real dynamic tools/extensions exist.
- TUI `surface`, `slots`, `snapshot`, and status abstractions should survive only if current product behavior needs the seam.
- `agent/loop.zig` copying/event-sink helpers may exist to satisfy callback protocols rather than a direct turn state machine.
- Print/json/interactive should be thin frontends over one direct session owner, not consumers of a broad host API.

## What's Been Tried
- New session begins after the Andrew Kelley Delete Loop. Old autoresearch artifacts were removed. Prior loop got `complexity_score` from 41446 to 37571, mostly by deleting small wrappers and dead seams. This new loop intentionally changes target from local deletion to executable-first rearchitecture.
