# Program design: durable agent tree

Research basis: [`research/2026-08-16-codex-v2-subagent-control-plane.md`](../research/2026-08-16-codex-v2-subagent-control-plane.md).

## Goal

Replace `SubagentSupervisor` with one root-scoped `AgentTeam` that owns durable agent identity, resident child sessions, active child turns, tree-addressed mail, completion acknowledgement, restoration, and bounded shutdown.

The replacement keeps Zi's in-process `AgentSession` runtime. It adopts Codex v2's six model-facing operations and context forks while strengthening four reliability properties: every retained collection is bounded, turn capacity is reserved before an effect starts, graph publication is journaled transactionally, and passive completion delivery is durable and idempotent.

The first acceptance path is one persistent direct child: fork the parent's context, finish a turn, restart Zi, restore the child without loading it, assign a follow-up, and admit exactly one completion for each child turn into the parent conversation. Recursive spawning and all-tree routing use the same owner after this path is proven.

## Vocabulary

- An **agent** is one durable non-root record in a root session's tree.
- An **agent path** is its canonical identity, such as `/root/research/indexes`.
- A **resident agent** has a loaded `AgentSession` and child-scoped runtime resources.
- An **active turn** is one admitted child model loop. Residency alone consumes no turn capacity.
- **Mail** is a durable tree-addressed message. A task may start an idle target; a message and a completion never do.
- A **completion** is passive final-answer mail sent to the completing agent's direct parent.
- A **fork** is a new child journal initialized from a bounded projection of its parent's durable conversation.

Existing Markdown profiles become optional **roles**. The implicit default role adds no role-specific prompt, so profile discovery can never make the collaboration tools disappear.

## Owner map

| Owner                  | Authoritative state and resources                                                                                                             |
| ---------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- |
| Root `AgentSession`    | Root conversation, root model turn, root extensions, and final disposal order                                                                 |
| `AgentTeam`            | Canonical paths, durable graph projection, agent records, resident LRU, active-turn admission, pending mail, waits, restoration, and shutdown |
| Resident child owner   | One child `AgentSession`, child shell, Code Mode, extension host, resource generation, and bounded disposal                                   |
| Child `AgentSession`   | One conversation, model calls, compaction, retry policy, message admission, and tool execution                                                |
| Root `SessionManager`  | Linear root journal plus agent graph, turn, mail, and acknowledgement entries                                                                 |
| Child `SessionManager` | Linear child conversation journal and immutable lineage header                                                                                |
| Root process tracker   | Processes from root and resident children; only the root session disposes it after `AgentTeam.shutdown()`                                     |

`AgentTeam` is the deep module. Callers request the six domain operations; they do not load sessions, reserve permits, append graph entries, route mail, or coordinate recovery themselves.

## Bounds

```ts
export const maxAgentThreads = 4 // root inclusive
export const maxResidentAgents = maxAgentThreads - 1
export const maxActiveAgentTurns = maxAgentThreads - 1
export const maxAgentRecords = 64
export const maxAgentDepth = 8
export const maxAgentTaskNameBytes = 64
export const maxAgentPathBytes = 512
export const maxPendingAgentMail = 256
export const maxPendingAgentMailBytes = 4 * 1024 * 1024
export const maxAgentMailTextBytes = 64 * 1024
```

The thread limit bounds expensive loaded sessions and active provider work. The record, depth, path, and mailbox limits separately prevent a long-lived root from accumulating an unbounded durable graph or pending communication after sessions unload.

Turn and wait deadlines continue to come from settings, renamed to `agentTurnTimeoutMs` and `agentWaitTimeoutMs`. Mail and graph entries also remain subject to the existing session journal byte and entry bounds.

## Canonical paths

`packages/coding-agent/src/agent-team/path.ts` owns `AgentPath` parsing and resolution.

