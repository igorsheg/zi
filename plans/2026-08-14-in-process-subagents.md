# Program design: in-process subagents

Research basis: [`research/2026-08-14-in-process-subagents.md`](../research/2026-08-14-in-process-subagents.md).

## Goal

Replace one Zi RPC process per subagent with parent-owned, depth-one `AgentSession` children. Delete the subprocess transport and its compatibility surface. Preserve durable completion delivery, reusable work cycles, bounded transcript presentation, extension behavior, Code Mode, shell cleanup, and peer collaboration.

The new design admits at most four live children and runs at most two child work cycles concurrently. An idle child without extensions or active tools owns no process, process-tree scope, polling timer, or copied transcript.

## Owner map

| Owner                       | Authoritative state and resources                                                                                                                         |
| --------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Production `AgentRuntime`   | Shared `ZiPaths`, settings, credentials, model registry, resource loader, admitted project configuration, process tracker, worker commands                |
| `SubagentSupervisor`        | Runtime names, four-live/two-running admission, FIFO permit queue, durable work ledger, parent journal entries, exited retention, shutdown                |
| `SubagentChild`             | One child `AgentSession`, child lifecycle, work-cycle identity and deadline, interruption settlement, live transcript projection, child resource disposal |
| Child `AgentSession`        | Conversation, model calls, retry/compaction policy, queues, messages, shell/work-plan events, extension lifecycle                                         |
| Child `ExtensionHost`       | One child-scoped extension generation and worker process when extensions are admitted                                                                     |
| Parent `ProcessTreeTracker` | All process scopes created by parent and child session owners; final disposal only after supervisor shutdown                                              |

No child object owns the shared process tracker. The supervisor knows how to schedule and retain children but does not know how sessions, tools, extensions, or workers are constructed.

## State machines

### Supervisor

```ts
type SupervisorState = { readonly type: "open" } | { readonly type: "stopping" } | { readonly type: "closed" }
```

The supervisor retains a bounded FIFO of runtime names whose child state is `queued`. It derives running count from child states; it does not mirror a counter.

```ts
const maxLiveChildren = 4
const maxRunningChildren = 2
```

Admission rules:

- `spawn` creates and publishes an idle child, reserves cycle 1, then queues its initial task.
- `continue` on an idle child reserves and queues the next cycle.
- `continue` on a queued or running child joins that exact cycle as a follow-up.
- `send` never creates a cycle. It queues context in idle, queued, or running child session state.
- whenever a running child settles or a queued child is cancelled/closed, the supervisor starts FIFO queued children until two are running.
- a queued work-cycle deadline starts only when the child transitions to `running`, matching current prompt-admission behavior.

### Child

```ts
type SubagentChildState =
  | { readonly type: "idle"; readonly nextWorkCycle: number }
  | { readonly type: "queued"; readonly workCycle: number; readonly admittedAt: number; readonly prompt: string }
  | { readonly type: "running"; readonly workCycle: number; readonly startedAt: number }
  | {
      readonly type: "interrupting"
      readonly workCycle: number
      readonly startedAt: number
      readonly requestedAt: number
      readonly reason: "requested" | "work_timeout"
    }
  | { readonly type: "closing"; readonly reason: string; readonly requestedAt: number }
  | { readonly type: "exited"; readonly outcome: SubagentChildExit }
```

`starting` remains a supervisor journal fact while the asynchronous child factory runs; an unpublished child is not a live `SubagentChild`. `spawn_admitting` disappears because there is no remote readiness or prompt-acknowledgement phase.

Allowed transitions:

```text
factory success -> idle
idle -> queued
queued -> running
queued -> idle          interrupt queued work
queued -> closing       close before execution
running -> interrupting
running -> idle         settled cycle
running -> closing
interrupting -> idle    settled interruption
interrupting -> closing
idle -> closing
closing -> exited
```

A child transition commits state before starting its effect. The completion callback is applied only when the state still names the same work cycle.

## Child interface

`packages/coding-agent/src/subagents/child.ts` is the deep module replacing `child-process.ts`.

