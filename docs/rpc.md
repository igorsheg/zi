---
slug: rpc
title: RPC protocol
order: 110
---

# RPC protocol

You are building an application or a long-running process that must drive Zi and observe it: send prompts, follow events, page messages, select a model, invoke an extension command. One-shot invocations stop being enough once your process needs to stay attached and correlate its own requests against what Zi actually [admitted](vocabulary.md). See [JSON event stream](json-events.md) for the one-shot alternative when a finite invocation is still enough.

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
    "workPlan": { "revision": 0, "steps": [] },
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

A request ID is connection-local and may identify only one admitted, unsettled operation. Reusing an in-flight ID produces a recoverable `protocol_error` with code `invalid_request` and the matching ID; the duplicate record is not launched, including when it requests the reserved interruption slot. An ID may be reused only after its prior correlated response. Reuse always denotes a new request rather than a replay of the prior result.

`session_event` frames contain source-ordered `AgentSessionEvent` values. Model-change events use the public model projection described below instead of exposing provider configuration or credentials. `entry_appended` is the raw all-journal event and includes `custom`, `custom_message`, `work_plan`, `subagent_work_result`, `background_task_result`, and substrate `subagent` entries. Work results are closed domain records rather than a generic RPC analytics envelope.

Work plan replacements also emit `work_plan_changed`; see [Work plans](work-plans.md) for the replacement and persistence rules. Message pages include displayed custom messages and omit hidden ones; a hidden custom message's committed entry event remains observable to the trusted process client.

## Methods

| Method                  | Parameters                                                 | Result                                               |
| ----------------------- | ---------------------------------------------------------- | ---------------------------------------------------- |
| `session.get_state`     | none                                                       | Current session snapshot                             |
| `session.get_messages`  | `start` defaults to `0`; `limit` defaults to and maxes 100 | Indexed message page, total count, and next start    |
| `session.prompt`        | `delivery`, `text`; optional `completionId`                | Admitted delivery and optional completion revision   |
| `session.interrupt`     | none                                                       | Empty object after interruption settles              |
| `session.await_idle`    | optional `completionId`                                    | Idle settlement and optional bounded completion      |
| `connection.set_events` | `mode`: `all` (default) or `none`                          | Active event mode                                    |
| `command.list`          | none                                                       | Admitted extension-command descriptors               |
| `command.invoke`        | `name`, bounded raw `arguments` string                     | Optional local feedback after command settlement     |
| `model.list`            | none                                                       | Bounded model descriptors with authentication status |
| `model.select`          | `provider`, `id`                                           | Selected public model descriptor                     |
| `thinking.list`         | none                                                       | Levels supported by the selected model               |
| `thinking.select`       | `level`; optional `scope`: `global` or `project`           | Requested, effective, and persisted scope            |

A direct prompt response means the input was admitted, not that provider work completed. Use ordered session events or `session.await_idle` for completion. `session.await_idle` follows the current session operation and is not an ordinary short request-response deadline; clients that need a work budget must own that policy separately and interrupt the session when it expires. Steering and follow-up input retain `AgentSession` queue semantics and may be queued before the next direct prompt.

A client that needs atomic terminal evidence may attach one stable `completionId` to every prompt admitted into the same logical work cycle, then pass that ID to `session.await_idle`. Each prompt joined to active work advances `completionRevision`; `steer` or `follow_up` input admitted while already idle remains queued for a future turn and keeps the settled revision.

The idle response returns the observed revision, final message count, and the latest assistant `message_end` captured for that cycle. Completion text is clipped to 50 KiB and provider error text to 8 KiB.

If input was admitted after an earlier idle observation, its newer admission revision tells the client to issue another idle watch; no transcript paging is needed to recover completion evidence. Omitting `completionId` preserves the generic empty idle response. A no-ID prompt that starts or joins work invalidates any earlier completion watch so unrelated assistant output cannot be attributed to it.

`delivery: "continue"` is decided inside the child `AgentSession`: idle starts a direct run; running queues follow-up into the active run. Aborting, compacting, reloading, failed, and disposed states reject the operation. The response reports only that the continue input was admitted, not that its resulting work settled. Clients using completion watches keep the same `completionId` when a continue belongs to the current logical cycle and choose a new ID when starting a new cycle.

`command.invoke` addresses an admitted extension command directly; it does not parse slash text. Commands are idle-only `AgentSession` operations. Their optional feedback is returned as `{ "message": "…" }` (or `{}`), remains outside the journal and provider context, and may be interrupted with `session.interrupt`. Unknown names return `not_found`. The copyable client exposes `runRpcCommand(...)`, which checks `command.list` before invoking the exact name.

## Application and retry semantics

Rejection before launch is definite non-application. This includes malformed requests, duplicate in-flight IDs, and `capacity` responses. A `command.invoke` response with `not_found` also means no extension command was invoked. These outcomes do not affect an already admitted operation that happens to use the duplicated ID.

Once a valid request is admitted, failure is not an idempotency guarantee. If the connection closes before its correlated response, the client cannot tell whether the operation was applied. An `operation_failed` response says that the operation did not complete normally; it does not promise rollback of effects that occurred before the failure.

In particular, a `session.prompt` may have started work or queued input before its response is lost, and an extension behind `command.invoke` may perform external side effects before it throws or before its response is lost. Retrying either operation can therefore apply it again.

RPC has no response cache or persisted idempotency storage. Clients must use domain evidence such as completion watches, session events, messages, or extension-owned operation keys when they need reconciliation. Reusing the same request ID after any correlated response, including a failure response, starts a new operation and does not retrieve the old response.

`connection.set_events` is owned by the RPC connection, not `AgentSession`. Admission applies the mode synchronously in input order before its response is emitted. Mode `none` suppresses only `session_event` frames; `ready`, `response`, and `protocol_error` are never suppressed. The compatibility default remains `all`.

RPC remains a transport for one parent session. Profile-driven standard delegation tools and optional extension-defined orchestration appear as ordinary tools; their durable substrate evidence may appear as journal-entry events. RPC deliberately adds no `agent.*` topology methods or direct external subagent control plane.

Public model descriptors contain only `provider`, `id`, `name`, `reasoning`, `input`, `contextWindow`, and `maxTokens`. Catalog results add `configured`. Base URLs, headers, compatibility settings, prices, and credentials do not cross RPC.

Message pages are bounded by both count and encoded bytes. A client should retain the `total` from each response, follow `nextStart`, and restart paging if intervening event sequences indicate the session changed.

## Bounds and lifecycle

- input or output record: 16 MiB;
- prompt text: 8 MiB;
- completion ID: 256 bytes;
- completion text/error projection: 50 KiB / 8 KiB;
- message page: 100 messages and 8 MiB;
- request ID, model provider, or model ID: 256 bytes;
- command name: 64 bytes; command arguments: 256 KiB;
- ordinary in-flight operations: 32;
- reserved concurrent interruption: 1;
- pending output: 1,024 records and 32 MiB;
- connection settlement: 5 seconds.

Closing stdin means the client has disconnected. Zi stops admitting requests, discards queued input, interrupts active work, waits boundedly, restores protocol resources, and then lets the CLI dispose the session it created. `SIGHUP`, `SIGINT`, and `SIGTERM` follow the same cancellation path and retain the CLI's established exit codes.
