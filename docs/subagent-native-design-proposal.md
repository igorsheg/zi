# Native subagent design proposal

Status: accepted  
Proposed: 2026-07-30  
Accepted: 2026-07-31  
Decision: [ADR 0027](./adr/0027-session-owned-native-subagents.md)

This accepted proposal revisits [`subagent-process-orchestration-spec.md`](./subagent-process-orchestration-spec.md) after the extension spike proved that a parent Zi session can supervise long-lived `zi --mode rpc --no-session` children. It resolves the product question: delegation is a native Zi capability owned by `AgentSession`. Zi uses a required model-authored name plus prompt and does not expose a subagent type or definition catalog to extensions.

## Research sources

The source review used these revisions:

- Grok Build: `xai-org/grok-build` at `a4221165824e5b1f5c4c10b7459f65e78dd6448d`
- OpenAI Codex Rust: `openai/codex` at `2e32d958949792e0747bd9b24293778fec431012`

The repositories are cached under `~/.cache/checkouts/github.com/` by the librarian workflow. Findings below cite source paths rather than relying on product summaries.

## Findings: Grok Build

### Product surface

Subagents are a native, enabled-by-default capability. The model receives a built-in `task` tool. Its input selects:

- a prompt and required short description of three to five words, which the UI retains as the readable task label;
- a named subagent type;
- foreground or background execution;
- capability mode;
- shared workspace or isolated worktree;
- optional model, cwd, and completed-agent resume handle.

Relevant sources:

- `crates/common/xai-tool-types/src/task.rs`
- `crates/codegen/xai-grok-tools/src/implementations/grok_build/task/mod.rs`
- `crates/codegen/xai-grok-pager/docs/user-guide/16-subagents.md`

Background subagents join the existing background-task user experience. `get_task_output`, `wait_tasks`, and `kill_task` operate on commands and subagents, and the tasks pane presents both. Completion may be polled, waited for, or surfaced through an automatic wake when the parent is idle.

Relevant sources:

- `crates/codegen/xai-grok-tools/src/implementations/grok_build/task_output/`
- `crates/codegen/xai-grok-tools/src/implementations/grok_build/kill_task/`
- `crates/codegen/xai-grok-pager/docs/user-guide/20-background-tasks.md`
- `crates/codegen/xai-grok-shell/src/agent/subagent/mod.rs`

### Ownership

Grok does not distribute orchestration among tools. One `SubagentCoordinator` actor is the single writer for pending, active, and completed children, waiters, foreground deadlines, cancellation, completion buffering, and delivery disposition. Tools communicate with it through a channel-backed `SubagentBackend` resource.

A `ChildRunner` trait exists because Grok has multiple real hosts for the same coordinator. The shell adapter creates in-process child sessions and snapshots parent-owned resources such as cwd, model state, MCP connections, hooks, LSP, terminal access, and process scope.

Relevant sources:

- `crates/codegen/xai-grok-tools/src/implementations/grok_build/task/coordinator.rs`
- `crates/codegen/xai-grok-tools/src/implementations/grok_build/task/coordinator_state.rs`
- `crates/codegen/xai-grok-tools/src/implementations/grok_build/task/backend.rs`
- `crates/codegen/xai-grok-shell/src/agent/mvp_agent/subagent_coordinator.rs`

Important behavior:

- the default depth is one;
- foreground calls forward tool cancellation to the child;
- background calls detach from tool cancellation;
- a foreground call exceeding its wait budget becomes background work instead of being killed;
- completed records and pending completion notifications are bounded;
- session teardown cancels its children;
- user Stop cancels non-workflow children and temporarily closes spawn admission;
- send-now interruption keeps background children alive;
- dropping the coordinator cancels all children.

### Extensibility

Grok's plugin seam is declarative. Plugins and user/project configuration contribute named agent definitions, roles, and personas. The native task tool dynamically describes the admitted agent roster; plugin authors do not implement spawning, waiting, cancellation, or completion delivery.

