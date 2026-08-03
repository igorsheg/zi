---
slug: json-events
title: JSON event stream
order: 90
---

# JSON event stream

Use JSON mode when one finite Zi invocation needs machine-readable progress and settlement:

```sh
zi --mode json "inspect this repo"
```

JSON mode writes UTF-8 JSONL to stdout: one complete object and one LF per record. Human-readable diagnostics use stderr. It requires a selected authenticated model and never opens an interactive login flow.

For a long-lived, bidirectional process connection, use the [RPC protocol](rpc.md) instead.

## Session record

The first record is the session header. It is emitted even for `--no-session` in-memory sessions:

```json
{ "type": "session", "id": "...", "timestamp": "...", "cwd": "..." }
```

The header identifies the session Zi is about to use. It is not a progress event.

## Event records

Subsequent records are source-ordered session events. Common event families include:

```text
agent_start
agent_end
turn_start
turn_end
message_start
message_update
message_end
tool_execution_start
tool_execution_update
tool_execution_end
queue_update
compaction_start
compaction_end
auto_retry_start
auto_retry_end
thinking_level_changed
model_changed
agent_settled
```

Retries and automatic compaction can produce multiple `agent_start` through `agent_end` lifecycles for one prompt. `agent_settled` occurs once after retry and compaction policy for that prompt is complete.

Extension tools and profile-driven subagents appear through the same ordinary tool and session event stream. Extension logs never enter protocol stdout.

## Output contract

Stdout contains only JSONL records. Stderr contains diagnostics such as settings warnings, missing-model errors, and operational frontend failures.

JSON records, pending writes, and retained output are bounded. If Zi cannot serialize or write JSONL safely, it reports an operational error instead of mixing prose into stdout.

## Exit behavior

Assistant failures are represented as normal message and session events. Operational failures of JSON mode itself write a diagnostic to stderr and exit nonzero.

Text mode differs because its artifact is the final assistant text: a final assistant error or abort returns nonzero. See [CLI](cli.md) for mode selection and process exit behavior.
