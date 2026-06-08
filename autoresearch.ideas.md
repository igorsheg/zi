# Andrew Kelley Delete Loop Ideas

Try one idea per iteration. Delete bullets once tried and log the result in `autoresearch.md` / `autoresearch.jsonl`.

- Audit `src/coding_agent/AgentSession.zig` for fields that duplicate facts already owned by `agent.Agent`, `session_manager`, `queue_mirror`, or `event_drain`; replace mirrors with derived snapshots where practical.
- Continue `src/tui/product/slots.zig` audit after modal/label/focus cleanup: check whether remaining slot priorities/owner clearing are current product needs or extension-shaped surface.
- Review non-test `catch unreachable` sites. For each: encode proof in the type/state, change to `std.debug.assert`, or handle the operational error.
- Look for one-caller public types/functions in `src/agent/root.zig`; make private, move closer to owner, or delete.
- Split `interactive.zig` only around existing ownership seams: input drain, public-event translation, render transaction. Do not create a generic TUI framework.
- In `agent/loop.zig`, search for state carried only to satisfy callback shape; collapse callback protocol if direct turn-loop data is clearer.
- In `frame.zig`, identify repeated rendering projection/chrome code that can be data-local without adding retained surfaces or dirty rectangles.
- Decide whether `src/tui/product/shuffle_text.zig` should disappear entirely now that no product status effect uses it; if deleting, adjust the test-count baseline deliberately and explain why the removed tests covered dead code only.
