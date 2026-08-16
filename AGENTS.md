# Zi engineering rules

## Product references

- `pi-coding-agent` at commit `73414d08b94d7db46d3fa66582c8fe3b02dabf72` is the coding-agent behavior **and architecture** reference, and its interactive mode is the TUI product-behavior reference.
- `pi-ai` and `pi-agent-core` are dependencies; `pi-coding-agent` and `pi-tui` are not.
- Imperative `@opentui/core` renderables are the terminal architecture; `@opentui/react` and Pi's TUI implementation are not.
- OpenCode is a source of proven OpenTUI application patterns, not a template to copy wholesale.
- `docs/` is the single source for public consumer guides shipped with Zi and rendered by the website. Do not keep a second Markdown corpus under `website/`; keep architecture decisions, roadmaps, research, implementation plans, and maintainer notes out of `docs/`.

## Documentation voice

`docs/` is a man page written by the person who built it. It ships inside the npm tarball and is read by Zi itself as agent context, so density is a feature and narrative padding is a cost.

- Open every page on the reader's situation, then what Zi does about it, then the smallest working example. Never open with a noun-phrase definition of the feature.
- State the failure a bound or rule prevents where it is not self-evident. Bounds must read as design, not legislation.
- Say plainly where Zi chose among alternatives or deliberately refuses to do something. A contract page with real non-numeric limits carries a `## What this does not do` section; that section is not a roadmap.
- One idea per paragraph, two to four sentences, varied sentence length. Do not chain more than two semicolon clauses.
- Keep Zi's ubiquitous language—admitted, settled, bounded, owner, evidence, projection, generation, trusted, journal—and define it only in `docs/vocabulary.md`.
- Titles are imperative and goal-shaped for guide pages, noun-shaped for reference pages. Cross-references state why you would follow them.
- The website Markdown subset is heading, paragraph, code, flat list, single-line definition, and table. Blockquotes and nested lists do not parse, mismatched table rows fail the build, and doc links are not validated. Use `text` fences for figures.

## Product direction

- Zi is a dependable coding-agent substrate with an opinionated reference terminal client. Optimize supported surfaces for downstream configuration, extension, process composition, and eventually deliberate embedding—not for exporting internal modules.
- Use the least powerful sufficient customization level: prompt policy, skill/template, CLI composition, extension, RPC, curated SDK, then separate client or fork.
- Route universal coding-agent policy into `AgentSession` or another concrete coding-agent owner; route specialized executable behavior into extensions; route external applications through RPC; keep substantially different interaction models in clients or forks.
- A public building block requires a narrow documented contract, one complete example, compiled-release acceptance, explicit lifecycle/cancellation/bounds/versioning, and no dependency on private Zi modules.
- Mainline adopts downstream behavior after repeated evidence or when required by a universal invariant or the reference client. Do not add speculative hooks, registries, package splits, or UI callbacks to appear extensible.

## Code quality

Legibility, local reasoning, and ease of change are the top priorities. Do not emit verbose, defensive AI-slop code.

- Write direct code with one obvious control path.
- Name the owner of mutable state and resource lifetimes.
- Keep modules deep and interfaces narrow.
- Prefer concrete types over generic frameworks and option bags.
- Do not create `shared`, `common`, `utils`, manager-of-managers, command buses, or view-model corridors without concrete repeated pressure.
- Do not mirror state between layers. Derive cheap values where they are rendered.
- Do not add defensive branches for states made impossible by the types or owner.
- Do validate external input, persisted data, provider data, and process boundaries.
- Validate runtime JSON with the compiled TypeBox guards in `packages/coding-agent/src/guards.ts`; reach for that owner before writing another inline `isRecord` or sibling primitive guard, and extend it when a primitive check repeats. Byte-length, cross-field, cycle, and exact-message checks stay with their owning domain module instead of becoming schema indirection.
- Bound queues, output, retries, subprocesses, retained UI data, and shutdown waits.
- Treat interruption, cancellation, shutdown, and disposal as distinct owner transitions. Restore terminal resources before bounded settlement waits; only the layer that created a session disposes it.
- Derive global `$HOME/.zi/agent` and exact `<cwd>/.zi` configuration through the immutable coding-agent `ZiPaths` owner. Settings, credentials, resources, and persistent session creation consume that cwd-bound value; do not join `.zi` or re-read process cwd inside those owners.
- Bind terminal product behavior through the instance-scoped semantic keybinding owner. Components may handle native mechanics but do not hard-code product chords; future extension shortcuts join through mode-owned conflict resolution, not mutable global registration.
- Comments explain invariants, trade-offs, and provenance. They do not narrate syntax or restate types.
- Avoid boilerplate JSDoc on self-explanatory symbols.
- Port one Pi capability at a time with its behavior tests and upstream provenance.
- For capabilities spanning `coding-agent` and a client, preserve owner decomposition: coding-agent owners expose authoritative domain data and operations; the client mode composes those owners and translates client input into closed typed intents; stores own admitted transient workflows; components only render state and report native interaction—never hard-code domain catalogs, parse domain syntax, or dispatch business operations.
- Keep imperative components cohesive. A deep prompt owner is preferable to many pass-through wrappers.
- Do not introduce a frontend-wide projection schema until multiple screens need it.

## State and transition design

Explicit-state, data-oriented design is mandatory for stateful behavior.

