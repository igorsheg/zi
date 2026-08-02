# Profile-driven subagents

Zi admits subagent profiles from Markdown resources and programmatic extension registration. Both declaration paths produce the same session-owned profile catalog and activate the same standard model-facing tools. The parent `AgentSession` owns profile precedence, model and thinking resolution, orchestration tools, child-process mechanics, durable evidence, and shutdown.

See [ADR 0029](adr/0029-subagent-profiles-share-session-owned-orchestration.md) for the ownership decision.

## Profile contract

A subagent profile contains:

- `name`: 1–64 bytes, beginning with `a-z` and containing only lowercase ASCII letters, numbers, `_`, or `-`;
- `description`: non-blank human- and model-facing purpose of at most 4 KiB;
- `instructions`: non-blank instructions of at most 8 KiB, prepended to the delegated task;
- `model`: optional non-blank `provider/model-id` selection of at most 4 KiB;
- `thinking`: optional `off`, `minimal`, `low`, `medium`, `high`, `xhigh`, or `max`.

Omitted model and thinking values inherit the parent's current selection. An unavailable explicit model fails with profile source attribution; Zi does not silently fall back.

Profiles do not claim permissions, read-only behavior, worktrees, tool restrictions, budgets, or filesystem isolation. Child Zi processes retain the current user's authority unless a future enforceable mechanism says otherwise.

## Markdown declaration

Global profiles load from:

```text
$HOME/.zi/agent/subagents/*.md
```

Trusted project profiles load from:

```text
<cwd>/.zi/subagents/*.md
```

The filename supplies the profile name:

```md
---
description: Find relevant implementation and tests
model: openai-codex/gpt-5.3-codex-spark
thinking: minimal
---

Inspect only the requested area. Return concrete file paths and concise findings.
```

Saved as `pathfinder.md`, this declares profile `pathfinder`. One valid admitted profile is sufficient to activate the standard tools after startup or `/reload`.

## Programmatic declaration

Extensions declare the same profile shape:

```ts
import type { ExtensionAPI } from "@with-zi/extension-api"

export default function (zi: ExtensionAPI): void {
  zi.registerSubagentProfile({
    name: "pathfinder",
    description: "Find relevant implementation and tests",
    instructions: "Inspect only the requested area and return concrete evidence.",
    model: "openai-codex/gpt-5.3-codex-spark",
    thinking: "minimal"
  })
}
```

This registration alone activates the same standard tools as the Markdown declaration. It does not require a second extension tool.

Profile precedence is:

1. trusted project Markdown;
2. global Markdown;
3. extension registration.

Resource loading and one extension generation each retain at most 64 profiles, so the composed catalog remains bounded at 128 before same-name precedence removes collisions.

## Standard tools

A non-empty catalog activates:

- `list_subagent_profiles`;
- `spawn_subagent`;
- `send_subagent`;
- `continue_subagent`;
- `wait_subagents`;
- `list_subagents`;
- `interrupt_subagent`;
- `close_subagent`.

`spawn_subagent` selects a profile and supplies a separate unique runtime name. The selected profile's instructions are prepended to the task, and its model and thinking selection are applied before the session-owned supervisor admits the child.

A session with no admitted profiles exposes none of these tools. Depth-one child sessions cannot recursively create subagents.

## Optional custom orchestration

Extensions may provide specialized tools or workflows over the same substrate. `zi.subagents` exists only when the runtime can create child sessions and provides bounded operations for profile listing, spawn, send, continue, wait, list, interrupt, and close. Runtime names follow the profile-name syntax, prompt and message inputs retain at most 8 MiB, waits accept 1–16 unique names and at most one hour, and result projections are bounded. Custom orchestration is optional; it is not required to use Markdown or programmatically registered profiles.

Extensions never receive `SubagentSupervisor` or child-process handles. Extension reload may replace programmatic registrations and custom tools without terminating already admitted children.

## Lifetime and safety

The parent `AgentSession` owns admitted child processes. Zi enforces child concurrency, runtime names, RPC framing, output retention, cancellation, wait bounds, credential and cwd propagation, process-tree containment, durable journal evidence, and forced cleanup.

Subagent completion never wakes the parent model automatically. The parent collects completion through standard or custom tools. Standard calls have concise semantic tool rows and expandable completion evidence, but Zi adds no separate subagent rail, notification channel, or generated completion prompt.
