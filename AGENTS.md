# zi

zi reimplements pi-mono (TS coding agent) in zig. **building block economy**: compose proven primitives — pi-mono's protocol, zig's stdlib — never reinvent. when the agent makes a mistake, encode the prevention here so it compounds away.

references on disk (Read/Grep, never github):
- `.references/pi-mono/` — protocol oracle
- `.references/opentui/` — zig TUI patterns

issues: `bd prime`

## Doctrine

pi-mono parity is the floor; extend, never narrow. close drift, don't defend it. no compat shims, no quick-fix theater.

**impl loop** — find the pi-mono function, list observable behavior (events / fields / order / edges), write idiomatic zig (loops not `.map`, error unions not try/catch, blocking not async). WHAT must match; HOW is zig.

**JSON** — never hand-roll. `std.json.Stringify` to write, `std.json.parseFromSlice` to read. wire is camelCase via explicit `objectField()`; struct fields stay snake_case. shared converters: `packages/ai/src/json_util.zig`.

**testing** — max 3-5 per task, behavior at boundaries, no mocks except network. fixtures generated from running pi-mono, not hand-written. priority: conformance > boundary > behavior. a test that can't fail shouldn't exist.

**storage** — all paths via `storage.zig` (`getAgentDir`, `getProjectDir`, `getSessionDirForCwd`).

## Threading

two long-lived threads — **TUI** and **agent**. every resource has exactly one owner for its entire lifetime. full doctrine: `.zi/design-notes/threading-doctrine.md`.

- agent owns: `lua_State`, `session_store`, `agent.state`, tools/registries, `agent_arena`
- TUI owns: transcript, widgets, overlays, editor, `tui_arena`
- crossing threads: `msg_allocator` (thread-safe GPA) for backing storage AND payloads — `dupe` before pushing

two channels, no third:
- `request_queue`: TUI → agent (`AgentRequest` in `src/agent/request.zig`) when TUI needs the agent to mutate or run
- `event_queue`: agent → TUI (`UiEvent`); TUI reads via published snapshots, never per-keystroke RPC

panics or races: TUI mutating agent state directly, lua from TUI, sharing arenas, borrowed payload slices crossing threads, mutexes added to paper over unclear ownership.

## TUI

`Component` vtable (`render` / `handleInput` / `measure` / `cursorState` / `setFocused`). `Container` is a vertical stack with one `flex` child and one `focused` child; composition root is `interactive.zig`. overlays via `OverlayManager` z-stack — input routes to overlay first. pickers compose `SelectList` + `ListPicker` + `fuzzy.zig` — don't make `SelectList` a Component. autocomplete is inline in the editor, not an overlay; store prefix *length*, never borrowed slices across input events. slash commands live in `slash_commands.zig` via `CommandRegistry`.

## Build & ship

- `zig build` to compile. **never** `zig build test` — it times out. standalone files: `zig test src/file.zig`.
- session is done when pushed: `git pull --rebase && bd sync && git push`. not complete until `git status` shows clean and up-to-date with origin.
