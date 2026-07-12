# Refactor PRD: make the TUI easy to reason about

- Status: ready for implementation
- Date: 2026-07-12
- Product owner: TUI frontend
- Primary implementation owner: `src/tui/Loop.zig`
- Refactor policy: breaking internal APIs are allowed; compatibility layers are forbidden

## 1. Purpose

Zi's gen-3 TUI has the correct architecture: one interactive owner loop, direct
`AgentSession` driving, one bounded `Transcript`, concrete chrome, and Vaxis as
the terminal mechanism. This refactor does not replace that architecture. It
makes the architecture obvious in the code.

The current implementation is hardest to understand where time and ownership
cross files. One logical owner iteration is distributed across
`FrameLoop.zig`, `root.zig`, and `Loop.zig`; asynchronous operations repeat
poll/cancel/deadline/shutdown rules in several methods; chrome is measured
through several capacity calls before independently planning the final frame;
and the composer is represented by related fields and transitions spread over
much of `Loop.zig`.

The product requirement is:

> A maintainer should be able to follow a TUI state transition from input or
> wake to terminal flush by reading one concrete owner path, without mentally
> joining independent scheduling, lifecycle, and presentation protocols.

Zi deliberately favors code readability and ease of reasoning over preserving
internal APIs, minimizing the size of `Loop.zig`, or making modules look simple
in isolation. A larger explicit owner is preferable to smaller modules joined
by synchronization contracts.

## 2. Why this work matters

The primary cost in `src/tui` is not line count. It is the number of places a
reader must inspect to answer ordinary questions:

- What runs after a terminal or runtime wake?
- Can another agent batch run before the current batch is rendered?
- Which deadline wakes the loop next?
- What does ESC cancel in the current state?
- Can session opening overlap image preparation or clipboard reading?
- Who destroys a canceled task's result?
- Which row count governs both viewport materialization and final composition?
- Which editor mutation invalidates completion or picker state?

Today those answers cross multiple modules and several independent fields. The
behavior is tested and bounded, but its temporal invariants are more distributed
than the gen-3 ownership model intends.

This refactor optimizes for the reader:

1. **Locality:** a transition, its state, and its cleanup live together.
2. **Explicitness:** legal states and transitions are represented by tagged
   unions rather than combinations of nullable fields and booleans.
3. **One owner path:** wait, input, bounded work, compose, paint, flush, and
   commit are visible in one concrete control flow.
4. **Compiler assistance:** adding a state creates exhaustive-switch failures at
   every policy decision that must consider it.
5. **Deletion:** obsolete seams, adapters, aliases, and duplicate calculations
   are removed rather than preserved.

## 3. Relationship to existing architecture

The following remain binding:

- `CONTEXT.md` and `AGENTS.md` define ownership, layer, and bounded-work rules.
- `docs/gen3-tui-plan.md` remains the architecture record and trap list.
- `docs/tui-performance.md` remains the transcript/layout performance contract.
- `docs/tui-responsiveness-ux-prd.md` remains the responsiveness and lifecycle
  behavior contract.
- `docs/transcript-vertical-rhythm.md` remains the transcript row contract.
- `docs/runtime-zio-capabilities.md` must be read before changing runtime
  mechanism.

This PRD changes internal TUI structure, not those product contracts. If an
implementation step introduces an Engine, ViewModel, protocol envelope, second
transcript, generic frontend framework, generic task registry, render thread,
or local terminal mechanism, stop and redesign it.

## 4. Scope and compatibility policy

### 4.1 In scope

1. Concentrate the complete interactive iteration in `Loop`.
2. Replace scattered user-visible asynchronous work with one explicit,
   concrete foreground-operation state machine.
3. Absorb the shallow `RunDriver` seam into `Loop`'s run state and transitions.
4. Deepen the composer implementation around editor, completion, and picker
   invariants.
5. Give chrome one authoritative row plan consumed by final composition.
6. Tighten tests around owner transitions instead of cross-file field mutation.
7. Delete obsolete modules, APIs, aliases, and duplicate paths.

