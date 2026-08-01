# Historical native-subagent design proposal

Status: superseded by [ADR 0029](adr/0029-subagent-profiles-share-session-owned-orchestration.md).

This document previously proposed an always-configurable native delegation product with built-in prompt policy, an enablement setting, semantic status events, and terminal-specific presentation. Implementation evidence separated those concerns more precisely.

Zi now admits subagent profiles only from trusted Markdown resources and programmatic extension registration. Both declaration paths feed one `AgentSession`-owned catalog and receive the same standard orchestration tools when the catalog is non-empty. `AgentSession` and `SubagentSupervisor` retain child-process safety, RPC, containment, cancellation, bounds, durable evidence, and final shutdown. Extensions may add optional custom orchestration over the same mechanics but are not required to make profiles executable.

The research behind the proposal remains useful provenance: Codex and Grok Build demonstrate reusable child sessions, bounded coordination, readable runtime names, explicit interruption, and process containment. Zi deliberately does not restore the former enablement setting, delegation system prompt, generated completion messages, composer rail, subagent-specific notification channel, or specialized terminal presentation.

Current references:

- [Profile-driven subagents](subagents.md)
- [Subagent child-process substrate specification](subagent-process-orchestration-spec.md)
- [ADR 0029: subagent profiles share session-owned orchestration](adr/0029-subagent-profiles-share-session-owned-orchestration.md)
