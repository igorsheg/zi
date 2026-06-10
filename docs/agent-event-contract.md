# agent event contract

`agent.AgentEvent` is a stream of ordered facts. It is not a transcript
snapshot, a model-context container, or a hidden transport for durable state.

## invariants

- Events are facts.
- Snapshots are state.
- Owners hold state.
- Pipes do not smuggle unbounded state.
- Tool display/session facts and model-context projections are separate.

## ownership

`agent.Agent` owns runtime transcript state, active run status, cancellation,
steering/follow-up queues, and tool execution state.

`agent/loop.zig` owns the provider/tool turn loop and emits facts through a
bounded `AgentEventStream`.

`coding_agent.AgentSession` owns product/session policy: persistence, retry,
compaction, prompt resources, builtin tools, and public event drain.

Frontends never observe `agent.AgentEvent` by reaching into `AgentSession` or
`agent.Agent`; they receive it only as `client_protocol.ClientEvent.agent_event`
inside a sequenced `EventEnvelope`.

## allowed event payload shape

Lifecycle events are markers only:

```zig
.agent_start
.turn_start
.turn_end
.agent_end
```

They must not carry transcript, tool results, snapshots, JSON blobs, or large
text. State recovery belongs to snapshots/replay.

Message events carry exactly one message fact:

```zig
.message_start
.message_update
.message_end
```

`message_update` may carry compact streaming partials. Tool-call argument
partials are previews, not full arbitrary JSON payloads.

Tool execution events carry execution facts:

```zig
.tool_execution_start
.tool_execution_update
.tool_execution_end
```

Tool result content is bounded by tool policy. The next model request receives a
separate compact projection, not the public/display payload verbatim.

## model context projection

The generic agent loop may compact tool results before building the next model
request. Current default policy:

- text tool result content is capped to `llm_tool_result_text_bytes_max`;
- a truncation note is appended when text is cut;
- image tool result content is omitted from model context;
- tool result details are stripped.

This is not a substitute for tool output bounds. Tools still own their runtime
output caps.

## failure handling

Operational run failures emit terminal assistant message facts before
`.agent_end`:

```text
message_start assistant(error)
message_end assistant(error)
turn_end
agent_end
```

The owner loop settles the run and emits `operation_finished.failed`; it does not
tear down a frontend loop just because a provider/tool allocation failed.

## regression gates

These should return no matches:

```sh
rg -n '<lifecycle event payload regex>' src
rg -n -U '\.message_start\s*=\s*\.\{[\s\S]{0,600}\.tool_result\b' src/agent src/coding_agent
rg -n --glob '*.zig' '\.message_start\b' src/agent/tool_runner.zig
```
