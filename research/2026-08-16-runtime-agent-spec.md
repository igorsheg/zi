# Runtime agent specification and profile removal research

## Approved direction

Zi treats the runtime task message and a concrete execution selection as the durable spawn primitive. User-defined roles and profiles do not participate in AgentTeam identity, restoration, or child construction.

Zi retains exactly three built-in agent types matching Codex v2: `default`, `explorer`, and `worker`. They are closed orchestration labels and model guidance, not user-extensible profile records. The runtime task message still carries the specialist behavior.

Code Mode makes this useful rather than merely simpler. Every admitted tool is projected into the cell's immutable `zi.*` catalog, so a cell can synthesize specialist instructions, spawn agents, retain their paths, wait, filter, and follow up without another orchestration interface. Child sessions already receive their own Code Mode instance and AgentTeam membership; only AgentTeam's direct-child restriction prevents recursive use today.

## Codex v2 reference

Pinned Codex v2 uses a hybrid design rather than requiring a role:

- `codex-rs/core/src/tools/handlers/multi_agents_v2/spawn.rs` always requires `task_name` and `message`; `agent_type` is optional.
- `codex-rs/core/src/tools/handlers/multi_agents_spec.rs` describes `agent_type` as an override to omit unless explicitly requested. It can separately expose per-spawn `model`, `reasoning_effort`, and `service_tier`.
- `codex-rs/core/src/agent/role.rs` resolves `default` when `agent_type` is omitted. Built-in roles include `default`, `explorer`, and `worker`.
- The built-in `explorer` config file is currently empty and `worker` has no config file. Their descriptions guide the spawning model; the dynamic spawn message carries the actual assignment.
- Codex also supports user role config layers, but Zi deliberately does not adopt that extensibility surface.

Zi's current user-defined profile is shallow. Its instructions are prepended to the ordinary task message, its description is tool-schema guidance, and only model/thinking alter execution. Profiles explicitly do not constrain permissions, tools, sandboxing, or authority.

## Current Zi flow

`packages/coding-agent/src/agent-session.ts` builds the active tool catalog and passes it to `CodeMode.createTool(tools)`. `packages/coding-agent/src/code-mode/code-mode.ts` derives the TypeScript `zi.*` interface from each admitted tool's input and output schemas and invokes the same underlying tool owner.

`packages/coding-agent/src/agent-team/tools.ts` currently resolves `agent_type`, prepends profile instructions to `message`, and sends optional `role` plus in-memory `roleSelection` to `AgentTeam.spawn()`.

`packages/coding-agent/src/agent-team/agent-team.ts` journals only the role name. The concrete model/thinking selection lives only on the resident `AgentRecord`.

`packages/coding-agent/src/agent-team/session-factory.ts` therefore has to re-read the current resource and extension role catalogs after restart. A changed or removed profile can alter or prevent restoration.

The child fork journal already retains inherited and selected model/thinking changes. Role instructions also survive because they were embedded in the initial task message. The missing durable fact is the concrete execution selection admitted at spawn.

## Profile substrate

Removing named profiles affects these active surfaces:

- `packages/coding-agent/src/subagent-profiles.ts` and `SessionResources.subagentProfiles`;
- `.zi/subagents` resource discovery and project-trust probing;
- `agent_type` in the model-facing spawn schema and semantic projections;
- `ExtensionAgentRole`, `registerAgentRole`, role catalogs, and `agent_roles_*` worker protocol frames;
- AgentSession catalog merging and collision diagnostics;
- AgentTeam role fields, journal validation, snapshots, and session-factory lookup;
- profile examples, public docs, and compiled acceptance fixtures.

The profile loader is also referenced by the old SubagentSupervisor implementation, but that implementation has no production constructor after the AgentTeam switch.

## Legacy subagent substrate

The old implementation remains under `packages/coding-agent/src/subagents/`:

- `supervisor.ts`
- `tools.ts`
- `tool-details.ts`
- `child.ts`
- `completion-ledger.ts`
- `invariant.ts`
- `session.ts`
- `text.ts`
- `peer.ts`
- timeout policy modules

Its direct users are legacy tests. `peer.ts` appears in `sdk.ts`, but no production caller supplies `peerRelay`; all live construction comes from the old supervisor and tests.

Remaining adapters expose the old vocabulary even though AgentTeam is authoritative:

- `AgentSession.subagentSnapshots()`, `subagentSnapshot()`, and the unimplemented `subagentTranscript()`;
- `subagent_changed` session events consumed by the TUI;
- `ExtensionSubagent*` transport types and `ExtensionSessionOperations.subagents`;
- old `subagent` and `subagent_work_result` session journal writers/readers;
- old RPC and public exports.

The timeout values remain active AgentTeam policy and should move to AgentTeam-owned modules rather than be deleted.

## Durability consequence

Deleting user-defined profiles does not by itself close the durability gap. It closes the catalog-re-resolution path only if every spawn first resolves a concrete built-in agent type and execution selection and AgentTeam journals them before creating the fork.

The durable value should be independent of resource names:

```ts
interface AgentExecutionSpec {
  readonly model: { readonly provider: string; readonly modelId: string }
  readonly thinkingLevel: ThinkingLevel
}

type AgentType = "default" | "explorer" | "worker"

interface AgentSpawnSpec {
  readonly agentType: AgentType
  readonly forkTurns: ForkTurns
  readonly execution: AgentExecutionSpec
}
```

Omitted model/thinking inputs inherit the caller's live selection, but the inherited values become concrete before `agent_spawn_reserved` is appended. Unknown requested models fail before reservation or fork creation.

The root AgentTeam journal remains authoritative. The child journal independently records the same effective model/thinking through normal AgentSession construction, giving restoration a cross-check rather than a second mutable source.

## Recursive topology seam

`AgentTeam.spawn()` currently rejects any sender except `/root`, always captures the root checkpoint, forces `parentPath` to `/root`, and delivers every completion to the root binding.

Recursive admission requires no new model-facing tool. Each member already receives the six AgentTeam tools and Code Mode projection. AgentTeam must instead:

- derive the path, parent session, checkpoint, and generation from the calling member;
- retain the exact resident parent's `SessionManager` while its session is live so a child fork captures the authoritative leaf;
- route completion to the direct parent;
- leave completion pending while the parent is unloaded and deliver it before that parent starts its next turn;
- preserve the existing tree, path, residency, active-turn, mail, and shutdown bounds.

Code Mode supplies recursive orchestration; AgentTeam still owns the graph and all lifecycle transitions.

## Compatibility boundary

Two durable compatibility questions differ:

The approved boundary is a hard deletion. Old AgentTeam records containing user-defined `role` data and older sessions containing `subagent` or `subagent_work_result` entries become unreadable. Zi retains no compatibility parser, writer, public type, or runtime owner for those formats.

This deliberately breaks sessions written by the superseded implementation so the new durable contract has one vocabulary and one restoration path.
