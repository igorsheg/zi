# Client protocol v2

Status: active draft, API-breaking.

This protocol is the durable boundary between the session owner and every
frontend: print, RPC, future TUI, and future extension host. It is not a TUI
state API.

## Shape

Ingress is bounded commands:

```text
CommandEnvelope { id?, command }
```

Egress is bounded facts:

```text
EventEnvelope { seq, id?, operationId?, event }
```

Rules:

- `seq` is assigned by `SessionRuntime` at the single event enqueue site.
- `id` correlates a fact to a client command when applicable.
- `operationId` identifies long-running work and is the stable cancellation
  target.
- Commands are intent. Events are facts.
- Frontends do not mutate session state except by submitting commands.
- stdout RPC output is JSONL event envelopes only; stderr is diagnostics only.

## Commands

```text
submit { text, mode }
  mode = auto | start | enqueue | steer

cancel { target }
  target = active | request_id | operation_id

queue.clear
snapshot
completion_snapshot
replay { after }
switch_session { sessionFile }
shutdown
```

Current implementation notes:

- `submit.mode=auto` starts when idle and steers when active.
- `submit.mode=start` rejects if an operation is active.
- `submit.mode=enqueue` adds a follow-up while active.
- `submit.mode=steer` adds steering text while active.
- `replay` reads the bounded retained event ledger. If `after` is older than
  the retained range, the response is `replay_gap` and the client should request
  `snapshot`.

## Events

Core lifecycle:

```text
operation_started { kind }
operation_finished { reason }
shutdown_started
rejected { code, message }
```

State/sync:

```text
snapshot
completion_snapshot
replay
replay_gap
queue_changed
session_changed
session_info_changed
event_overflow
```

Agent/session facts:

```text
agent_event       raw agent.AgentEvent, lossless agent-loop/tool/message stream
compaction_start
compaction_end
auto_retry_start
auto_retry_end
```

Live updates do not distill `agent.AgentEvent` into bespoke transcript/tool
projections. Tool-call granularity comes from `agent_event` variants such as
`message_update`, `tool_execution_start`, `tool_execution_update`, and
`tool_execution_end`. Snapshot/history state is the bounded reconstruction path:
assistant history items carry final tool calls, and tool-result history items
carry final tool output.

## Wire JSONL

Commands:

```json
{"id":1,"type":"submit","text":"hello","mode":"start"}
{"id":2,"type":"cancel","target":"active"}
{"id":3,"type":"cancel","target":{"operationId":1}}
{"id":4,"type":"queue.clear"}
{"id":5,"type":"snapshot"}
{"id":6,"type":"completion_snapshot"}
{"id":7,"type":"replay","after":42}
{"id":8,"type":"shutdown"}
```

Events are direct envelopes, never string-spliced:

```json
{"seq":1,"id":1,"operationId":1,"event":{"type":"operation_started","kind":"prompt"}}
{"seq":2,"id":1,"operationId":1,"event":{"type":"operation_finished","reason":"completed"}}
```

## Bounds

```text
input line: 64 KiB
output event: 256 KiB
prompt text: 32 KiB
malformed lines before disconnect: 16
command queue: bounded by SessionRuntime options
event queue: bounded by SessionRuntime options
retained event ledger: bounded by event count and encoded byte caps
completion snapshot: item count/id/label/detail byte caps
```

## Replay

`SessionRuntime` retains recently emitted event envelopes as encoded protocol
JSON. Live drain is still single-owner and bounded; the retained ledger is only
for catch-up.

```text
replay { after }
  -> replay { requestedAfter, firstRetainedSeq, lastRetainedSeq, events }
  -> replay_gap { requestedAfter, firstRetainedSeq, lastRetainedSeq }
```

`events` contains complete event envelope objects. Replay responses themselves
are not retained to avoid self-referential growth.

## Non-goals

- No JSON-RPC.
- No HTTP/WebSocket transport.
- No frontend-specific state stores in `coding_agent`.
- No compatibility shims for the removed TUI adapter.
