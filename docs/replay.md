# Replay and provider normalization

Replay is a core subsystem, not a provider-specific afterthought.

## The pipeline

Replay-safe behavior comes from keeping five concerns separate:

1. **transport** — bytes in and out
2. **normalization** — provider-specific events mapped into shared semantics
3. **final assembly** — build the final assistant message
4. **replay transform** — decide what prior transcript state should be replayed
5. **replay encode** — write provider-specific input from replay-safe state

## The key rule

Deltas are for UI.
Final item payloads are for persistence and replay.

If provisional streamed state leaks into persisted replay state, bugs follow.

## Provider seam rule

Provider quirks belong in provider seams.

That includes:
- terminal event normalization
- provider-specific replay quirks
- request/response shape differences

It does not belong in:
- the TUI
- generic session accounting
- ad-hoc agent-layer hacks

## Replay rule

Replay should operate on owned, final-state data.

It should decide:
- what messages are kept or dropped
- how tool identities map across turns
- how reasoning/text/tool calls replay
- how provider input should be rebuilt

It should not be mixed with transport serialization or temporary parse scratch.

## Ownership rule

Anything that survives the current parse step must be owned.

Do not let replay data borrow from:
- SSE buffers
- temporary JSON trees
- stack-local builders
- delta-only structures

## Goal

The durable goal is simple:
- provider-specific weirdness stays near the provider
- final assistant state is authoritative
- replay is a deliberate pipeline, not whatever the last stream happened to accumulate