```ts
export type AgentPath = string & { readonly __agentPath: unique symbol }

export const rootAgentPath: AgentPath

export function childAgentPath(parent: AgentPath, taskName: string): AgentPath
export function resolveAgentPath(sender: AgentPath, input: string): AgentPath
export function parentAgentPath(path: AgentPath): AgentPath | undefined
export function isAgentPathWithin(path: AgentPath, prefix: AgentPath): boolean
```

A task name contains lowercase ASCII letters, digits, and underscores. Paths are rooted at `/root`; a relative target resolves below the sender's path in the same way as Codex v2, while an absolute target starts at `/root`. Parsing validates segment, depth, and byte bounds before a path enters `AgentTeam`.

A committed path is never reused within one root tree. Failed spawn reservations release their path after recovery or abort. This makes path identity monotonic and keeps mail, turn, and completion references unambiguous.

## Durable journal model

Agent lineage does not use `SessionEntry.parentId`; that field remains the previous record in one linear journal. The root journal gains explicit typed entries.

The existing `appendFileSync` path is not a durable commit point because it does not flush the file. `SessionManager` therefore gains an internal critical-append path for graph, turn, mail, acknowledgement, and agent-mail custom entries: prepare and validate, append through one file handle, `fsync` that handle, and only then mutate the in-memory projection. Ordinary conversation entries retain their current persistence policy. In this program, **journaled** means that critical append has returned; power loss before it returns may reject the operation but may not publish its state.

```ts
type AgentTeamEntryData =
  | {
      readonly type: "agent_spawn_reserved"
      readonly operationId: string
      readonly path: AgentPath
      readonly parentPath: AgentPath
      readonly sessionId: string
      readonly parentSessionId: string
      readonly parentEntryId: string | null
      readonly generation: number
      readonly taskName: string
      readonly forkTurns: ForkTurns
      readonly role?: string
    }
  | { readonly type: "agent_spawn_committed"; readonly operationId: string }
  | { readonly type: "agent_spawn_aborted"; readonly operationId: string; readonly reason: string }
  | {
      readonly type: "agent_turn_reserved"
      readonly operationId: string
      readonly path: AgentPath
      readonly turn: number
      readonly mailId: string
    }
  | { readonly type: "agent_turn_started"; readonly operationId: string; readonly inputEntryId: string }
  | {
      readonly type: "agent_turn_settled"
      readonly operationId: string
      readonly path: AgentPath
      readonly turn: number
      readonly result: AgentTurnResult
    }
  | {
      readonly type: "agent_mail_queued"
      readonly mailId: string
      readonly sender: AgentPath
      readonly target: AgentPath
      readonly kind: "message" | "task"
      readonly text: string
    }
  | { readonly type: "agent_mail_delivered"; readonly mailId: string; readonly targetEntryId: string }
  | {
      readonly type: "agent_completion_delivered"
      readonly path: AgentPath
      readonly turn: number
      readonly targetEntryId: string
    }
```

`agent_turn_settled` is itself the durable completion reservation. It contains the bounded final result and remains pending for the direct parent until `agent_completion_delivered` names the parent's committed custom-message entry. It therefore does not need a second queued-mail copy.

`packages/coding-agent/src/agent-team/journal.ts` performs one strict fold over these entries. It rejects duplicate operation IDs, non-monotonic turns, commits without reservations, path-parent mismatches, starts or settlements without turn reservations, starts after settlement, duplicate settlement, duplicate delivery acknowledgement, mail delivered to the wrong target, and references to unknown records. A reserved turn may settle as a failed start without a `agent_turn_started` entry because no provider effect began. The fold returns durable agent metadata, pending operations, pending mail, pending completions, and the next turn for each path; it never constructs a session.

Critical append failure leaves both the journal projection and `AgentTeam` state unchanged. A failure after an earlier reservation can append an abort on the same critical path; if storage is no longer writable, that reservation remains private and recovery resolves it from the last flushed prefix. Tests distinguish ordinary process restart from injected write, flush, and rename failures.