```ts
export interface SubagentChildSession {
  readonly session: AgentSession
  dispose(reason: ExtensionShutdownReason): Promise<void>
}

export type CreateSubagentChildSession = (request: SubagentChildSessionRequest) => Promise<SubagentChildSession>

export class SubagentChild {
  readonly name: string
  readonly state: SubagentChildState

  snapshot(): SubagentChildSnapshot
  transcript(): SubagentTranscriptSnapshot

  queueCycle(text: string): number
  startQueuedCycle(): void
  send(text: string): Promise<void>
  assign(text: string): "queued" | "follow_up"
  interrupt(): Promise<"interrupted" | "already_idle">
  close(reason?: string): Promise<void>
}
```

The concrete type may combine creation and child construction if implementation locality is better, but the supervisor receives only `CreateSubagentChildSession`. No process command, environment, RPC timeout, or transport type crosses this seam.

`queueCycle(text)` retains the initial task in the `queued.prompt` state. `startQueuedCycle()` commits `running`, invokes `session.prompt(queued.prompt)` without awaiting it, attaches one exact settlement observer, and arms the work deadline. Follow-ups admitted while queued already reside in the child session through `session.followUp` and are consumed behind that prompt. The child emits one typed completion after settlement.

`assign(text)` behaves atomically from child state:

- idle: create a queued cycle;
- queued: `session.followUp(text)` and remain queued;
- running: `session.prompt(text, { streamingBehavior: "followUp" })` and remain in the current cycle;
- interrupting/closing/exited: reject.

The supervisor remains responsible for completion reservation and durable journal admission.

## Completion fold

The RPC `session.await_idle` projection is deleted. On settlement, `SubagentChild` reads the latest authoritative assistant message from `session.messages` and maps its typed stop reason:

| Assistant state | Work result                                           |
| --------------- | ----------------------------------------------------- |
| no assistant    | `failed / missing_assistant`                          |
| `aborted`       | `cancelled`                                           |
| `error`         | `failed / provider_error` with bounded provider error |
| `toolUse`       | `failed / missing_final_answer`                       |
| `pending`       | `failed / incomplete_final_answer`                    |
| otherwise       | `completed`                                           |

The result text is the assistant text fold, clipped once to 50 KiB before supervisor persistence. Work timeout overrides the terminal classification with `work_cycle_timeout`, while retaining partial text.

A queued cycle interrupted before execution settles `cancelled` with no assistant text and returns the child to idle. It does not call `AgentSession.abort()` because no run exists.

## Direct peer collaboration

`PeerMessenger` becomes a child-scoped tool adapter over one direct async relay:

```ts
export type PeerRelay = (
  request:
    { readonly operation: "list" } | { readonly operation: "send"; readonly target: string; readonly text: string },
  signal?: AbortSignal
) => Promise<PeerResult>
```

The supervisor creates a relay closure that captures the sender runtime name. A child cannot supply or override sender identity.

The supervisor still:

- returns at most four live siblings;
- rejects self, unknown, closing, and exited targets;
- bounds text to 64 KiB;
- serializes delivery through the target record;
- awaits target `send`, which reports synchronous queue rejection through a promise and never starts idle work.

Delete request IDs, response correlation, retired requests, frame guards, `peer_request`/`peer_response` RPC variants, and child RPC transport binding. Rename `peer-protocol.ts` to `peer.ts`; it retains only domain types, bounds, and external model-argument validation.

## Session construction

Add `packages/coding-agent/src/subagents/session.ts` as the production child-session constructor. It closes over the already admitted runtime capabilities rather than re-entering CLI construction.

For each child it creates:

1. `SessionManager.create(paths, { persist: false })`;
2. child-scoped `SessionShell` using the shared tracker;
3. child-scoped `CodeMode` using the shared tracker and worker command;
4. a fresh `ExtensionHost` and fresh extension discovery from the admitted `ZiPaths`, project admission, settings, and the current filesystem; explicit parent-only extension paths remain excluded, matching current subprocess behavior;
5. fresh session resources from the shared `ResourceLoader`;
6. built-in coding tools over the child shell;
7. `createAgentSessionWithProcessTreeTracker` in borrowed-tracker mode, depth one, with a direct peer relay;
8. `await session.startExtensionLifecycle("startup")` before returning the child owner.

