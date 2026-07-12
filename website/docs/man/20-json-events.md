---
slug: json-events
title: JSON event stream
order: 20
aliases:
  - ndjson
  - agent events
  - AgentSessionEvent
---

# JSON event stream

```sh
zi --mode json "inspect this repo"
```

JSON mode writes UTF-8 NDJSON to stdout: one complete object and one LF per
record. Human-readable diagnostics use stderr. The stream follows Pi's
`AgentSessionEvent` behavior for features shared by Pi and Zi.

## Session record

The first record is the current session header, including for `--no-session`
in-memory sessions:

```json
{"type":"session","version":3,"id":"...","timestamp":"...","cwd":"..."}
```

`parentSession` is present for a derived session. `version` is the durable
session-file version, not a JSON event schema version.

## Base events

Subsequent records are session events. Base agent events have these fields:

```text
agent_start             type
agent_end               type, messages, willRetry
turn_start              type
turn_end                type, message, toolResults
message_start           type, message
message_update          type, message, assistantMessageEvent
message_end             type, message
tool_execution_start    type, toolCallId, toolName, args
tool_execution_update   type, toolCallId, toolName, args, partialResult
tool_execution_end      type, toolCallId, toolName, result, isError
```

`agent_end.messages` contains messages produced by that agent run, not the full
session history. `turn_end.toolResults` contains that turn's tool-result
messages.

## Session policy events

Zi emits these events for supported session behavior:

```text
agent_settled            type
queue_update             type, steering, followUp
compaction_start         type, reason
compaction_end           type, reason, result?, aborted, willRetry, errorMessage?
auto_retry_start         type, attempt, maxAttempts, delayMs, errorMessage
auto_retry_end           type, success, attempt, finalError?
thinking_level_changed   type, level
```

Compaction reasons are `manual`, `threshold`, or `overflow`. A successful
result contains `summary`, `firstKeptEntryId`, and `tokensBefore`.

Retries and automatic compaction can produce multiple `agent_start` through
`agent_end` lifecycles for one prompt. `agent_settled` occurs once after all
session retry and compaction policy for that prompt is complete.

## Exit behavior

JSON mode reports assistant failures through normal message and session events;
an assistant message whose `stopReason` is `error` or `aborted` does not by
itself make the process exit non-zero. An operational failure of JSON mode
itself writes a diagnostic to stderr and exits non-zero. No extra JSON error
record is invented.

Text mode differs: it returns non-zero for a final assistant error or abort.

## Unsupported Pi event sources

Zi does not emit Pi events whose underlying product feature is absent. This
currently includes extension custom-entry `entry_appended` events, session-name
`session_info_changed` events, branch/tree events, and extension-provided
compaction details.
