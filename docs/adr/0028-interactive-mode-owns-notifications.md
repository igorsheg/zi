# ADR 0028: Interactive mode owns notifications

## Status

Accepted

## Context

Zi needs passive, updateable notices for long-running work and completion events without turning those notices into transcript messages or triggering model turns. The desired interaction follows Fidget: keyed replacement, grouped severity annotations, finite or persistent lifetimes, bottom-right upward stacking, suppression, and bounded history.

The notification surface is terminal-specific. `AgentSession` must not import OpenTUI or retain presentation state. A session screen is also too short-lived: interactive session replacement destroys and recreates it, while application notices may remain relevant across that replacement.

TTL expiry needs a wake source when the renderer would otherwise become idle. An independent interval or polling scheduler would compete with the renderer lifecycle and violate Zi's terminal hot-path policy.

## Decision

`InteractiveMode` creates and disposes one `NotificationCenter`. The center is the sole owner of active groups, keyed items, removed history, suppression, expiry admission, the retained OpenTUI surface, renderer listeners, and its live request.

The surface is attached to the current transcript region, which places it at the bottom-right of the editor-equivalent area above the composer. Before a screen replacement, the mode detaches the surface; after constructing the new screen, it reattaches it. A screen never disposes the notification renderable.

Finite TTLs acquire one renderer live request. The center checks expiry on renderer frame events and releases the request as soon as no finite item remains. Persistent items do not keep rendering live. The visible surface is one retained text node whose content changes only when its bounded presentation changes.

The public client API preserves Fidget's high-value call and option shape:

- `notify(message, level?, options?)`, including `null` keyed updates;
- `key`, `group`, `annote`, `hidden`, `ttl`, `update_only`, `skip_history`, and `data`;
- explicit close, clear, remove, suppress, reset, group configuration, and bounded history operations.

Zi bounds active items, visible items, history, text, keys, and attached JSON data. JSON admission is bounded during traversal as well as after serialization. A zero history size disables removed history; it never means unbounded retention. Neovim-specific echo history is not part of the client-independent contract.

An internal presenter may claim one notification group through a private center capability and an explicit capacity. The claim is the exclusive mutation authority for that group and is released by the presenter that acquired it. Public clear, reset, removal, and configuration operations cannot mutate claimed groups. Caller-owned items and producer-owned items occupy separate bounded partitions, so generic eviction cannot silently diverge a durable internal projection from a presenter's retained signature. Claimed capacities sum to at most 128; together with the maximum caller partition, the center retains at most 256 active items.

`SystemNotificationPresenter` claims `zi.system` for passive mode and session outcomes. Persistent startup/configuration diagnostics are replaced or removed when their authoritative condition changes; all system keys are cleared at session generation changes before the new session is projected. Automatic-compaction failure persists until successful compaction, selection-copy failure is removed by successful delivery, and background-shell capacity refusal is finite. `/reload` keeps its admitted `Reloading…` transition in prompt status and publishes only the settled outcome. Prompt components receive only the narrow operations they need, never the unrestricted notification API.

## Consequences

- Notifications remain passive presentation and cannot autonomously start a model turn.
- Keyed progress can update without transcript churn or renderable replacement.
- A mode-owned presenter projects passive system outcomes into one producer-owned bounded group without copying transcript content.
- Prompt feedback remains the foreground workflow channel; passive diagnostics no longer overwrite it.
- Session-screen replacement preserves notification state without split ownership.
- Other clients may define their own notification transport later; this ADR does not add presentation state to `AgentSession` or the extension protocol.
- Extension-facing notifications require a separate client-independent event contract before they can use this surface.