### 4.2 Out of scope

- New end-user features or visual redesign.
- Changes to agent/provider/tool semantics.
- A reusable TUI or widget framework.
- Splitting transcript content, layout cache, and line index into separate
  owners.
- Replacing Vaxis, `runtime`, or `AgentSession`.
- A generic scheduler, operation registry, completion registry, or effect
  protocol.
- Refactoring solely to reduce file length.

### 4.3 No-compatibility rule

This is an intentionally breaking internal refactor.

- Update callers directly when an API changes.
- Delete replaced declarations in the same change that introduces their
  replacement.
- Do not add forwarding methods, deprecated names, type aliases, compatibility
  structs, duplicate event paths, or temporary adapters.
- Do not retain `Runner`, `FrameLoop`, or `RunDriver` under new names with the
  same shallow responsibilities.
- Tests must migrate to the final owner interface rather than keeping old test
  accessors alive.
- Intermediate commits may be organized for review, but every merged commit
  must compile and must not contain a compatibility corridor.

User-visible behavior should remain stable unless a test exposes contradictory
existing behavior. Resolve such a contradiction in favor of the binding product
contracts and document it in the implementing PR.

## 5. Current reasoning hotspots

### 5.1 The owner iteration crosses three modules

The current iteration is assembled from:

- waiting and timeout selection in `src/tui/FrameLoop.zig`;
- input decoding, resize, paint, flush, and timing in `src/tui/root.zig`'s
  `Runner`;
- product state, deadlines, polling, frame composition, and render commit in
  `src/tui/Loop.zig`.

`FrameLoop` is generic over `anytype`, but Zi has one concrete interactive TUI.
It reaches through `runner.loop` to inspect scheduling fields, so its interface
is nearly as complex as the implementation it hides. `Runner` likewise owns
part of the loop's temporal state, including lone-escape timing and input
latency stamps.

The result is a distributed owner despite the intended single-owner design.

### 5.2 Asynchronous lifecycle policy is repeated

Session listing/opening/restoring, prompt-image preparation, clipboard-image
reading, file indexing, scoped completion queries, and agent runs all need some
combination of:

- admission and rejection policy;
- a bounded task or handle;
- result polling;
- deadline handling;
- cancel request;
- terminal result observation;
- result destruction;
- status rendering;
- submit blocking;
- shutdown draining.

Some of these operations are mutually exclusive, but exclusion is represented
by checks over independent fields. Lifecycle policy is consequently spread
between start methods, `tick`, deadline selection, status rendering, ESC,
shutdown polling, and `deinit`.

### 5.3 `RunDriver` is not a deep module

`RunDriver` holds useful run state, but its methods accept `*Loop` and directly
mutate editor, transcript, notices, dirty state, trace state, and file-index
state. Deleting the module would not remove that complexity; it would reveal
that the complexity already belongs to the owner loop.

A new effect/event translation layer would make this worse. The direct solution
is to retain a compact run-state value while putting run transitions on `Loop`.

### 5.4 Chrome measurement and composition can drift

`Loop.composeFrameAt` asks `chrome` separately for picker capacity, popup
capacity, and transcript capacity, applies viewport motion, then repeats those
queries. `chrome.compose` subsequently computes its own row plan.

Even when correct, the reader must prove that prediction and composition use
identical rules. The interface exposes chrome's implementation details instead
of providing one authoritative plan.

### 5.5 Composer invariants are dispersed

The composer is the omni input, but its state is represented by `Editor`,
completion fields, picker fields, dismissal fields, line buffers, file-index
state, scoped-query state, and many `Loop` methods. Understanding one insertion
requires following editor mutation, picker filtering, completion refresh, task
admission, and chrome materialization separately.

## 6. Target architecture

The target keeps `Loop` as the sole interactive product owner.

