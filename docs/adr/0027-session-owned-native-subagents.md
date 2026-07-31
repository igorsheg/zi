# ADR 0027: AgentSession owns native subagents

## Status

Accepted. Local implementation exists; supported release remains gated on compiled acceptance on all five release targets.

Supersedes the extension-generation ownership decision in [ADR 0026](0026-subagent-orchestration-supervises-rpc-processes.md). Retains ADR 0026's RPC subprocess, child-process, protocol, bounds, and process-containment decisions.

## Context

The ADR 0026 extension spike proved that one parent Zi session can supervise reusable `zi --mode rpc --no-session` children with queue-only and wake delivery, interruption, bounded waiting, completion projection, and concrete process isolation. It also exposed the cost of placing the product capability in an extension generation:

- users had to install a large orchestration extension to obtain a normal coding-agent behavior;
- extension reload and worker failure owned child lifetime even though the parent session remained alive;
- completion durability used extension custom state despite being native session evidence;
- each extension implementation could redefine process, cancellation, mailbox, and shutdown policy;
- extension code needed executable discovery and orchestration plumbing rather than contributing repository-specific policy.

Research in the accepted [native subagent design](../subagent-native-design-proposal.md) found the same decomposition in Grok Build and Codex: the coding-agent session owns delegation and bounded collaboration state, while plugins contribute declarative child definitions. Zi should adopt that ownership lesson without replacing its proven RPC subprocess boundary with in-process child sessions or a speculative transport abstraction.

## Decision

One `SubagentSupervisor` belongs to one `AgentSession`. `AgentSession` owns whether the capability is admitted, its model tool catalog, semantic events, native journal evidence, completion notice, interruption policy, and final disposal. The supervisor remains the concrete owner of child identity, four-child admission, immutable spawn-time definition snapshots, `ChildZiProcess` instances, work-cycle revisions, the bounded completion mailbox, waiters, retention, and shutdown.

Normal root Zi sessions expose seven built-in model tools when a model, a concrete child Zi command, and enabled settings are available:

- `spawn_subagent`;
- `send_subagent`;
- `continue_subagent`;
- `wait_subagents`;
- `interrupt_subagent`;
- `close_subagent`;
- `list_subagents`.

A private depth marker suppresses these tools in direct children, enforcing the V1 depth-one invocation policy. It is not a security boundary. Lower-level callers that do not supply a child command receive no unusable subagent catalog.

Each child remains a long-lived Zi RPC subprocess:

```text
<current zi command> --mode rpc --no-session --cwd <parent cwd> --model <parent model> [--api-key <ephemeral override>] --thinking <parent level>
```

One `ChildZiProcess` owns process and pipe lifetime, strict RPC sequencing and correlation, pending requests, bounded diagnostics and writes, prompt admission serialization, idle observation, completion projection, graceful EOF, and bounded forced termination. Zi does not add an in-process child adapter or generic `AgentTransport`.

The supervisor owns a bounded native completion mailbox separate from parent steering and follow-up queues. A settled work cycle enters `pending`, appends bounded native `subagent` evidence to the parent session journal, then becomes `durable`; `wait_subagents` returns the bounded completion and marks it `delivered`. A later parent turn may receive a short generated notice for undelivered durable completions, but completion does not start a parent turn. Full child conversations remain authoritative only in their child sessions.

The definition catalog contains the built-in `general` type plus extension registrations made through:

```ts
zi.registerSubagentType({ name, description, instructions })
```

Definitions are policy data, not executable runners. Extension sources are admitted in deterministic precedence order: explicit CLI sources, trusted project sources, then global sources. Earlier registrations win; a duplicate in a later source fails that source's registration. The built-in `general` name cannot be replaced. Reload atomically replaces the available extension definition catalog. A live child retains the immutable definition snapshot admitted at spawn, so reload or extension-worker failure affects only later spawns and never owns native child lifetime.

Native child lifecycle and completion records use session journal entries, not extension custom entries. Restoring a parent session does not recreate child processes; nonterminal prior evidence becomes a bounded `lost` projection.

Zi RPC remains a transport for one caller-owned `AgentSession`. Native subagent tools are part of that session's model tool catalog, and RPC clients may observe ordinary tool lifecycle, `subagent_changed`, and native journal-entry events. V1 adds no `agent.*` topology methods and no direct external subagent control plane.

Native process containment inherits ADR 0026's release requirement. Graceful EOF is primary; forced shutdown must also terminate descendants. The native subagent owner, not `ExtensionHost`, must own the relevant POSIX process-group/descendant tracking or Windows Job Object lifetime. Native subagents do not register their processes as extension-generation descendants.

## Consequences

- Delegation follows the parent session lifetime and survives extension reload after spawn admission.
- Users need no orchestration extension or `ZI_SUBAGENT_EXECUTABLE` product setting.
- Extensions gain a narrow declarative seam without process, RPC, waiter, mailbox, or shutdown authority.
- Completion notices do not consume the parent's bounded queued-input budget or trigger inference automatically.
- Child sessions keep the current user's filesystem, environment, credentials, extension, and network authority. Process isolation is fault containment, not a sandbox.
- V1 remains direct-child only, with at most four live children and no peer messaging, worktree isolation, parent-history fork, durable child resume, or procedural extension orchestration API.
- RPC remains inspectable JSONL and does not become a multi-agent topology service.
- The local implementation and mock-process behavior tests are development evidence only. Release remains blocked until compiled real-Zi acceptance passes on `darwin-arm64`, `darwin-x64`, `linux-arm64`, `linux-x64`, and `windows-x64`, including graceful and forced descendant cleanup through a real Windows Job Object.