Legacy `subagent`, `subagent_work_result`, and lifecycle entries remain readable so existing root sessions open and render. New code never appends them, restores their children, or exposes old model tools.

## Child lineage and storage

A child journal header gains immutable lineage independent of graph entries:

```ts
interface AgentSessionLineage {
  readonly rootSessionId: string
  readonly parentSessionId: string
  readonly parentEntryId: string | null
  readonly path: AgentPath
  readonly generation: number
}
```

Persistent child journals live below the root session directory rather than beside resumable root sessions:

```text
<session-directory>/agents/<root-session-id>/<child-session-id>.jsonl
```

This prevents children from appearing as independent root sessions. `SessionManager.createAgentFork()` and `openAgent()` consume the root's immutable cwd-bound `ZiPaths`; no team, child adapter, or caller joins `.zi` or re-reads process cwd. The manager derives the file from the admitted session directory, root session ID, and child session ID, validates the complete journal and image blobs, then verifies its lineage against the committed root graph record before returning it.

An in-memory root produces only in-memory child managers. No temporary file, graph file, or persistent descendant survives `--no-session`.

## Fork module

`packages/coding-agent/src/session-fork.ts` is the narrow module between `AgentTeam` and child journal construction.

```ts
export type ForkTurns = "all" | "none" | number

export interface SessionForkRequest {
  readonly path: AgentPath
  readonly rootSessionId: string
  readonly sessionId: string
  readonly forkTurns: ForkTurns
}

export function createSessionFork(
  parent: SessionManager,
  paths: ZiPaths,
  request: SessionForkRequest
): Promise<SessionManager>
```

`ForkTurns` accepts only `all`, `none`, or a positive safe integer. `SessionManager.captureForkCheckpoint()` synchronously snapshots the leaf ID, model, thinking, and frozen active-entry projection in one JavaScript turn before fork creation yields. Session append, compaction commit, and model mutation already enter through the same manager on the same event loop, so none can interleave inside that method. Selection operates only on the returned checkpoint.

Selection rules:

- `all` copies the parent's active compacted context: the latest compaction summary plus its exact retained tail, or all active messages when no compaction exists.
- `none` copies no conversation messages. Child resources and system instructions are rebuilt normally by the child session factory.
- positive `N` selects the latest `N` complete turns from that same active context. It never resurrects exact entries hidden behind a compaction checkpoint.
- a turn starts at a root user message or a typed agent-task custom message and includes its assistant and tool outcome through the entry before the next turn-starting input. Selection never starts on a `toolResult` or separates a tool call from its result.
- retry-failed assistant entries, excluded bash execution, lifecycle entries, work plans, usage entries, queue-only agent messages, completion envelopes, and other parent-only custom messages are excluded.
- ordinary user messages, turn-starting agent task text, compacted summaries, branch summaries, and final assistant/tool context needed by a selected turn remain. A copied task drops its parent-targeted mail ID and delivery details.
- model and thinking level inherit from the parent checkpoint. An optional role affects instructions, not model identity.
- the spawn task is not copied by the fork; `AgentTeam` admits it as the child's first durable task after graph commit.

Persistent creation is one bounded batch: prepare and validate the complete header, inherited entries, and image blobs; write them to a session-ID-specific temporary path; fsync file and directory; then rename to the final child path. The root spawn reservation exists before this begins, so recovery can identify and remove either a temporary or final uncommitted child journal.

## Transactional spawn

`AgentTeam.spawn()` uses the root journal as a write-ahead log:

```text
validate sender, role, path, bounds, and capacity
  -> append agent_spawn_reserved
  -> create and fsync child fork at deterministic path
  -> validate child lineage against reservation
  -> append agent_spawn_committed
  -> publish unloaded durable record in memory
  -> load child through normal residency admission
  -> reserve and start turn 1 with the spawn task
```

The path is visible to list, route, or wait only after `agent_spawn_committed`. If child creation fails, the owner deletes temporary/final child files, appends `agent_spawn_aborted`, releases the path reservation, and returns a structured spawn error.

