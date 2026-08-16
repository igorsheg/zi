# Research: replace Zi's subagent control plane with Codex v2 semantics

## Scope

Replace Zi's profile-driven, depth-one, ephemeral subagent supervisor with a root-scoped durable agent tree aligned with `openai/codex` commit `a95a6fe333c276623ef172f9f7825ac2790be184`.

This research covers the coding-agent control plane only: ownership, durable identity, context forks, residency, execution admission, messaging, completion, restoration, and shutdown. The `/agent` terminal experience is deliberately outside the first implementation sequence.

## Conclusion

Zi should keep its in-process `AgentSession` substrate and replace the control plane as a clean cut.

The current `SubagentSupervisor` makes a live in-memory child, a routable subagent, and an admitted work cycle the same lifetime. Codex v2 separates three facts:

- a durable agent remains part of the root tree after its runtime unloads;
- a resident session owns loaded conversation and executable resources;
- an active turn consumes execution capacity.

Adding persistence and recursive paths to the existing supervisor would mirror state across the parent journal, child sessions, and its live/exited maps. The replacement owner must make the durable tree authoritative and derive residency and active-turn projections from it.

Alignment means porting Codex's domain model and product behavior, not its known reliability defects. At the pinned commit, Codex's mailbox is in-memory and unbounded, a failed final-answer delivery is logged and dropped, active-turn admission is not atomic with permit acquisition, and graph persistence failures do not transactionally reject the corresponding in-memory transition. Zi should retain bounded durable mail, acknowledged delivery, atomic reservation, and transactional publication.

## Current Zi flow

```text
production AgentSession
  -> SubagentSupervisor
    -> flat name reservation
    -> SubagentChild
      -> ephemeral child AgentSession
        -> in-memory SessionManager
        -> child shell, Code Mode, extension host
    -> CompletionLedger
      -> parent subagent_work_result
      -> hidden parent completion context
```

Evidence:

- `packages/coding-agent/src/sdk.ts:145-162` constructs one `SubagentSupervisor` while creating an `AgentSession`.
- `packages/coding-agent/src/subagents/supervisor.ts:129-180` owns creations, flat names, live children, the FIFO queue, exited snapshots, and the completion ledger.
- `packages/coding-agent/src/subagents/session.ts:26-30` creates each child with `SessionManager.create(..., { persist: false })`.
- `packages/coding-agent/src/subagents/child.ts:21-38` makes idle, queued, running, interrupting, closing, and exited one child lifecycle.
- `packages/coding-agent/src/subagents/supervisor.ts:33-34,1066-1084` admits four live children and runs two work cycles through a FIFO queue.
- `packages/coding-agent/src/agent-session.ts:2144-2153` delivers settled child evidence into parent context without starting a parent turn.

The lifecycle is explicit and bounded, but its states describe resident process ownership rather than a durable agent tree.

## Codex v2 control plane

### One root-scoped owner is shared by every agent

Codex creates one `AgentControl` for a root thread tree and shares it with every spawned session. It owns a tree-scoped session identity, the agent registry, residency, execution admission, and rollout budget while holding only a weak reference to the global thread registry.

Evidence:

- `codex-rs/core/src/agent/control.rs:97-117` states the root-tree scope and names the owned collaborators.
- `codex-rs/core/src/agent/control.rs:133-157` constructs and initializes that shared owner.
- `codex-rs/core/src/tools/handlers/multi_agents_spec.rs:752-769` tells the model that spawned agents retain the same tools and may spawn descendants.

Zi needs the same ownership boundary, implemented in its own vocabulary: one root-owned agent tree shared by every `AgentSession` in that tree.

### Durable identity is independent of residency

Codex persists directional open/closed thread-spawn edges and child thread histories. Restoration first reconstructs agent metadata without loading runtimes. Messaging or follow-up work calls `ensure_v2_agent_loaded`, which resumes the stored thread only when required.

Evidence:

- `codex-rs/core/src/agent/control/spawn.rs:135-203` restores persisted v2 descendants into the registry without opening sessions.
- `codex-rs/core/src/agent/control/spawn.rs:257-370` loads persisted history and reconstructs the child runtime on demand.
- `codex-rs/core/src/agent/control/residency.rs:18-34` owns resident LRU order and pending reservations separately from thread metadata.
- `codex-rs/core/src/agent/control/residency.rs:82-108` reserves capacity or rejects when no terminal resident can unload.
- `codex-rs/core/src/agent/control/residency.rs:117-151,226-232` unloads only terminal, inactive children with empty mailboxes.

Zi's `SessionManager` already supplies durable append-only journals and reopening:

- `packages/coding-agent/src/session-manager.ts:405-447` creates, opens, and rebuilds session journals.
- `packages/coding-agent/src/sdk.ts:101-133` restores model, thinking, and active messages from a `SessionManager`.

It does not have a cross-session fork or tree-lineage primitive. `SessionEntry.parentId` is the previous entry in one linear journal, not an agent parent:

- `packages/coding-agent/src/session-manager.ts:46-58,745-751`
- `packages/coding-agent/src/session-manager.ts:1341-1351`

### Spawn is a conversation fork

Codex v2 accepts `fork_turns` as `all`, `none`, or a positive turn count and defaults to `all`. A fork flushes the parent rollout, loads durable model context, optionally truncates it, removes parent-only agent communication and usage hints, and preserves the reference prefix only for a compatible full-history fork.

Evidence:

- `codex-rs/core/src/tools/handlers/multi_agents_spec.rs:631-661` defines the v2 spawn arguments.
- `codex-rs/core/src/tools/handlers/multi_agents_v2/spawn.rs:229-264` resolves `none`, `all`, and positive integers.
- `codex-rs/core/src/agent/control/spawn.rs:650-704` materializes and selects parent history.
- `codex-rs/core/src/agent/control/spawn.rs:705-794` removes inherited agent-only context and handles compacted history.

Zi currently sends only profile instructions plus the explicit task (`packages/coding-agent/src/agent-session.ts:1123-1161`). A reliable port needs a bounded, typed session-fork operation owned beside `SessionManager`, not ad hoc message copying in the agent-tree owner.

### Residency and execution are different limits

Codex separately limits loaded child sessions and active child turns. Starting a turn acquires execution capacity; sending a queue-only message does not. When residency is full, a terminal inactive child can be unloaded before a new or restored child is admitted.

Evidence:

- `codex-rs/core/src/agent/control/execution.rs:14-27` owns active-turn permits.
- `codex-rs/core/src/agent/control/execution.rs:29-72` checks capacity only when a new child turn would start.
- `codex-rs/core/src/config/mod.rs:1496-1507` derives v2 child capacity from the configured root-inclusive thread limit.
- `codex-rs/core/src/agent/control/residency.rs:82-108` owns the independent loaded-session admission.

Zi's two-running/four-live FIFO is internally consistent but not the Codex model. The replacement should derive active count from resident agent turn states, reject over-capacity starts, and unload eligible terminal residents rather than requiring `close_subagent`.

Zi should retain a bounded turn deadline even though it is stricter than Codex. The repository requires bounded asynchronous work, and the existing `subagentWorkTimeoutMs` protects provider and tool failure modes independently of residency.

### Messaging addresses the tree

Codex resolves relative or canonical agent paths against the sender, ensures the target is known, loads it if necessary, and then either queues a message or starts/steers a turn. A follow-up task may not target the root; a queue-only message may.

Evidence:

- `codex-rs/protocol/src/agent_path.rs:17-72,124-145` defines `/root` paths, joins, relative resolution, and name validation.
- `codex-rs/core/src/tools/handlers/multi_agents_v2/message_tool.rs:51-125` resolves, loads, and submits tree-addressed communication.
- `codex-rs/core/src/agent/control.rs:177-267` routes communication through the shared control owner.

Zi's peer relay is reusable evidence for bounded queue-only delivery, but its sibling-only topology must go:

- `packages/coding-agent/src/subagents/peer.ts:4-20,33-67`
- `packages/coding-agent/src/subagents/supervisor.ts:1094-1131`

### Completion is a non-waking message to the direct parent

Codex maps a terminal child turn to a `FINAL_ANSWER` communication addressed to its direct parent. Delivery sets `trigger_turn: false`, so a result joins an active parent's next provider boundary or remains queued for later input.

Evidence:

- `codex-rs/core/src/session/mod.rs:1934-1981` recognizes a terminal v2 child turn.
- `codex-rs/core/src/session/mod.rs:1984-2032` derives the direct parent and submits non-triggering communication.
- `codex-rs/core/src/context/inter_agent_completion_message.rs:18-40` renders the typed final-answer envelope.

Zi already has the correct non-waking parent boundary. Its bounded completion ledger, claim/acknowledgement rules, and durable result should be adapted rather than deleted:

- `packages/coding-agent/src/subagents/completion-ledger.ts:37-180`
- `packages/coding-agent/src/agent-session.ts:2138-2181`

Identity must change from flat `{name, workCycle}` to durable `{agentPath, turn}`. The tree owner, not a resident child object, must own delivery state.

