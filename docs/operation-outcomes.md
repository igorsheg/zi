---
slug: operation-outcomes
title: Operation outcomes
order: 79
---

# Operation outcomes

An operation outcome is Zi's canonical durable terminal record for one admitted session operation. The session journal owns these records. They are not conversation messages, tool results, delivery receipts, or telemetry events.

Zi records every terminal result—`succeeded`, `failed`, or `cancelled`—through a closed capability-specific variant. A failed result carries a stable low-cardinality error code and may include bounded safe diagnostic text. Successful and cancelled results cannot carry failure fields. Capability variants use named evidence fields rather than an open details object.

Each outcome has a deterministic operation ID. Repeating the same admitted operation cannot append a second native outcome. Normalized projections retain the source journal entry ID and timestamp so analytics can preserve chronology. Optional runtime telemetry may correlate through the operation ID, but telemetry is not durable session state.

Operation outcomes are omitted from provider context and transcript presentation. A hidden context message or an orchestration tool result may deliver evidence derived from an outcome; those projections do not count as additional outcomes.

## Subagent work cycles

The initial variant records terminal subagent work cycles:

- capability: `subagent`
- operation: `work_cycle`
- identity: runtime name plus positive work-cycle number
- evidence: optional profile, bounded preview, original and omitted byte counts, truncation, and duration
- failures: a closed subagent work-cycle error code

The operation ID is deterministically derived from the runtime name and work-cycle number. The subagent supervisor constructs the outcome when its owned child cycle settles, and `SessionManager` validates and appends it before completion delivery is claimable.

Zi still reads legacy `subagent/work_cycle_finished` journal entries. `projectSessionOutcomes(entries)` normalizes both formats, maps unknown legacy failure reasons to `legacy_failure`, and emits at most one outcome per operation ID. A native `operation_outcome` wins when both native and legacy evidence exist. `legacy_failure` is migration-only and cannot be appended as a native failure code.

## Shell background tasks

Zi records a shell task after it enters background ownership, either because `bash` admitted it with `background: true` or because an active foreground command was demoted. Foreground-only commands are not part of this variant.

- capability: `shell`
- operation: `background_task`
- identity: the session shell's generated task ID
- evidence: requested or demoted origin, background-owned duration, and observed output byte count
- failures: non-zero exit, signal, timeout, output limit, or execution failure
- cancellations: explicit kill or session disposal

The operation ID is `shell/background_task/<task-id>`. `SessionShell` constructs exactly one outcome only after process and output settlement; `bash`, `list_tasks`, `task_output`, and `kill_task` do not append outcomes. This prevents repeated observation or a stop request from being counted as another terminal operation.

Background-task outcomes never contain command text, output text, the working directory, spill-file paths, or tool-call IDs. Exit codes and signals appear only in the terminal variants that require them.

Completion delivery is passive: settlement never wakes the model. Zi adds one bounded hidden completion message before the next parent model request unless a committed terminal `task_output` result already delivered the same task evidence. The message carries status, duration, and output-byte metadata—not command or output text—and is durable so resume and compaction do not inject it again.

Use `list_tasks` to recover bounded recent task identities and states without reading their output. `task_output` returns `nextCursor`; pass it back as `cursor` to receive only subsequently observed output. If output advanced beyond the retained preview window, `omittedBytes` reports the gap. These observations and `kill_task` do not append additional operation outcomes.

## Local reports

From a Zi source checkout, inspect bounded outcomes for the current project:

```bash
bun run outcomes
```

JSON is the default, scriptable format. Use `--format text` for a concise terminal report, `--days <count>` or `--since <timestamp>` to select a range, and `--cwd <path>` to inspect another project. Run `bun run outcomes --help` for all bounds and options.

Reports keep result counts, durations, chronology, and capability rows common. Profile, truncation, and subagent failure evidence remains under `subagentWorkCycles`; background-task origins, output-byte summaries, failures, and cancellations remain under `backgroundTasks`. Reports read session journals locally and never index prompt, completion, command, or shell-output text.