On restoration, an uncommitted reservation is never published. Recovery removes its possible child files and appends `agent_spawn_aborted` before accepting new operations. A committed edge whose child header is missing or mismatched remains a known durable record with `status: "failed"`; it is reported explicitly and never silently replaced by a new child.

A failure to append the abort leaves the reservation private and blocks reuse for the lifetime of that owner. Restart repeats bounded recovery from the durable reservation. No in-memory graph transition is published before its corresponding journal commit.

## Agent states

The root is always addressed as `/root` but is not mirrored as a child record. Its resident `AgentSession` is bound exactly once after construction.

```ts
type AgentRecordState =
  | { readonly type: "unloaded"; readonly status: SettledAgentStatus }
  | { readonly type: "loading"; readonly operationId: number; readonly previous: SettledAgentStatus }
  | { readonly type: "resident"; readonly owner: AgentTeamSessionOwner; readonly turn: AgentTurnState }
  | {
      readonly type: "unloading"
      readonly operationId: number
      readonly owner: AgentTeamSessionOwner
      readonly status: SettledAgentStatus
    }

type AgentTurnState =
  | { readonly type: "idle"; readonly status: SettledAgentStatus; readonly nextTurn: number }
  | {
      readonly type: "starting"
      readonly operationId: string
      readonly turn: number
      readonly mailId: string
      readonly reservedAt: number
    }
  | { readonly type: "running"; readonly operationId: string; readonly turn: number; readonly startedAt: number }
  | {
      readonly type: "interrupting"
      readonly operationId: string
      readonly turn: number
      readonly startedAt: number
      readonly requestedAt: number
      readonly reason: "requested" | "turn_timeout" | "shutdown"
    }

type AgentTeamState = { readonly type: "open" } | { readonly type: "stopping" } | { readonly type: "closed" }
```

`SettledAgentStatus` is `not_started`, `completed`, `interrupted`, or `failed`; the result retains the more specific bounded failure reason. Loading and unloading carry the prior settled status because a resident-session effect cannot change durable turn status.

Each record owns one serial operation tail used for load, unload, mail admission, turn start, interruption, and disposal. It prevents two asynchronous effects from becoming competing state machines. State changes still occur synchronously before each effect, and stale completions must match both operation ID and turn.

Allowed residency transitions:

```text
restoration/spawn commit -> unloaded
unloaded -> loading -> resident(idle)
loading -> unloaded                 load failure
resident(idle) -> unloading -> unloaded
unloading -> resident(idle)         disposal failure
resident(any) -> unloaded           bounded shutdown after owned resources settle
```

Allowed turn transitions:

```text
idle -> starting -> running
starting -> idle(failed)             input/start failure
running -> idle(settled)             provider/tool settlement
running -> interrupting -> idle      requested, timeout, or shutdown interruption
```

A restored reserved or started turn without a settlement cannot still be executing. Recovery appends one interrupted settlement, reserves its passive completion, and advances the next turn; it never silently retries a provider call.

## Residency and active-turn admission

The owner maintains a bounded LRU index of resident non-root paths. The record state remains authoritative; the index only selects an eviction candidate.

Loading or spawning reserves a residency slot synchronously before awaiting session construction. If all three child slots are resident or reserved, the owner chooses the least-recently-used agent that is idle, has no pending inbound mail, and is not needed by another operation. It transitions that record to `unloading`, disposes its child owner, and only then loads the target. If no record is eligible, the operation returns `agent_residency_full`.

Active capacity is derived from `starting`, `running`, and `interrupting` states. Starting a task checks the count and commits `idle -> starting` before any journal or session effect can yield. There is no FIFO and no semaphore acquired after publication. At three active child turns, a new task returns `agent_turn_capacity` while queue-only mail remains admissible.

A task sent to an already running target becomes prompt mail for that exact turn and does not consume another slot. A task sent to an idle target reserves a new turn. A message never starts a turn.

