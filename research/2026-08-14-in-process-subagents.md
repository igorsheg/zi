# Research: move Zi subagents in process

## Decision under review

Replace Zi's one-RPC-process-per-subagent implementation with depth-one `AgentSession` children in the parent process. This is a clean cut: remove the subprocess child implementation and its private invocation, peer framing, CLI wiring, tests, and documentation rather than retaining a fallback backend or compatibility names.

The user outcome is an idle group of subagents that does not keep a Mac awake through child-runtime polling and process-table scans. Active local tool work must remain bounded so four children cannot freely turn into four concurrent test or compiler workloads.

## Current execution flow

```text
AgentSession
  -> SubagentSupervisor.spawn()
    -> ChildZiProcess
      -> spawnOwnedProcess()
        -> Bun.spawn(zi --mode rpc --no-session ...)
          -> createUnboundAgentRuntime()
            -> new ProcessTreeTracker
            -> new ExtensionHost
            -> new SessionShell
            -> new CodeMode
            -> new AgentSession
      <- stdin/stdout JSONL RPC
```

Evidence:

- `packages/coding-agent/src/agent-session.ts:529` makes the supervisor an `AgentSession` owner.
- `packages/coding-agent/src/subagents/supervisor.ts:261-367` resolves model selection and creates one `ChildZiProcess` per runtime name.
- `packages/coding-agent/src/subagents/child-process.ts:226-256` spawns and starts stdout/stderr consumption.
- `packages/coding-agent/src/processes/owned-process.ts:206-223` selects Node or Bun process launch with piped stdio and a detached POSIX process group.
- `packages/coding-agent/src/rpc/rpc-mode.ts:188-359` owns the child-side JSONL connection.
- `packages/coding-agent/src/runtime.ts:73-164` constructs a complete runtime and every per-session process owner.

The parent retains at most four live children (`packages/coding-agent/src/subagents/supervisor.ts:35,270-274`). That is a process-count bound, not an active-work bound: all four children may execute tools concurrently.

## Energy-sensitive machinery

`owned-process.ts` polls each Bun child exit every 10 ms (`packages/coding-agent/src/processes/owned-process.ts:7,226-257`). Four idle subprocess children therefore schedule roughly 400 exit checks per second.

The POSIX process-tree tracker refreshes every 250 ms (`packages/coding-agent/src/processes/process-tree.ts:9,399-406`). On macOS each refresh launches `ps -axo ...` (`packages/coding-agent/src/processes/process-tree.ts:633,683-714`). One retained child scope keeps that parent tracker active while the child is idle. Each child runtime also owns another tracker when its own process owners are active.

The transport also serializes every projected child activity event to JSONL, parses it in the parent, and maintains a second bounded transcript projection (`packages/coding-agent/src/subagents/child-process.ts:874-1069`). Pipes are not the expensive choice; the process and projection machinery around them is.

## Existing owners that an in-process child needs

The following state remains per child:

- `SessionManager` with `persist: false`;
- `AgentSession` and Pi `Agent`;
- `SessionShell`, because shell task identity, output, and disposal are session-scoped;
- `CodeMode`, because its worker generation, state, and trace belong to one session;
- `WorkPlan`, authentication activity, project-file search, retry state, queues, and invariants;
- `ExtensionHost`, when extensions are admitted;
- peer tools and the depth-one peer identity;
- lifecycle deadlines, completion evidence, transcript presentation, and final disposal.

The following process-scoped or immutable capabilities can be shared:

- `ZiPaths` for the already admitted cwd;
- settings, credentials, model registry, and resource loader;
- the admitted project configuration;
- the parent process's `ProcessTreeTracker`, provided the parent remains its sole final-disposal owner;
- extension discovery inputs and worker command;
- Code Mode worker command.

Evidence:

- `packages/coding-agent/src/sdk.ts:71-90` names the inputs required to construct an `AgentSession`.
- `packages/coding-agent/src/sdk.ts:97-242` builds the Agent, work plan, peer tools, supervisor, and session owner from those inputs.
- `packages/coding-agent/src/agent-session.ts:512-565` lists the session-owned capabilities and mutable state.
- `packages/coding-agent/src/agent-session.ts:1873-1934` disposes session process owners and currently performs final process-tracker disposal.

## Extension-host constraint

One `ExtensionHost` cannot serve concurrent parent and child sessions. It permits only one catalog listener and one session-operations binding (`packages/coding-agent/src/extensions/host.ts:1342-1357`), has one `loaded -> started -> stopped` lifecycle, and host disposal terminates the generation (`packages/coding-agent/src/extensions/host.ts:1649-1690`). Sharing it would route child extension operations into the parent session and let either session dispose the other's extension generation.

The current subprocess child independently discovers and starts extensions. `runtime.ts` prepares only the global agent directory and depth/API-key environment for the child (`packages/coding-agent/src/runtime.ts:133-144`), while the supervisor forwards cwd, model, thinking, mode, and tool surface (`packages/coding-agent/src/subagents/supervisor.ts:298-319`). Explicit parent `extensionPaths` are not forwarded today.

