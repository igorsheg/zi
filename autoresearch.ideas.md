# Andrew Pi-Mono in Zig Ideas

Try one idea per iteration. Delete bullets once tried and log the result in `autoresearch.md` / `autoresearch.jsonl`.

- Collapse or delete `src/coding_agent/AgentSessionRuntimeHost.zig` if CLI modes can own session creation/replacement directly. Breaking SDK API is allowed.
- Shrink `src/coding_agent/sdk.zig` to only current executable/resume helpers, or delete it entirely if CLI can call lower-level constructors.
- Replace dynamic `tool_registry` with a static built-in tool table unless a current shipped behavior requires dynamic registration.
- Audit `AgentSession` mirrors: `queue_mirror`, event drain state, public queue, and `session_manager`. Keep one mutation owner and derive projections.
- Make print/json/interactive call one direct session API rather than host forwarding methods.
- In `agent/loop.zig`, collapse `EventSink`/stream copy protocol if direct event application can preserve bounded streaming and tests.
- In TUI product, delete `surface`, `slots`, `snapshot`, or `shimmer` seams that only serve future extension/general-framework needs.
- Read `.references/pi-mono/packages/coding-agent` for product behavior before deleting Zi behavior that may look unused locally.
