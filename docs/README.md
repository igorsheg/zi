# zi docs

This directory is the canonical home for repo documentation.

## What belongs here

Durable guidance:
- product principles
- architecture boundaries
- ownership rules
- extension model
- TUI model
- replay/provider philosophy

## What does not belong here

Docs should not try to mirror the codebase line by line.

If a doc is mostly:
- file paths
- function inventories
- implementation phase plans
- temporary migration steps
- exact call order that changes with refactors

then it will rot. Put that in an issue, a PR description, or `docs/archive/` if it is still worth keeping.

## Map

- `principles.md` — the doctrine that should survive refactors
- `architecture.md` — the system shape and layer boundaries
- `cli.md` — CLI actions, execution plans, truthful mode selection, and cutover doctrine
- `runtime.md` — thread ownership, queues, snapshots, allocator/lifetime rules
- `extensions.md` — what extensions are, where they run, and how they fit
- `tui.md` — component, overlay, editor, and wrapping philosophy
- `theme-system.md` — theme principles and token philosophy
- `replay.md` — provider normalization and replay architecture
- `archive/` — historical notes and superseded detailed specs; useful context, not source of truth
