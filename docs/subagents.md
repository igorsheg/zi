---
slug: subagents
title: Delegate work to agents
order: 90
---

# Delegate work to agents

You need a bounded second line of work without losing its context after Zi exits. Zi forks the current root session into a durable child, keeps the child's journal under the root session, and delivers one passive completion for each child turn.

The root-scoped `AgentTeam` owns addresses, residency, turns, mail, and completion acknowledgement. Child work still runs in an in-process `AgentSession`; it has its own context and journal rather than sharing the root transcript.

## Delegate one task

Call `spawn_agent` with a stable task name and the first task:

```json
{ "task_name": "storage_map", "message": "Find the journal write path and return concrete file references." }
```

The result contains the canonical path `/root/storage_map`. Use that path for later messages, follow-ups, interruption, and filtering.

Zi delivers the child's final result to the root as durable custom mail. `wait_agent` observes the root session's pending agent mail but does not carry final child content.

## Six collaboration tools

Every root session exposes exactly these model-facing operations:

- `spawn_agent` creates one durable direct child;
- `send_message` queues context without starting an idle turn;
- `followup_task` starts an idle child's next turn or joins its active turn;
- `wait_agent` waits for pending or future agent-mail activity;
- `list_agents` projects bounded current state;
- `interrupt_agent` interrupts the current turn without deleting its address.

There are no model-facing legacy aliases. In particular, `spawn_subagent`, `wait_subagents`, and the former close operation are not part of the catalog.

`wait_agent` subscribes to the caller's bounded input activity before checking for pending mail. A completion that wins the race therefore returns immediately; otherwise Zi waits for agent mail, steered input, or the bounded timeout. The configured default is 30 seconds, explicit waits shorter than 10 seconds are clamped, and one hour is the hard maximum.

The result contains only a summary and timeout status. A timeout does not cancel work or acknowledge a completion.

`list_agents` returns identity and lifecycle facts, not copied conversations. Each row includes the canonical path, parent path, task name, optional role, residency, turn state, turn number, and latest settled status.

## Reuse a child

A settled child is unloaded to release its in-process resources, but its durable identity remains. Give it another task with the same path:

```json
{ "target": "/root/storage_map", "message": "Now compare that path with compaction restoration." }
```

Use this input with `followup_task`. Zi lazily opens the same child journal, starts its next numbered turn, and unloads it again after settlement.

`send_message` is different. It durably queues context and leaves an unloaded child unloaded; the mail is admitted when a later follow-up loads that journal. If the child is already working, the message joins its next safe provider boundary.

## Choose an optional role

Roles add reusable instructions and optional model selection, but they are not required to spawn an agent. Put a role in the global directory:

```text
$HOME/.zi/agent/subagents/pathfinder.md
```

Trusted projects may add roles under:

```text
<cwd>/.zi/subagents/pathfinder.md
```

A minimal role is:

```md
---
description: Find implementation evidence for one bounded question
model: openai-codex/gpt-5.3-codex-spark
thinking: minimal
---

Inspect only the requested scope. Return concrete file paths and unresolved questions.
```

Pass `"agent_type": "pathfinder"` to `spawn_agent`. Zi prepends the role instructions to the task and records the selected role in durable lineage; omitting `agent_type` uses the implicit default behavior.

Role names begin with a lowercase ASCII letter and contain only lowercase letters, numbers, `_`, or `-`. Unknown roles fail admission instead of silently falling back.

Extensions register the same role shape:

```ts
import type { ExtensionAPI } from "@with-zi/extension-api"

export default function (zi: ExtensionAPI): void {
  zi.registerAgentRole({
    name: "pathfinder",
    description: "Find implementation evidence for one bounded question",
    instructions: "Inspect only the requested scope and return concrete paths."
  })
}
```

Project Markdown wins over global Markdown, which wins over extension registration when names collide. Roles configure behavior; they do not enforce permissions, filesystem isolation, tool restrictions, or worktrees.

## Orchestrate from an extension

When the runtime owns an `AgentTeam`, extensions receive `zi.agents`:

```ts
const path = await zi.agents.spawn("storage_map", "Find the journal write path.")
await zi.agents.send(path, "Include restoration checks.")
const agents = await zi.agents.list()
```

The API also provides `followup`, targetless bounded `wait`, and `interrupt`. Paths are canonical root-child addresses, and sender identity is captured by the worker bridge rather than supplied by extension code.

An extension wait belongs to its command or tool invocation. Cancellation of that owner cancels the wait without cancelling child work.

## Understand durability

A persistent root produces persistent descendants. Spawn first writes a root reservation, creates the child fork, then commits the root record before starting provider work. A failed admission never publishes a half-created child.

The root journal is authoritative for the tree. Each child journal also carries immutable lineage—root session, parent session, parent entry, path, generation, and role—as a cross-check when Zi opens it.

Each child turn has one durable operation identity. Settlement is recorded before passive completion delivery, and delivery is acknowledged in the root journal with `completion:<path>:<turn>`. Restart therefore restores pending delivery without duplicating a completion already acknowledged.

`--no-session` keeps the same ownership model in memory. Child journals remain available for unloading and later follow-up for the lifetime of that root runtime, but they do not survive process exit.

## Capacity and shutdown

The root and its team share four execution slots: one root slot and at most three active child turns. Residency is separate from durable identity, so settled children unload automatically and do not permanently consume those slots.

Queues, waiters, mail, tool results, retained journal data, turn deadlines, and shutdown waits are bounded. A root session owns team shutdown; member sessions borrow the team and never dispose it.

Shutdown interrupts active turns, waits within its settlement bound, and disposes resident child sessions. It does not erase durable child records or acknowledged completion evidence.

## What this does not do

- This release admits direct children only. A child cannot create a recursive descendant even though it shares the collaboration catalog.
- Zi does not expose a model-facing close or delete operation. Terminal residency is reclaimed automatically while durable identity remains.
- `wait_agent` does not return final child text and is not the completion-delivery channel.
- The terminal client does not yet provide `/agent` transcript browsing for durable children.
- Roles do not create a security boundary. Child sessions and executable tools retain the current user's authority.