An in-process child therefore needs a fresh `ExtensionHost` using the same admitted cwd/global/project discovery rules. That may still mean one extension worker process per child when extensions exist. It does not justify retaining a full Zi child process. With no extensions, an idle child needs no OS process.

## Peer messaging becomes a direct module

Peer messaging currently crosses two serialization layers:

```text
child PeerMessenger
  -> child RPC peer_request frame
    -> parent ChildZiProcess
      -> SubagentSupervisor route
        -> sibling RPC follow-up
```

The request/response IDs, frame guards, retired-response handling, and RPC-mode peer frames exist only because the child is a separate process (`packages/coding-agent/src/subagents/peer-messenger.ts`, `peer-protocol.ts`, and `packages/coding-agent/src/rpc/rpc-mode.ts:225-228,337-351`).

In process, a child-scoped peer tool can call a parent-owned relay directly. The relay still derives the sender from the child instance, enforces the eight-request and 64 KiB bounds, lists only live siblings, and serializes delivery through the target child. Frame validation and correlated response state should be deleted, not adapted.

## Transcript ownership

The child `SessionManager` is authoritative for settled messages and `AgentSession.streamingMessage` is authoritative for the current assistant message. An in-process presentation projection can retain bounded message references and active-tool facts without serializing or copying message text.

The existing public presentation contract can remain: newest 200 messages, 8 MiB per live transcript, and 16 MiB across exited transcripts. The implementation should slice authoritative child messages at snapshot/reconciliation boundaries and retain only the exited bounded snapshot after child disposal.

## Clean-cut removal surface

The design stage should plan deletion of:

- `packages/coding-agent/src/subagents/child-process.ts`;
- `packages/coding-agent/src/subagents/invocation.ts`;
- process-frame portions of `packages/coding-agent/src/subagents/peer-protocol.ts`;
- subagent peer frames from `packages/coding-agent/src/rpc/rpc-mode.ts`;
- `subagentCommand`, `subagentEnvironment`, `internalSubagentDepth`, and their runtime/CLI environment wiring;
- `@with-zi/coding-agent/internal/subagent-invocation`;
- the mock RPC child and subprocess-specific child tests;
- compiled acceptance assertions whose subject is a child Zi process rather than subagent behavior.

There should be no subprocess adapter, feature flag, deprecated option, alias, or compatibility backend after the cut.

## Required invariants after the cut

- The parent `AgentSession` owns every child session and closes children before disposing shared process infrastructure.
- Each child has exactly one explicit lifecycle state and exactly one work-cycle identity.
- A child never owns or disposes the shared process tracker.
- Depth-one children cannot create another supervisor or expose delegation tools.
- At most four children are live and at most two work cycles run concurrently by default.
- Queue admission, cancellation, interruption, shutdown, and disposal remain distinct transitions.
- Work deadlines include time waiting for a running permit only if the design says so explicitly; the current deadline begins after prompt admission.
- Completion evidence remains durable in the parent journal and is delivered at most once.
- Peer delivery remains queue-only and never wakes an idle sibling.
- No idle child without admitted extensions owns an OS process, periodic timer, or process-tree scope.

## Risks to resolve in program design

1. Move final `ProcessTreeTracker` disposal out of child-capable `AgentSession` construction without introducing an ownership boolean or a reference-counted generic manager.
2. Define one narrow child-session factory owned by the production runtime. Avoid teaching `SubagentSupervisor` how to discover extensions or assemble coding tools.
3. Give a child its own `ExtensionHost` without re-reading ambient cwd or bypassing the parent's admitted `ZiPaths` and project trust.
4. Replace RPC-derived idle completion with one authoritative `AgentSession` settlement observation, including provider errors, cancellation, and missing final answers.
5. Preserve transcript structural-performance guarantees using references to authoritative child messages.
6. Introduce the two-running-child admission state without mirroring child lifecycle or creating a second task queue.
7. Remove the 10 ms Bun exit poll for remaining extension, Code Mode, and shell-owned processes using the runtime's exit promise.
8. Treat the macOS process-table scan separately: do not weaken descendant containment merely to improve an idle benchmark. After subprocess children are gone, measure remaining scans with idle extension workers before changing the tracker contract.

## Verification surfaces

- Transition tests through the child module's interface: spawn, queued admission, running, follow-up, interruption, timeout, reuse, close, and parent shutdown.
- Integration tests with faux models proving profile selection, model/thinking inheritance, depth-one tools, completion delivery, Code Mode, shell cleanup, and independent extension lifecycle.
- Structural tests proving two-running/four-live bounds, stable transcript references, bounded exited retention, stale-completion rejection, and no process creation for a child without extensions or tool work.
- Remaining owned-process tests proving event-driven Bun exit settlement.
- Compiled acceptance focused on observable subagent behavior and process cleanup of tool descendants, not the deleted child executable.
- `bun run check` plus the compiled subagent acceptance.