## Clean-cut seam

### Keep

- `AgentSession` model loop, queues, interruption, compaction, extension lifecycle, and parent provider-boundary completion admission.
- `SessionShell`, `CodeMode`, child-scoped `ExtensionHost`, and borrowed process-tree ownership.
- `SessionManager` journal validation, bounds, reopening, and bootstrap projection.
- Completion claim/acknowledgement semantics and bounded result projection.
- Transcript projection over authoritative `AgentSession` messages.
- Work timeout, interruption settlement, shutdown bounds, and runtime invariants.

### Replace

- `SubagentSupervisor` as the authoritative owner.
- `SubagentChild`'s single lifecycle as the durable agent state model.
- `createSubagentSessionFactory`'s unconditional in-memory manager.
- Flat runtime names and parent-local name reservation.
- Four-live/two-running FIFO admission.
- Sibling-only peer routing.
- Mandatory profile selection in the model-facing spawn contract.
- Manual close as the mechanism that releases capacity.

### Adapt

- `CompletionLedger` to durable path and turn identity.
- Parent `subagent_work_result` entries to tree-addressed completion evidence.
- Profile resources into optional Codex-style agent roles; they must no longer gate whether collaboration tools exist.
- Tool details and extension orchestration after the domain contract settles.
- TUI snapshots and transcript sources after the control plane is complete.

## Proposed authoritative states

The program design should use three direct unions rather than extending the current child lifecycle.

```ts
type AgentRecord =
  | { type: "unloaded"; path: AgentPath; sessionId: string; status: TerminalAgentStatus }
  | { type: "loading"; path: AgentPath; sessionId: string; operationId: number }
  | { type: "resident"; path: AgentPath; sessionId: string; session: AgentSession; turn: AgentTurnState }
  | { type: "unloading"; path: AgentPath; sessionId: string; operationId: number }

type AgentTurnState =
  | { type: "idle"; status: AgentStatus }
  | { type: "running"; turn: number; startedAt: number }
  | { type: "interrupting"; turn: number; startedAt: number; requestedAt: number }

type AgentTreeState = { type: "open" } | { type: "stopping" } | { type: "closed" }
```

Exact fields and whether loading/unloading operations live on records or in a separate bounded reservation map remain program-design decisions. The invariant is fixed: durable identity, residency, and active turn cannot be one state machine.

## First vertical slice

The first implementation slice should remain direct-child only while using the final root-scoped owner and durable identity:

```text
persistent parent AgentSession
  -> spawn /root/research with fork_turns=all
    -> durable child SessionManager
    -> child AgentSession runs and settles
    -> non-waking completion reaches /root once
  -> dispose runtime
  -> resume parent
    -> restore /root/research metadata without loading it
  -> follow-up /root/research
    -> load child journal
    -> continue the same conversation
    -> completion reaches /root once
```

This proves the new ownership seam before adding recursive tools, residency eviction, or all-tree communication.

## Verification requirements

- Default full-history fork sees parent instructions, user context, and committed final answers without copying agent-only communication.
- `fork_turns=none` starts from admitted system/resources plus the task, not parent conversation history.
- A positive turn count retains only the requested recent user turns and their outcomes.
- Restart restores path, parent, role, session ID, model, thinking, and terminal status without constructing a child runtime.
- A follow-up loads the stored session and continues its conversation.
- Completion is persisted before delivery and delivered at most once across cancellation and restart.
- Queue-only messages do not start idle work; follow-up tasks do.
- Active-turn admission reserves capacity atomically before publication, and active-turn and resident-session bounds cannot leak permits during spawn, load, interruption, unload, or shutdown.
- Child sessions borrow but cannot dispose the root process tracker.
- Parent shutdown settles resident children before final shared-process disposal.
- A `--no-session` root remains intentionally ephemeral; it does not leave persistent child threads behind.

## Decisions required before program design

1. Adopt Codex's six-tool v2 model contract as a clean cut, removing the current standard profile/list/close tool surface rather than retaining aliases.
2. Convert existing Markdown subagent profiles into optional agent roles, with an implicit default role always available.
3. Adopt Codex's default root-inclusive capacity of four threads, reject new turn starts at capacity, and unload terminal residents automatically.
4. Keep Zi's bounded per-turn work timeout, bounded durable mailbox, acknowledged completion delivery, and transactional graph admission as intentional reliability improvements over Codex.
5. Make child persistence follow the root: durable root means durable descendants; `--no-session` means the complete tree is ephemeral.
6. Defer `/agent` parity until the durable control plane, restoration, and transcript APIs are stable.