```text
root.run
  -> initialize RuntimeServices, AgentSession, Terminal, InputPump, WakeEvent
  -> initialize Loop completely
  -> Loop.run
       wait for input/runtime wake or nearest owned deadline
       decode and dispatch all bounded input foreground work
       poll one bounded batch from owned state machines
       update resize/title state
       decide whether a frame is due
       prepare Transcript layout and visible rows
       obtain one authoritative chrome plan
       compose -> paint -> synchronous flush
       commit rendered state only after successful flush
  -> request shutdown
  -> Loop drains owned work to terminal states
  -> root tears down process resources in reverse order
```

`root.zig` remains process/bootstrap policy. `InputPump`, `InputDecoder`,
`Terminal`, `Transcript`, `chrome`, `screen`, and pure layout modules retain
their concrete responsibilities. `FrameLoop` and `Runner` do not survive as
coordination tiers.

### 6.1 Final `Loop` interface

The production interface should stay small and direct. It should cover:

- complete initialization with the already-open session and runtime resources;
- running or stepping the concrete owner loop;
- explicit shutdown request and terminal-completion observation where bootstrap
  needs them;
- deterministic action/step/frame entry points needed by headless tests.

The exact Zig signatures may follow implementation constraints, but callers may
not inspect scheduling fields or mutate editor, transcript, dirty, picker,
completion, or task state directly.

`Loop.init` must establish invariants completely. Replace staged `bindSession`
and `bindServices` setup rather than preserving optional half-initialized
production state. A deliberately minimal test constructor is acceptable only if
it creates a valid explicit test state, not an object that production methods
must treat as partially initialized.

### 6.2 One concrete iteration

The iteration order is normative:

1. Wake and capture the owner-edge timestamp.
2. Drain input bytes and decode actions.
3. Dispatch input actions before background continuation work.
4. Poll at most the documented bounded amount of agent, restore, completion,
   and foreground-operation work.
5. Apply resize and other owner-edge terminal facts.
6. Compute the nearest deadline from owned state.
7. If rendering is due, compose, paint, synchronously flush, then mark the frame
   rendered.
8. Clear dirty/render gates only after successful flush.
9. Return to the single wait point.

There must be one production function where this order can be read top to
bottom. Helpers may contain mechanism, but they may not create a second
scheduler or reorder owner phases implicitly.

Time enters at the iteration edge and is passed into transitions. Worker
completion wakes carry no payload; the owner inspects its state after waking.

### 6.3 Scheduling state

All fields that decide when the loop wakes or renders must be grouped as owned
frame state rather than split between `Runner`, `FrameLoop`, and `Loop`. This
includes:

- dirty state;
- last frame start;
- frame floor;
- animation deadlines;
- lone-escape deadline;
- retry and bounded-continuation deadlines;
- input latency stamps and trace counters that are committed at flush.

There is one `nextDeadline` calculation over concrete owned states. There is no
`anytype` runner dispatch, `@hasDecl` scheduling branch, or separate render
policy hidden in bootstrap code.

### 6.4 Agent run state

Replace `RunDriver` with an explicit run-state value held by `Loop`. Preserve the
existing states and bounds:

- idle;
- running prompt;
- retry wait;
- compacting;
- saved prompt and image ownership;
- eight live events per owner iteration;
- render-before-next-batch gate;
- request-cancel then observe-settled shutdown.

All transitions that affect transcript, notices, queued text, file-index
staleness, trace counters, or frame dirtiness are direct `Loop` methods in one
contiguous implementation region. Do not replace direct calls with a list of
run effects that `Loop` later translates.

### 6.5 Foreground operation state

Represent mutually exclusive user-visible asynchronous work with one concrete
tagged union owned by `Loop`. Its variants cover the current lifecycle states
for:

- session listing;
- session opening;
- disposal of an opened-but-canceled session;
- previous-session drain;
- interactive restore;
- clipboard-image read;
- prompt-image preparation.

The union is product-specific. It is not a generic task registry. For each
variant, co-locate or exhaustively switch over:

- admission and conflict policy;
- status text;
- whether submit is blocked;
- nearest deadline;
- normal polling;
- ESC cancellation;
- timeout transition;
- shutdown request;
- terminal-completion observation;
- owned result and cancel-source destruction.

A variant transition must leave no stale nullable task or ownership flag
elsewhere in `Loop`.

File-index rebuilding and scoped file queries remain bounded background
composer mechanism because they do not have the same user-visible exclusive
lifecycle. Their state must nevertheless be grouped with the composer and have
one explicit latest/reject/cancel policy.

### 6.6 Composer

Create a deep, concrete composer implementation around the existing product
concept. `Loop` remains the owner; the composer concentrates:

- `Editor` state;
- preferred visual column;
- slash and file completion candidates;
- picker stack, filtering, and selection;
- picker dismissal tied to composer text;
- bounded popup/picker line materialization;
- scoped file-query identity and latest-result policy.

The composer may return typed local selections such as submit text, model
selection, session selection, or settings selection. `Loop` applies effects to
`AgentSession`, settings, transcript, and foreground operation state directly.
Do not introduce opaque IDs, command envelopes, a widget framework, or a second
input focus model.

The composer remains the omni input. Picker filtering derives from composer
text, and the ESC cascade remains centralized in `Loop`.

### 6.7 Authoritative chrome planning

Replace the independent capacity functions with one authoritative chrome plan.
The plan contains the concrete row allocation for:

- transcript;
- queue and viewport hint;
- status;
- completion popup;
- picker;
- composer.

Final `chrome.compose` consumes that exact plan and asserts that the supplied
materialized rows fit it. It must not independently derive a conflicting plan.

Viewport motion may require a bounded provisional measurement before applying a
pending scroll, especially across resize. If so, encode the operation as an
explicit two-pass transaction:

1. compute one provisional plan;
2. apply pending viewport motion using its transcript capacity;
3. recompute the viewport hint;
4. compute one final authoritative plan;
5. materialize rows and compose with that final plan.

Do not expose separate picker, popup, and transcript capacity APIs again.

### 6.8 Transcript remains deep and intact

`Transcript` continues to own:

- the bounded event fold;
- transcript items and source caps;
- streaming UTF-8 reconciliation;
- tool display data;
- per-item derived layout;
- active and pending relayout state;
- the line prefix index;
- visible-row materialization;
- position resolution and eviction behavior.

Do not split these responsibilities into separate owners to make
`Transcript.zig` shorter. Its algorithmic complexity is essential and already
contained behind a meaningful interface. This refactor may tighten call sites
and tests, but it must not create a second transcript representation or layout
index.

### 6.9 Internal organization rule

Prefer contiguous nested state and owner methods before creating more files.
Extract a file only when it produces a deep module with a smaller interface and
better locality. File length is not an acceptance criterion.

The deletion test applies to every proposed module:

- If deleting it merely removes pass-through calls and exposes the same logic in
  `Loop`, absorb it.
- If deleting it would force several callers to duplicate bounded mechanism or
  pure presentation logic, retain or deepen it.

## 7. Bounds that must not regress

This structural refactor preserves all existing bounded policies, including:

- transcript retention: 2,000 items and 8 MiB source text;
- transcript item text: 256 KiB;
- relayout: 128 items or approximately 256 KiB per prepare step;
- visible materialization: at most `screen.row_capacity` rows;
- agent application: at most eight live results per owner iteration;
- restore: at most 16 entries and a 256 KiB measured-work target per step;
- picker/completion candidate, text, row, and stack caps;
- prompt images: four images and 768 KiB encoded data in aggregate;
- one session operation, with existing listing/opening/drain deadlines;
- one scoped file query with explicit stale/latest-result handling;
- fixed 16 ms frame cadence floor;
- five-second bounded shutdown drain before the existing fatal undrained path.

Every moved accumulation point must retain an explicit reject, evict,
backpressure, spill, or deadline/cancel policy. “It was bounded before” is not a
substitute for naming the bound in the new owner state.

## 8. Implementation sequence