## Durable mail and idempotent delivery

`send_message` first appends `agent_mail_queued`; only then may it load and deliver to the target. Pending count and bytes are checked before the append. Mail to a running target is steered at the next model boundary; mail to an idle target is appended without waking it.

Every admitted agent message is a typed custom message containing its stable `mailId`, sender, target, kind, and bounded text. Child journal admission is idempotent by `mailId`. After the target entry is durable, the root appends `agent_mail_delivered` with that entry ID.

The current in-memory `steer` queue is not this seam. `AgentSession.admitAgentMail()` first critical-appends or recognizes the typed custom entry, then either publishes it immediately while idle or queues the already committed entry for publication at the next provider boundary while running. The queue contains entry identity, not a second uncommitted message. Bootstrap already includes a committed entry after restart, so restoration marks that mail consumed without appending it again.

A crash before target admission leaves pending root mail. A crash after target admission but before root acknowledgement finds the same `mailId` in the target journal and appends the missing acknowledgement without adding a second context message. An unloaded target with pending ordinary mail is loaded for prompt delivery; an unloaded parent with only passive completion mail may remain unloaded until it is otherwise needed.

A turn settlement appends `agent_turn_settled` before notifying waiters. Its direct-parent completion envelope uses `{path, turn}` as its stable delivery identity. Delivery to the parent is the same idempotent custom-message admission followed by `agent_completion_delivered`. It never starts a parent turn.

The root session is normally resident, so direct-child completions enter its durable context promptly. Completion acknowledgement survives restart; a settled turn is delivered to its direct parent at most once even if shutdown, restoration, or cancellation races with delivery.

## Turn execution

All tasks enter child context as typed agent-task custom messages rather than anonymous copied user strings. The existing `sendCustomMessage(..., {type: "trigger_turn"})` starts `#drive` too early for transactional publication, so `AgentSession` gains one owner-only turn seam:

```ts
startAgentTurn(
  input: AgentMailInput,
  commit: (entry: CustomMessageEntry) => void
): { readonly entry: CustomMessageEntry; readonly settled: Promise<void> }
```

It validates idle state, critical-appends the idempotent input, invokes `commit` synchronously, then begins and publishes the run before starting `#drive`. The callback appends `agent_turn_started` and commits the team's `starting -> running` transition. If it throws, no provider effect starts; the durable reservation and child input are reconciled as a failed start. This narrow callback is the transaction seam, not a general hook or externally configurable lifecycle event.

Starting an idle agent is ordered as follows:

```text
reserve active capacity and commit starting state
  -> append agent_turn_reserved
  -> AgentSession critical-appends the idempotent task input
  -> synchronous commit callback appends agent_turn_started
  -> commit running state, begin the session run, and arm bounded turn deadline
  -> start the provider effect
  -> observe the exact AgentSession settlement once
  -> fold bounded final result
  -> append agent_turn_settled
  -> commit idle state
  -> deliver passive completion to direct parent
  -> notify waiters
```

If the process ends after task admission but before root `agent_turn_started`, recovery recognizes the reserved operation and child mail ID, then settles it as interrupted. It does not duplicate the task or infer that an unknown provider effect succeeded.

The result fold retains current Zi behavior: no assistant, provider error, missing final answer, incomplete answer, cancellation, and timeout remain distinct. Final text is clipped once before root persistence. The timeout starts when the session turn starts, not while residency is loading.

## Six tool operations

`packages/coding-agent/src/agent-team/tools.ts` creates tools closed over the caller's trusted `AgentPath`; model arguments cannot forge a sender.

| Tool              | Owner operation                                                                   |
| ----------------- | --------------------------------------------------------------------------------- |
| `spawn_agent`     | Create a named child with `fork_turns`, optional role, and initial task           |
| `send_message`    | Queue durable mail without starting an idle turn                                  |
| `followup_task`   | Queue durable task mail; start a turn only when the target is idle                |
| `wait_agent`      | Wait for pending or future caller-session input activity; return no final content |
| `list_agents`     | Return bounded durable tree snapshots, optionally under a path prefix             |
| `interrupt_agent` | Interrupt the current target turn and keep the durable agent addressable          |

