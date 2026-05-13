# TUI subsystem map

The TUI subsystem is organized by depth: small primitives at the bottom, reusable widgets above them, and interactive flows at the composition edge.

- `primitives/` — terminal-agnostic building blocks: geometry, surfaces, views, layout, focus, overlays.
- `terminal/` — terminal adapters: keys, input buffering, ANSI output, clipboard, file descriptors.
- `wrap/` — text wrapping primitives. `wrap/display.zig` is the canonical display-width wrapper.
- `transcript/` — retained transcript rendering core: item protocol, row/segment layout, document fragments, boxed/chrome variants.
- `markdown/` — markdown parsing and rendering into TUI spans/surfaces.
- `components/` — reusable visual modules built on `primitives`: text, editor, messages, pickers, panels, overlays, status text.
- `editor/` — editor internals and the editor interface (`buffer`, `layout`, `navigation`, `render`, `autocomplete`, `interface`, `view`).
- `autocomplete/` — provider-side autocomplete interfaces and provider composition.
- `conversation/` — conversation transcript UI: transcript rows, projection, tool display, rendered tool result views, and tool renderers.
- `interactive/` — interactive-mode orchestration. `interactive/runtime/` owns queues, the agent loop, job manager, event publication, idle dispatch, and memory telemetry; sibling files are user-facing flows, input handling, startup/setup, and request/event adaptation.

Top-level files are reserved for cross-cutting TUI concepts that are intentionally shared by several groups: `tui.zig`, `root.zig`, `renderer.zig`, `theme.zig`, `ui_event.zig`, `status_data.zig`, and small rendering primitives such as `cell.zig` and `grapheme.zig`.
