# ADR 0029: Subagent profiles share session-owned orchestration

## Status

Accepted. Supersedes [ADR 0027](0027-session-owned-native-subagents.md) while retaining its session-owned child-process mechanics and [ADR 0026](0026-subagent-orchestration-supervises-rpc-processes.md)'s RPC, containment, cancellation, and bounds.

## Decision

A subagent profile is one admitted declaration of delegated behavior. Global and trusted project Markdown resources and programmatic extension registration are equal declaration paths into one `AgentSession`-owned profile catalog. They share the same name, description, instructions, optional model, and optional thinking contract. Trusted project resources take precedence over global resources, which take precedence over extension registrations with the same name.

When child execution is available and the catalog is non-empty, `AgentSession` derives Zi's standard model-facing subagent tools from that catalog. The tools list profiles and provide spawn, send, continue, wait, list, interrupt, and close operations. With no admitted profiles, Zi exposes no standard subagent tools. Profiles therefore activate the shared subagent system; users do not need a second extension solely to make a Markdown profile executable.

Extensions may register profiles without registering tools. They may also build specialized delegation tools and orchestration over the same versioned, source-attributed, bounded `zi.subagents` operations. Those optional operations never expose `SubagentSupervisor` or child-process handles. Extension reload replaces programmatic profile declarations and custom policy without terminating admitted session-owned children.

`AgentSession` owns the canonical catalog, profile precedence, model and thinking resolution, instruction composition, standard tool projection, and one optional `SubagentSupervisor`. The supervisor owns runtime-name admission, child processes, work cycles, completion retention, durable evidence, cancellation, bounds, process containment, and final shutdown. A subagent name remains a unique runtime routing identity separate from its profile name.

Profiles deliberately do not declare permissions, read-only behavior, worktrees, tool restrictions, budgets, or filesystem isolation because Zi cannot enforce those claims. Omitted model and thinking values inherit the parent selection; an unavailable explicit model fails with profile source attribution.

Zi retains no native delegation system prompt, generated completion message, enablement setting, semantic `subagent_changed` event, composer rail, subagent-specific notification presenter, or separate terminal status surface. Standard tools use ordinary tool lifecycle plus coding-agent-owned semantic projections rendered through the TUI's generic tool primitives. Completion remains passive until the parent collects it through a tool.

## Consequences

Dropping one valid Markdown file into an admitted subagent resource directory is sufficient to activate standard delegation on the next session or reload. Registering the same shape from an extension produces the same behavior and shares the same mechanics. Custom extension orchestration remains possible without becoming a prerequisite for declarative profiles.

The canonical acceptance case covers both declaration paths: each must activate the same standard tool catalog and complete real child work. A profile-less session must expose no standard subagent tools, and a depth-one child session must not recursively expose child execution. Zi v0.1.16 passed that compiled acceptance on all five release targets, including graceful and forced descendant cleanup through a real Windows Job Object.
