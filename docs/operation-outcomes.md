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