A lifecycle-start failure disposes the unpublished session, awaits `waitForIdle()`, and unwinds remaining unpublished owners. Successful disposal calls `AgentSession.dispose(reason)` and awaits `waitForIdle()`; the session disposes its shell, Code Mode, extension host, searches, and authentication, but not the borrowed tracker.

## Process-tracker ownership

Replace the implicit "every session disposes its tracker" rule with an explicit construction value:

```ts
export type AgentSessionProcessTree =
  | { readonly type: "owned"; readonly tracker: ProcessTreeTracker }
  | { readonly type: "borrowed"; readonly tracker: ProcessTreeTracker }
```

`createAgentSession()` creates an `owned` tracker. Production parent runtime passes its tracker as `owned`. Child construction passes the same tracker as `borrowed`.

The ownership union is threaded through the SDK constructor and `AgentSessionConfig`. `SessionShell`, `CodeMode`, and `ExtensionHost` continue receiving the raw shared tracker as process-scope collaborators; `AgentSession` stores only `ownedProcessTreeTracker?: ProcessTreeTracker` for final disposal. Borrowed use is visible at construction and cannot be changed later. There is no boolean option, reference count, or generic process manager.

Parent disposal order remains structural without serializing independent cleanup:

```text
AgentSession.dispose
  -> settle together
     - SubagentSupervisor.shutdown -> every child session dispose/wait
     - parent CodeMode.dispose
     - parent ExtensionHost disposal
     - parent SessionShell.dispose
  -> shared ProcessTreeTracker.dispose
```

## Transcript presentation

Delete the raw child session-event buffer and public `subagentSessionEvents()` surface; it has no production consumer and exists to expose the RPC projection.

`SubagentChild` subscribes to typed `AgentSessionEvent`s only to maintain:

- active tool identities and bounded result details;
- a transcript revision;
- presentation change notifications.

Settled messages and streaming text remain authoritative in the child session. `transcript()` returns a cached bounded array of references into `session.messages`, newest 200 and at most 8 MiB, plus `session.streamingMessage` and at most 64 active tools. It never JSON-clones message text. The cached array identity changes only when its visible contents or omission facts change.

On child exit, the supervisor retains the final bounded transcript snapshot. Exited snapshots continue to share the 16 MiB aggregate bound.

## Runtime and CLI deletion

Remove these options and paths entirely:

```diff
 CreateAgentRuntimeOptions
-  subagentCommand
-  internalSubagentDepth
-  internalSubagentEnvironment

 CreateAgentSessionOptions
-  subagentCommand
-  subagentEnvironment
-  internalSubagentDepth
+  createSubagentChildSession
+  peerRelay
```

`packages/cli/src/run.ts` no longer sets a subagent command or reads child-depth/API-key environment markers. `packages/cli/src/main.ts` no longer mutates child API-key environment. Remove the `internal/subagent-invocation` package export.

Depth one is a typed child-construction fact. The child constructor omits `createSubagentChildSession`, so recursive tools cannot exist.

## File-tree change

```diff
 packages/coding-agent/src
 ├── runtime.ts                         # construct shared child-session factory
 ├── runtime-options.ts                 # delete subprocess/depth options
 ├── sdk.ts                             # accept child factory and process ownership union
 ├── agent-session.ts                   # direct peer relay; owned tracker only
 ├── rpc/rpc-mode.ts                    # delete peer frames
 ├── processes/owned-process.ts         # event-driven Bun exit
 └── subagents
-    ├── child-process.ts
-    ├── invocation.ts
-    ├── peer-protocol.ts
+    ├── child.ts                        # child state/work/transcript owner
+    ├── peer.ts                         # direct relay vocabulary
+    ├── session.ts                      # production child-session construction
     ├── supervisor.ts                  # FIFO two-running admission
     ├── tools.ts
     └── ... durable ledger/policy modules unchanged

 packages/coding-agent/test
-├── fixtures/mock-rpc-child.ts
-├── subagent-child-process.test.ts
+├── subagent-child.test.ts
+├── subagent-session.test.ts
 ├── subagent-supervisor.test.ts         # production child factory + faux models
 ├── peer-messenger.test.ts              # direct relay tests
 └── owned-process.test.ts               # event-driven Bun exit

 packages/cli
 ├── src/main.ts
 ├── src/run.ts
 └── test/run.test.ts

 scripts/subagent-compiled-acceptance.ts  # observable behavior, no child-process assumptions
 docs/subagents.md
 docs/settings.md                         # only if concurrency is exposed; current design keeps fixed bound
 CONTEXT.md                               # update owned-process/subagent vocabulary
```

