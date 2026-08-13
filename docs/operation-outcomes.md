---
slug: operation-outcomes
title: Operation outcomes
order: 79
---

# Operation outcomes

An operation outcome is Zi's canonical durable terminal record for one admitted session operation. The session journal owns these records. They are not conversation messages, tool results, delivery receipts, logs, or telemetry events.

Every outcome uses one open envelope:

```json
{
  "type": "operation_outcome",
  "id": "journal-entry-id",
  "parentId": "previous-journal-entry-id",
  "timestamp": "2026-08-12T12:00:00.000Z",
  "operationId": "shell/background_task/task-1",
  "capability": "shell",
  "operation": "background_task",
  "result": "succeeded",
  "durationMs": 1250,
  "evidence": { "taskId": "task-1" }
}
```

`result` is `succeeded`, `failed`, or `cancelled`. `id`, `parentId`, and `timestamp` place the outcome in journal chronology. `operationId` identifies the admitted operation; Zi rejects a second outcome with the same operation ID.

The core validates the common envelope and its bounds. Capability and operation names are lowercase identifiers of at most 64 bytes, operation IDs fit in 256 bytes, and durations are non-negative integer milliseconds. `evidence` is bounded `SessionJson`: `null`, a boolean, a finite number, a string, an array, or an object composed recursively from those values. Outcome evidence is limited to 8 KiB of encoded JSON, 32 levels, and 4,096 values.

The producer owns the capability and operation names, the deterministic operation ID, the evidence schema, and the meaning of that evidence. It must exclude secrets and unnecessary user content, choose fields consumers can safely retain, and document any producer-specific interpretation. Adding a producer does not extend a central capability union or the common envelope.

Operation outcomes are omitted from provider context and transcript presentation. A hidden context message or tool result may deliver evidence derived from an outcome; those deliveries do not create another outcome. Runtime telemetry may correlate through `operationId`, but telemetry is not durable session state.

## Events and history

An appended outcome emits both session events:

- `entry_appended` is the raw all-journal event. Its `entry` contains the `operation_outcome` journal entry, just as it contains every other admitted journal entry.
- `operation_outcome` is the semantic terminal event for consumers that only need outcomes.

The outcome carried by `operation_outcome` has the same shape as an item returned by RPC `session.get_outcomes`. Consumers can therefore use one decoder for live and historical outcomes. See [RPC](rpc.md) for paging and protocol bounds.

## Current producers

Zi currently records outcomes for settled subagent work cycles and background-owned shell tasks. Each producer derives its operation ID from its own stable identity and places only bounded, privacy-reviewed facts in `evidence`.

A subagent outcome is recorded when the supervisor's admitted work cycle settles. Hidden completion context and orchestration tool results may deliver the same completion evidence without creating another outcome.

A shell outcome is recorded after a background-owned process and its bounded output settle. Foreground-only commands are not recorded. Observing a task with `list_tasks` or `task_output`, or requesting cancellation with `kill_task`, does not create another outcome. Shell evidence excludes command text, output text, working directories, spill-file paths, and tool-call IDs.

## Local reports

From a Zi source checkout, inspect bounded outcomes for the current project:

```bash
bun run outcomes
```

JSON is the default, scriptable format. Use `--format text` for a concise terminal report, `--days <count>` or `--since <timestamp>` to select a range, and `--cwd <path>` to inspect another project. Run `bun run outcomes --help` for all bounds and options.

Reports aggregate only common envelope fields such as result, duration, chronology, capability, and operation. Evidence remains producer-owned opaque `SessionJson`; generic reports do not interpret it or create capability-specific schemas. Reports read session journals locally and never index prompt, completion, command, or shell-output text.
