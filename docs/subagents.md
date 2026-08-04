---
slug: subagents
title: Delegate with subagents
order: 80
---

# Profile-driven subagents

Zi admits subagent profiles from Markdown resources and programmatic extension registration. Both declaration paths produce the same session-owned profile catalog and activate the same standard model-facing tools. The parent `AgentSession` owns profile precedence, model and thinking resolution, orchestration tools, child-process mechanics, durable evidence, and shutdown.

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

Saved as `pathfinder.md`, this declares profile `pathfinder`. One valid admitted profile is sufficient to activate the standard tools after startup or `/reload`. Start from the copyable [`examples/subagents/pathfinder.md`](../examples/subagents/pathfinder.md) profile when creating one with Zi.

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

`spawn_subagent` selects a profile and supplies a separate unique runtime name. A profile is reusable behavior configuration; a runtime name is a parent-session-unique routing identity. Use the runtime name—not the profile name—for every later operation. Runtime names remain reserved after close.

The profile parameter includes bounded purpose summaries for the admitted catalog, so normal selection does not require a preliminary tool call. `list_subagent_profiles` remains available when the full structured catalog is useful. The selected profile's instructions are prepended to the task, and its model and thinking selection are applied before the session-owned supervisor admits the child. Each parent may own at most four live children. Idle children still consume a slot; close children that will not be reused to free capacity.

`send_subagent` queues context or information and never starts an idle turn. Use it when new material should inform the existing assignment rather than become another task. `continue_subagent` assigns work: it starts an idle turn or adds the task to the active work cycle. If that work must be a separate next assignment, wait for the child to become idle before continuing it. Their successful model-facing results are concise text; typed semantic details remain authoritative for client presentation.

`wait_subagents` accepts 1–16 explicit runtime names. Omitting `names` captures once, when the call begins, up to 16 children that are working or have an uncollected result; later changes do not join that wait. If none qualify, the call returns immediately with an empty result, whose `all_completed` value describes that empty captured set and is therefore true. A timeout reports each captured target independently and never cancels child work. A wait returns the captured cycle's completion when durable, otherwise current status at timeout; older and newer completions are never substituted. Returning a captured completion marks it and older completions for that runtime name delivered. A timeout without that completion marks nothing delivered. The extension API retains explicit-name waits so custom orchestration controls its collection set.

Zi keeps completion collection explicit instead of injecting child completion into parent context.

A session with no admitted profiles exposes none of these tools. Depth-one child sessions cannot recursively create subagents.

## Optional custom orchestration

Extensions may provide specialized tools or workflows over the same substrate. `zi.subagents` exists only when the runtime can create child sessions and provides bounded operations for profile listing, spawn, send, continue, wait, list, interrupt, and close. Runtime names follow the profile-name syntax, prompt and message inputs retain at most 8 MiB, waits accept 1–16 unique names and at most one hour, and result projections are bounded. A wait started by an extension command or tool must fit that invocation's remaining deadline and is cancelled when its owner is cancelled or settles. Custom orchestration is optional; it is not required to use Markdown or programmatically registered profiles.

Extensions never receive `SubagentSupervisor` or child-process handles. Extension reload may replace programmatic registrations and custom tools without terminating already admitted children.

## Lifetime and safety

The parent `AgentSession` owns admitted child processes. Zi enforces child concurrency, runtime names, RPC framing, output retention, cancellation, wait bounds, credential and cwd propagation, process-tree containment, durable journal evidence, and forced cleanup.

Subagent completion never wakes the parent model automatically. Settling child work records a ready result but does not append parent input or start inference. The parent collects completion through standard or custom tools; if its turn has ended, a user or external client must start another turn before the model can collect the result. Standard calls have concise semantic tool rows and expandable completion evidence, but Zi adds no separate subagent rail, notification channel, or generated completion prompt.