Relevant sources:

- `crates/codegen/xai-grok-agent/src/discovery.rs`
- `crates/codegen/xai-grok-agent/src/config.rs`
- `crates/codegen/xai-grok-pager/docs/user-guide/09-plugins.md`
- `crates/codegen/xai-grok-pager/docs/user-guide/16-subagents.md`

### Lessons for Zi

Adopt:

- native model tool availability;
- one coordinator owner;
- explicit foreground/background ownership transfer;
- bounded completion records;
- concise model-authored names for readable delegation.

Grok's declarative definitions remain useful research evidence, but Zi does not adopt them without concrete enforced role semantics.

Do not copy yet:

- unifying shell tasks and subagents under one task registry: Zi's `SessionShell` already owns shell-process state, and merging unrelated owners would make that module shallower rather than deeper;
- worktree isolation, personas, resume, or inherited live MCP/LSP state before the basic native contract is stable;
- automatic parent wake before Zi has a dedicated bounded subagent mailbox.

## Findings: Codex Rust

### Product surface

Codex MultiAgent V2 exposes native collaboration tools:

- `spawn_agent`;
- `send_message` for queue-only delivery;
- `followup_task` for delivery that starts an idle turn;
- `wait_agent`;
- `interrupt_agent`;
- `list_agents`.

The spawn call requires a model-authored `task_name`, assigns a canonical task path such as `/root/research`, and rejects path collisions. Codex separately assigns a harness-generated nickname from a bounded candidate pool. Spawn may fork all, some, or none of the parent's turn history and may select a role or explicit model. The default prompt policy tells the root model when collaboration exists. Explicit-request-only is the normal mode; Ultra reasoning may use proactive delegation.

Relevant sources:

- `codex-rs/core/src/tools/handlers/multi_agents_spec.rs`
- `codex-rs/core/src/tools/handlers/multi_agents_v2/`
- `codex-rs/core/src/config/mod.rs`
- `codex-rs/core/src/session/multi_agents.rs`

### Ownership

One `AgentControl` is created per root thread tree and cloned into every child. It owns the tree-scoped registry, execution limit, residency, rollout budget, and access to the thread manager. The registry reserves capacity before spawn and releases it on close or runtime death.

Relevant sources:

- `codex-rs/core/src/agent/control.rs`
- `codex-rs/core/src/agent/registry.rs`
- `codex-rs/core/src/agent/control/spawn.rs`
- `codex-rs/core/src/agent/control/execution.rs`
- `codex-rs/core/src/agent/control/residency.rs`

Children are in-process Codex threads rather than subprocesses. Spawn edges and child histories are durable. V2 can restore metadata and lazily reload child threads, which is substantially beyond Zi's current ephemeral RPC-child contract.

### Mailbox semantics

Codex separates queue-only communication from task-triggering communication. A child terminal turn sends a final-answer envelope to its direct parent's mailbox without automatically triggering a parent turn. `wait_agent` waits for mailbox activity, steered user input, or timeout; it does not duplicate message content in its result.

Relevant sources:

- `codex-rs/core/src/tools/handlers/multi_agents_v2/message_tool.rs`
- `codex-rs/core/src/tools/handlers/multi_agents_v2/followup_task.rs`
- `codex-rs/core/src/tools/handlers/multi_agents_v2/wait.rs`
- `codex-rs/core/src/session/mod.rs` (`maybe_notify_parent_of_terminal_turn`)

This is a cleaner baseline than consuming the parent's ordinary queued-input budget for every completion.

### Extensibility and clients

Codex supports built-in and configured roles. Role files are configuration layers that can change model, instructions, tools, permissions, and other child-session settings. The model-facing spawn description is derived from the admitted role catalog.

App-server clients observe subagent threads and collaboration lifecycle items, but MultiAgent V2 rejects direct external turn input to a subagent: inter-agent delivery remains owned by the collaboration control plane.

Relevant sources:

- `codex-rs/core/src/agent/role.rs`
- `codex-rs/core/src/config/agent_roles.rs`
- `codex-rs/app-server/README.md`
- `codex-rs/app-server/src/request_processors/turn_processor.rs`

### Lessons for Zi

Adopt:

- one root/session-scoped control owner shared by every model tool;
- separate queue-only and wake delivery;
- a dedicated mailbox rather than ordinary parent input queues;
- completion notification without automatic turn creation;
- client-neutral lifecycle events and typed tool details;
- session-unique model-authored names that remain readable when used as operational identity.

Codex's configured roles remain a research fact, not a Zi V1 extension surface.

Do not copy yet:

- nested trees;
- durable child conversations and lazy residency;
- parent-history forks;
- canonical agent paths or generated nicknames; Zi uses one parent-session-unique model-authored name as the sole child identity;
- in-process child sessions, which would couple failures and require exposing runtime construction that Zi intentionally keeps private.

## Accepted Zi product

### User experience

Subagents are built into normal Zi. No extension installation or environment variable is required.

```text
zi
```

The model receives the native tools when subagents are enabled:

- `spawn_subagent`;
- `send_subagent` — deliver information without starting a turn;
- `continue_subagent` — assign follow-up work, starting a turn when idle;
- `wait_subagents`;
- `interrupt_subagent`;
- `close_subagent`;
- `list_subagents`.

The current operation set is retained because its queue-only/wake distinction matches Codex's proven mailbox split, and because Zi already has tests for the RPC race at that boundary. Spawn always transfers admitted work to background ownership; callers that want foreground behavior call `wait_subagents`. Zi therefore needs no Grok-style foreground-to-background timer mode.

A concise system-prompt section tells the model:

- delegation is available for independent or context-heavy work;
- trivial work should remain in the parent;
- delegated prompts need concrete output, explicit scope boundaries, and a stopping condition or bounded exploration budget;
- the parent continues non-overlapping local work and waits only when blocked;
- at most four direct children may be live;
- children share filesystem and credential authority;
- `wait_subagents` obtains completed output;
- send delivers information without starting a child turn, while continue assigns work and starts an idle turn.

Subagents are enabled by default. A setting may disable the entire capability, but V1 does not add proactive/explicit collaboration modes.

### Names and deferred roles

`spawn_subagent` requires:

```ts
{
  name: string
  prompt: string
}
```

The model authors a short name such as `reviewer` or `test_runner`. It must be unique for the complete parent session. That name is the child's sole identity: send, continue, wait, interrupt, close, and status operations all use it directly. It is not a role selector.

Every initial child prompt receives the same universal instructions owned by `SubagentSupervisor`, followed by the delegated prompt. Extensions neither register subagent types nor receive procedural orchestration methods.

Grok and Codex prove that configured roles can be useful, but their roles also carry concrete behavior such as model selection, tool policy, permissions, or other child-session settings. Zi defers a role catalog until it has similarly enforced semantics. It must not describe a prompt-only `reviewer` as read-only when child tool filtering does not enforce that restriction.

## Ownership

### State owner

One `SubagentSupervisor` belongs to one `AgentSession`:

```text
AgentSession
├── authoritative parent conversation
├── SubagentSupervisor
│   ├── admission and four-child capacity
│   ├── parent-session-unique names as sole child identities
│   ├── universal initial child instructions
│   ├── child lifecycle transitions
│   ├── ChildZiProcess owners
│   ├── work-cycle revisions
│   ├── bounded completion mailbox and waiters
│   ├── native journal evidence
│   └── bounded shutdown
└── built-in subagent tools (adapters)
```

`AgentSession` owns the capability because its lifetime, tool catalog, interruption policy, journal, and child policy are all session policy. `SubagentSupervisor` remains a deep concrete module; it does not become a generic agent transport or session registry.

`createAgentSession()` creates the supervisor when given a concrete Zi child command and transfers disposal ownership to the returned session. The installed product always supplies that command. Lower-level SDK callers that do not supply a child command get no subagent tools rather than an unusable catalog.

