# zi TUI — session primer

## what this is

zi is a zig rewrite of pi-mono (a terminal coding agent). the core agent/provider/session/prompt layers are done and oracle-verified against pi-mono contracts. 119 tests, all passing. now building the TUI/interactive layer.

## the spec

`workflows/zi-tui.md` (886 lines, oracle-reviewed) defines the full architecture. read it before writing any code.

key decisions already made:
- **cell-buffer differential rendering** (opentui technique, NOT pi-mono's string-based approach)
- **pi-mono product parity** — same UX, same surfaces, same commands
- **two-thread model** — agent thread runs `ca.run()`, main thread owns terminal I/O + rendering, communicate via `ThreadSafeQueue`
- **component vtable** — `render(region)` writes cells to buffer, not `render(width) → string[]`

## what exists

```
src/agent2/         — Agent struct, dual loop, tool pipeline (36 tests)
src/session/        — JSONL protocol, reader, writer, context builder (27 tests)
src/coding_agent.zig — composition root, 16 e2e tests with faux provider
src/system_prompt.zig — buildSystemPrompt matching pi-mono (4 tests)
src/ai/             — provider registry, anthropic, faux, model catalog
src/tools/bash.zig  — bash tool
src/main.zig        — thin CLI shell (print mode + --continue)
```

no TUI code exists yet. target directory: `src/tui/`.

## build order

**phase 1**: `cell.zig`, `buffer.zig`, `grapheme.zig`, `terminal.zig`, `renderer.zig`, `keys.zig`
- test buffer operations against cell snapshots
- test renderer produces correct ANSI for cell changes
- test key parsing for xterm + kitty sequences

**phase 2**: `components/` — text, container, markdown, editor, loader, box
- test against buffer snapshots (render component → check cells at coordinates)

**phase 3**: `interactive.zig` + overlays + selectors — wire CodingAgent events to components
- test with faux provider: prompt → streaming events → verify buffer state

**phase 4**: polish — syntax highlighting, images, extension UI, advanced editor

## references

- pi-mono TUI: `.references/pi-mono/packages/tui/src/` (tui.ts, terminal.ts, components/)
- pi-mono interactive mode: `.references/pi-mono/packages/coding-agent/src/modes/interactive/`
- opentui zig renderer: `github.com/anomalyco/opentui` packages/core/src/zig/ (buffer.zig, renderer.zig, terminal.zig)
- do NOT add opentui as a dependency — learn its techniques, implement our own

## doctrine

- pi-mono contracts are the spec. port observable behavior, not syntax.
- oracle audit after structural changes. implement → oracle → fix drifts → re-verify.
- test against buffer snapshots, not terminal output. the renderer is tested separately.
- zig idioms: arenas per render cycle, comptime vtable validation, no GC.