`followup_task` rejects `/root`. Relative and canonical paths work from every child, enabling recursion without creating another owner. `list_agents` reads graph and record state without loading sessions. `wait_agent` subscribes to the caller session's bounded input activity before checking pending agent mail, so an already-queued completion returns immediately without moving final content into the tool result.

Tools return structured domain errors for invalid path, unknown target, duplicate child name, role not found, graph capacity, mailbox capacity, turn capacity, residency capacity, non-running interrupt, unavailable child journal, cancellation, and shutdown. Tool adapters format those errors once; lower owners do not return prose variants.

## Session construction seam

`packages/coding-agent/src/agent-team/session.ts` constructs resident child owners from an already selected `SessionManager`.

```ts
export interface AgentTeamSessionOwner {
  readonly session: AgentSession
  dispose(reason: ExtensionShutdownReason): Promise<void>
}

export interface AgentTeamSessionRequest {
  readonly path: AgentPath
  readonly role?: AgentRole
  readonly sessionManager: SessionManager
  readonly team: AgentTeam
}

export type CreateAgentTeamSession = (request: AgentTeamSessionRequest) => Promise<AgentTeamSessionOwner>
```

The production adapter creates the child shell, Code Mode, extension host, resources, tools, and `AgentSession` with the root process tracker marked borrowed. A new fork and a restored journal use the same adapter. The adapter does not choose persistence, derive paths, reserve capacity, or mutate graph state.

SDK construction uses an explicit membership union:

```ts
type AgentTeamMembership =
  | { readonly type: "root"; readonly createChildSession: CreateAgentTeamSession }
  | { readonly type: "member"; readonly team: AgentTeam; readonly path: AgentPath }
```

For a root, `createAgentSessionWithProcessTreeTracker()` constructs `AgentTeam`, adds six root-bound tools, constructs the root `AgentSession`, binds it exactly once, restores pending graph work, and gives the root session ownership of team shutdown. For a member, it reuses the supplied team and adds six tools bound to that member path; it cannot create or dispose another team.

`AgentSession` retains four control-plane responsibilities: idempotent typed mail admission, transactional child-turn start, bounded waiting on its owned pending-input activity, and owned-root shutdown. Mail admission is valid while a parent runs because the committed entry waits for the next provider boundary instead of mutating an in-flight request. `AgentTeam`, not a parallel ledger in the session, still owns durable pending and acknowledged completion identity; the session wait observes only whether admitted input is ready for its current provider boundary.

## Roles

`subagent-profiles.ts` becomes `agent-roles.ts`. Existing admitted Markdown files remain the resource format, but selection is optional:

- omitted role uses the implicit default and only the spawned task/context;
- named roles add their instructions and declared resources;
- unknown roles reject spawn without reserving a path;
- every role receives the same six collaboration tools and may create descendants;
- role catalogs remain bounded and immutable for one resource generation.

The model-facing argument follows Codex's optional `agent_type` field even though Zi's internal domain term is role. There is no `list_subagent_profiles` tool; available role names and descriptions are included compactly in the `spawn_agent` tool description.

## Wait and notification model

The calling `AgentSession` owns a bounded set of active waiters beside its pending-input queue. `wait_agent` installs its waiter before checking for pending agent mail or steered caller input, matching Codex v2's subscribe-then-check ordering. It otherwise settles on later caller-session activity, cancellation, or the configured timeout; it never polls and never returns final content.

Wait settlement removes its listener before resolving. Session disposal rejects remaining waiters, while cancellation removes only the owning invocation's waiter. Durable completion remains journaled before parent mail admission, so observing mailbox readiness never outruns restoration evidence.

## Shutdown

