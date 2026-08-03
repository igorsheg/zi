---
slug: rpc
title: RPC protocol
order: 100
---

# RPC protocol

Zi RPC is a long-lived process protocol over the same authoritative `AgentSession` used by interactive and print modes. Start with the copyable one-shot client in [`examples/rpc/client.ts`](../examples/rpc/client.ts).

```sh
zi --mode rpc --no-session
```

The client writes strict UTF-8 JSONL to stdin and reads JSONL from stdout. Positional prompts are rejected. Diagnostics use stderr and never contaminate protocol stdout.

## Framing and ordering

Every request carries protocol version `1` and a required correlation ID:

```json
{ "version": 1, "id": "state-1", "method": "session.get_state" }
```

Every server frame carries version `1` and a connection-local monotonic `sequence`. The first frame is always `ready`:

```json
{
  "version": 1,
  "sequence": 1,
  "type": "ready",
  "state": {
    "sessionId": "…",
    "activity": { "type": "idle" },
    "model": { "type": "unselected" },
    "thinkingLevel": "off",
    "supportedThinkingLevels": ["off"],
    "steeringMode": "one-at-a-time",
    "followUpMode": "one-at-a-time",
    "queuedInputs": { "steering": [], "followUp": [] },
    "messageCount": 0,
    "compaction": { "type": "idle" },
    "retry": { "type": "idle" },
    "contextUsage": { "type": "unavailable", "reason": "no_model" }
  }
}
```

A successful request receives a correlated response:

```json
{
  "version": 1,
  "sequence": 2,
  "type": "response",
  "id": "state-1",
  "method": "session.get_state",
  "ok": true,
  "result": { "sessionId": "…" }
}
```

Operation failures use `ok: false` with `capacity`, `not_found`, or `operation_failed`. Invalid JSON and rejected request shapes produce `protocol_error` frames and do not close the connection. Invalid UTF-8 and oversized framing are fatal after one `invalid_framing` frame.

`session_event` frames contain source-ordered `AgentSessionEvent` values. Model-change events use the public model projection described below instead of exposing provider configuration or credentials. `entry_appended` explicitly includes `custom`, `custom_message`, and substrate `subagent` journal variants. Message pages include displayed custom messages and omit hidden ones; a hidden custom message's committed entry event remains observable to the trusted process client. Child mechanics add no separate semantic session event.

## Methods

| Method                  | Parameters                                                        | Result                                               |
| ----------------------- | ----------------------------------------------------------------- | ---------------------------------------------------- |
| `session.get_state`     | none                                                              | Current session snapshot                             |
| `session.get_messages`  | `start` defaults to `0`; `limit` defaults to and maxes 100        | Indexed message page, total count, and next start    |
| `session.prompt`        | `delivery`: `direct`, `steer`, `follow_up`, or `continue`; `text` | Admitted delivery                                    |
| `session.interrupt`     | none                                                              | Empty object after interruption settles              |
| `session.await_idle`    | none                                                              | Empty object after current session work settles      |
| `connection.set_events` | `mode`: `all` (default) or `none`                                 | Active event mode                                    |
| `command.list`          | none                                                              | Admitted extension-command descriptors               |
| `command.invoke`        | `name`, bounded raw `arguments` string                            | Optional local feedback after command settlement     |
| `model.list`            | none                                                              | Bounded model descriptors with authentication status |
| `model.select`          | `provider`, `id`                                                  | Selected public model descriptor                     |
| `thinking.list`         | none                                                              | Levels supported by the selected model               |
| `thinking.select`       | `level`; optional `scope`: `global` or `project`                  | Requested, effective, and persisted scope            |

A direct prompt response means the input was admitted, not that provider work completed. Use ordered session events or `session.await_idle` for completion. Steering and follow-up input retain `AgentSession` queue semantics and may be queued before the next direct prompt.

`delivery: "continue"` is decided inside the child `AgentSession`: idle starts a direct run; running queues follow-up into the active run. Aborting, compacting, reloading, failed, and disposed states reject the operation. The response reports only that the continue input was admitted, not that its resulting work settled.

`command.invoke` addresses an admitted extension command directly; it does not parse slash text. Commands are idle-only `AgentSession` operations. Their optional feedback is returned as `{ "message": "…" }` (or `{}`), remains outside the journal and provider context, and may be interrupted with `session.interrupt`. Unknown names return `not_found`. The copyable client exposes `runRpcCommand(...)`, which checks `command.list` before invoking the exact name.

`connection.set_events` is owned by the RPC connection, not `AgentSession`. Admission applies the mode synchronously in input order before its response is emitted. Mode `none` suppresses only `session_event` frames; `ready`, `response`, and `protocol_error` are never suppressed. The compatibility default remains `all`.

RPC remains a transport for one parent session. Profile-driven standard delegation tools and optional extension-defined orchestration appear as ordinary tools; their durable substrate evidence may appear as journal-entry events. RPC deliberately adds no `agent.*` topology methods or direct external subagent control plane.

Public model descriptors contain only `provider`, `id`, `name`, `reasoning`, `input`, `contextWindow`, and `maxTokens`. Catalog results add `configured`. Base URLs, headers, compatibility settings, prices, and credentials do not cross RPC.

Message pages are bounded by both count and encoded bytes. A client should retain the `total` from each response, follow `nextStart`, and restart paging if intervening event sequences indicate the session changed.

## Bounds and lifecycle

- input or output record: 16 MiB;
- prompt text: 8 MiB;
- message page: 100 messages and 8 MiB;
- request ID, model provider, or model ID: 256 bytes;
- command name: 64 bytes; command arguments: 256 KiB;
- ordinary in-flight operations: 32;
- reserved concurrent interruption: 1;
- pending output: 1,024 records and 32 MiB;
- connection settlement: 5 seconds.

Closing stdin means the client has disconnected. Zi stops admitting requests, discards queued input, interrupts active work, waits boundedly, restores protocol resources, and then lets the CLI dispose the session it created. `SIGHUP`, `SIGINT`, and `SIGTERM` follow the same cancellation path and retain the CLI's established exit codes.
