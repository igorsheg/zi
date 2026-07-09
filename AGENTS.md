# zi agent operating guide

Read `CONTEXT.md` first for vocabulary and ownership. This file is the working
checklist for changing Zi without drifting from the completed gen-3 architecture.

The default review question for any change is: **does this make the direct
frontend -> AgentSession -> agent -> Transcript/screen path clearer, smaller, or
more bounded?** If not, redesign before editing.

## Start every task

1. Read the code that owns the state you intend to change.
2. Identify the owner allowed to mutate that state.
3. Identify the bounded policy for every queue, buffer, transcript view, picker,
   retry, subprocess, tool output, batch, or concurrent task you touch.
4. Check whether the behavior belongs to TUI, print, `coding_agent`, `agent`,
   `ai`, or `runtime`. Do not put it in a convenient neighbor.
5. Preserve unrelated user changes. Never revert files you did not intentionally
   change.

## Gen-3 non-negotiables

- No Engine, ViewModel, wire protocol, client protocol, or in-process event
  translation tier may be reintroduced.
- No generic frontend framework may be added around `src/tui`. Zi has a concrete
  TUI product, not a reusable TUI SDK.
- No duplicate transcript model. `Transcript` is the TUI render fold; session
  jsonl is durable truth; `agent.Agent` holds runtime context.
- No opaque ids as local UI discriminators when a typed action or direct function
  call can be used.
- No producer-side UI throttles, reveal queues, pacing constants, or extra timing
  layers. Coalescing belongs to the frame/render policy.
- No unbounded owner-loop work. If a CPU step can exceed roughly a frame budget,
  move it behind a bounded runtime task and poll the typed result.
- No local terminal mechanisms that Vaxis already owns: ANSI encoders, raw-mode
  stacks, cell buffers, diff renderers, style/color encodings, or width engines.
- No new dependency without explicit approval. `zio` and `vaxis` are vendored;
  `zio` stays private behind `src/runtime`.

## Layer boundaries

```text
main.zig       process/runtime setup, then cli.main
cli            parse flags/modes, select concrete frontend/auth
ai             provider protocol, models, registry, wire adapters, streams
agent          generic transcript/tool/provider turn loop
runtime        std.Io-first mechanism; zio private behind adapters
coding_agent   sessions, resources, settings, auth, tools, paths, persistence
frontends      concrete non-interactive adapters such as print mode
tui            concrete alt-screen terminal product on vaxis
```

Import rules:

- `ai`: std plus runtime I/O mechanism only when needed.
- `agent`: std, ai, runtime. Never `coding_agent`, `tui`, or concrete frontends.
- `runtime`: std only publicly. No product policy. `zio` imports stay private.
- `coding_agent`: std, ai, agent, runtime. Never `tui` or concrete frontends.
- `frontends`: concrete adapters may bridge cli/process resources to
  `coding_agent`, `agent`, `ai`, and `runtime`.
- `tui`: std, vendored vaxis, ai, agent, coding_agent, runtime. Never imported by
  lower layers.

## Where changes belong

### CLI and frontend selection

Use `src/cli` for argv parsing, mode selection, process-facing errors, and wiring
concrete frontends. CLI does not own session internals or TUI state.

### Runtime services and session bootstrap

Use `RuntimeServices` for cwd-scoped services shared by frontends. Use
`session_bootstrap.OpenSpec` for fresh/resumed/ephemeral session policy. Keep
session creation complete before passing it to a frontend loop.

### AgentSession

`AgentSession` owns one long-lived `agent.Agent` plus resources, builtin tools,
persistence, lifecycle, retry, compaction, and session event state.

Rules:

- Frontends drive runs by creating `RunHandle`s, setting wake handles, polling,
  settling, and deinitializing handles.
- Persist durable session facts before mutating the live agent.
- Session replacement builds the next session completely before swapping.
- Shutdown is two phase: request, drain/observe terminal completion, then deinit.
- `store == null` is persistence mechanism, not a UI policy flag. Frontends carry
  explicit persistence intent such as `persist_new_sessions`.

### agent

Use `src/agent` only for product-agnostic provider/tool turn mechanics. It should
not know settings files, TUI chrome, print formatting, session jsonl names, or
resource paths.

### Runtime

When touching `src/runtime` or code that uses it:

- Pass `std.Io` explicitly. Do not add ambient I/O or globals.
- Wakes are coalesced and payload-free; after waking, inspect owned state.
- Cancellation is request -> observe completion, not request -> assume stopped.
- `deinit` must not race worker-visible memory.
- Name the bounded policy: reject, evict, backpressure, spill, or deadline/cancel.
- Do not add a generic operation/completion registry unless repeated concrete
  code proves the owner, bound, and failure mode.

### TUI owner loop

`src/tui/Loop.zig` owns interactive product state: editor, picker stack,
completion, viewport, run driver, notices, trace counters, and frame composition.
Mutate it through `Loop.dispatch`, `Loop.tick`, driver polling, and explicit owner
methods.

Rules:

- The composer is the omni input. Pickers filter from composer text and render as
  listbox frames; they do not take focus through nested modal text fields.
- ESC cascade stays centralized in the loop.
- Typed input is foreground work and must remain responsive while streaming.
- Time enters through frame-loop/runner deadlines and `std.Io` timestamps at owner
  edges; do not scatter wall-clock reads.
