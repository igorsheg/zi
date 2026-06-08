# Andrew Kelley Delete Loop Ideas

Try one idea per iteration. Delete bullets once tried and log the result in `autoresearch.md` / `autoresearch.jsonl`.

- Audit `src/coding_agent/AgentSession.zig` for fields that duplicate facts already owned by `agent.Agent`, `session_manager`, `queue_mirror`, or `event_drain`; replace mirrors with derived snapshots where practical.
- Look for one-caller public types/functions in `src/agent/root.zig`; make private, move closer to owner, or delete.
- Split `interactive.zig` only around existing ownership seams: input drain, public-event translation, render transaction. Do not create a generic TUI framework.
- In `agent/loop.zig`, search for state carried only to satisfy callback shape; collapse callback protocol if direct turn-loop data is clearer.
- In `frame.zig`, identify repeated rendering projection/chrome code that can be data-local without adding retained surfaces or dirty rectangles.
