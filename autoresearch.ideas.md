# Andrew Kelley Delete Loop Ideas

Try one idea per iteration. Delete bullets once tried and log the result in `autoresearch.md` / `autoresearch.jsonl`.

- Audit `src/coding_agent/AgentSession.zig` for fields that duplicate facts already owned by `agent.Agent`, `session_manager`, `queue_mirror`, or `event_drain`; replace mirrors with derived snapshots where practical.
- Inspect `src/tui/product/slots.zig` and `src/tui/product/surface.zig`: if they exist mainly for future extensions, collapse them into today's status/modal behavior or delete unused surface area.
- Review non-test `catch unreachable` sites. For each: encode proof in the type/state, change to `std.debug.assert`, or handle the operational error.
- Look for one-caller public types/functions in `src/agent/root.zig`; make private, move closer to owner, or delete.
- Split `interactive.zig` only around existing ownership seams: input drain, public-event translation, render transaction. Do not create a generic TUI framework.
- In `agent/loop.zig`, search for state carried only to satisfy callback shape; collapse callback protocol if direct turn-loop data is clearer.
- In `frame.zig`, identify repeated rendering projection/chrome code that can be data-local without adding retained surfaces or dirty rectangles.
