# OpenZi engineering rules

## Product references

- `pi-coding-agent` is the coding-agent behavior **and architecture** reference, and its interactive mode is the TUI product-behavior reference.
- `pi-ai` and `pi-agent-core` are dependencies; `pi-coding-agent` and `pi-tui` are not.
- Imperative `@opentui/core` renderables are the terminal architecture; `@opentui/react` and Pi's TUI implementation are not.
- OpenCode is a source of proven OpenTUI application patterns, not a template to copy wholesale.

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
- Bound queues, output, retries, subprocesses, retained UI data, and shutdown waits.
- Treat interruption, cancellation, shutdown, and disposal as distinct owner transitions. Restore terminal resources before bounded settlement waits; only the layer that created a session disposes it.
- Derive global `$HOME/.openzi` and exact `<cwd>/.openzi` configuration through the immutable coding-agent `OpenZiPaths` owner. Settings, credentials, resources, and persistent session creation consume that cwd-bound value; do not join `.openzi` or re-read process cwd inside those owners.
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
- A boolean is acceptable only for a truly independent binary fact. When combinations acquire meaning, replace the flags with explicit states.
- Keep one source of truth. Derived render values are not additional state, and mutable state is never mirrored between owners.
- `AgentSession` is the shared client-independent business boundary. The terminal-specific `InteractiveMode`, OpenTUI renderables, and presentation stores live under `packages/tui/src/interactive/`.
- Stores are instance-scoped and created by factories. Never export a mutable module-global application store or collect unrelated capabilities into one root state blob.
- Store writable atoms are private implementation details. Components subscribe and request domain-named operations; they do not call `.set()`.
- TUI stores may retain an `AgentSession` reference for subscription identity but may not copy messages, model, queues, or other authoritative state. Native textarea and scroll state remain OpenTUI-owned.
- Below-composer choice flows use the instance-scoped `PickerStack`: `Composer` remains the only input and focus owner; the stack owns frames, selection, suspended parent filters, and top-frame filtering; picker views render only the active frame and never create or edit an input.
- Coding-agent owners do not depend on frontend state libraries. TUI stores use explicit binding and disposal; use Nano Stores `onMount()` only when a terminal resource lifetime genuinely follows observation.

See `docs/adr/0004-explicit-state-and-transitions.md`, `docs/adr/0006-instance-scoped-nano-stores-own-tui-state.md`, `docs/adr/0008-composer-owned-picker-stack.md`, `docs/adr/0009-interruption-and-terminal-shutdown.md`, `docs/adr/0010-interactive-mode-owns-keybindings.md`, and `docs/adr/0011-openzi-path-policy.md` for the project decisions.

## Workspace ownership

- `packages/coding-agent`: `AgentSession`, coding-agent policy, managers, tools, and non-terminal modes such as print/RPC.
- `packages/tui`: the terminal-specific interactive mode, Nano Stores, and imperative OpenTUI composition.
- `packages/cli`: argument parsing, mode selection, and process exit reporting only.

Dependencies point `cli -> tui -> coding-agent`, with `cli -> coding-agent` for shared runtime construction and future non-terminal modes. `coding-agent` never imports a frontend. The TUI entrypoint is loaded dynamically so print/JSON modes need not load OpenTUI.
