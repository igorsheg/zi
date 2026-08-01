# ADR 0027: AgentSession owns native subagents

## Status

Accepted. Local implementation exists; supported release remains gated on compiled acceptance on all five release targets.

Supersedes the extension-generation ownership decision in [ADR 0026](0026-subagent-orchestration-supervises-rpc-processes.md). Retains ADR 0026's RPC subprocess, child-process, protocol, bounds, and process-containment decisions.

## Context

The ADR 0026 extension spike proved that one parent Zi session can supervise reusable `zi --mode rpc --no-session` children with queue-only and wake delivery, interruption, bounded waiting, completion projection, and concrete process isolation. It also exposed the cost of placing the product capability in an extension generation:

- users had to install a large orchestration extension to obtain normal coding-agent behavior;
- extension reload and worker failure owned child lifetime even though the parent session remained alive;
- completion durability used extension custom state despite being native session evidence;
- each extension implementation could redefine process, cancellation, mailbox, and shutdown policy;
- extension code needed executable discovery and orchestration plumbing rather than contributing repository-specific behavior.

Research in the accepted [native subagent design](../subagent-native-design-proposal.md) found a common ownership lesson in Grok Build and Codex: the coding-agent session owns delegation and bounded collaboration state. Both products also support configured child definitions or roles. Zi preserves that research fact but does not adopt the role catalog. A prompt-only role would suggest model, tool, permission, worktree, or read-only semantics that Zi does not enforce.

## Decision

One `SubagentSupervisor` belongs to one `AgentSession`. `AgentSession` owns whether the capability is admitted, its model tool catalog, semantic events, native journal evidence, completion notice, interruption policy, and final disposal. The supervisor remains the concrete owner of parent-session-unique child names, four-child admission, `ChildZiProcess` instances, work-cycle revisions, the bounded completion mailbox, waiters, retention, universal child instructions, and shutdown.

Normal root Zi sessions expose seven built-in model tools when a model, a concrete child Zi command, and enabled settings are available:

- `spawn_subagent`;
- `send_subagent`;
- `continue_subagent`;
- `wait_subagents`;
- `interrupt_subagent`;
- `close_subagent`;
- `list_subagents`.

`spawn_subagent` requires `{ name, prompt }`. The model authors a short name for readable delegation and presentation. The name is unique for the complete parent session, including closed and restored children, and is the child's sole identity. Every later operation uses that name directly.

The supervisor prepends one universal native instruction policy to every initial delegated prompt. Extensions do not register subagent types, definitions, instructions, runners, or catalogs. Zi defers roles until a concrete requirement has an owner and enforceable behavior, such as model routing, tool filtering, permissions, worktree isolation, or resumable child context.

A private depth marker suppresses the tools in direct children, enforcing the V1 depth-one invocation policy. It is not a security boundary. Lower-level callers that do not supply a child command receive no unusable subagent tools.

Each child remains a long-lived Zi RPC subprocess:

```text
<current zi command> --mode rpc --no-session --cwd <parent cwd> --model <parent model> --thinking <parent level>
```

An ephemeral parent API-key override crosses through a private child-invocation environment value rather than argv. The child CLI captures it for runtime construction and removes it from `process.env` before extensions or shell tools start.

One `ChildZiProcess` owns process and pipe lifetime, strict RPC sequencing and correlation, pending requests, bounded diagnostics and writes, prompt admission serialization, idle observation, completion projection, graceful EOF, and bounded forced termination. Zi does not add an in-process child adapter or generic `AgentTransport`.

The supervisor owns a bounded native completion mailbox separate from parent steering and follow-up queues. A settled work cycle enters `pending`, appends bounded native `subagent` evidence to the parent session journal, then becomes `durable`. `wait_subagents` addresses children by name, captures each requested child's current cycle, waits for every captured cycle by default, returns bounded completions in requested-name order, and marks them `delivered`. Delivery state and cycle numbers remain internal; the model-facing wait projection returns either the captured completion or current status, and list reports only current status plus undelivered result readiness. A later parent turn may receive a short generated notice for undelivered durable completions, but completion does not start a parent turn. Full child conversations remain authoritative only in their child sessions.

Native child lifecycle and completion records use session journal entries, not extension custom entries. Starting evidence records the model-authored name. Restoring a parent session reserves prior names, does not recreate child processes, and projects nonterminal prior evidence as bounded `lost` state.

Zi RPC remains a transport for one caller-owned `AgentSession`. Native subagent tools are part of that session's model tool catalog, and RPC clients may observe ordinary tool lifecycle, `subagent_changed`, and native journal-entry events. V1 adds no `agent.*` topology methods and no direct external subagent control plane.

Native process containment inherits ADR 0026's release requirement. Graceful EOF is primary; forced shutdown must also terminate descendants. `SubagentSupervisor` and `ExtensionHost` own distinct root-scope lifetimes and failure transitions; native subagents do not register their processes as extension-generation descendants. The runtime owns their shared OS observation resource: one asynchronous POSIX process-tree tracker with one scan in flight and one refresh timer, or independent Windows Job Objects with kill-on-close. This removes child-count-proportional synchronous process-table work from the terminal event loop without merging the domain owners.

## Consequences

- Delegation follows the parent session lifetime and is independent of extension reload or worker failure.
- Users need no orchestration extension or `ZI_SUBAGENT_EXECUTABLE` product setting.
- Extension API and worker protocol contain no subagent registration or catalog surface.
- Parent-session-unique model-authored names are both readable collaboration labels and the sole stable operational identity. Pre-release UUID-shaped subagent journal entries are intentionally rejected rather than retained as a second routing scheme.
- Universal child instructions have one native owner and cannot vary by extension.
- Multi-child waits target names and wait for every work cycle captured at admission by default; timeout still returns current state without cancellation.
- `close_subagent` returns the pre-close lifecycle as `previous_status` and previous completion status when present, without model-facing cycle or delivery bookkeeping.
- Completion notices do not consume the parent's bounded queued-input budget or trigger inference automatically.
- Child sessions keep the current user's filesystem, environment, credentials, extension, and network authority. Process isolation is fault containment, not a sandbox.
- V1 remains direct-child only, with at most four live children and no peer messaging, role catalog, worktree isolation, parent-history fork, durable child resume, or procedural extension orchestration API.
- RPC remains inspectable JSONL and does not become a multi-agent topology service.
- The local implementation and mock-process behavior tests are development evidence only. Release remains blocked until compiled real-Zi acceptance passes on `darwin-arm64`, `darwin-x64`, `linux-arm64`, `linux-x64`, and `windows-x64`, including graceful and forced descendant cleanup through a real Windows Job Object.