## Vertical implementation slices

### Slice 1: one in-process child cycle

Implement `subagents/session.ts` and `subagents/child.ts` for create, immediate start, completion, transcript, interruption, and close. Wire the supervisor through `CreateSubagentChildSession`, initially without the two-running queue or peer tools.

Delete `ChildZiProcess` and rewrite its vertical test against faux models. Verify one child runs, returns evidence, exposes a bounded transcript, and disposes shell/Code Mode/extensions.

Commands:

```sh
bun test packages/coding-agent/test/subagent-child.test.ts
bun test packages/coding-agent/test/subagent-supervisor.test.ts
bun run --filter @with-zi/coding-agent typecheck
```

### Slice 2: clean transport deletion

Delete child invocation options, CLI environment wiring, subagent RPC peer frames, mock RPC fixture, and process-specific assertions. Convert extension/runtime tests to the production in-process child constructor.

Verify depth one, selected model/thinking, API-key routing, extension profile/tool behavior, Code Mode surface, and durable completion restoration.

Commands:

```sh
bun test packages/coding-agent/test/runtime-extensions.test.ts
bun test packages/coding-agent/test/rpc-mode.test.ts
bun test packages/cli/test/run.test.ts
bun run typecheck
```

### Slice 3: running admission and direct peers

Add `queued`, the FIFO name queue, `maxRunningChildren = 2`, queued cancellation, and scheduler pumping. Replace framed peer messaging with direct relay calls and delete `peer-protocol.ts`.

Verify four live children, no more than two running, FIFO starts, queue-only sends, assignment joining, queued interruption, closing queued children, and shutdown without permit leaks.

Commands:

```sh
bun test packages/coding-agent/test/subagent-child.test.ts
bun test packages/coding-agent/test/subagent-supervisor.test.ts
bun test packages/coding-agent/test/peer-messenger.test.ts
```

### Slice 4: remaining wakeups and product acceptance

Replace Bun's 10 ms exit poll with `Subprocess.exited`. Update compiled acceptance and docs. Do not change process-table containment in this slice.

Verify no periodic exit timer, compiled child behavior, descendant cleanup, package build, and the complete repository.

Commands:

```sh
bun test packages/coding-agent/test/owned-process.test.ts
bun scripts/subagent-compiled-acceptance.ts <compiled-zi>
bun run check
```

## Structural acceptance

The refactor is complete only when:

- repository search finds no `ChildZiProcess`, `ZI_SUBAGENT_DEPTH`, `ZI_SUBAGENT_API_KEY`, `subagentCommand`, child peer RPC frames, or mock RPC child;
- ordinary child creation calls no process spawn function;
- a child with no extensions and no tool work adds no process-tree scope;
- four children may be retained while only two cycles are running;
- closing or interrupting queued/running children releases the next FIFO permit exactly once;
- child disposal cannot dispose the parent process tracker;
- completion, transcript, and TUI presentation bounds remain structural tests;
- compiled interactive and headless subagent acceptance pass;
- `bun run check` passes.

## Explicit non-goals

- No subprocess fallback or migration setting.
- No socket transport, worker-per-child, or child process pool.
- No recursive subagents.
- No public concurrency setting; two running children is a product bound.
- No macOS process-table containment weakening without post-refactor measurements.
- No change to extension-worker, Code Mode worker, or shell-process isolation.
