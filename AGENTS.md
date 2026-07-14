# OpenZi engineering rules

## Product references

- `pi-coding-agent` is the coding-agent behavior **and architecture** reference, and its interactive mode is the TUI product-behavior reference.
- `pi-ai` and `pi-agent-core` are dependencies; `pi-coding-agent` and `pi-tui` are not.
- OpenTUI React is the frontend architecture; Pi's TUI implementation is not.
- Zi is the visual styling reference only.
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
- Comments explain invariants, trade-offs, and provenance. They do not narrate syntax or restate types.
- Avoid boilerplate JSDoc on self-explanatory symbols.
- Port one Pi capability at a time with its behavior tests and upstream provenance.
- Keep React components cohesive. A deep prompt component is preferable to many pass-through wrappers.
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

See `docs/adr/0004-explicit-state-and-transitions.md` for the project decision.

## Workspace ownership

- `packages/coding-agent`: coding-agent policy and Pi parity.
- `packages/tui`: OpenTUI React frontend only.
- `packages/cli`: process entrypoint and mode composition only.

Dependencies point `cli -> tui -> coding-agent`. `coding-agent` never imports a frontend.