### Child process

Zi retains the proven process architecture:

```text
<current zi command> --mode rpc --no-session --cwd <exact parent cwd>
```

Runtime construction supplies the exact current command, using the same compiled-vs-source resolution already used for extension and Code Mode workers. `ZI_SUBAGENT_EXECUTABLE` is removed from the product contract.

The parent also passes its admitted model and thinking level explicitly so a child does not silently select a different default. Credentials continue through normal Zi credential and provider environment policy. An ephemeral parent API-key override uses a private child-invocation environment value rather than argv; the child captures it for runtime construction and removes it from `process.env` before extensions or shell tools start.

A private invocation marker disables native subagent tools in depth-one children. It is an invocation constraint, not a security boundary.

Each `ChildZiProcess` still owns:

- process and pipe lifetime;
- RPC sequencing and pending requests;
- stderr diagnostics;
- prompt admission serialization;
- idle observation and work-cycle revision;
- graceful EOF and bounded hard termination.

Direct children, depth one, and four live children remain V1 bounds.

### Extension independence

Native subagents do not belong to an extension generation. Reload and extension-worker failure do not alter admitted names, universal child instructions, or child lifetime. Parent session disposal closes all children. This is the main ownership change from ADR 0026.

## Completion mailbox and durability

The supervisor owns a bounded `SubagentMailbox`. It is distinct from the parent's steering/follow-up queues.

When a work cycle settles:

1. the child projects one bounded `SubagentCompletion`;
2. the supervisor appends native subagent lifecycle/completion evidence to the parent journal;
3. after durable admission, the completion becomes available in the mailbox;
4. matching `wait_subagents` callers settle;
5. a later parent turn receives a short generated notice naming children with undelivered results and instructing the model to call `wait_subagents`.

Completion does not automatically start a parent turn in V1. This follows Codex's mailbox behavior and avoids Grok's auto-wake complexity while preserving autonomous spawn and background progress.

`wait_subagents` addresses children by name, captures each requested child's current work cycle, and waits for durable completions from all captured cycles by default. It returns bounded full completions in requested-name order and marks those mailbox items delivered. The model-facing projection returns either the captured completion or current status for each child and hides delivery/work-cycle bookkeeping, so an earlier completion never appears to describe newer running work. Timeout returns current status and never cancels children.

The mailbox and journal evidence are native session data, not `zi.subagent.lifecycle` extension custom entries. The complete child transcript remains authoritative only in the child and is never copied into the parent.

V1 bounds retained from the spike:

- maximum four live children;
- maximum sixteen distinct names per wait;
- configurable thirty-second default tool wait with a one-hour hard maximum;
- maximum 50 KiB model-visible completion per work cycle;
- maximum 8 KiB durable preview;
- bounded terminal/exited projections with oldest-first eviction after durable evidence.

## Cancellation and shutdown

The owner transitions remain explicit:

- cancelling `spawn_subagent` before initial prompt admission closes that child;
- after spawn returns, parent run interruption does not cancel the child;
- `interrupt_subagent` stops active child work but preserves the reusable child process;
- `close_subagent` ends the child process, releases capacity, and returns the lifecycle observed before shutdown as `previous_status` plus the previous completion status when present;
- `/reload` does not affect live children;
- parent session disposal closes all children concurrently under one bounded deadline;
- unexpected child exit produces a failed completion and exited projection.

This deliberately differs from Grok's user Stop behavior. Zi already defines run interruption as stopping active parent work while preserving admitted background work, matching `SessionShell`; native subagents should follow the same product invariant.

The existing extension-worker process scope remains owned by `ExtensionHost`. Native subagent process groups move under `SubagentSupervisor`; they must not be registered as extension descendants. Compiled acceptance must still prove graceful EOF, hard fallback, and no child descendants after forced child termination on all five targets.

## Model and client surfaces

### Model tools

Built-in tool handlers are thin adapters over `SubagentSupervisor`. They contain schemas and model-facing formatting but no lifecycle state.

