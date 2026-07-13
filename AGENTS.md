# OpenZi engineering rules

## Product references

- `pi-coding-agent` is the coding-agent behavior **and architecture** reference.
- `pi-ai` and `pi-agent-core` are dependencies; `pi-coding-agent` and `pi-tui` are not.
- OpenTUI React is the frontend architecture.
- Zi is the visual and interaction reference, not a source architecture.
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

## Workspace ownership

- `packages/coding-agent`: coding-agent policy and Pi parity.
- `packages/tui`: OpenTUI React frontend only.
- `packages/cli`: process entrypoint and mode composition only.

Dependencies point `cli -> tui -> coding-agent`. `coding-agent` never imports a frontend.
