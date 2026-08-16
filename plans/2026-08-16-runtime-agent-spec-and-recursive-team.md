# Runtime agent specification, recursive lineage, and legacy cleanup

## Status

Approved. Implementation proceeds in vertical slices.

This work builds on the committed AgentTeam control plane and the uncommitted explicit `zi.agents.wait()` outcome change. It does not alter the six model-facing collaboration operation names.

## Product decision

Zi has exactly three built-in agent types matching Codex v2: `default`, `explorer`, and `worker`. They are closed orchestration labels with built-in descriptions, not user-defined profiles or config layers. Omitting `agent_type` selects `default`.

The runtime `message` is the complete specialist instruction and task. Direct tool calls, Code Mode, and extensions all use the same spawn primitive. Skills, prompts, and extension tools may construct reusable delegation recipes, but AgentTeam never resolves a named recipe. The built-in type does not prepend hidden user instructions or select a model.

A child receives the same admitted tool surface and Code Mode policy as its parent. Once AgentTeam admits recursive lineage, a child may construct and spawn another child through the same six operations.

## Public contracts

### Model-facing spawn

```ts
spawn_agent({
  task_name: string,
  message: string,
  agent_type?: "default" | "explorer" | "worker",
  fork_turns?: "all" | "none" | positiveIntegerString,
  model?: string,
  thinking?: "off" | "minimal" | "low" | "medium" | "high" | "xhigh" | "max"
})
```

`message` carries runtime specialist instructions and the task. There is no user-defined role lookup or separate `instructions` field.

Omitted `model` and `thinking` inherit the caller's live values. Zi resolves and validates the effective model/thinking before asking AgentTeam to reserve the child.

### Extension spawn

```ts
zi.agents.spawn(taskName, message, {
  agentType?: "default" | "explorer" | "worker"
  forkTurns?: "all" | "none" | number
  model?: string
  thinking?: ExtensionThinkingLevel
}): Promise<string>
```

The extension call and model tool share the same resolution owner. Extensions do not receive role registration or role catalogs.

### Durable domain types

```ts
interface AgentExecutionSpec {
  readonly model: SessionModel
  readonly thinkingLevel: ThinkingLevel
}

type AgentType = "default" | "explorer" | "worker"

interface AgentSpawnSpec {
  readonly agentType: AgentType
  readonly forkTurns: ForkTurns
  readonly execution: AgentExecutionSpec
}

interface SpawnAgentRequest {
  readonly sender: AgentPath
  readonly taskName: string
  readonly message: string
  readonly spec: AgentSpawnSpec
}
```

`AgentTeam` receives only resolved, serializable facts. It does not depend on `ModelRegistry`, resource loading, extension catalogs, or AgentSession's current selection.

## Ownership and call flow

```text
AgentSession caller
  resolveAgentSpawnSpec(requested type/model/thinking/fork, live selection)
  createAgentTeamTools(... resolveSpawnSpec ...)
    AgentTeam.spawn({ sender, taskName, message, spec })
      append agent_spawn_reserved including spec
      capture the direct parent's authoritative fork checkpoint
      create child fork
      append agent_spawn_committed
      create child AgentSession with the durable execution spec
      start child turn with the runtime message
```

On restoration:

```text
root SessionManager
  replay AgentTeam records including concrete spec
  keep every child unloaded
  follow-up or pending-parent delivery loads one child
    open exact child journal
    create AgentSession from durable spec plus child history
```

The root journal decides which execution spec was admitted. The child journal records the effective model/thinking through normal session evidence and must agree after creation.

## Recursive lineage

### Spawn

For sender `/root`, the parent manager is the root `SessionManager`. For any other sender, the sender must be a resident AgentTeam record; its resident state retains the exact `SessionManager` borrowed by that AgentSession.

AgentTeam derives:

```text
parentPath      = sender
parentSessionId = parentManager.sessionId
parentEntryId   = parentManager.captureForkCheckpoint().leafId
path            = childAgentPath(sender, taskName)
generation      = parent.generation + 1
```

The existing 64-record tree bound, three-resident-agent bound, three-active-child-turn bound, path-byte bound, and fork/history bounds remain authoritative. Recursive work does not receive an unbounded side channel.

### Completion

A settled child publishes one durable completion addressed to `record.parentPath`.

- Root parent: deliver through the bound root AgentSession.
- Resident member parent: deliver through its AgentTeam session owner using append or boundary publication according to its activity.
- Unloaded member parent: leave the completion pending in the root journal.

When a member becomes resident, AgentTeam delivers pending ordinary mail and pending direct-child completions before starting its next task. Acknowledgement remains a root-journal `agent_completion_delivered` record keyed by child path and turn.

A parent may finish and unload while descendants continue. Descendant residency and execution therefore do not pin every ancestor in memory.

### Inspection and addressing

`list_agents` continues to return the complete bounded durable tree and accepts canonical or caller-relative prefixes. `send_message`, `followup_task`, and `interrupt_agent` resolve relative targets from the calling member path.

## Legacy deletion boundary

### Delete named profile support

Delete:

- `packages/coding-agent/src/subagent-profiles.ts`;
- `SessionResources.subagentProfiles` and `.zi/subagents` discovery;
- `ExtensionAgentRole`, `ExtensionSubagentProfile`, and `registerAgentRole`;
- role registration/catalog worker frames and validators;
- user-defined role descriptions, collision diagnostics, and role-derived instruction prefixing;
- `AgentRoleSelection` and user-defined role fields in AgentTeam state;
- profile examples and public documentation.

### Replace extension transport with the six Agent operations

The host/worker protocol should carry public Agent-shaped values directly:

- spawn returns canonical path;
- send returns void;
- follow-up returns `started | joined`;
- wait returns `{ message, timedOut, agents }`;
- list returns `ExtensionAgentSnapshot[]`;
- interrupt returns `interrupted | idle`.

Delete `agent_roles_get`, close, named wait targets, `ExtensionSubagentAPI`, `ExtensionSubagentSnapshot`, and the legacy Agent-to-Subagent projection adapters. Bump the internal extension protocol once for the final closed shape rather than preserving aliases.

### Delete the old supervisor

Delete all of `packages/coding-agent/src/subagents/`, including peer relay. Move the active timeout policy into AgentTeam-owned modules first.

Delete the supervisor, child, peer, completion-ledger, legacy tool, and invariant tests. Preserve behavior coverage only where AgentTeam owns the corresponding contract.

Remove `peerRelay` from SDK construction, old `subagent_changed` events, `subagentSnapshots()` adapters, old public exports, and dormant subagent transcript UI. Transcript browsing remains deferred until AgentTeam exposes a real durable transcript source.

### Durable old-session reads

Hard-delete legacy journal support. Remove old `subagent`, `subagent_work_result`, and user-defined AgentTeam `role` entry variants and their validators. Sessions containing those entries become unreadable by design.

New AgentTeam writes persist only the closed built-in `agentType` and concrete execution spec. There is no compatibility parser or catalog lookup.

## Vertical implementation slices

### Slice 1: Durable runtime spawn spec

Behavior:

- `agent_type` is the closed `default | explorer | worker` catalog;
- optional per-spawn model/thinking overrides;
- omitted values inherit the caller;
- unknown model fails before reservation;
- concrete execution spec survives unload and process restart.

Tests:

- one model-facing spawn schema/behavior test;
- journal validation and replay of the concrete spec;
- production child restoration with explicit model/thinking;
- extension spawn contract using the same resolver;
- atomic unknown-model rejection.

Verification:

```text
coding-agent AgentTeam, journal, AgentSession, extension protocol/runtime suites
extension-api typecheck
compiled AgentTeam acceptance
```

### Slice 2: Recursive lineage and direct-parent completion

Behavior:

- a resident child spawns a grandchild;
- the grandchild fork uses the child's exact checkpoint;
- completion wakes a running direct parent;
- completion remains pending while its parent is unloaded;
- loading that parent delivers completion before its next turn;
- restart restores the nested tree unloaded and follow-up reuses exact journals.

Tests:

- fake-session AgentTeam transition tests for nested spawn, capacity, and pending parent delivery;
- production integration test for nested journal restoration;
- Code Mode or compiled acceptance proving a child can invoke the same spawn primitive.

Verification:

```text
AgentTeam journal/owner/integration suites
AgentSession mailbox suite
compiled recursive acceptance
```

### Slice 3: Profile and extension substrate deletion

Behavior:

- resource reload no longer scans agent profile files;
- extensions cannot register roles or call legacy subagent operations;
- `zi.agents` exposes exactly the six Agent operations and Agent-shaped results;
- extension wait outcome work remains intact.

Tests:

- closed extension API/protocol contract;
- no role/profile catalog in runtime extension tests;
- resource loader and project-trust tests remove profile expectations;
- updated docs/example acceptance.

Verification:

```text
extension-api and coding-agent typecheck
extension host/worker/protocol/runtime suites
resource-loader and project-trust suites
```

### Slice 4: Old supervisor and presentation deletion

Behavior:

- no legacy supervisor, child runtime, peer relay, legacy model tools, or legacy semantic adapters remain;
- TUI consumes AgentTeam events and snapshots only;
- old journal entries follow the approved compatibility policy.

Tests:

- delete implementation-mirroring legacy suites;
- assert old supervisor journal entries are rejected at the hard compatibility boundary;
- run coding-agent and TUI suites in bounded chunks.

Verification:

```text
rg for SubagentSupervisor, ExtensionSubagent, registerAgentRole,
subagentProfiles, subagent_changed, and production imports from src/subagents
full package typecheck/lint/tests
fresh compiled release acceptance
format and git diff --check
```

## Documentation

Update `docs/subagents.md` around the user situation: write the specialist behavior in the spawn message, or let Code Mode construct it. Explain that model/thinking are concrete execution overrides, not permissions or roles.

Update `docs/code-mode.md` with one small recursive orchestration example after recursive admission ships. Update extension, resource, settings, and RPC pages only where their contracts changed. Remove profile examples rather than retaining a second vocabulary.

## Review decisions

1. Zi exposes exactly the closed built-in `default`, `explorer`, and `worker` agent types from Codex v2; no user-defined roles or profiles remain.
2. Model and thinking are optional direct spawn overrides and become concrete durable facts before reservation.
3. Recursive lineage is part of this change, after the spawn-spec slice.
4. Legacy supervisor and user-role journal entries receive no compatibility reader. Affected old sessions become unreadable.