- Name the state owner, the concrete states, and the allowed transitions before distributing behavior across methods, hooks, or components.
- Represent mutually exclusive states as explicit discriminated unions with domain-named fields. Make invalid combinations unrepresentable instead of coordinating boolean flags and optional properties.
- Write unions directly. Do not hide domain states behind generic tagged-union builders, payload envelopes, class hierarchies, or a state-machine framework.
- Keep transition rules with the state owner. UI components render state and request operations; effects synchronize owned resources but do not become a second transition system.
- Separate transition decisions from side effects. Admit an operation from the current state, record the new state, run the bounded effect, then apply its success, failure, or cancellation transition.
- Handle closed unions exhaustively and use `never` checks. Validate open or external events before they enter the machine.
- Test transitions and forbidden transitions as behavior. Include races, cancellation, stale completion, and bounds where the owner crosses asynchronous or process boundaries.
- Add a runtime invariant when correctness depends on a relationship across authoritative events or mutable owner state: start/end pairing, monotonic identity, settlement/result correspondence, or terminal cleanup. Keep the check beside that owner and observe the operation at its admission or commit point; reject an invalid candidate before external publication when possible.
- `@with-zi/invariants` owns only instance-scoped selection, owner reservation, failure attribution, and cleanup. Product vocabulary and transition rules stay in owner-local invariant modules; do not add product knowledge to the registry, module-global registrations, or a generic invariant event bus.
- Runtime invariants are diagnostics, not validation or business enforcement. External input and durable data remain unconditionally validated, and guarantees required when diagnostics are disabled—such as bounds, uniqueness, and successful-shutdown correspondence—remain in production owners. Never add invariant observations to the journal merely to test runtime behavior.
- Test each invariant with a valid trace and deliberately invalid observations, including transactional rejection, disposal, and restoration from durable history when the owner supports resume. Do not invent checks for method presence, metadata, fixed examples, or states already enforced by types and load-time wiring.
- A boolean is acceptable only for a truly independent binary fact. When combinations acquire meaning, replace the flags with explicit states.
- Keep one source of truth. Derived render values are not additional state, and mutable state is never mirrored between owners.
- `AgentSession` is the shared client-independent business boundary. The terminal-specific `InteractiveMode`, OpenTUI renderables, and presentation stores live under `packages/tui/src/interactive/`.
- Stores are instance-scoped and created by factories. Never export a mutable module-global application store or collect unrelated capabilities into one root state blob.
- Store writable atoms are private implementation details. Components subscribe and request domain-named operations; they do not call `.set()`.
- TUI stores may retain an `AgentSession` reference for subscription identity but may not copy messages, model, queues, or other authoritative state. Native textarea and scroll state remain OpenTUI-owned.
- Below-composer choice flows use the instance-scoped `PickerStack`: `Composer` remains the only input and focus owner; the stack owns frames, selection, suspended parent filters, and top-frame filtering; picker views render only the active frame and never create or edit an input.
- Coding-agent owners do not depend on frontend state libraries. TUI stores use explicit binding and disposal; use Nano Stores `onMount()` only when a terminal resource lifetime genuinely follows observation.

## TUI hot paths and retained projections

Terminal performance is an ownership and data-flow property, not a late rendering optimization.

- Treat native renderable identity, retained node count, subscriptions, scheduled frames, and listeners as owned resources with explicit lifetimes.
- A TUI projection reads authoritative domain state; it may retain bounded indexes, keys, omission counts, and renderable handles, but never copied message text or a second mutable timeline.
- Hot-path work must scale with the changed tail or invalidated suffix. Do not scan complete sessions, rebuild unchanged siblings, or recreate roots for streaming text and progress updates.
- Keep committed renderables stable until explicit reset or bounded eviction. Keep transient renderables keyed and update native properties only when their visible presentation changed.
- Admit high-frequency presentation work through one semantic notification stream and one renderer-owned pre-layout lifecycle admission per visible frame. Use renderer-installed `requestAnimationFrame` only for work that must observe the following frame's settled layout; do not add polling, timers, or an independent FPS scheduler.
- Every retained terminal collection and presentation index has a hard bound. Eviction must preserve explicit navigation state, clear native selection before destroying selectable nodes, and anchor detached viewports when layout changes.
- The owner that creates a renderable, subscription, listener, scheduled callback, or live renderer request releases it. Destroyed or replaced screens must reject stale callbacks.
- Test performance properties structurally: reconciliation count, stable identity, bounded roots, sibling retention, native assignment avoidance, stale completion, and cleanup. Do not use CI wall-clock thresholds.
- Add custom framebuffer renderables only after instrumentation proves stable core renderables, bounded projection, reduced assignments, and frame coalescing are insufficient.
- New asynchronous terminal catalogs and history views load from their presenting feature owner after first draw; the authoritative coding-agent owner provides bounded single-flight operations. Do not introduce a generic query cache or preload inactive screens.

Before adding a new retained row or transient workflow, identify its authoritative source, stable key, invalidation boundary, retention bound, disposal path, and structural tests.

## Workspace ownership

- `packages/coding-agent`: `AgentSession`, coding-agent policy, managers, tools, and non-terminal modes such as print/RPC.
- `packages/tui`: the terminal-specific interactive mode, Nano Stores, and imperative OpenTUI composition.
- `packages/cli`: argument parsing, mode selection, and process exit reporting only.

Dependencies point `cli -> tui -> coding-agent`, with `cli -> coding-agent` for shared runtime construction and future non-terminal modes. `coding-agent` never imports a frontend. The TUI entrypoint is loaded dynamically so print/JSON modes need not load OpenTUI.