- Rendering is compose -> paint -> synchronous flush -> clear dirty only after
  success.
- Frame loop wait is over input/runtime wake sources with a deadline.
- The debug watchdog budget is meaningful; do not add exemptions to hide owner
  loop stalls.

### Transcript and tool UI

`src/tui/Transcript.zig` owns the bounded fold from live/restored events to render
items. `src/tui/blocks.zig` owns transcript block rendering and tool-call UX.

Rules:

- Tool execution details are converted into neutral display data before rendering.
- Tool-specific visuals belong in `blocks.zig`, not `screen.zig`, `chrome.zig`, or
  session persistence.
- Write/read/bash/edit/symbols presentation should be tested as user-visible UX,
  including streaming args and capped bodies.
- Coalesce stream fragments before layout/render when ordering allows.
- Transcript retention is bounded by item/byte caps; eviction must preserve valid
  viewport anchors.

### Screen, chrome, layout, and colors

- `screen.zig` owns primitive frame/line/span types, Kanso raw tokens, semantic
  color tokens, and Vaxis painting. It holds zero application state.
- Text styles should default to transparent/default backgrounds; row surfaces own
  backgrounds.
- Shimmer is the only allowed ad-hoc/interpolated RGB color path. Keep that
  exception contained in `text_shimmer.zig`; all other UI colors use semantic
  tokens.
- `chrome.zig` composes composer, picker/completion listbox, status, footer, and
  viewport hint from already-owned state.
- `layout.zig` and `markdown.zig` are pure presentation helpers. They should not
  sample sessions or mutate product state.

### Print frontend

`src/frontends/print` owns non-interactive text/json prompt behavior. It drives
one `AgentSession.RunHandle`, writes bounded output to supplied writers, honors
retry/compaction policy, and returns process-ready status. It must not import
`tui` or share TUI presentation state.

### Tools

Builtin tools live under `src/coding_agent/tools` and are registered through
`tool_registry.zig`.

Rules:

- Tool definitions include metadata, JSON schema, prompt text, and implementation.
- The core agent receives borrowed `agent.AgentTool` views.
- File mutation goes through `FileMutationQueue`.
- Tool output is bounded and classified by explicit policy.
- Process tools require timeout and cancellation.
- Add a new builtin by updating implementation, metadata/registry, prompt text,
  output policy, transcript display policy, and tests together.

### Paths, resources, settings, auth

- All path policy lives in `src/coding_agent/paths.zig`.
- Use `.zi`, never `.pi`, for Zi-owned behavior.
- Do not hardcode agent-dir resource names outside the path owner.
- `ZI_CODING_AGENT_DIR` overrides the agent dir.
- Option resolution is explicit -> project -> global -> default. Provider/model
  are scope-atomic; reject mixed-scope pairs and record a diagnostic.

## Feature design checklist

Before implementing any feature, write down the answers in your own notes or PR:

1. User-visible behavior: what will the user see or be able to do?
2. Owner: which existing owner mutates the state?
3. Dataflow: what direct function call or existing event fold carries the fact?
4. Bounds: what is the cap and what happens at the cap?
5. Persistence: is it durable jsonl, settings, ephemeral UI state, or runtime
   context only?
6. Frontends: does print need behavior too, or is this TUI-only?
7. Tests: what headless unit test and what pty/e2e or focused integration test
   prove the behavior?

If the answer requires a new mirror model, protocol envelope, global registry, or
unbounded queue, stop and redesign.

## Testing expectations

Scale tests to risk and owner boundary:

- Parser/input/editor behavior: same-file unit tests.
- TUI layout/render/viewport/tool UX: headless `Loop`/`Transcript`/`screen` tests.
- Terminal behavior, responsiveness, restore, picker flows, and regressions that
  depend on real tty mechanics: `zig build pty-test`.
- Print/text/json behavior: print frontend and CLI tests using the env-gated faux
  provider path.
- Runtime/tool/process behavior: focused owner tests plus cancellation/timeout
  coverage.

E2E provider tests must use `ZI_ENABLE_FAUX_PROVIDER=1` and normal provider
resolution. Do not inject private stream callbacks to bypass `RuntimeServices`.

## Zig workflow

- Use the local Zig 0.16 toolchain and vendored sources as the API source of truth.
- Pass allocators and `std.Io` explicitly.
- Use small structs with explicit lifetimes.
- Prefer state machines over callback control flow.
- Borrowed slices are valid only for the owner call that returned them.
- Use `errdefer` for partial initialization.
- `deinit` releases all owned memory and poisons `self` when practical.
- Prefer fixed arrays or bounded owned buffers over unbounded lists.
- Use `std.json.encodeJsonString` or runtime JSON helpers for JSON strings.
- Validate boundary text with `std.unicode`.
- Delete dead code completely. No commented-out code, shims, or "just in case".
- Comments explain why, edge cases, or surprising constraints only.

## Before finishing

For code changes, run:

```sh
zig build test
zig build pty-test
zig build
zig fmt --check src
zig fmt --check build.zig
git diff --check
```

For docs-only changes, run at least:

```sh
git diff --check
```

For focused behavior, also run the narrow command that exercises the changed
path. Report any gate you did not run.
