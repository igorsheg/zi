# Agent ownership alignment spec

## Target architecture

The runtime stack is:

```text
CLI / app
  -> coding_agent.AgentSession
    -> agent.Agent
      -> agent.Run
        -> stream/tool/provider mechanisms
```

## Ownership boundaries

### `src/agent/`

`src/agent/` owns generic agent runtime behavior. It must not import `src/coding_agent/`.

It owns:

- in-memory agent transcript
- current model
- current reasoning level
- current system prompt
- current tools slice
- run backend hook/config
- active run identity internal to the agent
- cancellation source for the active run
- follow-up queue
- prompt/continue/follow-up/abort state transitions
- agent runtime state projection
- agent event emission
- conversion from `AgentMessage[]` to provider/LLM messages
- one-run loop via `Run`

### `src/coding_agent/`

`src/coding_agent/` owns product/session behavior. It may import `src/agent/`.

It owns:

- command ids and public command API
- durable append/projection/store
- provider/model/settings resolution
- builtin and extension host construction
- cwd/resources/session metadata
- mapping coding-agent commands to `agent.Agent` calls
- wrapping `agent.AgentEvent` as `coding_agent.Event.agent`
- persisting observed agent messages/events
- product diagnostics

It must not own:

- active run execution state
- run cancellation source
- follow-up runtime queue semantics
- provider message conversion
- run backend config shape
- generic agent transcript mutation after a run terminal

## Prohibited shapes

- `coding_agent.AgentSession.active_run`
- `coding_agent.AgentSession.pending_follow_ups`
- `coding_agent.AgentSession.pending_abort`
- `coding_agent.AgentSession.applyRunCompletion`
- `coding_agent.AgentSession.startRun`
- `coding_agent.AgentSession.startNextFollowUpOrIdle`
- `coding_agent.AgentSession.drainAbortControl`
- `coding_agent/run_executor.zig` used by `AgentSession`
- `src/agent/` importing `src/coding_agent/`
- transient `agent.Agent` created per run by `AgentSession`

## Required shapes

- `coding_agent.AgentSession` contains a long-lived `agent.Agent` field.
- `agent.Agent` exposes deterministic command-like methods:
  - `prompt(messages)`
  - `followUp(messages)`
  - `continueRun()`
  - `abort()`
  - `drain()`
  - `state()`
- `agent.Agent` emits all runtime lifecycle events as `agent.AgentEvent`.
- `coding_agent.AgentSession` observes agent events and persists them.
- `agent.Agent` owns and frees cloned message input/follow-up memory.
- `agent.Agent` owns cancellation intent and observes cancellation completion through `agent.Run` terminal events.

## Acceptance criteria

Run all checks from repository root.

### Build/test

```sh
zig fmt src/**/*.zig
zig build test
```

must pass.

### Static ownership checks

These commands must return no matches:

```sh
rg 'active_run|pending_follow_ups|pending_abort|applyRunCompletion|startNextFollowUpOrIdle|drainAbortControl' src/coding_agent/session.zig
rg 'run_executor' src/coding_agent/session.zig
rg '@import\("\.\./coding_agent|@import\("coding_agent' src/agent
```

These commands must return matches:

```sh
rg 'agent: agent_mod.Agent' src/coding_agent/session.zig
rg 'pub fn prompt|pub fn followUp|pub fn continueRun|pub fn abort|pub fn drain|pub fn state' src/agent/agent.zig
```

### Behavioral checks

Existing tests must cover or be updated to cover:

- submitting a prompt runs to completed terminal and returns idle state
- follow-up submitted during a running agent queues and starts after terminal completion
- abort while running transitions through aborting/aborted and clears queued follow-ups
- command rejection remains a coding-agent concern
- durable projection appends run input and terminal output from observed agent behavior
- event order remains command accepted before run started, and run finished before session returns idle

### Deletion criteria

Delete if unused after refactor:

- `src/coding_agent/run_executor.zig`
- stale run completion paths that only existed for `AgentSession` owning active runs

Keep `src/coding_agent/run_completion.zig` only if an external async completion API remains. Otherwise delete it.