`spawn_subagent` exposes required `name` and `prompt` fields. The name is bounded, model-authored, unique for the parent session, and used by every later operation. There is no model-facing type catalog.

Universal child instructions are native supervisor policy. Extension catalog publication does not rebuild or customize the native subagent contract.

The tools are admitted before Code Mode captures its immutable catalog, so generated orchestration can call them exactly like other built-ins.

### AgentSession API

`AgentSession` exposes client-neutral snapshots and status needed by clients, rather than exposing the supervisor:

- `subagents`;
- `subagentStatus`, including bounded working and ready names;
- semantic subagent-change events;
- concrete spawn/send/continue/wait/interrupt/close operations only if a non-model client has an actual need.

The initial implementation should add only the snapshot/event surface required by the TUI and built-in tools. Do not pre-build a broad public coding-agent SDK.

### RPC

Zi RPC remains a single-session transport. V1 does not add `agent.*` topology methods. A process client can ask the parent model to use built-in tools and observe normal tool lifecycle plus native subagent events. Direct external orchestration can be reconsidered when a real client requires it.

### TUI

Native tools project concise semantic rows such as `Started Reviewer`, `Finished waiting`, and `Closed Reviewer` through the coding-agent `ToolPresentation` boundary. Typed result details preserve model-facing JSON while keeping protocol names and envelopes out of compact transcript presentation.

The composer rail distinguishes agents working from durable results ready for collection. The TUI reads authoritative `AgentSession` snapshots, status, and semantic notifications. It does not parse tool text, retain child transcripts, or own process state. A tasks pane or child transcript browser remains a later client feature.

## Explicit non-goals for native V1

- nested subagent trees;
- child-to-child messaging;
- durable child conversation resume after parent restart;
- parent-history forks;
- worktree creation or merge policy;
- reduced filesystem, credential, or network authority;
- extension-provided executable runners or transports;
- a generic `AgentTransport`;
- a procedural extension orchestration API;
- automatic completion-triggered parent turns;
- a combined shell/subagent task registry.

## Delivery sequence

1. [x] Accept this direction in ADR 0027 and supersede ADR 0026's extension-generation ownership while retaining its RPC-process and containment decisions.
2. [x] Move `ChildZiProcess`, `SubagentSupervisor`, and local behavior tests into `packages/coding-agent`.
3. [x] Pass the current Zi command through runtime construction and remove `ZI_SUBAGENT_EXECUTABLE` from native product behavior.
4. [x] Make `AgentSession` own supervisor lifetime, native journal evidence, and reload-independent operation.
5. [x] Register the seven built-in tools and add concise delegation prompt policy.
6. [x] Add the dedicated bounded completion mailbox and next-turn completion notice.
7. [x] Require parent-session-unique model-authored names as sole child identity and keep subagent roles out of the extension API and worker protocol.
8. [x] Add client-neutral subagent snapshots and semantic events.
9. [x] Complete local race, cancellation, mailbox, journal, and Code Mode acceptance against mock RPC children.
10. [ ] Pass compiled real-Zi and process-containment acceptance on darwin-arm64, darwin-x64, linux-arm64, linux-x64, and windows-x64, including a real Windows Job Object.
11. [x] Remove the installed/copyable orchestration implementation and its speculative definition-registration surface.

## Decision summary

Zi adopts the shared ownership conclusion from Grok Build and Codex: subagent orchestration is native coding-agent policy. Unlike those systems, Zi V1 uses model-authored names plus prompts and defers declarative roles until they carry concrete enforced semantics.

Zi retains its own process boundary: child Zi sessions remain supervised RPC subprocesses. This preserves fault containment and avoids exposing private runtime construction. The extension spike is therefore not discarded; its process client and state-machine work move behind a native `AgentSession` capability, and its large end-user boilerplate disappears.

The implementation exists locally, but native subagents are not a supported release until compiled acceptance passes on all five targets, including real Windows Job Object containment.