Only the root session owns `AgentTeam.shutdown()`. The terminal client restores its terminal resources before asking the session for bounded settlement. Inside session disposal, team shutdown and independent root-resource disposal may proceed together, but the shared process tracker remains last:

```text
InteractiveMode restores terminal ownership
  -> AgentSession enters disposing
  -> settle together within existing bounds
     - AgentTeam open -> stopping
       - reject new admissions and cancel waiters
       - request interruption for every running child
       - persist settlements; leave root completion pending if root context no longer admits mail
       - dispose resident child owners
       - AgentTeam stopping -> closed
     - dispose root shell, Code Mode, extensions, searches, and authentication
  -> dispose shared process tracker
```

This replaces the current supervisor member of the concurrent disposal set; it does not wait for the team before releasing unrelated root resources. A timed-out child disposal releases no false success state; shutdown reports bounded failure evidence and the shared process tracker performs final process cleanup. Only sessions constructed by the child adapter are disposed by `AgentTeam`. Unloaded durable records own no runtime resource and remain restorable on the next root resume.

## Runtime invariants

`packages/coding-agent/src/agent-team/invariant.ts` observes owner-local facts:

- every committed non-root path has exactly one committed parent edge and matching child lineage;
- spawn reservation reaches exactly one commit or abort;
- a turn reservation reaches at most one settlement with the same path and turn;
- next turn is monotonic per path;
- active and residency reservations never exceed bounds;
- every delivery acknowledgement names one durable target entry with the same stable identity;
- a resident owner is disposed exactly once before the record becomes unloaded or the team closes;
- closed team implies no resident owner, waiter, scheduled deadline, or active turn remains.

These diagnostics do not replace unconditional journal validation, idempotency, capacity checks, or shutdown cleanup.

## File-tree change

```diff
 packages/coding-agent/src/
+├── agent-team/
+│   ├── agent-team.ts          # root-scoped owner and state transitions
+│   ├── path.ts                # canonical path parsing and resolution
+│   ├── journal.ts             # strict durable graph/mail/turn fold
+│   ├── result.ts              # bounded terminal result fold
+│   ├── session.ts             # production resident-session adapter
+│   ├── tools.ts               # six model-facing tool adapters
+│   └── invariant.ts           # owner-local runtime diagnostics
+├── session-fork.ts            # bounded context selection and child journal creation
+├── agent-roles.ts             # optional roles plus implicit default
 ├── session-manager.ts         # lineage header, agent paths, entries, idempotent mail lookup
 ├── sdk.ts                     # root/member membership and tool composition
 ├── runtime.ts                 # production root membership and child adapter
 ├── agent-session.ts           # idempotent mail admission and owned-team shutdown only
 ├── settings-manager.ts        # agent turn/wait settings
 ├── guards.ts                  # compiled guards for new external and stored shapes
 ├── rpc/rpc-mode.ts            # project new journal entries; delete flat subagent projection
 └── index.ts                   # export deliberate public snapshots only
-├── subagent-profiles.ts
-└── subagents/
-    ├── child.ts
-    ├── completion-ledger.ts
-    ├── invariant.ts
-    ├── peer.ts
-    ├── result.ts
-    ├── session.ts
-    ├── supervisor.ts
-    ├── tool-details.ts
-    └── tools.ts

 packages/extension-api/src/
-└── subagents.ts               # flat profile/work-cycle extension contract
+└── agents.ts                  # six tree operations and durable snapshots

 packages/tui/src/interactive/
 ├── session-workspace.ts       # consume agent snapshots, not supervisor snapshots
-├── subagent-activity.ts
+├── agent-activity.ts          # bounded tree activity projection
 └── prompt/                    # rename tool detail rows; no /agent picker in this program

 packages/coding-agent/test/
+├── agent-path.test.ts
+├── agent-team-journal.test.ts
+├── session-fork.test.ts
+├── agent-team.test.ts
+├── agent-team-session.test.ts
+├── agent-team-tools.test.ts
+└── agent-team-integration.test.ts
-├── subagent-child.test.ts
-├── subagent-completion-ledger.test.ts
-├── subagent-session.test.ts
-├── subagent-supervisor.test.ts
-└── peer.test.ts
```

