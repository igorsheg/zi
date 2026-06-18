# mailbox contract

`SessionRuntime + client_protocol` is Zi's client mailbox boundary. Frontends
submit commands and drain sequenced facts. Session mutation remains single-owner.

## owner path

```text
ClientCommand
  -> bounded command queue
  -> SessionRuntime owner step
  -> AgentSession / agent owner mutation
  -> bounded public ClientEvent queue
  -> sequenced EventEnvelope
  -> frontend adapter owner
```

No callback path from a frontend mutates session state. No session callback
mutates TUI/product state.

## command semantics

Commands are owned envelopes. Enqueue acceptance transfers ownership to
`AgentSessionRuntimeHost`; rejection leaves the submitter responsible for
cleanup/reporting.

Current commands:

```text
submit { text, mode }
cancel { target }
queue.clear
snapshot
history_page { before_entry_id }
replay { after, max_events }
switch_session { session_file_name }
shutdown
```

Command queue full is operational pressure: reject/report. It is not success.
Local frontend state may change only after enqueue success.

## event semantics

Every emitted envelope has a monotonically increasing `seq` assigned by the
runtime host.

Events are facts, not state dumps. State-shaped data travels through bounded
`snapshot` or retained replay.

Clients track `last_seq`:

```text
seq == last_seq + 1 -> apply
seq gap             -> request replay after last_seq
replay_gap          -> request snapshot
snapshot            -> reset/rebuild presentation state
```

## backpressure and overflow

Named caps:

- commands: `client_protocol.command_queue_capacity_default`
- client events: `client_protocol.event_queue_capacity_default`
- retained events: `retained_event_count_default` and `retained_event_bytes_default`
- replay batch: `replay_event_count_max`
- snapshot history: item count/per-item/total text caps
- history pages: item count/per-item/total text caps

Policy:

- command queue full: reject command;
- event queue full: retain pending event or emit/drop overflow fact;
- retained encode over byte cap: evict through that sequence and force replay gap;
- replay gap: client must request snapshot;
- frontend transcript/status/tool text: sanitize, split, truncate, or drop at the adapter boundary.

## prompt completion

```text
agent stream terminal
  -> await producer
  -> Agent.finishRun or failRun settlement
  -> afterPromptRunFinished retry/compaction policy
  -> operation_finished { completed | failed | canceled }
```

Operational provider/tool failures are terminal facts. They are surfaced as
assistant error messages and failed operations; they do not crash frontend owner
loops.

## architecture gates

Expected empty:

```sh
rg -n --glob '*.zig' '@import\("(?:\.\./)+(?:coding_agent|runtime|ai|agent)(?:/|\.zig)' src/tui
rg -n --glob '*.zig' '@import\("(?:\.\./)+(?:tui|frontends)(?:/|\.zig)' src/coding_agent
rg -n --glob '*.zig' '@import\("(?:\.\./)+(?:coding_agent|tui|frontends)(?:/|\.zig)' src/agent src/ai src/runtime
rg -n --glob '*.zig' --glob '!src/runtime/**' '(@import\("zio"\)|\bzio\.)' src
rg -n --glob '*.zig' '@import\(".*coding_agent/(AgentSession|event_drain|queue_mirror|session_manager|session_store)\.zig"\)|\bAgentSession\b|\.session\.' src/frontends
```

Expected present:

```sh
rg -n --glob '*.zig' '@import\("zio"\)' src/runtime
rg -n --glob '*.zig' 'pub const (retained_event_(count|bytes)_default|replay_event_count_max|snapshot_history_.*_max)' src/coding_agent/client_protocol.zig
rg -n -U '\.message_end\s*=\s*\.\{[\s\S]{0,250}\.tool_result\b' src/agent/tool_runner.zig
```