### Phase 0 — Characterize and protect behavior

1. Add or identify focused tests for iteration order, ESC precedence, deadline
   selection, render-after-agent-batch gating, and shutdown terminal states.
2. Record the current public declarations and cross-file direct field accesses
   that must disappear.
3. Do not add temporary compatibility APIs for later phases.

**Gate:** tests prove current behavior and fail when input is moved after an
agent batch, dirty is cleared before flush, or cancellation deinitializes a live
task.

### Phase 1 — Concentrate the owner iteration

1. Move input decoder state, lone-escape timing, input latency accounting,
   waiting, resize, compose, paint, flush, and render commit into `Loop`'s
   concrete run/step path.
2. Make initialization complete rather than staged through bind calls.
3. Reduce `root.zig` to bootstrap, fatal restoration, trace output, and teardown.
4. Delete `Runner` and `src/tui/FrameLoop.zig`.
5. Delete generic runner tests and replace them with deterministic `Loop` step
   tests.

**Gate:** there is one production iteration and one next-deadline calculation;
`root.zig` does not inspect mutable `Loop` internals.

### Phase 2 — Make lifecycle state explicit

1. Replace `RunDriver` with `Loop`-owned run state and contiguous transitions.
2. Introduce the concrete foreground-operation union.
3. Move status, submit blocking, deadline, cancel, timeout, poll, shutdown, and
   cleanup decisions onto exhaustive state transitions.
4. Remove superseded nullable task fields and cleanup branches.
5. Add a transition matrix test for every variant.

**Gate:** adding a foreground-operation variant produces compile failures in all
policy switches that must handle it; normal, error, cancel, timeout, and
shutdown paths each destroy owned resources exactly once.

### Phase 3 — Deepen the composer

1. Group editor, completion, picker, dismissal, materialization buffers, and
   scoped query state under the concrete composer implementation.
2. Keep product side effects in direct `Loop` methods.
3. Centralize mutation rules so editor changes cannot forget completion/picker
   refresh or dismissal invalidation.
4. Preserve the centralized ESC cascade and all existing caps.

**Gate:** composer behavior is tested through text/action/selection transitions;
no nested focus model, command protocol, or generic widget seam exists.

### Phase 4 — Make chrome planning authoritative

1. Introduce the single row plan.
2. Replace separate capacity APIs.
3. Make final composition consume and validate the plan.
4. Express viewport motion as the explicit bounded transaction described in
   section 6.7.
5. Expand small-terminal and resize matrix tests.

**Gate:** every frame uses the same final plan for visible-row materialization
and composition, and all width/height matrix cases fit exactly within terminal
height.

### Phase 5 — Delete residue and tighten documentation

1. Delete unused declarations, old tests, obsolete comments, and pass-through
   helpers.
2. Remove direct mutable-field access from modules outside `Loop.zig`.
3. Update `CONTEXT.md`, `AGENTS.md`, and TUI docs only where final names or owner
   paths changed.
4. Run the full quality gates and compare responsiveness traces.

**Gate:** no compatibility aliases or duplicate paths remain, and the final diff
shows a smaller coordination interface even if `Loop.zig` itself remains large.

## 9. Testing requirements

### 9.1 Headless owner-loop tests

Tests must deterministically cover:

- input dispatch precedes bounded continuation work;
- a full agent-event batch is flushed before another batch becomes eligible;
- nearest-deadline selection across escape, retry, animation, restore, and
  foreground operations;
- resize causes immediate authoritative replanning;
- dirty state and progress gates clear only after successful flush;
- failed paint/flush leaves the frame eligible for retry;
- ESC precedence for picker, completion, session open, image preparation, run
  cancellation, and composer clearing;
- shutdown requests every live source and waits for terminal completion.

### 9.2 Foreground-operation transition matrix

For every operation variant, test:

1. admission from every relevant conflicting state;
2. pending poll;
3. successful result;
4. worker error;
5. user cancel;
6. deadline expiry;
7. late result after cancel or timeout;
8. shutdown while pending;
9. exact-once destruction of task result, cancel source, session, image, or path
   ownership.