Current presentation tests move only after the authoritative snapshots change. `/agent` navigation, picker, transcript switching, and Codex status-feed parity remain outside this program.

## Implementation slices

### Slice 1: durable direct child across restart

Write failing behavior tests for path validation, journal folding, critical append failure, `all|none|N` fork projection, spawn WAL recovery, transactional turn start, and mail idempotency. Add the minimum `AgentTeam`, session fork, child storage, production child adapter, root SDK membership, and `AgentSession` mail/turn seams needed to pass this acceptance test:

```text
parent context -> spawn /root/research -> child turn settles
-> parent receives completion once -> dispose root
-> reopen root -> restore /root/research unloaded
-> followup_task -> same child journal resumes -> second completion once
```

This slice uses direct children in its tests but already stores canonical paths and shares one team with the child session. The production path switches to `AgentTeam`; it does not add a second backend around `SubagentSupervisor`. In the same slice, compile-time consumers move from supervisor snapshots/events to the initial `AgentSnapshot` projection: SDK/runtime construction, `AgentSession` disposal and events, RPC journal serialization, extension binding, and TUI activity rows. Old source files may remain temporarily unreferenced, but no production import or selectable backend reaches them.

### Slice 2: six-tool contract and recursive routing

Add tool schema tests, relative/canonical path tests, optional role tests, recursive spawn, message versus task behavior, direct-parent completion, list prefix, pending and future mailbox waits, steered-input wake-up, and interrupt. Complete extension operations on the same six domain operations. Remove current profile/list/send/continue/close tools rather than retaining aliases.

### Slice 3: residency and concurrent admission

Add structural race tests for three active turns, residency reservation, LRU eviction, no-eligible-resident rejection, concurrent load of one path, task admission while full, mail admission while full, stale load completion, interruption during start, and turn deadline cleanup. No test uses wall-clock performance thresholds.

### Slice 4: restoration and failure matrix

Inject failure after every spawn, turn, mail, acknowledgement, load, unload, and shutdown journal/effect boundary. Verify deterministic recovery, no duplicate context mail, no capacity leaks, and bounded settlement. Add corrupted graph/lineage guards and `--no-session` acceptance.

### Slice 5: delete the old plane and finish public surfaces

Delete all now-unreferenced `subagents/` implementation and obsolete tests, finish setting and extension type renames, remove legacy presentation adapters, then update `docs/subagents.md`, `docs/cli.md`, `docs/extensions.md`, `docs/sdk.md`, and vocabulary where needed. Keep persisted legacy entry readers, but keep `/agent` UX explicitly out of scope.

## Verification

Run targeted tests after each red-green step:

```sh
bun test --preload ./test/isolate-zi-home.ts packages/coding-agent/test/agent-path.test.ts
bun test --preload ./test/isolate-zi-home.ts packages/coding-agent/test/agent-team-journal.test.ts
bun test --preload ./test/isolate-zi-home.ts packages/coding-agent/test/session-fork.test.ts
bun test --preload ./test/isolate-zi-home.ts packages/coding-agent/test/agent-team.test.ts
bun test --preload ./test/isolate-zi-home.ts packages/coding-agent/test/agent-team-integration.test.ts
```

At slice boundaries:

```sh
bun run --filter @with-zi/coding-agent typecheck
bun run --filter @with-zi/coding-agent test
bun run --filter @with-zi/tui test
bun run --filter @with-zi/cli test
```

Before completion:

```sh
bun run check
bun run build
bun run package:npm
```

Acceptance is behavioral and structural: durable reload continues one child conversation; every completion has one target context entry; active and resident counts never exceed three children; unchanged agent identities survive unload/reload; and no production import references `SubagentSupervisor` or obsolete flat/work-cycle tools.
