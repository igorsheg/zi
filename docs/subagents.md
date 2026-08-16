---
slug: subagents
title: Delegate work to agents
order: 90
---

# Delegate work to agents

You need parallel work without losing its context after Zi exits. Zi forks the caller's session into a durable descendant, runs another in-process `AgentSession`, and routes one passive completion to that agent's direct parent.

The root-scoped `AgentTeam` owns identity, recursive lineage, residency, turns, bounded mail, and completion acknowledgement across the tree. Every descendant receives the same six collaboration operations, so orchestration can continue recursively without private runtime access.

## Delegate one task

Call `spawn_agent` with a stable task name and the complete runtime-authored instructions:

```json
{
  "task_name": "storage_map",
  "message": "Act as a storage specialist. Find the journal write path and return concrete file references.",
  "agent_type": "explorer"
}
```

Omitting `agent_type` selects `default`. Zi returns the canonical path `/root/storage_map`; a descendant named `verification` spawned by that agent becomes `/root/storage_map/verification`.

The `message` is the agent's actual role and task. Zi does not prepend a hidden profile, load role files, or infer a model from the built-in type.

## Use the six operations

Every team member exposes exactly these model-facing operations:

- `spawn_agent` creates one durable child below the caller;
- `send_message` queues context without starting an idle turn;
- `followup_task` starts an idle agent's next turn or joins its active turn;
- `wait_agent` waits for caller-session mail or input activity;
- `list_agents` projects bounded state below an optional path;
- `interrupt_agent` interrupts a current turn without deleting its identity.

There are no legacy aliases and no close operation. Residency is reclaimed automatically while durable identities remain reusable.

`wait_agent` returns `{ message, timed_out }`; final child text remains durable mail. A pending completion returns immediately, while future mail, user steering, custom steered input, cancellation, or the bounded timeout settles the wait. The configured default is 30 seconds, explicit waits shorter than 10 seconds are clamped, and one hour is the hard maximum.

`list_agents` returns identity and lifecycle facts rather than copied conversations. Each row includes path, parent path, task name, built-in agent type, residency, turn state, turn number, and settled status.

In the terminal, `/agents` opens the same durable facts in a read-only picker. `Tab` switches between running and all agents; descendant transcripts remain unavailable.

## Choose a built-in type

Zi admits exactly three closed orchestration labels:

| Type       | Use it for                                                          |
| ---------- | ------------------------------------------------------------------- |
| `default`  | General delegated work when no narrower label helps.                |
| `explorer` | Read-heavy investigation and exact evidence gathering.              |
| `worker`   | Focused implementation or verification with a concrete deliverable. |

These labels guide orchestration and tool descriptions. They do not register prompts, permissions, tool restrictions, worktrees, or isolation, and extensions cannot add more types.

Specialist behavior belongs in the spawn `message`. This keeps the instruction visible at the call site and prevents project or global profile files from silently changing execution.

## Select execution explicitly

A spawn may override the caller's current model and thinking level:

```json
{
  "task_name": "verification",
  "message": "Verify the proposed journal change and report only concrete regressions.",
  "agent_type": "worker",
  "fork_turns": "none",
  "model": "openai-codex/gpt-5.3-codex",
  "thinking": "high"
}
```

`fork_turns` accepts `all`, `none`, or a positive integer encoded as a string in the model-facing tool. Omitted model and thinking values inherit the caller's live admitted selections.

Zi resolves model and thinking before reserving the spawn. An unknown model leaves no visible child or fork; a successful reservation journals the concrete provider, model ID, and effective thinking level so restoration cannot drift with later settings.

## Reuse and coordinate agents

A settled agent unloads to release resources but keeps its durable path. Start another numbered turn with `followup_task`:

```json
{ "target": "/root/storage_map", "message": "Compare that path with compaction restoration." }
```

`send_message` only delivers context. It leaves an unloaded target unloaded, admits queued mail when that journal is restored, and joins an active target at a safe provider boundary.

Paths make recursive routing explicit. A child can message `/root`, its direct parent, a sibling it learned from `list_agents`, or one of its own descendants.

## Orchestrate from an extension

When the session belongs to an `AgentTeam`, extensions receive the same six operations through `zi.agents`:

```ts
const path = await zi.agents.spawn("storage_map", "Find the journal write path.", {
  agentType: "explorer",
  forkTurns: "all"
})
await zi.agents.send(path, "Include restoration checks.")
const wait = await zi.agents.wait()
if (wait.timedOut) return wait.message
return wait.agents
```

`spawn` also accepts `model` and `thinking`. The extension bridge captures caller identity instead of accepting a forged sender, and its wait belongs to the invoking command or tool. Cancelling that owner cancels the wait without cancelling agent work.

## Understand durability

A persistent root produces persistent descendants. Spawn writes a root-journal reservation, creates a fork from the direct parent's admitted checkpoint, and commits the graph record before provider work starts. Failed model resolution or fork creation never publishes a half-created agent.

The root journal is authoritative for the whole tree. Each descendant journal carries immutable root session, direct-parent session, parent entry, path, and generation lineage, plus the concrete execution selection used to restore it.

Settlement is recorded before completion delivery. The completion target is the direct parent, not always `/root`; if that parent is unloaded, the root journal retains pending delivery until the parent is restored. Acknowledgement by `completion:<path>:<turn>` prevents duplicate delivery after restart.

Old journals containing the removed `subagent` or `subagent_work_result` entry types are intentionally unreadable. Zi does not keep a private compatibility parser for that retired execution system.

## Capacity and shutdown

The tree shares root-scoped bounds: at most 64 durable records, depth 8 including `/root`, three resident descendants, and three active descendant turns. Queues, mail, waits, retained output, turn deadlines, and shutdown settlement are bounded separately.

The root session owns team shutdown; descendants borrow the team and never dispose it. Shutdown interrupts active turns, waits within its bound, and disposes resident sessions without erasing durable identities or acknowledged completion evidence.

## What this does not do

- Zi does not load project, global, or extension-defined agent profiles.
- Built-in types do not create a security boundary; agents and executable tools retain the current user's authority.
- `wait_agent` does not return final child text or acknowledge completion mail.
- Zi does not expose model-facing close or delete operations.
- The terminal client lists durable agents but does not yet open descendant transcripts.