### 9.3 Composer tests

Preserve and concentrate tests for:

- slash completion activation and acceptance;
- file completion and scoped query replacement;
- picker stack navigation and filtering from composer text;
- dismissal invalidation after text changes;
- visual-row cursor movement and history boundaries;
- candidate, row, text, and stack caps;
- typed selections without opaque discriminator strings.

### 9.4 Chrome and viewport tests

Use a matrix of pathological widths/heights, multiline composer sizes, queue
counts, status visibility, popup/picker state, and anchored/following viewport
state. Assert:

- the final plan never exceeds terminal height;
- composition consumes exactly the planned row classes;
- composer rows are protected before optional rows;
- pending scroll uses the plan's transcript capacity;
- eviction and relayout preserve a valid viewport anchor;
- no leading transcript item margin appears after planning.

### 9.5 PTY and performance gates

Run the existing PTY gates for typing, resize storms, picker flows, session
restore, synthetic streaming, faux-provider floods, shutdown, and terminal
restoration. Compare deterministic work counters and trace baselines before and
after the refactor.

This is a readability refactor, not permission to regress latency. Input-to-flush,
owner-iteration, event-budget, restore-budget, layout-work, paint, and flush
metrics must remain within existing contracts.

## 10. Structural acceptance criteria

The refactor is complete only when all of the following are true:

1. `src/tui/FrameLoop.zig` is deleted.
2. No production `Runner` coordination type remains.
3. No `RunDriver` type or equivalent owner-callback wrapper remains.
4. One concrete `Loop` path visibly performs wait through successful flush.
5. One deadline calculation covers every owned timer and continuation.
6. `root.zig` performs bootstrap/teardown without mutating `Loop` internals.
7. User-visible exclusive asynchronous work is represented by one concrete
   tagged union with exhaustive lifecycle policy.
8. Composer mutation, completion, and picker invariants have one local home.
9. Chrome exposes one authoritative row plan; separate popup/picker/transcript
   capacity APIs are gone.
10. `Transcript` remains the only transcript and derived-layout owner.
11. No compatibility methods, aliases, deprecated declarations, duplicate
    paths, generic registries, or new protocol tiers remain.
12. Existing bounds and responsiveness metrics pass.

Useful mechanical checks include:

```sh
! test -e src/tui/FrameLoop.zig
! rg '\bRunner\b|\bRunDriver\b|runner\.loop|@hasDecl\(.*nextTimerDeadline' src/tui
! rg 'client_protocol|view_model|engine_drain|wire_protocol' src
```

The implementation may adapt the exact grep expressions to final naming, but it
must preserve the structural intent.

## 11. Quality gates

Run all of the following before completion:

```sh
zig build test
zig build pty-test
zig build
zig fmt --check src
zig fmt --check build.zig
git diff --check
```

Also run the focused headless transition matrices and responsiveness trace
comparisons introduced by this refactor. Report any gate not run.

## 12. Review rubric

Reviewers should ask:

1. Can the full owner iteration be read in one place, in execution order?
2. Can a foreground operation's complete lifecycle be understood without
   searching unrelated fields and cleanup methods?
3. Does the compiler force every new state to define status, deadline, cancel,
   shutdown, and cleanup policy?
4. Does chrome plan once and compose from that same authoritative result?
5. Are composer invariants local without creating a widget framework or command
   protocol?
6. Did the change delete a shallow seam rather than rename it?
7. Did any compatibility shim, alias, mirror model, or translation layer survive?
8. Are all work and memory accumulations still explicitly bounded?
9. Is the direct frontend -> `AgentSession` -> agent -> `Transcript`/screen path
   clearer after the change?

If the implementation produces more modules but requires the reader to know
more interfaces, it has failed even if individual files are shorter. If it
concentrates essential complexity behind a small direct owner interface and
makes state transitions exhaustive, it has succeeded.
